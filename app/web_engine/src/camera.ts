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
  recording?: { start: number; frames: Candidate[]; timer: number; resolve: (f: Candidate[]) => void; maxSec: number; onTick?: (sec: number, hand: boolean) => void };
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

function startPreview(c: Cam, hand: HandLandmarker) {
  const tick = () => {
    if (!cam || cam !== c) return;
    if (c.video.readyState >= 2) {
      try {
        const small = makeCanvas(c.video, 480);
        const r = hand.detect(small);
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

export async function startCamera(el: HTMLElement, hand: HandLandmarker) {
  if (!navigator.mediaDevices?.getUserMedia) throw new Error('このブラウザではカメラを使えません（HTTPSで開いているか確かめてください）');
  stopCamera();
  el.innerHTML = '';
  el.style.position = 'relative';
  el.style.background = '#111';
  const video = document.createElement('video');
  video.muted = true; video.playsInline = true; video.autoplay = true;
  video.setAttribute('playsinline', '');
  // 枠いっぱいに広げる（cover）。はみ出た端は見えないが撮れているので、画面にこぶし全体が入っていれば、撮ったフレームにも必ず入る
  Object.assign(video.style, { position: 'absolute', inset: '0', width: '100%', height: '100%', objectFit: 'cover' });
  const overlay = document.createElement('canvas');
  Object.assign(overlay.style, { position: 'absolute', inset: '0', width: '100%', height: '100%', pointerEvents: 'none' });
  el.append(video, overlay);
  const c: Cam = { el, video, overlay, devices: [], deviceIndex: 0, mirror: false, status: { hand: false, lastSeen: 0 } };
  cam = c;
  try {
    await openStream(c);
  } catch (e: any) {
    cam = undefined;
    const name = e?.name ?? '';
    if (name === 'NotAllowedError') throw new Error('カメラの使用が許可されませんでした。ブラウザの設定でカメラを許可してください');
    if (name === 'NotFoundError') throw new Error('カメラが見つかりませんでした');
    throw new Error(`カメラを開けませんでした（${e?.message ?? name}）`);
  }
  startPreview(c, hand);
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
  if (cam.recording) window.clearTimeout(cam.recording.timer);
  cam.stream?.getTracks().forEach((t) => t.stop());
  cam.video.srcObject = null;
  cam.el.innerHTML = '';
  cam = undefined;
}
