// 3D表示（three.js）。Flutterからは window.jijoguViewer を dart:js_interop で呼ぶ。
// 手のメッシュ（GLB）と、カバー・C字クリップ（STL）は、同じ手の座標系（mm）で描かれているので、そのまま重ねる（docs/api.md §3.4）。
import * as THREE from 'three';
import { STLLoader } from 'three/addons/loaders/STLLoader.js';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
// OrbitControls は上下の回転が真上・真下で止まる（180度まで）ので、どの向きにも回せる TrackballControls を使う（2026-11-08）
import { TrackballControls } from 'three/addons/controls/TrackballControls.js';

const views = new WeakMap();
const SKIN = 0xf2c09e;

function setup(el) {
  if (views.has(el)) return views.get(el);
  const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, preserveDrawingBuffer: true });
  renderer.setPixelRatio(window.devicePixelRatio);
  el.style.touchAction = 'none';
  el.appendChild(renderer.domElement);
  const scene = new THREE.Scene();
  scene.add(new THREE.HemisphereLight(0xffffff, 0x8899aa, 1.6));
  const dir = new THREE.DirectionalLight(0xffffff, 1.3);
  dir.position.set(-80, -120, -160);
  scene.add(dir);
  const dir2 = new THREE.DirectionalLight(0xffffff, 0.6);
  dir2.position.set(120, 60, 100);
  scene.add(dir2);
  const camera = new THREE.PerspectiveCamera(35, 1, 1, 5000);
  const controls = new TrackballControls(camera, renderer.domElement);
  controls.rotateSpeed = 3.0;
  controls.zoomSpeed = 1.2;
  controls.panSpeed = 0.6;
  controls.dynamicDampingFactor = 0.15;
  const group = new THREE.Group();
  scene.add(group);
  // dorsal：手の甲の向きの z の符号（右手 +1、左手 −1。実際の手の座標では右手の手の甲が +z）。初期の視点は手の甲側から
  const state = { el, renderer, scene, camera, controls, group, hand: null, parts: new Map(), tool: null, toolD: 0, toolSpec: null, landmarks: null, framed: false, dorsal: 1 };
  const resize = () => {
    const w = el.clientWidth || 300, h = el.clientHeight || 300;
    renderer.setSize(w, h, false);
    renderer.domElement.style.width = '100%';
    renderer.domElement.style.height = '100%';
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
    controls.handleResize();
  };
  const ro = new ResizeObserver(resize);
  ro.observe(el);
  resize();
  state.ro = ro;
  const loop = () => {
    if (state.disposed) return;
    controls.update(); renderer.render(scene, camera);
    state.raf = requestAnimationFrame(loop);
  };
  loop();
  views.set(el, state);
  return state;
}

// 3D表示を片付ける（画面を閉じたとき）。iOS Safari は WebGL のコンテキストの数に上限（約16）があり、
// 角度を変えるたびに新しい表示を作るので、古いものを解放しないと表示が消え、裏で描画も回り続ける（2026-11-08）
function disposeView(el) {
  const state = views.get(el);
  if (!state) return;
  state.disposed = true;
  if (state.raf) cancelAnimationFrame(state.raf);
  state.ro?.disconnect();
  state.controls.dispose();
  dispose(state.group);
  state.renderer.dispose();
  state.renderer.forceContextLoss();
  state.renderer.domElement.remove();
  views.delete(el);
}

function frame(state) {
  const box = new THREE.Box3().setFromObject(state.group);
  if (box.isEmpty()) return;
  const size = box.getSize(new THREE.Vector3()).length();
  const center = box.getCenter(new THREE.Vector3());
  state.controls.target.copy(center);
  // 全体が収まる距離。縦長の画面（スマホ）では横の画角が狭いので、そのぶん離す
  const fov = (state.camera.fov * Math.PI) / 180;
  const dist = ((size / 2 / Math.tan(fov / 2)) * 1.1) / Math.min(1, state.camera.aspect);
  // 手の甲側（右手は +z、左手は −z）の、親指側（−x）の少し手首寄りから見る。手の甲を上にする
  const dz = state.dorsal || 1;
  state.camera.up.set(0, 0, dz);
  const d = new THREE.Vector3(-0.45, -0.35, 0.82 * dz).normalize();
  state.camera.position.copy(center).add(d.multiplyScalar(dist));
  state.camera.near = size / 100;
  state.camera.far = size * 20;
  state.camera.updateProjectionMatrix();
  state.framed = true;
}

function dispose(obj) {
  obj?.traverse?.((o) => { o.geometry?.dispose?.(); o.material?.dispose?.(); });
}

function loadStl(url, headers) {
  const l = new STLLoader();
  if (headers) l.setRequestHeader(headers);
  return l.loadAsync(url).then((geo) => { geo.computeVertexNormals(); return geo; });
}

function loadGlb(url, headers) {
  const l = new GLTFLoader();
  if (headers) l.setRequestHeader(headers);
  return l.loadAsync(url);
}

async function setHand(state, url, headers, opacity) {
  if (state.hand) { state.group.remove(state.hand); dispose(state.hand); state.hand = null; }
  if (!url) return;
  const gltf = await loadGlb(url, headers);
  const mat = new THREE.MeshStandardMaterial({ color: SKIN, roughness: 0.75, transparent: opacity < 1, opacity, depthWrite: opacity >= 1 });
  gltf.scene.traverse((o) => { if (o.isMesh) { o.material = mat; o.geometry.computeVertexNormals(); } });
  state.hand = gltf.scene;
  state.group.add(state.hand);
}

async function setPart(state, id, url, headers, color) {
  const old = state.parts.get(id);
  if (old) { state.group.remove(old); dispose(old); state.parts.delete(id); }
  if (!url) return;
  const geo = await loadStl(url, headers);
  const mesh = new THREE.Mesh(geo, new THREE.MeshStandardMaterial({ color, roughness: 0.55, metalness: 0.05 }));
  mesh.userData.partId = id;
  state.parts.set(id, mesh);
  state.group.add(mesh);
  if (id === 'c_clip') placeTool(state);
}

// 道具（筆など）の棒。生成APIが版に書いた軸（tool: {center, axis, tip_mm, rear_mm}。実際の手の座標）があればそれで描く。
// なければ（古い版）、クリップの輪の軸（頂点の広がりが一番小さい向き）を推定して、指先の向き（+y）へ伸ばす
function placeTool(state) {
  if (state.tool) { state.group.remove(state.tool); dispose(state.tool); state.tool = null; }
  const clip = state.parts.get('c_clip');
  if (!clip || !(state.toolD > 0)) return;
  const spec = state.toolSpec;
  if (spec && Array.isArray(spec.center) && Array.isArray(spec.axis)) {
    const c = new THREE.Vector3(...spec.center);
    const axis = new THREE.Vector3(...spec.axis).normalize();
    const tipL = spec.tip_mm || 100, rearL = spec.rear_mm || 50, len = tipL + rearL, r = state.toolD / 2;
    const g = new THREE.Group();
    const rod = new THREE.Mesh(new THREE.CylinderGeometry(r, r, len, 24), new THREE.MeshStandardMaterial({ color: 0xc8a165, roughness: 0.6 }));
    const tip = new THREE.Mesh(new THREE.ConeGeometry(r * 1.1, 22, 24), new THREE.MeshStandardMaterial({ color: 0x333333 }));
    tip.position.y = len / 2 + 11;
    g.add(rod, tip);
    g.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), axis);
    g.position.copy(c).add(axis.clone().multiplyScalar((tipL - rearL) / 2));   // クリップの位置が、後ろから rear_mm の所
    state.tool = g;
    state.group.add(g);
    return;
  }
  const pos = clip.geometry.attributes.position;
  const n = pos.count, c = new THREE.Vector3();
  for (let i = 0; i < n; i++) c.add(new THREE.Vector3().fromBufferAttribute(pos, i));
  c.divideScalar(n);
  const cov = [[0, 0, 0], [0, 0, 0], [0, 0, 0]];
  const v = new THREE.Vector3();
  for (let i = 0; i < n; i += Math.max(1, Math.floor(n / 4000))) {
    v.fromBufferAttribute(pos, i).sub(c);
    const a = [v.x, v.y, v.z];
    for (let r = 0; r < 3; r++) for (let s = 0; s < 3; s++) cov[r][s] += a[r] * a[s];
  }
  // べき乗法の逆：一番小さい固有値の向きを、大きい2つを取り除いて求める
  const m = new THREE.Matrix3().set(...cov[0], ...cov[1], ...cov[2]);
  const big = (mm) => { let x = new THREE.Vector3(1, 0.3, 0.2); for (let k = 0; k < 40; k++) x = x.applyMatrix3(mm).normalize(); return x; };
  const e1 = big(m);
  const l1 = e1.clone().applyMatrix3(m).dot(e1);
  const m2 = m.clone(); const o = e1.clone();
  const sub = new THREE.Matrix3().set(o.x * o.x, o.x * o.y, o.x * o.z, o.y * o.x, o.y * o.y, o.y * o.z, o.z * o.x, o.z * o.y, o.z * o.z).multiplyScalar(l1);
  for (let i = 0; i < 9; i++) m2.elements[i] -= sub.elements[i];
  const e2 = big(m2);
  const axis = new THREE.Vector3().crossVectors(e1, e2).normalize();
  if (axis.y < 0) axis.negate();
  const len = 150, r = state.toolD / 2;
  const g = new THREE.Group();
  const rod = new THREE.Mesh(new THREE.CylinderGeometry(r, r, len, 24), new THREE.MeshStandardMaterial({ color: 0xc8a165, roughness: 0.6 }));
  const tip = new THREE.Mesh(new THREE.ConeGeometry(r * 1.1, 22, 24), new THREE.MeshStandardMaterial({ color: 0x333333 }));
  tip.position.y = len / 2 + 11;
  g.add(rod, tip);
  g.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), axis);
  g.position.copy(c).add(axis.clone().multiplyScalar(len * 0.25));
  state.tool = g;
  state.group.add(g);
}

// カバーの目印（手のひら側を切る高さ、手首側の端）を薄い板で示す（S5）
function setLandmarks(state, lm) {
  if (state.landmarks) { state.group.remove(state.landmarks); dispose(state.landmarks); state.landmarks = null; }
  if (!lm || !state.hand) return;
  const box = new THREE.Box3().setFromObject(state.hand);
  const size = box.getSize(new THREE.Vector3()), center = box.getCenter(new THREE.Vector3());
  const g = new THREE.Group();
  const mat = (color) => new THREE.MeshBasicMaterial({ color, transparent: true, opacity: 0.18, side: THREE.DoubleSide, depthWrite: false });
  if (typeof lm.palm_cut_z === 'number') {
    const p = new THREE.Mesh(new THREE.PlaneGeometry(size.x * 1.2, size.y * 1.2), mat(0x2a9d8f));
    p.position.set(center.x, center.y, lm.palm_cut_z);
    g.add(p);
  }
  if (typeof lm.wrist_cut_y === 'number') {
    const p = new THREE.Mesh(new THREE.PlaneGeometry(size.x * 1.2, size.z * 1.2), mat(0xe76f51));
    p.rotation.x = Math.PI / 2;
    p.position.set(center.x, lm.wrist_cut_y, center.z);
    g.add(p);
  }
  state.landmarks = g;
  state.group.add(g);
}

const H = (json) => { try { const h = JSON.parse(json || '{}'); return Object.keys(h).length ? h : null; } catch { return null; } };

window.jijoguViewer = {
  // S5：手の3Dメッシュ（GLB）だけ。landmarksJson は { palm_cut_z, wrist_cut_y }（任意）
  async showHand(el, url, headersJson, landmarksJson) {
    const state = setup(el);
    const lmAll = JSON.parse(landmarksJson || 'null');
    state.dorsal = lmAll?.hand_side === 'left' ? -1 : 1;
    for (const id of [...state.parts.keys()]) await setPart(state, id, null);
    await setHand(state, url, H(headersJson), 1.0);
    setLandmarks(state, JSON.parse(landmarksJson || 'null'));
    frame(state);
  },
  // S7：手（半透明）＋部品＋道具の棒。sceneJson = { hand: {url, headers, opacity, visible}, parts: [{id, url, headers, color}], tool_d_mm,
  //   tool: {center, axis, tip_mm, rear_mm}（任意。生成APIが版に書いた道具の軸） }
  async showAssembly(el, sceneJson) {
    const state = setup(el);
    const s = JSON.parse(sceneJson);
    state.toolD = s.tool_d_mm || 0;
    state.toolSpec = s.tool || null;
    state.dorsal = s.hand_side === 'left' ? -1 : 1;
    if (s.hand?.url) {
      await setHand(state, s.hand.url, s.hand.headers, s.hand.opacity ?? 0.35);
      state.hand.visible = s.hand.visible !== false;
    }
    const want = new Set((s.parts || []).map((p) => p.id));
    for (const id of [...state.parts.keys()]) if (!want.has(id)) await setPart(state, id, null);
    for (const p of s.parts || []) await setPart(state, p.id, p.url, p.headers, p.color);
    if (!state.framed) frame(state);
  },
  // 1つの部品だけ差し替える（クリップの角度を変えたとき）
  async setPart(el, id, url, headersJson, color) {
    const state = setup(el);
    await setPart(state, id, url, H(headersJson), color);
  },
  setColor(el, color) {
    const state = views.get(el);
    if (!state) return;
    for (const m of state.parts.values()) m.material.color.set(color);
  },
  setHandVisible(el, visible) {
    const state = views.get(el);
    if (state?.hand) state.hand.visible = !!visible;
  },
  reframe(el) { const state = views.get(el); if (state) frame(state); },
  dispose(el) { disposeView(el); },
};
window.dispatchEvent(new Event('jijogu-viewer-ready'));
