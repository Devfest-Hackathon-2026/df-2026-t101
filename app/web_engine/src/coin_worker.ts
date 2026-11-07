// 1円玉の自動検出を、画面とは別のスレッド（Web Worker）で動かす。検出（1フレーム0.1〜0.2秒）の間も画面が止まらない。
// 注意：OpenCV.js のモジュールは then を持つので、Promise の resolve に直接渡すと、then が呼ばれ続けて止まる。
// 必ず { cv } のように包んで渡す。
import { detectCoins } from './coin_cv';
import type { CoinHints } from './coin_cv';

declare const self: any;

let cvReady: Promise<{ cv: any }> | undefined;

function loadCv(url: string): Promise<{ cv: any }> {
  return new Promise((resolve, reject) => {
    try {
      self.importScripts(url); // UMD：Worker では self.cv に入る
    } catch (e: any) {
      reject(new Error('OpenCV を読み込めませんでした：' + (e?.message ?? e)));
      return;
    }
    const cv = self.cv;
    if (cv?.Mat) resolve({ cv });
    else cv.onRuntimeInitialized = () => resolve({ cv });
  });
}

self.onmessage = async (ev: MessageEvent) => {
  const m = ev.data;
  if (m.type === 'init') {
    cvReady ??= loadCv(m.url);
    try { await cvReady; self.postMessage({ type: 'ready' }); }
    catch (e: any) { self.postMessage({ type: 'error', message: e?.message ?? String(e) }); }
    return;
  }
  if (m.type === 'detect') {
    try {
      if (!cvReady) throw new Error('OpenCV がまだ読み込まれていません');
      const { cv } = await cvReady;
      const t0 = performance.now();
      const list = detectCoins(cv, new Uint8ClampedArray(m.rgba), m.w, m.h, m.hints as CoinHints, m.maxN);
      self.postMessage({ type: 'result', id: m.id, list, ms: performance.now() - t0 });
    } catch (e: any) {
      self.postMessage({ type: 'result', id: m.id, error: e?.message ?? String(e) });
    }
  }
};
