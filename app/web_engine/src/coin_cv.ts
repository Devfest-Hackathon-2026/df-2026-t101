// 1円玉の自動検出（OpenCV.js）。タップしなくても、画像の中の楕円から1円玉を探す。
// 手の21点が分かっていれば、指と関節の上の丸（爪・関節）を外し、手の大きさから1円玉の大きさの見当をつける。
// 1円玉は手の甲のまん中に置く（2026-11-09）。測る点（手首と指の付け根）と同じ高さにあるので、机に置いたとき
// のように、カメラからの距離の差で手が大きく測られることがない。手の上の丸は、指先と爪のまわりだけを外し、
// それ以外（手の甲・横から見た手の甲のふくらみ）は、楕円にきれいに乗ったものを受け付けて、机の上の丸より先に選ぶ。
// cv は OpenCV.js のモジュール（読み込みは engine.ts）。ここは画像処理だけで、DOM に触らない（Node でも試せる）。

export type CoinEllipse = {
  cx: number; cy: number;       // 中心（元の画像のpx）
  major: number; minor: number; // 長径・短径（px）
  ratio: number; angle: number; // 短径÷長径、傾き（度）
  areaRatio: number; momentMajor: number; pixels: number; // ほかの方法の結果と同じ形にするため
  fitErr: number; coverage: number; score: number;
  onHand?: boolean;             // 手の甲の上にあるか
};

export type CoinHints = {
  hand?: { x: number; y: number }[]; // 手の21点（px）
  prev?: { cx: number; cy: number; major: number }; // 前のフレームの1円玉（動画で追いかけるとき）
  near?: { x: number; y: number };    // タップした点（px）
  minMajor?: number;                  // これより小さい楕円は見ない（px）
};

import { roundSpots, fitCoinAt } from './geometry';

const WORK_LONG_SIDE = 960; // 速さのため、この大きさに縮めて探す
const ARC_FIT_ERR = 0.03;      // 弧をつなぐ元にする弧：楕円にこれよりきれいに乗っている
const ARC_MIN_COVERAGE = 0.3;  //   かつ、ぐるりのこれ以上を覆っている
const ARC_JOIN_ERR = 0.04;     // ほかの弧は、点のずれの平均がこれ以下なら同じ楕円の弧とみなす

/** 点が多角形の中にあるか */
function inPolygon(p: { x: number; y: number }, poly: { x: number; y: number }[]) {
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const a = poly[i], b = poly[j];
    if ((a.y > p.y) !== (b.y > p.y) && p.x < ((b.x - a.x) * (p.y - a.y)) / (b.y - a.y) + a.x) inside = !inside;
  }
  return inside;
}

/** 手の甲の範囲：手首・親指の根元・4本の指の付け根の凸包を、重心から1.3倍に広げたもの。
 * 横から見たときは手の甲の面が点の外へふくらんで見えるので、少し広げる。指（PIP から先）と爪はこの外になる */
export function backOfHandPoly(hand: { x: number; y: number }[]) {
  const ids = [0, 1, 5, 9, 13, 17];
  const pts = ids.map((i) => hand[i]);
  const c = pts.reduce((a, p) => ({ x: a.x + p.x / pts.length, y: a.y + p.y / pts.length }), { x: 0, y: 0 });
  return hull(pts).map((p) => ({ x: c.x + (p.x - c.x) * 1.3, y: c.y + (p.y - c.y) * 1.3 }));
}

/** 手全体の凸包を、重心から scale 倍に広げたもの */
function handHull(hand: { x: number; y: number }[], scale: number) {
  const c = hand.reduce((a, p) => ({ x: a.x + p.x / hand.length, y: a.y + p.y / hand.length }), { x: 0, y: 0 });
  return hull(hand).map((p) => ({ x: c.x + (p.x - c.x) * scale, y: c.y + (p.y - c.y) * scale }));
}

/** 点が手の上か（手の21点は同じ座標のpx）。横から見ると手の甲は点の外へふくらんで写るので、凸包を1.25倍に広げて見る。
 * 机の上の1円玉を使っていないかを知らせるため（解析の警告 COIN_OFF_HAND） */
export function onBackOfHand(p: { x: number; y: number }, hand?: { x: number; y: number }[]) {
  return !!hand && hand.length === 21 && (inPolygon(p, backOfHandPoly(hand)) || inPolygon(p, handHull(hand, 1.25)));
}

const NAIL_IDS = [3, 4, 7, 8, 11, 12, 15, 16, 19, 20];   // 指先と、その1つ手前の関節（爪と指先の丸）

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
    let handPoly: { x: number; y: number }[] | undefined, backPoly: { x: number; y: number }[] | undefined, palmW: number | undefined;
    let nails: { x: number; y: number }[] = [];
    if (hints.hand?.length === 21) {
      const hp = hints.hand.map((p) => ({ x: p.x * k, y: p.y * k }));
      handPoly = handHull(hp, 1.25);
      backPoly = backOfHandPoly(hp);
      palmW = Math.hypot(hp[5].x - hp[17].x, hp[5].y - hp[17].y);
      // 握りこぶしを真上から見ると、指先は手のひらの下に隠れ、その点は手の甲の範囲の中に来る。隠れた指先の爪は
      // 写らないので外さない（外すと、手の甲のまん中の1円玉まで外してしまった。11/9 の動画）
      nails = NAIL_IDS.map((i) => hp[i]).filter((q) => !inPolygon(q, backPoly!));
    }
    // 指先と爪のまわり（人差し指と小指の付け根の間の18%）は外す。手の甲・手の横は1円玉の候補（'back'）、手の外は 'off'。
    // 横から見ると手の甲は点の外へふくらんで写り、付け根の幅も縮むので、手の甲の範囲だけに絞ると1円玉を取りこぼした（11/9 の動画）
    // タップした（near）ときは、手の点からの絞り込み（爪のまわりを外す・手の上を厳しく・手の幅との比）をかけない。
    // 握りこぶしでは手の点がずれやすく、はっきり写った1円玉までタップしても外していた（2026-11-09）。形の条件は残す
    const tapped = !!hints.near;
    const nailR = palmW && !tapped ? Math.max(6, palmW * 0.18) : 0;
    const where = (p: { x: number; y: number }) =>
      nails.some((q) => Math.hypot(p.x - q.x, p.y - q.y) < nailR) ? 'finger'
        : (backPoly && inPolygon(p, backPoly)) || (handPoly && inPolygon(p, handPoly)) ? 'back' : 'off';
    const L = Math.max(W, H) * k;
    const minMajor = Math.max(10, (hints.minMajor ?? 14) * k), maxMajor = L * 0.3;

    const cands: CoinEllipse[] = [];
    // 輪郭を点の配列にして取っておく（弧をつなぐときに何度も見るので）
    type Arc = { d: Int32Array; n: number; x0: number; y0: number; x1: number; y1: number };
    const arcs: Arc[] = [];
    for (let i = 0; i < contours.size(); i++) {
      const cnt = contours.get(i);
      const n = cnt.rows;
      if (n >= 16) {
        const d = Int32Array.from(cnt.data32S as Int32Array);
        let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
        for (let j = 0; j < n; j++) {
          const x = d[2 * j], y = d[2 * j + 1];
          if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y;
        }
        arcs.push({ d, n, x0, y0, x1, y1 });
      }
      cnt.delete();
    }
    type Fit = { cx: number; cy: number; ax: number; ay: number; ct: number; st: number; angle: number; a: number; b: number };
    /** 点に楕円を当てる。大きさ・形が1円玉らしくなければ null */
    const fitPoints = (d: Int32Array, n: number): Fit | null => {
      const m = new cv.Mat(n, 1, cv.CV_32SC2);
      try {
        (m.data32S as Int32Array).set(d.subarray(0, 2 * n));
        const e = cv.fitEllipse(m);
        const a = Math.max(e.size.width, e.size.height) / 2, b = Math.min(e.size.width, e.size.height) / 2;
        if (!(a > 0 && b > 0) || 2 * a < minMajor || 2 * a > maxMajor || b / a < 0.35) return null;
        const th = (e.angle * Math.PI) / 180;
        return { cx: e.center.x, cy: e.center.y, ax: e.size.width / 2, ay: e.size.height / 2, ct: Math.cos(th), st: Math.sin(th), angle: e.angle, a, b };
      } finally {
        m.delete();
      }
    };
    /** 当てはめの誤差（点の、楕円からのずれの平均）とぐるりの覆い（36に分けた向きのうち点のある割合）。楕円の座標系に直して見る */
    const fitStats = (f: Fit, group: Arc[]) => {
      const bins = new Uint8Array(36);
      let err = 0, n = 0;
      for (const arc of group) {
        for (let j = 0; j < arc.n; j++) {
          const x = arc.d[2 * j] - f.cx, y = arc.d[2 * j + 1] - f.cy;
          const u = (x * f.ct + y * f.st) / f.ax, v = (-x * f.st + y * f.ct) / f.ay;
          err += Math.abs(Math.hypot(u, v) - 1);
          bins[Math.min(35, Math.floor(((Math.atan2(v, u) + Math.PI) / (2 * Math.PI)) * 36))] = 1;
        }
        n += arc.n;
      }
      return { fitErr: err / n, coverage: bins.reduce((s, x) => s + x, 0) / 36 };
    };
    /** 弧の点が楕円にどれだけ乗っているか（ずれの平均） */
    const offEllipse = (f: Fit, arc: Arc) => {
      let err = 0;
      for (let j = 0; j < arc.n; j++) {
        const x = arc.d[2 * j] - f.cx, y = arc.d[2 * j + 1] - f.cy;
        err += Math.abs(Math.hypot((x * f.ct + y * f.st) / f.ax, (-x * f.st + y * f.ct) / f.ay) - 1);
      }
      return err / arc.n;
    };
    /** 1円玉の候補にするか決めて、点数をつける */
    const consider = (f: Fit, fitErr: number, coverage: number) => {
      if (fitErr > 0.06 || coverage < 0.75) return;
      const { a, b } = f;
      const center = { x: f.cx, y: f.cy };
      const at = where(center);
      if (at === 'finger') return; // 指と関節の上の丸（爪・関節）
      // 手の上は、関節の出っ張りや皮膚の模様と間違えないよう、楕円にきれいに乗ったものだけ。明るい肌との境目で輪郭が
      // 途切れやすいので、ぐるりの覆いは机の上と同じ（0.75）にする（0.85 にしたら、真上からの1円玉まで落ちた。11/9 の動画）
      if (at === 'back' && fitErr > 0.035 && !tapped) return;
      // 点数（小さいほどよい）。手の甲の上の1円玉を、机の上の1円玉より先に選ぶ
      let score = fitErr * 10 + (1 - coverage) * 2 + (at === 'back' ? -0.5 : 0);
      if (palmW) {
        // 1円玉（20mm）は、人差し指と小指の付け根の間（大人で約55〜65mm）の約1/3
        const r = (2 * a) / palmW;
        if ((r < 0.12 || r > 0.8) && !tapped) return;
        score += Math.abs(Math.log(r / 0.33)) * 0.6;
      }
      if (hints.prev) {
        const dp = Math.hypot(center.x - hints.prev.cx * k, center.y - hints.prev.cy * k) / L;
        const ds = Math.abs(Math.log((2 * a) / (hints.prev.major * k)));
        // 大きさが急に変わったものは別の物。カメラを動かして撮るので、距離の変化の分（約1.5倍まで）は許す
        if (ds > 0.4) return;
        score += dp * 4 + ds * 3;
      }
      if (hints.near) score += (Math.hypot(center.x - hints.near.x * k, center.y - hints.near.y * k) / L) * 8;
      cands.push({
        cx: center.x / k, cy: center.y / k, major: (2 * a) / k, minor: (2 * b) / k, ratio: b / a, angle: f.angle,
        areaRatio: 1, momentMajor: (2 * a) / k, pixels: Math.round(Math.PI * a * b / (k * k)),
        fitErr, coverage, score, onHand: at === 'back',
      });
    };

    // 1本の輪郭で一周取れたもの。きれいな弧なのに一周に足りないものは、弧をつなぐ元にする
    const seeds: { f: Fit; arc: Arc }[] = [];
    for (const arc of arcs) {
      const f = fitPoints(arc.d, arc.n);
      if (!f) continue;
      const s = fitStats(f, [arc]);
      if (s.fitErr <= 0.06 && s.coverage >= 0.75) consider(f, s.fitErr, s.coverage);
      else if (s.fitErr <= ARC_FIT_ERR && s.coverage >= ARC_MIN_COVERAGE && arc.n >= 30) seeds.push({ f, arc });
    }
    // 弧をつなぐ：1円玉の縁は、肌や机と明るさが近い所で途切れて、いくつかの弧に分かれる（手の甲の上で覆い 0.55 しか
    // なかった。2026-11-09 の写真）。同じ楕円の上に乗っているほかの弧を集めて当て直し、同じ条件（誤差・覆い）で見る。
    // 1本の輪郭で取れた所には足さない（縁の線の内側と外側の輪郭の平均が縁の位置。つないだ弧が混ざると大きさがずれる）
    const same = (f: Fit, g: { cx: number; cy: number; a: number }) =>
      Math.hypot(g.cx - f.cx, g.cy - f.cy) < 0.4 * g.a && Math.abs(g.a - f.a) < 0.15 * g.a;
    const single = cands.map((c) => ({ cx: c.cx * k, cy: c.cy * k, a: (c.major * k) / 2 }));
    const already = (f: Fit) => single.some((g) => same(f, g));
    const joined: { f: Fit; fitErr: number; coverage: number }[] = [];
    for (const { f, arc: seed } of seeds) {
      if (already(f)) continue;
      const reach = f.a * 1.15;
      const group = [seed];
      for (const arc of arcs) {
        if (arc === seed || arc.x0 < f.cx - reach || arc.x1 > f.cx + reach || arc.y0 < f.cy - reach || arc.y1 > f.cy + reach) continue;
        if (offEllipse(f, arc) <= ARC_JOIN_ERR) group.push(arc);
      }
      if (group.length === 1) continue;
      const n = group.reduce((s, g) => s + g.n, 0);
      const d = new Int32Array(2 * n);
      let o = 0;
      for (const g of group) { d.set(g.d.subarray(0, 2 * g.n), o); o += 2 * g.n; }
      const f2 = fitPoints(d, n);
      if (!f2 || already(f2)) continue;
      const s2 = fitStats(f2, group);
      if (s2.fitErr <= 0.06 && s2.coverage >= 0.75) joined.push({ f: f2, ...s2 });
    }
    // 同じ中心の丸がいくつかできたら、いちばん大きいものだけ。1円玉の内側のふち（盛り上がった輪）や模様の弧からも
    // 小さめの丸ができる（外の縁より6%小さかった。11/9 の動画）。外の縁がいちばん外側
    joined.sort((p, q) => q.f.a - p.f.a);
    const kept: Fit[] = [];
    for (const j of joined) {
      if (kept.some((g) => same(j.f, g))) continue;
      kept.push(j.f);
      consider(j.f, j.fitErr, j.coverage);
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
        .filter((sp) => where(sp) !== 'finger');
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
        const at = where(c);
        if (at === 'finger') continue;
        const fitErr = Math.abs(e.areaRatio - 1) * 0.3 + Math.abs(e.momentMajor - e.major) / e.major;
        let score = fitErr * 10 + 0.15 + (at === 'back' ? -0.5 : 0);  // 輪郭の方法より少しだけ後に回す。手の甲の上を先に
        if (palmW) { const r = e.major / palmW; if ((r < 0.12 || r > 0.8) && !tapped) continue; score += Math.abs(Math.log(r / 0.33)) * 0.6; }
        if (hints.prev) {
          const ds = Math.abs(Math.log(e.major / (hints.prev.major * k)));
          if (ds > 0.4) continue;
          score += (Math.hypot(c.x - hints.prev.cx * k, c.y - hints.prev.cy * k) / L) * 4 + ds * 3;
        }
        if (hints.near) score += (Math.hypot(c.x - hints.near.x * k, c.y - hints.near.y * k) / L) * 8;
        cands.push({ cx: c.x / k, cy: c.y / k, major: e.major / k, minor: e.minor / k, ratio: e.ratio, angle: (e.angle * 180) / Math.PI,
          areaRatio: e.areaRatio, momentMajor: e.momentMajor / k, pixels: Math.round(e.pixels / (k * k)), fitErr, coverage: 1, score,
          onHand: at === 'back' });
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
