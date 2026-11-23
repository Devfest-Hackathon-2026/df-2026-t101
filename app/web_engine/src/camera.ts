// アプリの中でカメラを開いて撮る（docs/measurement.md §2.3 の「拡張機能」を前倒し）。
// スマホは背面カメラ、PCはWebカメラ（内蔵カメラ）を使う。映像はこの端末の外に出さない。
// 撮っている間は、手の骨組みと案内を重ね、1秒に6枚の候補フレームをメモリに取っておく。
import type { HandLandmarker } from '@mediapipe/tasks-vision';
import { CHAIN } from './geometry';

export type Candidate = { t: number; canvas: HTMLCanvasElement };

type Cam = {
  el: HTMLElement;
  video: HTMLVideoElement;
  overlay: HTMLCanvasElement;
  stream?: MediaStream;
  devices: MediaDeviceInfo[];
  deviceIndex: number;
  mirror: boolean;
  previewTimer?: number;
  status: { hand: boolean; lastSeen: number };
  dbg?: Dbg;
  recording?:{ start: number; frames: Candidate[]; timer: number; resolve: (f: Candidate[]) => void; maxSec: number; onTick?: (sec: number, hand: boolean) => void };
};

let cam: Cam | undefined;
const SAMPLE_FPS = 6;
// 録画中にためる画像（1280px、1枚約3.7MB）は60枚まで。iOS Safari はキャンバスのメモリに上限があるので、
// 長く撮るときは1秒あたりの枚数を減らす（20秒なら1秒に3枚。2026-11-08 に撮影を15〜20秒にしたとき）
const MAX_CANDIDATES = 60;

function makeCanvas(src: HTMLVideoElement, longSide: number): HTMLCanvasElement {
  const w = src.videoWidth, h = src.videoHeight;
  const scale = Math.min(1, longSide / Math.max(w, h));
  const c = document.createElement('canvas');
  c.width = Math.round(w * scale); c.height = Math.round(h * scale);
  c.getContext('2d')!.drawImage(src, 0, 0, c.width, c.height);
  return c;
}

async function openStream(c: Cam): Promise<void> {
  c.stream?.getTracks().forEach((t) => t.stop());
  const dev = c.devices[c.deviceIndex];
  const video: MediaTrackConstraints = dev
    ? { deviceId: { exact: dev.deviceId }, width: { ideal: 1920 }, height: { ideal: 1080 } }
    : { facingMode: { ideal: 'environment' }, width: { ideal: 1920 }, height: { ideal: 1080 } };
  c.stream = await navigator.mediaDevices.getUserMedia({ video, audio: false });
  c.video.srcObject = c.stream;
  await c.video.play();
  const settings = c.stream.getVideoTracks()[0].getSettings();
  // 前面カメラ（PCのWebカメラを含む）は鏡のように見せる。取っておくフレームは反転しない
  c.mirror = settings.facingMode === 'user' || (!settings.facingMode && !/Android|iPhone|iPad/i.test(navigator.userAgent));
  c.video.style.transform = c.overlay.style.transform = c.mirror ? 'scaleX(-1)' : '';
  if (!c.devices.length) {
    c.devices = (await navigator.mediaDevices.enumerateDevices()).filter((d) => d.kind === 'videoinput');
    const cur = c.stream.getVideoTracks()[0].getSettings().deviceId;
    c.deviceIndex = Math.max(0, c.devices.findIndex((d) => d.deviceId === cur));
  }
}

function drawOverlay(c: Cam, landmarks?: { x: number; y: number }[]) {
  const o = c.overlay, r = c.el.getBoundingClientRect();
  if (o.width !== Math.round(r.width) || o.height !== Math.round(r.height)) { o.width = Math.round(r.width); o.height = Math.round(r.height); }
  const ctx = o.getContext('2d')!;
  ctx.clearRect(0, 0, o.width, o.height);
  if (!landmarks) return;
  // video は object-fit: cover で置いているので、表示の範囲（はみ出た所は見えない）を計算する
  const vw = c.video.videoWidth, vh = c.video.videoHeight;
  const s = Math.max(o.width / vw, o.height / vh);
  const ox = (o.width - vw * s) / 2, oy = (o.height - vh * s) / 2;
  const P = landmarks.map((p) => ({ x: ox + p.x * vw * s, y: oy + p.y * vh * s }));
  ctx.strokeStyle = '#2fd3b0'; ctx.lineWidth = 3;
  for (const ch of Object.values(CHAIN)) {
    ctx.beginPath(); ctx.moveTo(P[0].x, P[0].y);
    for (const k of ch) ctx.lineTo(P[k].x, P[k].y);
    ctx.stroke();
  }
  ctx.fillStyle = '#fff';
  for (const p of P) { ctx.beginPath(); ctx.arc(p.x, p.y, 3.5, 0, Math.PI * 2); ctx.fill(); }
}

// video：hand が VIDEO モードなら true（detectForVideo で前の画像の手を追いかける。時刻は前より大きくする）
let lastVideoTs = 0;
function startPreview(c: Cam, hand: HandLandmarker, video: boolean) {
  const tick = () => {
    if (!cam || cam !== c) return;
    if (c.video.readyState >= 2) {
      try {
        const small = makeCanvas(c.video, 480);
        let r;
        try {
          if (video) { lastVideoTs = Math.max(lastVideoTs + 1, Math.round(performance.now())); r = hand.detectForVideo(small, lastVideoTs); }
          else r = hand.detect(small);
        } finally {
          // 0.18秒ごとに作るので、iOS の Safari のキャンバスのメモリの上限に効く。検出が終わったらすぐ返す（engine.ts の releaseCanvas と同じ）
          small.width = 0; small.height = 0;
        }
        const lm = r.landmarks.length === 1 ? r.landmarks[0] : undefined;
        c.status.hand = !!lm;
        if (lm) c.status.lastSeen = performance.now();
        drawOverlay(c, lm);
      } catch { /* 1回の失敗は無視して次へ */ }
    }
    c.previewTimer = window.setTimeout(tick, 180);
  };
  tick();
}

// ---- カメラの起動を調べる表示（?camdebug=1 で開いたときだけ。2026-11-24） ----
// 映像・トラック・枠の大きさと、起動の各段階の時刻、メインスレッドが止まった時間を、映像の左上に出す
const DEBUG = /[?&#]camdebug=1/.test(location.href);
type Dbg = { t0: number; ev: string[]; box: HTMLDivElement; timer: number; last: number; dims: string };

function startDebug(c: Cam) {
  if (!DEBUG) return;
  const box = document.createElement('div');
  Object.assign(box.style, {
    position: 'absolute', left: '4px', top: '4px', zIndex: '2', font: '11px/1.35 monospace', color: '#3f3',
    background: 'rgba(0,0,0,.65)', padding: '4px 6px', whiteSpace: 'pre', pointerEvents: 'none',
  });
  c.el.append(box);
  const d: Dbg = { t0: performance.now(), ev: [], box, timer: 0, last: performance.now(), dims: '' };
  c.dbg = d;
  const update = () => {
    const now = performance.now(), v = c.video, r = c.el.getBoundingClientRect();
    if (now - d.last > 300) mark(c, `止まった ${Math.round(now - d.last)}ms`);
    d.last = now;
    const dims = `${v.videoWidth}x${v.videoHeight}`;
    if (dims !== d.dims) { d.dims = dims; mark(c, `映像 ${dims}`); }
    const tr = c.stream?.getVideoTracks()[0]?.getSettings();
    box.textContent = [
      `t=${Math.round(now - d.t0)}ms rs=${v.readyState} 表示=${v.style.opacity || '1'}`,
      `映像 ${dims} トラック ${tr?.width ?? '-'}x${tr?.height ?? '-'}`,
      `枠 ${Math.round(r.width)}x${Math.round(r.height)} dpr=${devicePixelRatio} ${screen.orientation?.type ?? ''}`,
      ...d.ev.slice(-10),
    ].join('\n');
  };
  d.timer = window.setInterval(update, 100);
  update();
}

function mark(c: Cam, s: string) {
  if (c.dbg) c.dbg.ev.push(`${Math.round(performance.now() - c.dbg.t0)}ms ${s}`);
}

// 検出器ごとに1回だけ、見えない小さな画像で検出しておく。初回の検出は GPU の準備で長く止まる（PC で約0.2秒、
// iPhone ではその数倍）。前は映像を出した直後にこれが起き、iPhone で映像の向き・大きさが切り替わる時と重なって、
// 初回だけ映像の大きさがおかしく見えた（待つと直った）。映像の大きさが落ち着いてから行う
const warmed = new WeakSet<HandLandmarker>();
function warmUp(hand: HandLandmarker, video: boolean) {
  if (warmed.has(hand)) return;
  warmed.add(hand);
  const t = document.createElement('canvas');
  t.width = 256; t.height = 256;
  t.getContext('2d')!.fillRect(0, 0, t.width, t.height);
  try {
    if (video) { lastVideoTs = Math.max(lastVideoTs + 1, Math.round(performance.now())); hand.detectForVideo(t, lastVideoTs); }
    else hand.detect(t);
  } catch { /* 準備だけなので、失敗しても表示の検出で同じことが起きるだけ */ }
  finally { t.width = 0; t.height = 0; }
}

// iPhone は映像が出た直後に、向きと大きさ（videoWidth・videoHeight）が切り替わることがある。
// 同じ大きさが 0.3 秒続くまで待つ（最大 2 秒。待ちきれなくても先へ進む）
async function settle(c: Cam) {
  const t0 = performance.now();
  let last = '', since = t0;
  while (cam === c && performance.now() - t0 < 2000) {
    const v = c.video, now = performance.now();
    const k = v.readyState >= 2 ? `${v.videoWidth}x${v.videoHeight}` : '';
    if (k !== last) { last = k; since = now; }
    else if (k && now - since >= 300) return;
    await new Promise((res) => window.setTimeout(res, 50));
  }
}

export type PreviewHand = { hand: HandLandmarker; tracking: boolean };

/** カメラを開く。ready（表示用の手の検出器）の読み込みとカメラの起動を並べて進める。映像は大きさが落ち着いたら見せ、
 *  検出器がそろって準備が済んだら手の検出を始めて終わる（終わるまでアプリは「撮り始める」を押せない） */
export async function startCamera(el: HTMLElement, ready: Promise<PreviewHand>) {
  if (!navigator.mediaDevices?.getUserMedia) throw new Error('このブラウザではカメラを使えません（HTTPSで開いているか確かめてください）');
  stopCamera();
  el.innerHTML = '';
  el.style.position = 'relative';
  el.style.background = '#111';
  const video = document.createElement('video');
  video.muted = true; video.playsInline = true; video.autoplay = true;
  video.setAttribute('playsinline', '');
  // 枠いっぱいに広げる（cover）。はみ出た端は見えないが撮れているので、画面にこぶし全体が入っていれば、撮ったフレームにも必ず入る。
  // 準備ができるまでは透明にしておく（display: none だと iPhone で再生が進まないことがあるので、透明にする）
  Object.assign(video.style, { position: 'absolute', inset: '0', width: '100%', height: '100%', objectFit: 'cover', opacity: '0' });
  const overlay = document.createElement('canvas');
  Object.assign(overlay.style, { position: 'absolute', inset: '0', width: '100%', height: '100%', pointerEvents: 'none' });
  el.append(video, overlay);
  const c: Cam = { el, video, overlay, devices: [], deviceIndex: 0, mirror: false, status: { hand: false, lastSeen: 0 } };
  cam = c;
  startDebug(c);
  const closed = () => new Error('カメラを閉じました');
  mark(c, 'カメラを開く');
  try {
    await openStream(c);
  } catch (e: any) {
    if (cam === c) stopCamera();
    const name = e?.name ?? '';
    if (name === 'NotAllowedError') throw new Error('カメラの使用が許可されませんでした。ブラウザの設定でカメラを許可してください');
    if (name === 'NotFoundError') throw new Error('カメラが見つかりませんでした');
    throw new Error(`カメラを開けませんでした（${e?.message ?? name}）`);
  }
  // 待っている間に画面を閉じた（stopCamera が呼ばれた）なら、あとから開いたカメラも止める
  if (cam !== c) { c.stream?.getTracks().forEach((t) => t.stop()); throw closed(); }
  mark(c, 'カメラが開いた');
  // 映像の大きさが落ち着いたら、検出器を待たずに見せる（初回は検出器の読み込みに数秒かかるので、その間も映像を出す）。
  // 初回の重い検出（warmUp）はこのあとで、映像は止まって見えるが、大きさはもう切り替わらないので乱れない
  // （2026-11-24 iPhone：重い検出を映像を見せる前に済ませたら、初回の乱れが消えた。順番をこの形にして早く出す）
  await settle(c);
  if (cam !== c) throw closed();
  video.style.opacity = '1';
  mark(c, '映像を見せた');
  let r: PreviewHand;
  try {
    r = await ready;
  } catch (e) {
    if (cam === c) stopCamera();
    throw e;
  }
  if (cam !== c) throw closed();
  mark(c, '検出器ができた');
  warmUp(r.hand, r.tracking);
  mark(c, '検出の準備が済んだ');
  startPreview(c, r.hand, r.tracking);
  return { cameras: c.devices.length, label: c.devices[c.deviceIndex]?.label ?? '', width: video.videoWidth, height: video.videoHeight };
}

export async function switchCamera() {
  if (!cam || cam.devices.length < 2) return { cameras: cam?.devices.length ?? 0 };
  cam.deviceIndex = (cam.deviceIndex + 1) % cam.devices.length;
  await openStream(cam);
  return { cameras: cam.devices.length, label: cam.devices[cam.deviceIndex]?.label ?? '' };
}

/** 録画（フレームをメモリに取っておく）。止めるか maxSec 秒で終わり、候補フレームを返す */
export function startRecording(maxSec: number, onTick?: (sec: number, hand: boolean) => void): Promise<Candidate[]> {
  const c = cam;
  if (!c) return Promise.reject(new Error('カメラが開いていません'));
  if (c.recording) return Promise.reject(new Error('録画中です'));
  return new Promise((resolve) => {
    const start = performance.now();
    const frames: Candidate[] = [];
    const grab = () => {
      const rec = c.recording;
      if (!rec) return;
      const sec = (performance.now() - start) / 1000;
      if (c.video.readyState >= 2) frames.push({ t: sec, canvas: makeCanvas(c.video, 1280) });
      rec.onTick?.(sec, c.status.hand);
      if (sec >= rec.maxSec) { finish(); return; }
      rec.timer = window.setTimeout(grab, 1000 / Math.min(SAMPLE_FPS, MAX_CANDIDATES / Math.max(1, rec.maxSec)));
    };
    const finish = () => {
      const rec = c.recording;
      if (!rec) return;
      window.clearTimeout(rec.timer);
      c.recording = undefined;
      rec.resolve(rec.frames);
    };
    c.recording = { start, frames, timer: 0, resolve, maxSec, onTick };
    (c.recording as any).finish = finish;
    grab();
  });
}

export function stopRecording() {
  const rec: any = cam?.recording;
  rec?.finish?.();
}

export function stopCamera() {
  if (!cam) return;
  window.clearTimeout(cam.previewTimer);
  if (cam.dbg) window.clearInterval(cam.dbg.timer);
  if (cam.recording) window.clearTimeout(cam.recording.timer);
  cam.stream?.getTracks().forEach((t) => t.stop());
  cam.video.srcObject = null;
  cam.el.innerHTML = '';
  cam = undefined;
}
