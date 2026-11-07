// 1円玉の自動検出（OpenCV.js）。タップしなくても、画像の中の楕円から1円玉を探す。
// 手の21点が分かっていれば、手の上の丸（爪・関節）を外し、手の大きさから1円玉の大きさの見当をつける。
// cv は OpenCV.js のモジュール（読み込みは engine.ts）。ここは画像処理だけで、DOM に触らない（Node でも試せる）。

export type CoinEllipse = {
  cx: number; cy: number;       // 中心（元の画像のpx）
  major: number; minor: number; // 長径・短径（px）
  ratio: number; angle: number; // 短径÷長径、傾き（度）
  areaRatio: number; momentMajor: number; pixels: number; // ほかの方法の結果と同じ形にするため
  fitErr: number; coverage: number; score: number;
};

export type CoinHints = {
  hand?: { x: number; y: number }[]; // 手の21点（px）
  prev?: { cx: number; cy: number; major: number }; // 前のフレームの1円玉（動画で追いかけるとき）
  near?: { x: number; y: number };    // タップした点（px）
  minMajor?: number;                  // これより小さい楕円は見ない（px）
};

import { roundSpots, fitCoinAt } from './geometry';

const WORK_LONG_SIDE = 960; // 速さのため、この大きさに縮めて探す

/** 点が多角形の中にあるか */
function inPolygon(p: { x: number; y: number }, poly: { x: number; y: number }[]) {
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const a = poly[i], b = poly[j];
    if ((a.y > p.y) !== (b.y > p.y) && p.x < ((b.x - a.x) * (p.y - a.y)) / (b.y - a.y) + a.x) inside = !inside;
  }
  return inside;
}

/** 凸包（Andrew の方法） */
function hull(pts: { x: number; y: number }[]) {
  const P = [...pts].sort((a, b) => a.x - b.x || a.y - b.y);
  const cross = (o: any, a: any, b: any) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
  const lo: any[] = [], up: any[] = [];
  for (const p of P) { while (lo.length >= 2 && cross(lo[lo.length - 2], lo[lo.length - 1], p) <= 0) lo.pop(); lo.push(p); }
  for (const p of P.reverse()) { while (up.length >= 2 && cross(up[up.length - 2], up[up.length - 1], p) <= 0) up.pop(); up.push(p); }
  return lo.slice(0, -1).concat(up.slice(0, -1));
}

/**
 * 画像（RGBA）から1円玉らしい楕円を探し、点数のよい順に返す（最大 maxN 個）。
 * 方法：灰色 → ぼかし → Canny（しきい値は大津の方法から）→ 輪郭 → 楕円の当てはめ。
 * 楕円にきれいに乗っているか（当てはめの誤差）、ぐるりと閉じているか（角度の覆い）、
 * 手の上でないか、手に比べて大きさがおかしくないか、で選ぶ。
 */
export function detectCoins(cv: any, rgba: Uint8ClampedArray, W: number, H: number, hints: CoinHints = {}, maxN = 3): CoinEllipse[] {
  const k = Math.min(1, WORK_LONG_SIDE / Math.max(W, H)); // 縮める倍率
  const src = cv.matFromImageData({ data: rgba, width: W, height: H });
  const gray = new cv.Mat(), small = new cv.Mat(), blur = new cv.Mat(), edges = new cv.Mat(), tmp = new cv.Mat();
  const contours = new cv.MatVector(), hier = new cv.Mat();
  const out: CoinEllipse[] = [];
  try {
    cv.cvtColor(src, gray, cv.COLOR_RGBA2GRAY);
    if (k < 1) cv.resize(gray, small, new cv.Size(Math.round(W * k), Math.round(H * k)), 0, 0, cv.INTER_AREA);
    else gray.copyTo(small);
    cv.GaussianBlur(small, blur, new cv.Size(5, 5), 0);
    // しきい値を3段で試す（1円玉と机の明るさの差は、机によって大きく違う）。輪郭はまとめて調べる
    for (const hi of [120, 60, 30]) {
      cv.Canny(blur, edges, hi * 0.4, hi);
      const cs = new cv.MatVector();
      cv.findContours(edges, cs, hier, cv.RETR_LIST, cv.CHAIN_APPROX_NONE);
      for (let i = 0; i < cs.size(); i++) contours.push_back(cs.get(i));
      cs.delete();
    }

    // 手（縮めた座標）：凸包を少し広げたもの。手のひらの幅（人差し指と小指の付け根の間）
    let handPoly: { x: number; y: number }[] | undefined, palmW: number | undefined;
    if (hints.hand?.length === 21) {
      const hp = hints.hand.map((p) => ({ x: p.x * k, y: p.y * k }));
      const c = hp.reduce((a, p) => ({ x: a.x + p.x / 21, y: a.y + p.y / 21 }), { x: 0, y: 0 });
      handPoly = hull(hp).map((p) => ({ x: c.x + (p.x - c.x) * 1.12, y: c.y + (p.y - c.y) * 1.12 }));
      palmW = Math.hypot(hp[5].x - hp[17].x, hp[5].y - hp[17].y);
    }
    const L = Math.max(W, H) * k;
    const minMajor = Math.max(10, (hints.minMajor ?? 14) * k), maxMajor = L * 0.3;

    const cands: CoinEllipse[] = [];
    for (let i = 0; i < contours.size(); i++) {
      const cnt = contours.get(i);
      try {
        const n = cnt.rows;
        if (n < 16) continue;
        const e = cv.fitEllipse(cnt);
        const a = Math.max(e.size.width, e.size.height) / 2, b = Math.min(e.size.width, e.size.height) / 2;
        if (!(a > 0 && b > 0) || 2 * a < minMajor || 2 * a > maxMajor || b / a < 0.35) continue;
        // 当てはめの誤差とぐるりの覆い。楕円の座標系に直して見る
        const th = (e.angle * Math.PI) / 180, ct = Math.cos(th), st = Math.sin(th);
        const ax = e.size.width / 2, ay = e.size.height / 2;
        const bins = new Uint8Array(36);
        let err = 0;
        const d = cnt.data32S;
        for (let j = 0; j < n; j++) {
          const x = d[2 * j] - e.center.x, y = d[2 * j + 1] - e.center.y;
          const u = (x * ct + y * st) / ax, v = (-x * st + y * ct) / ay;
          const rr = Math.hypot(u, v);
          err += Math.abs(rr - 1);
          bins[Math.min(35, Math.floor(((Math.atan2(v, u) + Math.PI) / (2 * Math.PI)) * 36))] = 1;
        }
        const fitErr = err / n, coverage = bins.reduce((s, x) => s + x, 0) / 36;
        if (fitErr > 0.06 || coverage < 0.75) continue;
        const center = { x: e.center.x, y: e.center.y };
        if (handPoly && inPolygon(center, handPoly)) continue; // 手の上の丸（爪・関節）
        // 点数（小さいほどよい）
        let score = fitErr * 10 + (1 - coverage) * 2;
        if (palmW) {
          // 1円玉（20mm）は、人差し指と小指の付け根の間（大人で約55〜65mm）の約1/3
          const r = (2 * a) / palmW;
          if (r < 0.12 || r > 0.8) continue;
          score += Math.abs(Math.log(r / 0.33)) * 0.6;
        }
        if (hints.prev) {
          const dp = Math.hypot(center.x - hints.prev.cx * k, center.y - hints.prev.cy * k) / L;
          const ds = Math.abs(Math.log((2 * a) / (hints.prev.major * k)));
          if (ds > 0.25) continue; // 大きさが急に変わったものは別の物
          score += dp * 4 + ds * 3;
        }
        if (hints.near) score += (Math.hypot(center.x - hints.near.x * k, center.y - hints.near.y * k) / L) * 8;
        cands.push({
          cx: center.x / k, cy: center.y / k, major: (2 * a) / k, minor: (2 * b) / k, ratio: b / a, angle: e.angle,
          areaRatio: 1, momentMajor: (2 * a) / k, pixels: Math.round(Math.PI * a * b / (k * k)),
          fitErr, coverage, score,
        });
      } finally {
        cnt.delete();
      }
    }
    // もう1つの方法：丸い斑点から色で領域を広げる（光った所で輪郭が切れる1円玉でも取れる）
    const smallRgba = new cv.Mat();
    try {
      if (k < 1) cv.resize(src, smallRgba, new cv.Size(small.cols, small.rows), 0, 0, cv.INTER_AREA); else src.copyTo(smallRgba);
      const sw = small.cols, sh = small.rows, px = smallRgba.data as Uint8Array, g = small.data as Uint8Array;
      const grayF = Float32Array.from(g);
      const radii: number[] = [];
      for (let r = minMajor / 2; r <= maxMajor / 2; r *= 1.3) radii.push(r);
      const center = hints.near ? { x: hints.near.x * k, y: hints.near.y * k } : hints.prev ? { x: hints.prev.cx * k, y: hints.prev.cy * k } : { x: sw / 2, y: sh / 2 };
      const spots = roundSpots(grayF, sw, sh, center, radii, 12, hints.near || hints.prev ? sw / 4 : Infinity)
        .filter((sp) => !(handPoly && inPolygon(sp, handPoly)));
      for (const sp of spots.slice(0, 8)) {
        const half = Math.ceil(sp.r * 2.6);
        const x0 = Math.max(0, Math.round(sp.x) - half), y0 = Math.max(0, Math.round(sp.y) - half);
        const ww = Math.min(sw, Math.round(sp.x) + half) - x0, hh = Math.min(sh, Math.round(sp.y) + half) - y0;
        if (ww < 8 || hh < 8) continue;
        const win = new Uint8ClampedArray(ww * hh * 4);
        for (let y = 0; y < hh; y++) win.set(px.subarray(((y0 + y) * sw + x0) * 4, ((y0 + y) * sw + x0 + ww) * 4), y * ww * 4);
        const e = fitCoinAt(win, ww, hh, sp.x - x0, sp.y - y0, sp.r);
        if (!e || e.major < minMajor || e.major > maxMajor || e.ratio < 0.35) continue;
        if (e.areaRatio < 0.85 || e.areaRatio > 1.15 || Math.abs(e.momentMajor - e.major) / e.major > 0.05) continue;
        const c = { x: e.cx + x0, y: e.cy + y0 };
        if (handPoly && inPolygon(c, handPoly)) continue;
        const fitErr = Math.abs(e.areaRatio - 1) * 0.3 + Math.abs(e.momentMajor - e.major) / e.major;
        let score = fitErr * 10 + 0.15;  // 輪郭の方法より少しだけ後に回す
        if (palmW) { const r = e.major / palmW; if (r < 0.12 || r > 0.8) continue; score += Math.abs(Math.log(r / 0.33)) * 0.6; }
        if (hints.prev) {
          const ds = Math.abs(Math.log(e.major / (hints.prev.major * k)));
          if (ds > 0.25) continue;
          score += (Math.hypot(c.x - hints.prev.cx * k, c.y - hints.prev.cy * k) / L) * 4 + ds * 3;
        }
        if (hints.near) score += (Math.hypot(c.x - hints.near.x * k, c.y - hints.near.y * k) / L) * 8;
        cands.push({ cx: c.x / k, cy: c.y / k, major: e.major / k, minor: e.minor / k, ratio: e.ratio, angle: (e.angle * 180) / Math.PI,
          areaRatio: e.areaRatio, momentMajor: e.momentMajor / k, pixels: Math.round(e.pixels / (k * k)), fitErr, coverage: 1, score });
      }
    } finally {
      smallRgba.delete();
    }
    // Canny の線は1本でも、輪郭は内側と外側の2つになる。近いものはまとめ、大きさは平均する
    cands.sort((p, q) => p.score - q.score);
    for (const c of cands) {
      const same = out.find((o) => Math.hypot(o.cx - c.cx, o.cy - c.cy) < 0.2 * o.major && Math.abs(o.major - c.major) < 0.15 * o.major);
      if (same) {
        if (!(same as any)._merged) { same.major = (same.major + c.major) / 2; same.minor = (same.minor + c.minor) / 2; same.momentMajor = same.major; (same as any)._merged = true; }
        continue;
      }
      if (out.length < maxN) out.push(c);
    }
    for (const o of out) delete (o as any)._merged;
    return out;
  } finally {
    [src, gray, small, blur, edges, tmp, hier].forEach((m) => m.delete());
    contours.delete();
  }
}
