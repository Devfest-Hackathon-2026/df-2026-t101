// 採寸エンジン（docs/measurement.md）。動画（または写真2枚）をブラウザの中だけで解析し、採寸値のJSONを作る。
// Flutter からは window.jijoguMeasure を dart:js_interop で呼ぶ。動画・フレームはこのモジュールのメモリの外に出さない。
// 例外：角度の推定のため、手を切り抜いたフレーム（最大8枚）だけを、同意を得て hand-mesh に送る（§11）。
import { FilesetResolver, HandLandmarker } from '@mediapipe/tasks-vision';
import type { CoinEllipse, CoinHints } from './coin_cv';
import { onBackOfHand } from './coin_cv';
import * as G from './geometry';
import * as Cam from './camera';
import type { P2, P3, Finger } from './geometry';

type Ellipse = NonNullable<ReturnType<typeof G.ellipseFromMask>>;
type Frame = {
  t: number;
  canvas: HTMLCanvasElement;
  sharp: number;
  lm?: P2[];            // 画像のpx
  world?: P3[];         // メートル（推定値。長さには使わない）
  coin?: Ellipse;       // 画像のpx
  coinOnHand?: boolean; // 1円玉が手の甲の上にあったか（机の上なら、手が大きく測られる）
  s?: number;           // px/mm
  palmArea?: number;    // mm²
  fingerLen?: Record<Finger, number>;
  side?: 'thumb_side' | 'pinky_side' | 'top';
  reject?: string;
  det?: ReturnType<HandLandmarker['detect']>;  // 手の検出の結果（何度も呼ばないよう取っておく）
};

const SAMPLE_FPS = 6;
const KEEP_PER_SEC = 3;
// 長さの補正係数（measurement.md §10.3）。生成APIが倍率に掛ける。1円玉は手の甲の皮膚の上、測る点は関節の中心で、
// 1円玉がカメラに近い分だけ手が約5%小さく出た（11/9、1人・動画1本：定規の手首→中指 90mm（表面）＝関節で約81mm、採寸 76.6mm）。
// 仮の値。本番で撮り直し、scripts/check_hand_size.py で3Dの手の表面の寸法と定規を比べて決め直す
const LENGTH_FACTOR = 1.05;
const LENGTH_FACTOR_SOURCE = '2026-11-09-provisional';
const MAX_SECONDS = 25;          // 撮影の目安は15〜20秒（2026-11-08 に5〜10秒から）。動画ファイルは25秒までを使う
const MAX_CANDIDATES = 60;       // 候補の画像は60枚まで（メモリ対策。camera.ts と同じ）
const ANALYSIS_LONG_SIDE = 1280;
const COIN_MM = 20.0;

const st: {
  vision?: Awaited<ReturnType<typeof FilesetResolver.forVisionTasks>>;
  hand?: HandLandmarker;
  coinRef?: { cx: number; cy: number; major: number };  // 確かめた1円玉（動画で追いかける出発点）
  frames: Frame[];
  mode: 'video' | 'photos';
  coinSeed?: { x: number; y: number };
  coinSeeds: Map<number, { x: number; y: number }>;  // 写真モード：写真ごとの1円玉の位置
  coinManual: boolean;
  coinTapped: boolean;                // 1円玉をタップで指定した（自動検出から直した）
  source: 'live_camera' | 'file';
  duration: number;
  sampled: number;
  result?: any;
} = { frames: [], mode: 'video', coinManual: false, coinTapped: false, source: 'live_camera', duration: 0, sampled: 0, coinSeeds: new Map() };

const base = () => new URL('.', document.baseURI).href;

// ---- 1円玉の自動検出（OpenCV.js を Web Worker で動かす。src/coin_worker.ts） ----
let worker: Worker | undefined;
let workerReady: Promise<boolean> | undefined;  // 使えるようになったら true、だめなら false
let reqId = 0;
const pending = new Map<number, (list: CoinEllipse[] | null) => void>();

/** Worker を作って OpenCV.js（約11MB）の読み込みを始める（待たない） */
function startOpenCV() {
  if (workerReady) return;
  workerReady = new Promise<boolean>((resolve) => {
    try {
      worker = new Worker(base() + 'js/coin_worker.js');
    } catch {
      resolve(false);
      return;
    }
    const timer = setTimeout(() => resolve(false), 60000);
    worker.onmessage = (ev) => {
      const m = ev.data;
      if (m.type === 'ready') { clearTimeout(timer); resolve(true); }
      else if (m.type === 'error') { clearTimeout(timer); console.warn(m.message); resolve(false); }
      else if (m.type === 'result') {
        const done = pending.get(m.id);
        pending.delete(m.id);
        if (m.error) console.warn('1円玉の自動検出：' + m.error);
        done?.(m.error ? null : m.list);
      }
    };
    worker.onerror = () => { clearTimeout(timer); resolve(false); };
    worker.postMessage({ type: 'init', url: base() + 'opencv/opencv.js' });
  });
}

/** Worker で1円玉の候補を探す。OpenCV が使えなければ null */
async function cvDetect(f: Frame, hints: CoinHints, maxN = 3): Promise<CoinEllipse[] | null> {
  startOpenCV();
  if (!(await workerReady)) return null;
  const W = f.canvas.width, H = f.canvas.height;
  const img = (f.canvas.getContext('2d') as CanvasRenderingContext2D).getImageData(0, 0, W, H);
  const id = ++reqId;
  return new Promise((resolve) => {
    pending.set(id, resolve);
    worker!.postMessage({ type: 'detect', id, rgba: img.data.buffer, w: W, h: H, hints, maxN }, [img.data.buffer]);
  });
}

let initP: Promise<void> | undefined;
function init(): Promise<void> {
  initP ??= initOnce().catch((e) => { initP = undefined; throw e; });  // 同時に呼ばれても、作るのは1回
  return initP;
}

async function initOnce(): Promise<void> {
  st.vision = await FilesetResolver.forVisionTasks(base() + 'mediapipe/wasm');
  const make = async (delegate: 'GPU' | 'CPU') =>
    HandLandmarker.createFromOptions(st.vision!, {
      baseOptions: { modelAssetPath: base() + 'mediapipe/models/hand_landmarker.task', delegate },
      runningMode: 'IMAGE',
      numHands: 2,
    });
  try { st.hand = await make('GPU'); } catch { st.hand = await make('CPU'); }
  startOpenCV();  // 待たない
}

function pickFile(accept: string, multiple = false, capture?: string): Promise<File[]> {
  return new Promise((resolve) => {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = accept;
    input.multiple = multiple;
    if (capture) input.setAttribute('capture', capture);
    input.onchange = () => resolve(Array.from(input.files ?? []));
    // 選ばずに閉じたとき。これがないと待ったままになり、ボタンが押せないまま「選んでください」が残った（2026-11-09）
    input.addEventListener('cancel', () => resolve([]));
    input.click();
  });
}

function canvasOf(src: CanvasImageSource, w: number, h: number): HTMLCanvasElement {
  const scale = Math.min(1, ANALYSIS_LONG_SIDE / Math.max(w, h));
  const c = document.createElement('canvas');
  c.width = Math.round(w * scale);
  c.height = Math.round(h * scale);
  c.getContext('2d')!.drawImage(src, 0, 0, c.width, c.height);
  return c;
}

function sharpnessOf(c: HTMLCanvasElement): number {
  const scale = 256 / Math.max(c.width, c.height);
  const w = Math.max(8, Math.round(c.width * scale)), h = Math.max(8, Math.round(c.height * scale));
  const t = document.createElement('canvas');
  t.width = w; t.height = h;
  const ctx = t.getContext('2d', { willReadFrequently: true })!;
  ctx.drawImage(c, 0, 0, w, h);
  const d = ctx.getImageData(0, 0, w, h).data;
  const g = new Float32Array(w * h);
  for (let i = 0; i < w * h; i++) g[i] = 0.299 * d[i * 4] + 0.587 * d[i * 4 + 1] + 0.114 * d[i * 4 + 2];
  return G.sharpness(g, w, h);
}

const toJpeg = (c: HTMLCanvasElement, longSide = 900, q = 0.82) => {
  const scale = Math.min(1, longSide / Math.max(c.width, c.height));
  const t = document.createElement('canvas');
  t.width = Math.round(c.width * scale); t.height = Math.round(c.height * scale);
  t.getContext('2d')!.drawImage(c, 0, 0, t.width, t.height);
  return t.toDataURL('image/jpeg', q);
};

/** §3：動画から1秒に6枚の候補を取り出し、ぼけの少ない上位3枚/秒を残す */
async function loadVideoFile(file: File, progress?: (stage: string, i: number, n: number) => void) {
  const url = URL.createObjectURL(file);
  try {
    const v = document.createElement('video');
    v.muted = true; v.playsInline = true; v.preload = 'auto'; v.src = url;
    await new Promise<void>((res, rej) => { v.onloadeddata = () => res(); v.onerror = () => rej(new Error('動画を読めませんでした。カメラの設定を「互換性優先」にして撮り直してください。')); });
    const dur = Math.min(v.duration || 0, MAX_SECONDS);
    const times: number[] = [];
    const fps = Math.min(SAMPLE_FPS, MAX_CANDIDATES / Math.max(1, dur));
    for (let t = 0.05; t < dur; t += 1 / fps) times.push(t);
    const cands: Frame[] = [];
    for (const [i, t] of times.entries()) {
      progress?.('フレームを選んでいます', i + 1, times.length);
      await new Promise<void>((res) => { v.onseeked = () => res(); v.currentTime = t; });
      const c = canvasOf(v, v.videoWidth, v.videoHeight);
      cands.push({ t, canvas: c, sharp: sharpnessOf(c) });
    }
    useCandidates(cands, dur);
  } finally {
    URL.revokeObjectURL(url);
  }
}

/** 候補フレームから、1秒ごとにぼけの少ない上位3枚を残す（動画ファイルとカメラで共通） */
function useCandidates(cands: Frame[], duration: number) {
  st.sampled = cands.length;
  st.duration = duration;
  const bySec = new Map<number, Frame[]>();
  for (const f of cands) { const k = Math.floor(f.t); bySec.set(k, [...(bySec.get(k) ?? []), f]); }
  // 1秒あたりに残す枚数：取り出した枚数の半分（最大 KEEP_PER_SEC）。1秒に6枚なら3枚、3枚なら2枚
  const keep = Math.min(KEEP_PER_SEC, Math.max(1, Math.ceil(cands.length / Math.max(1, duration) / 2)));
  st.frames = [...bySec.values()].flatMap((fs) => fs.sort((a, b) => b.sharp - a.sharp).slice(0, keep)).sort((a, b) => a.t - b.t);
  st.mode = 'video';
  st.coinSeeds = new Map();
  st.coinSeed = undefined;
}

async function loadImages(files: File[]) {
  st.frames = [];
  for (const [i, f] of files.slice(0, 2).entries()) {
    const bmp = await createImageBitmap(f, { imageOrientation: 'from-image' });
    st.frames.push({ t: i, canvas: canvasOf(bmp, bmp.width, bmp.height), sharp: 0 });
    bmp.close();
  }
  st.mode = 'photos';
  st.sampled = st.frames.length;
  st.duration = 0;
}

const COIN_MIN_PX = 14;   // これより小さく写った1円玉は、縮尺の精度が足りない
const PALM_MIN_PROPORTION = 1.1;  // 手首→中指の付け根 ÷ 付け根の幅 がこれより小さいフレームは、手の点が崩れている

/** 1円玉らしさ（小さいほどよい）。楕円の形・面積の比・大きさで判定し、だめなら null */
function coinScore(e: Ellipse | null, f: Frame): number | null {
  if (!e) return null;
  const maxPx = Math.max(f.canvas.width, f.canvas.height) * 0.3;
  // 投影の幅と、共分散からの長径が5%以上違うものは使わない（measurement.md §4.3）
  if (Math.abs(e.momentMajor - e.major) / e.major > 0.05) return null;
  if (e.ratio < 0.15 || e.areaRatio < 0.8 || e.areaRatio > 1.25 || e.major < COIN_MIN_PX || e.major > Math.min(400, maxPx)) return null;
  return Math.abs(e.areaRatio - 1) + Math.max(0, 0.6 - e.ratio) * 0.5;
}

/** 押した点のまわりの窓（画素とその明るさ） */
function windowAround(f: Frame, seed: { x: number; y: number }) {
  const W = f.canvas.width, H = f.canvas.height, L = Math.max(W, H);
  const half = Math.round(L * 0.1);  // 窓の半分の大きさ（1280pxなら128px）
  const sx = Math.round(seed.x * W), sy = Math.round(seed.y * H);
  const x0 = Math.max(0, sx - half), y0 = Math.max(0, sy - half);
  const w = Math.min(W, sx + half) - x0, h = Math.min(H, sy + half) - y0;
  if (w < 16 || h < 16) return null;
  const rgba = (f.canvas.getContext('2d') as CanvasRenderingContext2D).getImageData(x0, y0, w, h).data as Uint8ClampedArray;
  const gray = new Float32Array(w * h);
  for (let i = 0; i < w * h; i++) gray[i] = 0.299 * rgba[4 * i] + 0.587 * rgba[4 * i + 1] + 0.114 * rgba[4 * i + 2];
  return { x0, y0, w, h, half, rgba, gray, tap: { x: sx - x0, y: sy - y0 } };
}

/** 速い方法：近くの丸い斑点から、色で1円玉の領域を広げて楕円を当てる（数ミリ秒） */
function fastCoin(f: Frame, seed: { x: number; y: number }): { coin: Ellipse | null; small?: boolean } {
  const win = windowAround(f, seed);
  if (!win) return { coin: null };
  let small = false;
  const rMin = COIN_MIN_PX / 2, rMax = win.half / 1.8;
  const radii: number[] = [];
  for (let r = rMin; r <= rMax; r *= 1.3) radii.push(r);
  const spots = G.roundSpots(win.gray, win.w, win.h, win.tap, radii, 6);
  for (const sp of spots) {
    const e = G.fitCoinAt(win.rgba, win.w, win.h, sp.x, sp.y, sp.r);
    const coin = e ? { ...e, cx: e.cx + win.x0, cy: e.cy + win.y0 } : null;
    if (coinScore(coin, f) !== null) return { coin };
    if (e && e.major < COIN_MIN_PX && e.areaRatio > 0.8 && e.areaRatio < 1.2) small = true;
  }
  return { coin: null, small };
}

/** フレームの手の検出（結果を取っておく） */
function detectHand(f: Frame) {
  f.det ??= st.hand!.detect(f.canvas);
  return f.det;
}

/**
 * 1円玉を探す。まず OpenCV で画像全体から楕円を探す（指と関節の上は外し、手の甲の上を先に選び、手の大きさから1円玉の大きさの見当をつける）。
 * near（タップした点）があれば、その近くのものだけ。prev（前のフレームの1円玉）があれば、近くて大きさが近いもの。
 * 見つからなければ、タップした点か前の中心のまわりで、色で領域を広げる方法を使う。
 */
async function findCoin(f: Frame, opt: { near?: { x: number; y: number }; prev?: { cx: number; cy: number; major: number } } = {}) {
  const t0 = performance.now();
  const W = f.canvas.width, H = f.canvas.height, L = Math.max(W, H);
  const r = detectHand(f);
  const hand = r.landmarks.length === 1 ? r.landmarks[0].map((q) => ({ x: q.x * W, y: q.y * H })) : undefined;
  let coin: Ellipse | null = null, via = 'none', small = false;
  const list = await cvDetect(f, { hand, near: opt.near, prev: opt.prev, minMajor: COIN_MIN_PX }, 3);
  if (list) {
    const c = list.find((c) =>
      (!opt.near || Math.hypot(c.cx - opt.near.x, c.cy - opt.near.y) < Math.max(0.08 * L, c.major)) &&
      // 前のフレームの近く。手の上の1円玉はカメラの動きと一緒に動くので、手の上なら位置の差は問わない（11/9）
      (!opt.prev || c.onHand || Math.hypot(c.cx - opt.prev.cx, c.cy - opt.prev.cy) < 0.2 * L));
    if (c) { coin = c; via = 'opencv'; }
  }
  const seed = opt.near ?? (opt.prev ? { x: opt.prev.cx, y: opt.prev.cy } : undefined);
  if (!coin && seed) {
    const fast = fastCoin(f, { x: seed.x / W, y: seed.y / H });
    if (fast.coin && (!opt.prev || Math.abs(Math.log(fast.coin.major / opt.prev.major)) < 0.25)) { coin = fast.coin; via = 'color'; }
    small = !!fast.small;
  }
  console.debug(`findCoin: ${via}, ${Math.round(performance.now() - t0)}ms, 長径${coin ? coin.major.toFixed(1) : '-'}px 比${coin ? coin.ratio.toFixed(2) : '-'}`);
  return { coin, via, small };
}

function drawOverlay(f: Frame, opts: { coin?: Ellipse | null; landmarks?: boolean; tap?: { x: number; y: number } } = {}): string {
  const c = document.createElement('canvas');
  c.width = f.canvas.width; c.height = f.canvas.height;
  const ctx = c.getContext('2d')!;
  ctx.drawImage(f.canvas, 0, 0);
  const lw = Math.max(2, c.width / 300);
  const coin = 'coin' in opts ? opts.coin : f.coin;
  if (opts.tap) {  // タップした所に小さな十字を出す（どこを押したか分かるように）
    ctx.strokeStyle = '#ff4d4f'; ctx.lineWidth = lw;
    const r = lw * 5;
    ctx.beginPath(); ctx.moveTo(opts.tap.x - r, opts.tap.y); ctx.lineTo(opts.tap.x + r, opts.tap.y);
    ctx.moveTo(opts.tap.x, opts.tap.y - r); ctx.lineTo(opts.tap.x, opts.tap.y + r); ctx.stroke();
  }
  if (coin) {
    ctx.strokeStyle = '#FBBC04'; ctx.lineWidth = lw * 3;  // Figma S4 の黄色い輪（Google Yellow）
    ctx.beginPath();
    ctx.ellipse(coin.cx, coin.cy, coin.major / 2, coin.minor / 2, coin.angle, 0, Math.PI * 2);
    ctx.stroke();
  }
  if (opts.landmarks !== false && f.lm) {
    const p = f.lm;
    ctx.strokeStyle = '#2fd3b0'; ctx.lineWidth = lw;
    for (const ch of Object.values(G.CHAIN)) {
      ctx.beginPath(); ctx.moveTo(p[0].x, p[0].y);
      for (const k of ch) ctx.lineTo(p[k].x, p[k].y);
      ctx.stroke();
    }
    ctx.fillStyle = '#ffffff';
    for (const q of p) { ctx.beginPath(); ctx.arc(q.x, q.y, lw * 1.6, 0, Math.PI * 2); ctx.fill(); }
  }
  return toJpeg(c, 720, 0.8);
}

function cropHand(f: Frame): Promise<Blob> {
  const xs = f.lm!.map((p) => p.x), ys = f.lm!.map((p) => p.y);
  let x0 = Math.min(...xs), x1 = Math.max(...xs), y0 = Math.min(...ys), y1 = Math.max(...ys);
  const mx = (x1 - x0) * 0.2, my = (y1 - y0) * 0.2;
  x0 = Math.max(0, x0 - mx); y0 = Math.max(0, y0 - my);
  x1 = Math.min(f.canvas.width, x1 + mx); y1 = Math.min(f.canvas.height, y1 + my);
  const w = x1 - x0, h = y1 - y0, scale = 512 / Math.max(w, h);
  const c = document.createElement('canvas');
  c.width = Math.round(w * scale); c.height = Math.round(h * scale);
  c.getContext('2d')!.drawImage(f.canvas, x0, y0, w, h, 0, 0, c.width, c.height);
  return new Promise((res) => c.toBlob((b) => res(b!), 'image/jpeg', 0.85));
}

/** §6：フレームごとの値 */
function perFrame(f: Frame) {
  const p = f.lm!, s = f.s!;
  f.palmArea = G.triArea(p[0], p[5], p[17]) / (s * s);
  f.fingerLen = Object.fromEntries(G.FINGERS.map((fg) => {
    const [a, b, c, d] = G.CHAIN[fg];
    return [fg, (G.dist2(p[a], p[b]) + G.dist2(p[b], p[c]) + G.dist2(p[c], p[d])) / s];
  })) as Record<Finger, number>;
}

/** 画面に描かせてから次へ進む（重い処理の前に「探しています」などを出すため） */
const paint = () => new Promise<void>((r) => requestAnimationFrame(() => setTimeout(r, 30)));

/** §3〜§7：解析して採寸値を作る */
async function analyze(progress?: (stage: string, i: number, n: number) => void) {
  if (!st.coinSeed) throw new Error('1円玉の位置が決まっていません');
  const warnings = new Set<string>();
  let prev = st.coinRef;
  let prevS: number | undefined;
  const n = st.frames.length;
  for (const [i, f] of st.frames.entries()) {
    progress?.('手の形を調べています', i + 1, n);
    await paint();
    const r = detectHand(f);
    if (!r.landmarks.length) { f.reject = 'NO_HAND'; continue; }
    if (r.landmarks.length > 1) { f.reject = 'MULTIPLE_HANDS'; continue; }
    f.lm = r.landmarks[0].map((q) => ({ x: q.x * f.canvas.width, y: q.y * f.canvas.height }));
    f.world = (r.worldLandmarks[0] ?? []).map((q) => ({ x: q.x, y: q.y, z: q.z }));
    const edge = r.landmarks[0].some((q) => q.x < 0.05 || q.x > 0.95 || q.y < 0.05 || q.y > 0.95);
    if (edge) { f.reject = 'HAND_AT_EDGE'; continue; }
    // 手の点が崩れたフレームは使わない。握りこぶしを真上から撮ると、手首の点が手の甲のまん中（1円玉のすぐ下）に
    // 来て、手首→中指の付け根が付け根の幅と同じくらいか短く出る。本当の手は手首→中指の付け根の方がはっきり長い。
    // 崩れたフレームが多いと手が25%小さく測られ、ベルトのスリットがレールの台と重なった（2026-11-09。
    // IMG_0147 の比：崩れたフレーム 0.46〜1.01、ふつうのフレーム 1.18〜1.44。横から見たフレームは幅が縮むので大きく出る）
    if (G.dist2(f.lm[0], f.lm[9]) < PALM_MIN_PROPORTION * G.dist2(f.lm[5], f.lm[17])) { f.reject = 'HAND_POINTS_OFF'; continue; }
    // 動画は前のフレームの中心で追いかける。写真は1枚ずつ別の向きなので、写真ごとにタップした位置を使う
    const tapped = st.coinSeeds.get(i);
    const { coin } = st.mode === 'photos'
      ? await findCoin(f, { near: tapped ? { x: tapped.x * f.canvas.width, y: tapped.y * f.canvas.height } : undefined })
      : await findCoin(f, { prev });
    if (!coin) { f.reject = 'NO_COIN'; continue; }
    const s = coin.major / COIN_MM;
    // 1円玉の大きさが急に変わったら、別の物に乗り換えたとみなす。カメラを動かして撮るので、距離の変化の分（35%まで）は許す（11/9）
    if (st.mode === 'video' && prevS && Math.abs(s - prevS) / prevS > 0.35) { f.reject = 'COIN_JUMP'; continue; }
    f.coin = coin; f.s = s; prevS = s;
    f.coinOnHand = onBackOfHand({ x: coin.cx, y: coin.cy }, f.lm);
    prev = { cx: coin.cx, cy: coin.cy, major: coin.major };
    const w = f.world;
    if (w.length === 21) f.side = w[5].z < w[17].z ? 'thumb_side' : 'pinky_side';
    perFrame(f);
  }
  progress?.('まとめています', n, n);
  const ok = st.frames.filter((f) => f.s);
  if (ok.length < (st.mode === 'photos' ? 2 : 1)) {
    const why: Record<string, string> = { NO_HAND: '手が見つからない', MULTIPLE_HANDS: '手が2つ以上写っている', HAND_AT_EDGE: '手が画面の端にかかっている', HAND_POINTS_OFF: '手首の点がずれた（真上から撮ったときに起きやすい。横からも撮ってください）',NO_COIN: '1円玉が見つからない', COIN_JUMP: '1円玉の大きさが急に変わった' };
    const counts: Record<string, number> = {};
    for (const f of st.frames) if (f.reject) counts[f.reject] = (counts[f.reject] ?? 0) + 1;
    const detail = Object.entries(counts).map(([k, v]) => `${why[k] ?? k}：${v}枚`).join('、');
    throw new Error(`手と1円玉が両方写ったフレームが足りませんでした（${detail}）。撮り直してください。`);
  }
  if (st.mode === 'video' && ok.length < 10) warnings.add('FEW_FRAMES');
  if (st.coinManual) warnings.add('COIN_MANUAL');
  // 1円玉は手の甲のまん中に置く（2026-11-09）。机の上の1円玉はこぶしの高さの分だけカメラから遠く、小さく写るので、
  // 手が1.2〜1.5倍に大きく測られる（実測：こぶしの高さ 6〜7cm が約10cm に出た）。半分より多くのフレームで机の上なら知らせる
  if (ok.filter((f) => f.coinOnHand).length * 2 < ok.length) warnings.add('COIN_OFF_HAND');

  // 手の甲が真上に近いフレーム（手のひらの見かけの面積の上位20%）
  const maxArea = Math.max(...ok.map((f) => f.palmArea!));
  const topFrames = [...ok].sort((a, b) => b.palmArea! - a.palmArea!).slice(0, Math.max(1, Math.ceil(ok.length * 0.2)));
  for (const f of ok) if (f.palmArea! > 0.7 * maxArea) f.side = 'top';
  const views = new Set(ok.map((f) => f.side).filter(Boolean) as string[]);
  if (st.mode === 'video' && views.size < 3) warnings.add('VIEW_BIASED');

  const fingers: any = {};
  const anglesA: any = {}, anglesB: any = {};
  for (const fg of G.FINGERS) {
    const [a, b, c, d] = G.CHAIN[fg];
    const segLen = (i: number, j: number) => ok.map((f) => G.dist2(f.lm![i], f.lm![j]) / f.s!);
    const raw = [segLen(a, b), segLen(b, c), segLen(c, d)];
    const lengths = raw.map((xs) => G.topMedian(xs, 0.2, st.mode === 'photos' ? 1 : 3));
    raw.forEach((xs, k) => { if (st.mode === 'video' && G.iqr(xs) > 0.2 * lengths[k]) warnings.add('LENGTH_UNSTABLE'); });
    // 角度A：その指が長く写ったフレーム（横向き）の2Dの角度の中央値
    const lat = [...ok].sort((x, y) => y.fingerLen![fg] - x.fingerLen![fg]).slice(0, Math.max(1, Math.ceil(ok.length * 0.2)));
    const ang2 = (f: Frame) => {
      const p = f.lm!;
      return [G.angle2(G.sub2(p[a], p[0]), G.sub2(p[b], p[a])), G.angle2(G.sub2(p[b], p[a]), G.sub2(p[c], p[b])), G.angle2(G.sub2(p[c], p[b]), G.sub2(p[d], p[c]))];
    };
    const A = [0, 1, 2].map((k) => G.median(lat.map((f) => ang2(f)[k])));
    // 角度B：worldLandmarks の3Dの角度の中央値
    const ang3 = (f: Frame) => {
      const w = f.world!;
      return [G.angle3(G.sub3(w[a], w[0]), G.sub3(w[b], w[a])), G.angle3(G.sub3(w[b], w[a]), G.sub3(w[c], w[b])), G.angle3(G.sub3(w[c], w[b]), G.sub3(w[d], w[c]))];
    };
    const withWorld = ok.filter((f) => f.world?.length === 21);
    const B = [0, 1, 2].map((k) => G.median(withWorld.map((f) => ang3(f)[k])));
    anglesA[fg] = { mcp: r1(A[0]), pip: r1(A[1]), dip: r1(A[2]) };
    anglesB[fg] = { mcp: r1(B[0]), pip: r1(B[1]), dip: r1(B[2]) };
    // 指の開き（外転）：投影した基節が短いときは0度＋警告
    const abd: number[] = [];
    for (const f of topFrames) {
      const pf = G.palmFrame(f.lm!);
      const v = G.sub2(pf(f.lm![b]), pf(f.lm![a]));
      if (G.len2(v) / f.s! < 10) continue;
      abd.push((Math.atan2(v.x, v.y) * 180) / Math.PI);
    }
    let abduction = 0;
    if (abd.length) abduction = clamp(G.median(abd), -40, 40); else warnings.add('ABDUCTION_UNKNOWN');
    const useA = fg === 'index' || fg === 'pinky';
    const base = useA ? A : B;
    fingers[fg] = {
      lengths_mm: lengths.map((x) => r1(clamp(x, 1, 100))),
      radii_mm: [0, 0, 0],
      flexion_deg: { mcp: r1(clamp(base[0], -45, 135)), pip: r1(clamp(base[1], -45, 135)), dip: r1(clamp(base[2], -45, 135)) },
      abduction_deg: r1(abduction),
      angle_method: useA ? 'mp_lateral2d' : 'mp_world3d',
      iqr: { lengths_mm: raw.map((xs) => r1(G.iqr(xs))) },
    };
  }
  if (Object.values(fingers).some((f: any) => f.lengths_mm[0] < f.lengths_mm[1])) warnings.add('ODD_PROPORTION');

  // 手のひら：付け根の位置
  const mcpPos: any = {};
  for (const fg of G.FINGERS) {
    const k = G.CHAIN[fg][0];
    const xs = topFrames.map((f) => G.palmFrame(f.lm!)(f.lm![k]).x / f.s!);
    const ys = topFrames.map((f) => G.palmFrame(f.lm!)(f.lm![k]).y / f.s!);
    mcpPos[fg] = [r1(G.median(xs)), r1(Math.max(0, G.median(ys)))];
  }
  // 手の甲の4区間（§7.1。倍率に使う）：長く写ったフレームの上位20%の中央値
  const palm = palmSegments(ok, (f) => f.lm!, (f) => f.s!, st.mode === 'photos' ? 1 : 3);
  // 比較用の太さ：隣り合う指のPIPの間隔（§7.3。生成APIはメッシュから出し直す）
  const gap = (i: number, j: number) => G.median(topFrames.map((f) => G.dist2(f.lm![i], f.lm![j]) / f.s!));
  const g1 = gap(6, 10), g2 = gap(10, 14), g3 = gap(14, 18);
  const widths: Record<Finger, number> = { index: g1, middle: (g1 + g2) / 2, ring: (g2 + g3) / 2, pinky: g3 * 0.9 };
  for (const fg of G.FINGERS) {
    let w = widths[fg];
    if (!(w > 0) || w > 25) { w = palm.hand_width_mcp_mm / 3.4; warnings.add('FINGERS_SPREAD'); }
    const r = w / 2;
    fingers[fg].radii_mm = [r1(clamp(r, 3, 20)), r1(clamp(r * 0.9, 3, 20)), r1(clamp(r * 0.8, 3, 20))];
  }

  // 代表フレーム（上・親指側・小指側。§13）：上は手の甲が一番大きく写ったもの、横は手の甲の4区間が一番長く写ったもの
  const sum4 = (f: Frame) => PALM_SEGS.reduce((a, [i, j]) => a + G.dist2(f.lm![i], f.lm![j]) / f.s!, 0);
  const best = (xs: Frame[], fn: (f: Frame) => number) => xs.length ? [...xs].sort((a, b) => fn(b) - fn(a))[0] : undefined;
  const repList: { f: Frame; view: string }[] = [];
  const top = best(ok, (f) => f.palmArea!);
  if (top) repList.push({ f: top, view: 'top' });
  for (const side of ['thumb_side', 'pinky_side'] as const) {
    const f = best(ok.filter((x) => x.side === side && x !== top), sum4);
    if (f) repList.push({ f, view: side });
  }
  const repFrames = repList.map(({ f, view }) => ({
    frame_index: ok.indexOf(f), view, px_per_mm: r4(f.s!), width: f.canvas.width, height: f.canvas.height,
    image: drawOverlay(f), raw: toJpeg(f.canvas, 1280, 0.85),
    points: Object.fromEntries(PALM_POINTS.map((k) => [String(k), [r1(f.lm![k].x), r1(f.lm![k].y)]])),
  }));
  // hand-mesh に送るフレーム（最大8枚。代表フレーム＋等間隔）
  const meshFrames = [...new Set([...repList.map((x) => x.f), ...ok.filter((_, i) => i % Math.max(1, Math.floor(ok.length / 5)) === 0)])].slice(0, 8);

  const sVals = ok.map((f) => f.s!);
  const measurement = {
    schema_version: '2.2',
    hand_side: 'right',
    capture: {
      mode: st.mode,
      source: st.source,
      duration_s: st.mode === 'video' ? r1(clamp(st.duration, 0.1, MAX_SECONDS)) : undefined,
      frames_sampled: Math.min(90, Math.max(1, st.sampled)),
      frames_used: Math.min(60, ok.length),   // schemas/measurement.schema.json の上限（1秒あたり1〜3枚×最大25秒）
      mesh_consent: true,
      mesh_frames_sent: Math.max(1, Math.min(8, meshFrames.length)),
      mesh_id: '',
      mesh_result_token: '',
    },
    scale: { reference: 'jp_1yen', diameter_mm: 20.0, method: st.coinManual ? 'coin_manual' : st.coinTapped ? 'coin_tapped' : 'coin_auto', px_per_mm_median: r2(G.median(sVals)), px_per_mm_iqr: r2(G.iqr(sVals)) },
    fingers,
    palm: { mcp_positions_mm: mcpPos, ...palm, segments_source: 'auto' },
    calibration: { length_factor: LENGTH_FACTOR, source: LENGTH_FACTOR_SOURCE },
    manual_points: [] as any[],
    quality: { warnings: [...warnings], views_covered: [...views] },
    method_version: 'measure-2.2',
  };
  st.result = { measurement, anglesA, anglesB, meshFrames, ok, autoPalm: { ...palm } };
  const rejected: Record<string, number> = {};
  for (const f of st.frames) if (f.reject) rejected[f.reject] = (rejected[f.reject] ?? 0) + 1;
  return { measurement, rep_frames: repFrames, stats: { candidates: st.sampled, kept: n, used: ok.length, rejected } };
}

/** 手の甲の4区間（手首→人差し指・中指・小指の付け根、人差し指→小指の付け根）。§7.1・§8.2 */
const PALM_SEGS: [number, number, string][] = [[0, 5, 'wrist_to_index_mcp_mm'], [0, 9, 'wrist_to_middle_mcp_mm'], [0, 17, 'wrist_to_pinky_mcp_mm'], [5, 17, 'hand_width_mcp_mm']];
const PALM_POINTS = [0, 5, 9, 13, 17];

function palmSegments<T>(frames: T[], pts: (f: T) => P2[], scale: (f: T) => number, minN: number) {
  const out: Record<string, number> = {};
  for (const [i, j, key] of PALM_SEGS) {
    const xs = frames.map((f) => G.dist2(pts(f)[i], pts(f)[j]) / scale(f));
    out[key] = r1(G.topMedian(xs, 0.2, Math.min(minN, xs.length)));
  }
  return out as { wrist_to_index_mcp_mm: number; wrist_to_middle_mcp_mm: number; wrist_to_pinky_mcp_mm: number; hand_width_mcp_mm: number };
}

/**
 * §13：確認の画面で直した点（代表のフレームの手首と付け根の5点）から、手の甲の4区間を出し直す。
 * 直したフレームが1枚でもあれば、4区間は直したフレームだけの中央値にする。空なら自動の値に戻す。
 * 送る px_per_mm と点は丸めた値で計算する（サーバーが同じ値で計算し直して、1mm以内か確かめるため）
 */
function applyManualPoints(input: { frames: { frame_index: number; view: string; points: Record<string, number[]>; moved: number[] }[] }) {
  const r = st.result;
  if (!r?.final) throw new Error('先に手の3Dを作ってください');
  const m = structuredClone(r.final);
  const warnings = new Set<string>(m.quality.warnings);
  warnings.delete('POINTS_MANUAL');
  const frames = (input.frames ?? []).filter((x) => r.ok[x.frame_index]).slice(0, 3);
  if (!frames.length) {
    Object.assign(m.palm, r.autoPalm, { segments_source: 'auto' });
    m.manual_points = [];
  } else {
    const items = frames.map((x) => {
      const f: Frame = r.ok[x.frame_index];
      const pts: Record<string, number[]> = {};
      for (const k of PALM_POINTS) {
        const v = x.points[String(k)] ?? [f.lm![k].x, f.lm![k].y];
        pts[String(k)] = [r1(clamp(v[0], 0, 4096)), r1(clamp(v[1], 0, 4096))];
      }
      return { frame_index: x.frame_index, view: x.view, px_per_mm: r4(f.s!), points: pts, moved: [...new Set(x.moved)].filter((k) => PALM_POINTS.includes(k)) };
    });
    const asP2 = (it: (typeof items)[number]) => { const a: P2[] = []; for (const k of PALM_POINTS) a[k] = { x: it.points[String(k)][0], y: it.points[String(k)][1] }; return a; };
    for (const [i, j, key] of PALM_SEGS) {
      m.palm[key] = r1(G.median(items.map((it) => G.dist2(asP2(it)[i], asP2(it)[j]) / it.px_per_mm)));
    }
    m.palm.segments_source = 'manual';
    m.manual_points = items;
    warnings.add('POINTS_MANUAL');
  }
  m.quality.warnings = [...warnings];
  r.final = m;
  return { measurement: m };
}

/** §11：切り抜いたフレームを hand-mesh に送り、手の3Dメッシュ（mesh_id）と角度を受け取って採寸値に入れる */
async function callHandMesh(url: string, caseId: string, authName: string, authValue: string, handSide: string) {
  const r = st.result;
  if (!r) throw new Error('先に解析してください');
  const fd = new FormData();
  const frames = r.meshFrames as Frame[];
  fd.append('meta', JSON.stringify({ case_id: caseId, hand_side: handSide, frames: frames.map((f, i) => ({ name: `frame_${i}`, view: f.side ?? 'top' })) }));
  for (const [i, f] of frames.entries()) fd.append(`frame_${i}`, await cropHand(f), `frame_${i}.jpg`);
  const res = await fetch(url.replace(/\/$/, '') + '/v1/hand', { method: 'POST', body: fd, headers: { [authName]: authValue } });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const e = body?.error ?? body?.detail?.error ?? {};
    throw Object.assign(new Error(e.message ?? `手の3Dを作れませんでした（${res.status}）`), { code: e.code ?? (res.status === 429 ? 'MESH_UNAVAILABLE' : 'MESH_UNAVAILABLE'), retryable: e.retryable ?? (res.status >= 500 || (res.status === 429 && !e.code)) });
  }
  return JSON.stringify(mergeHandMesh(body, handSide));
}

/** hand-mesh の応答を採寸JSONに入れる（モックの応答にも使う） */
function mergeHandMesh(body: any, handSide: string) {
  const r = st.result;
  if (!r) throw new Error('先に解析してください');
  const m = structuredClone(r.measurement);
  m.hand_side = handSide;
  m.capture.mesh_id = body.mesh_id;
  m.capture.mesh_result_token = body.result_token;
  const warnings = new Set<string>(m.quality.warnings);
  for (const w of body.warnings ?? []) warnings.add(w);
  for (const fg of G.FINGERS) {
    const mesh = body.fingers?.[fg]?.flexion_deg;
    // メッシュ復元の角度がない指は、MediaPipeの角度で代わりにしない（ADR-0008）
    if (!mesh) throw Object.assign(new Error('手の3Dから指の角度が取れませんでした。撮り直してください'), { code: 'NO_HAND_DETECTED' });
    const alt = fg === 'index' || fg === 'pinky' ? r.anglesA[fg] : r.anglesB[fg];
    for (const k of ['mcp', 'pip', 'dip']) if (Math.abs(mesh[k] - alt[k]) > 15) warnings.add('ANGLE_DISAGREE');
    m.fingers[fg].flexion_deg = { mcp: r1(clamp(mesh.mcp, -45, 135)), pip: r1(clamp(mesh.pip, -45, 135)), dip: r1(clamp(mesh.dip, -45, 135)) };
    m.fingers[fg].angles_alt_deg = { method_a: r.anglesA[fg], method_b: r.anglesB[fg] };
    m.fingers[fg].angle_method = 'mesh_recovery';
  }
  m.quality.warnings = [...warnings];
  r.final = m;
  return { measurement: m, mesh: { mesh_id: body.mesh_id, mesh_stats: body.mesh_stats, joints_mm: body.joints_mm, frames_used: body.frames_used, model: body.model } };
}

const r1 = (x: number) => Math.round(x * 10) / 10;
const r2 = (x: number) => Math.round(x * 100) / 100;
const r4 = (x: number) => Math.round(x * 10000) / 10000;
const clamp = (x: number, a: number, b: number) => Math.min(b, Math.max(a, x));

function keepCoin(f: Frame, index: number, coin: Ellipse | null) {
  if (!coin) return;
  const c = { x: coin.cx / f.canvas.width, y: coin.cy / f.canvas.height };
  st.coinSeeds.set(index, c);
  if (index === 0) { st.coinSeed = c; st.coinRef = { cx: coin.cx, cy: coin.cy, major: coin.major }; }
  st.coinManual = false;
}

const api = {
  /** MediaPipe（約18MB）を読み込み、OpenCV.js（約11MB）の読み込みを裏で始める */
  init: () => init(),
  /** 動画を選ぶ（スマホではカメラが開く）。最初のフレームを返す */
  async pickVideo(progress?: (stage: string, i: number, n: number) => void) {
    const files = await pickFile('video/*', false, 'environment');
    if (!files.length) return JSON.stringify({ cancelled: true });
    await loadVideoFile(files[0], progress);
    st.source = 'file';
    if (!st.frames.length) throw new Error('フレームを取り出せませんでした');
    return JSON.stringify({ frames: st.frames.length, duration_s: st.duration, first: toJpeg(st.frames[0].canvas), width: st.frames[0].canvas.width, height: st.frames[0].canvas.height });
  },
  /** アプリの中でカメラを開く（スマホは背面、PCはWebカメラ）。el は映像を出す要素 */
  async startCamera(el: HTMLElement) {
    await init();
    return JSON.stringify(await Cam.startCamera(el, st.hand!));
  },
  async switchCamera() { return JSON.stringify(await Cam.switchCamera()); },
  /** 録画する。maxSec 秒か stopRecording で終わる。終わったら最初のフレームを返す */
  async record(maxSec: number, onTick?: (sec: number, hand: boolean) => void) {
    const raw = await Cam.startRecording(maxSec, onTick);
    const cands: Frame[] = raw.map((f) => ({ t: f.t, canvas: f.canvas, sharp: sharpnessOf(f.canvas) }));
    const dur = raw.length ? raw[raw.length - 1].t : 0;
    if (raw.length < 6) throw new Error('撮れたフレームが少なすぎます。もう一度撮ってください');
    useCandidates(cands, dur);
    st.source = 'live_camera';
    Cam.stopCamera();
    return JSON.stringify({ frames: st.frames.length, duration_s: dur, first: toJpeg(st.frames[0].canvas), width: st.frames[0].canvas.width, height: st.frames[0].canvas.height });
  },
  stopRecording() { Cam.stopRecording(); },
  stopCamera() { Cam.stopCamera(); },
  cameraStatus() { return JSON.stringify(Cam.cameraStatus()); },
  /** 写真2枚（上から・親指側の横から）を選ぶ */
  async pickPhotos() {
    const files = await pickFile('image/*', true);
    if (files.length < 2) return JSON.stringify({ cancelled: true, message: '写真を2枚選んでください' });
    await loadImages(files);
    st.source = 'file';
    return JSON.stringify({ frames: st.frames.length, first: toJpeg(st.frames[0].canvas), width: st.frames[0].canvas.width, height: st.frames[0].canvas.height });
  },
  /** i枚目のフレームで1円玉を自動で探す（タップなし）。楕円を重ねた画像を返す */
  async autoCoin(index = 0) {
    const f = st.frames[index];
    await paint();
    await init();
    const { coin, small } = await findCoin(f);
    keepCoin(f, index, coin);
    return JSON.stringify({ ok: !!coin, too_small: small, auto: true, major_px: coin?.major ?? null, image: drawOverlay(f, { coin, landmarks: false }) });
  },
  /** 自動で違う物を選んだとき、1円玉をタップした位置（0〜1）で探し直す */
  async setCoin(x: number, y: number, index = 0) {
    const f = st.frames[index];
    await paint();
    await init();
    const tap = { x: x * f.canvas.width, y: y * f.canvas.height };
    const { coin, small } = await findCoin(f, { near: tap });
    keepCoin(f, index, coin);
    if (coin) st.coinTapped = true;
    return JSON.stringify({ ok: !!coin, too_small: small, major_px: coin?.major ?? null, image: drawOverlay(f, { coin, landmarks: false, tap }) });
  },
  async analyze(progress?: (stage: string, i: number, n: number) => void) {
    return JSON.stringify(await analyze(progress));
  },
  /** hand-mesh（POST /v1/hand）を呼ぶ。authName は dev なら X-User、本番なら Authorization */
  async callHandMesh(url: string, caseId: string, authName: string, authValue: string, handSide: string) {
    return callHandMesh(url, caseId, authName, authValue, handSide);
  },
  /** hand-mesh の代わりに、モックの応答を入れる（開発用。本物の hand-mesh がないとき） */
  async useMockHandMesh(bodyJson: string, handSide: string) {
    return JSON.stringify(mergeHandMesh(JSON.parse(bodyJson), handSide));
  },
  /** 確認の画面で直した点から、手の甲の4区間を出し直す（§13） */
  async applyManualPoints(json: string) {
    return JSON.stringify(applyManualPoints(JSON.parse(json)));
  },
  /** i枚目のフレームの画像（写真モードで2枚目の1円玉を指定するため） */
  async frameImage(index: number) {
    const f = st.frames[index];
    if (!f) throw new Error('その写真はありません');
    return JSON.stringify({ first: toJpeg(f.canvas), width: f.canvas.width, height: f.canvas.height });
  },
  /** 動画とフレームを捨てる */
  reset() { Cam.stopCamera(); st.frames = []; st.result = undefined; st.coinSeed = undefined; st.coinRef = undefined; st.coinSeeds = new Map(); st.coinTapped = false; st.coinManual = false; },
};

/** Dart から扱いやすいよう、失敗も JSON（{"error": {...}}）で返す */
const safe = (fn: (...a: any[]) => Promise<string>) => async (...a: any[]) => {
  try { return await fn(...a); }
  catch (e: any) { return JSON.stringify({ error: { message: e?.message ?? String(e), code: e?.code ?? 'ENGINE_ERROR', retryable: !!e?.retryable } }); }
};
(window as any).jijoguMeasure = {
  init: safe(async () => { await api.init(); return '{}'; }),
  pickVideo: safe(api.pickVideo),
  pickPhotos: safe(api.pickPhotos),
  autoCoin: safe(api.autoCoin),
  setCoin: safe(api.setCoin),
  startCamera: safe(api.startCamera),
  switchCamera: safe(api.switchCamera),
  record: safe(api.record),
  stopRecording: api.stopRecording,
  stopCamera: api.stopCamera,
  cameraStatus: api.cameraStatus,
  frameImage: safe(api.frameImage),
  analyze: safe(api.analyze),
  callHandMesh: safe(api.callHandMesh),
  useMockHandMesh: safe(api.useMockHandMesh),
  applyManualPoints: safe(api.applyManualPoints),
  reset: api.reset,
};
window.dispatchEvent(new Event('jijogu-measure-ready'));
