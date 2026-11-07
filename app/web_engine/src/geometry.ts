// 採寸の計算（docs/measurement.md §4〜§7）。画像のpx座標、mm、度を扱う純粋な関数だけを置く。
export type P2 = { x: number; y: number };
export type P3 = { x: number; y: number; z: number };

export const FINGERS = ['index', 'middle', 'ring', 'pinky'] as const;
export type Finger = (typeof FINGERS)[number];
// MediaPipe の21点：付け根・PIP・DIP・指先
export const CHAIN: Record<Finger, [number, number, number, number]> = {
  index: [5, 6, 7, 8],
  middle: [9, 10, 11, 12],
  ring: [13, 14, 15, 16],
  pinky: [17, 18, 19, 20],
};

export const sub2 = (a: P2, b: P2): P2 => ({ x: a.x - b.x, y: a.y - b.y });
export const len2 = (a: P2) => Math.hypot(a.x, a.y);
export const dist2 = (a: P2, b: P2) => len2(sub2(a, b));
export const dot2 = (a: P2, b: P2) => a.x * b.x + a.y * b.y;
export const sub3 = (a: P3, b: P3): P3 => ({ x: a.x - b.x, y: a.y - b.y, z: a.z - b.z });
export const dot3 = (a: P3, b: P3) => a.x * b.x + a.y * b.y + a.z * b.z;
export const len3 = (a: P3) => Math.sqrt(dot3(a, a));

/** 2つのベクトルのなす角（度、0〜180）。0＝まっすぐ */
export function angle2(a: P2, b: P2): number {
  const c = dot2(a, b) / (len2(a) * len2(b) || 1);
  return (Math.acos(Math.max(-1, Math.min(1, c))) * 180) / Math.PI;
}
export function angle3(a: P3, b: P3): number {
  const c = dot3(a, b) / (len3(a) * len3(b) || 1);
  return (Math.acos(Math.max(-1, Math.min(1, c))) * 180) / Math.PI;
}

export function median(xs: number[]): number {
  if (!xs.length) return NaN;
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}
export function quantile(xs: number[], q: number): number {
  if (!xs.length) return NaN;
  const s = [...xs].sort((a, b) => a - b);
  const pos = (s.length - 1) * q;
  const lo = Math.floor(pos), hi = Math.ceil(pos);
  return s[lo] + (s[hi] - s[lo]) * (pos - lo);
}
export const iqr = (xs: number[]) => quantile(xs, 0.75) - quantile(xs, 0.25);

/** 長く写ったフレームの上位20%（最低3枚）の中央値（§7.1） */
export function topMedian(xs: number[], frac = 0.2, min = 3): number {
  const s = xs.filter(Number.isFinite).sort((a, b) => b - a);
  if (!s.length) return NaN;
  const k = Math.min(s.length, Math.max(min, Math.ceil(s.length * frac)));
  return median(s.slice(0, k));
}

/** 三角形の面積 */
export function triArea(a: P2, b: P2, c: P2): number {
  return Math.abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) / 2;
}

/** 手のひらの面の座標系（2D、§8.1）：x＝人差し指の付け根→小指の付け根、y＝手首→中指の付け根（x成分を除く） */
export function palmFrame(pts: P2[]) {
  const o = pts[0];
  const xr = sub2(pts[17], pts[5]);
  const xl = len2(xr) || 1;
  const ex = { x: xr.x / xl, y: xr.y / xl };
  const yr = sub2(pts[9], o);
  const yp = { x: yr.x - dot2(yr, ex) * ex.x, y: yr.y - dot2(yr, ex) * ex.y };
  const yl = len2(yp) || 1;
  const ey = { x: yp.x / yl, y: yp.y / yl };
  return (p: P2): P2 => {
    const d = sub2(p, o);
    return { x: dot2(d, ex), y: dot2(d, ey) };
  };
}

/** ぼけの少なさ（ラプラシアンの分散）。gray は長い辺256px程度の白黒画像 */
export function sharpness(gray: Float32Array, w: number, h: number): number {
  let sum = 0, sum2 = 0, n = 0;
  for (let y = 1; y < h - 1; y++) {
    for (let x = 1; x < w - 1; x++) {
      const i = y * w + x;
      const v = 4 * gray[i] - gray[i - 1] - gray[i + 1] - gray[i - w] - gray[i + w];
      sum += v; sum2 += v * v; n++;
    }
  }
  const m = sum / n;
  return sum2 / n - m * m;
}

/**
 * 1円玉のマスクから楕円を求める（§4.3）。長径は、主軸の向きに投影した幅（両端0.5%を除く）で測る。
 * 低い角度から見たときに、縁の厚さの帯で共分散が膨らむずれを避けるため。
 */
export function ellipseFromMask(mask: Float32Array, w: number, h: number, thr = 0.5, maxPixels = Infinity) {
  let n = 0, sx = 0, sy = 0;
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) if (mask[y * w + x] > thr) { n++; sx += x; sy += y; }
  if (n < 30 || n > maxPixels) return null;  // 大きすぎる領域（背景など）は形を調べない（重いので）
  const cx = sx / n, cy = sy / n;
  let sxx = 0, syy = 0, sxy = 0;
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) if (mask[y * w + x] > thr) {
    const dx = x - cx, dy = y - cy; sxx += dx * dx; syy += dy * dy; sxy += dx * dy;
  }
  sxx /= n; syy /= n; sxy /= n;
  const tr = sxx + syy, det = sxx * syy - sxy * sxy;
  const l1 = tr / 2 + Math.sqrt(Math.max(0, (tr * tr) / 4 - det));
  const l2 = Math.max(1e-9, tr - l1);
  const theta = Math.atan2(l1 - sxx, sxy || 1e-9);
  const ux = Math.cos(theta), uy = Math.sin(theta);
  // 長径は、長軸の向きに投影したときの幅（最大−最小）。measurement.md §4.3。
  // 両端を0.5%ずつ削る方法は、円では幅が4〜7%短く出たのでやめた（円の端は細いので、削ると大きく減る）
  let pMin = Infinity, pMax = -Infinity, qMin = Infinity, qMax = -Infinity;
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) if (mask[y * w + x] > thr) {
    const p = (x - cx) * ux + (y - cy) * uy, q = -(x - cx) * uy + (y - cy) * ux;
    if (p < pMin) pMin = p; if (p > pMax) pMax = p;
    if (q < qMin) qMin = q; if (q > qMax) qMax = q;
  }
  const major = pMax - pMin, minor = qMax - qMin;
  const momentMajor = 4 * Math.sqrt(l1);  // 中身の詰まった楕円なら長径と一致する。離れた点や縁の帯があるとずれる
  const areaRatio = n / ((Math.PI * 4 * Math.sqrt(l1) * 4 * Math.sqrt(l2)) / 4);
  return { cx, cy, major, minor, ratio: minor / (major || 1), areaRatio, momentMajor, angle: theta, pixels: n };
}

/**
 * 押した点の近くで「丸い斑点」（まわりより明るい／暗い円）を探す。1円玉の候補を数点に絞るためで、
 * 切り出し（重い）を何度も呼ばずに済む。gray は窓の中の明るさ（0〜255、行ごと）。
 * 箱フィルタで、内側の平均と外側の輪の平均の差を見る（積分画像なので速い）。
 * 返すのは窓の中の座標と、推定の半径。押した点に近いほど点数を高くする。
 */
export function roundSpots(gray: Float32Array, w: number, h: number, tap: { x: number; y: number }, radii: number[], maxN = 3, sigmaOverride?: number) {
  const I = new Float64Array((w + 1) * (h + 1));
  for (let y = 0; y < h; y++) {
    let row = 0;
    for (let x = 0; x < w; x++) { row += gray[y * w + x]; I[(y + 1) * (w + 1) + x + 1] = I[y * (w + 1) + x + 1] + row; }
  }
  const box = (x0: number, y0: number, x1: number, y1: number) => I[y1 * (w + 1) + x1] - I[y0 * (w + 1) + x1] - I[y1 * (w + 1) + x0] + I[y0 * (w + 1) + x0];
  const sigma = sigmaOverride ?? Math.max(w, h) / 3;  // Infinity なら、押した点からの距離を見ない
  const found: { x: number; y: number; r: number; score: number }[] = [];
  for (const r of radii) {
    const ri = Math.max(2, Math.round(r * 0.7)), ro = Math.round(r * 1.6);
    const step = Math.max(1, Math.round(r / 4));
    for (let y = ro; y < h - ro; y += step) for (let x = ro; x < w - ro; x += step) {
      const mIn = box(x - ri, y - ri, x + ri + 1, y + ri + 1) / (2 * ri + 1) ** 2;
      // 上下左右の4つの帯と比べ、どの向きとも同じ側に差があるときだけ丸い斑点とみなす
      // （縁や角は1〜2方向にしか差がないので落ちる）
      const g = Math.round(r * 1.15);  // 1円玉の縁のすぐ外から
      const aSide = (ro - g + 1) * (2 * ri + 1);
      const sides = [
        box(x - ri, y - ro, x + ri + 1, y - g + 1),
        box(x - ri, y + g, x + ri + 1, y + ro + 1),
        box(x - ro, y - ri, x - g + 1, y + ri + 1),
        box(x + g, y - ri, x + ro + 1, y + ri + 1),
      ].map((v) => mIn - v / aSide);
      const sign = Math.sign(sides[0]);
      const contrast = sides.every((d) => Math.sign(d) === sign) ? Math.min(...sides.map(Math.abs)) : 0;
      if (contrast < 8) continue;
      const d2 = (x - tap.x) ** 2 + (y - tap.y) ** 2;
      const score = contrast * Math.exp(-d2 / (2 * sigma * sigma));
      found.push({ x, y, r, score });
    }
  }
  found.sort((a, b) => b.score - a.score);
  const out: typeof found = [];
  for (const c of found) {  // 近すぎる候補は1つにまとめる
    if (out.every((o) => Math.hypot(o.x - c.x, o.y - c.y) > Math.max(o.r, c.r))) out.push(c);
    if (out.length >= maxN) break;
  }
  return out;
}

/**
 * 丸い斑点の中心から、色で1円玉の領域を広げて取る（MediaPipe の切り出しより桁違いに速い）。
 * 内側の平均の色と外側の輪の平均の色のどちらに近いかで分け、中心からつながった所だけを残し、
 * 穴を埋めて、楕円を当てる。窓の端まで広がったら（背景と同じ色）失敗とする。
 * rgba は窓の画素（RGBA）、(cx, cy, r) は窓の中の斑点の中心と半径。返す座標は窓の中。
 */
export function fitCoinAt(rgba: Uint8ClampedArray, w: number, h: number, cx: number, cy: number, r: number) {
  const N = w * h;
  const meanIn = (pred: (x: number, y: number, i: number) => boolean) => {
    let n = 0, R = 0, Gc = 0, B = 0;
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const i = y * w + x;
      if (pred(x, y, i)) { n++; R += rgba[4 * i]; Gc += rgba[4 * i + 1]; B += rgba[4 * i + 2]; }
    }
    return n ? [R / n, Gc / n, B / n, n] : null;
  };
  const d2 = (x: number, y: number) => (x - cx) ** 2 + (y - cy) ** 2;
  let mi = meanIn((x, y) => d2(x, y) <= (0.5 * r) ** 2);
  let mo = meanIn((x, y) => d2(x, y) >= (1.4 * r) ** 2 && d2(x, y) <= (1.9 * r) ** 2);
  if (!mi || !mo) return null;
  const region = new Uint8Array(N);
  const stack = new Int32Array(N);
  for (let iter = 0; iter < 3; iter++) {
    const contrast = Math.hypot(mi[0] - mo[0], mi[1] - mo[1], mi[2] - mo[2]);
    if (contrast < 30) return null;  // まわりと色の差が小さい
    const inside = (i: number) => {
      const R = rgba[4 * i], Gc = rgba[4 * i + 1], B = rgba[4 * i + 2];
      return (R - mi![0]) ** 2 + (Gc - mi![1]) ** 2 + (B - mi![2]) ** 2 < (R - mo![0]) ** 2 + (Gc - mo![1]) ** 2 + (B - mo![2]) ** 2;
    };
    // 中心の近くで「内側の色」の画素から広げる（光った所が中心にあることがある）
    region.fill(0);
    let start = -1;
    for (let rr = 0; rr <= Math.max(2, r * 0.4) && start < 0; rr++) {
      for (let dy = -rr; dy <= rr && start < 0; dy++) for (let dx = -rr; dx <= rr; dx++) {
        const x = Math.round(cx + dx), y = Math.round(cy + dy);
        if (x >= 0 && y >= 0 && x < w && y < h && inside(y * w + x)) { start = y * w + x; break; }
      }
    }
    if (start < 0) return null;
    let sp = 0, n = 0;
    const maxN = Math.PI * (2.4 * r) ** 2;
    stack[sp++] = start; region[start] = 1;
    while (sp) {
      const i = stack[--sp]; n++;
      const x = i % w, y = (i - x) / w;
      if (x === 0 || y === 0 || x === w - 1 || y === h - 1 || n > maxN) return null;  // 背景まで漏れた
      for (const j of [i - 1, i + 1, i - w, i + w]) if (!region[j] && inside(j)) { region[j] = 1; stack[sp++] = j; }
    }
    // 色を取り直す（内側は取れた領域、外側はそのまわりの輪）
    const rr = Math.sqrt(n / Math.PI);
    let sx = 0, sy = 0;
    for (let i = 0; i < N; i++) if (region[i]) { sx += i % w; sy += Math.floor(i / w); }
    cx = sx / n; cy = sy / n; r = rr;
    mi = meanIn((_x, _y, i) => region[i] === 1);
    mo = meanIn((x, y, i) => !region[i] && d2(x, y) >= (1.25 * r) ** 2 && d2(x, y) <= (1.8 * r) ** 2);
    if (!mi || !mo) return null;
  }
  // 穴を埋める：窓の端からつながる「外」以外は全部1円玉
  const outside = new Uint8Array(N);
  let sp = 0;
  for (let x = 0; x < w; x++) for (const y of [0, h - 1]) { const i = y * w + x; if (!region[i] && !outside[i]) { outside[i] = 1; stack[sp++] = i; } }
  for (let y = 0; y < h; y++) for (const x of [0, w - 1]) { const i = y * w + x; if (!region[i] && !outside[i]) { outside[i] = 1; stack[sp++] = i; } }
  while (sp) {
    const i = stack[--sp];
    const x = i % w;
    for (const j of [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, i - w, i + w]) if (j >= 0 && j < N && !outside[j] && !region[j]) { outside[j] = 1; stack[sp++] = j; }
  }
  const mask = new Float32Array(N);
  for (let i = 0; i < N; i++) mask[i] = outside[i] ? 0 : 1;
  return ellipseFromMask(mask, w, h);
}
