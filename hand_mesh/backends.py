"""推定の部分：SAM 3D Body（本物、GPU）と、決まった結果を返すモック。

どちらも次の2つを持つ（docs/api.md §4、ADR-0010）：
- infer_params(images, hand_side)：フレームごとに {"shape","scale","hand","kps"}（手が出なければ None）。
  kps は MHR70 の形 (70, 3)、右手、m。左手の画像は左右反転してから推定する（手のデコーダは右手だけ）
- forward(shape, scale, hand)：パラメータから1つの手（体）を作り直す → (頂点 m, kps (70,3) m, 三角形)
画像はメモリの中だけで扱う。
"""

from __future__ import annotations

import logging
import math
import os
import sys
import threading
import time
from pathlib import Path
from typing import List, Optional

import numpy as np

from angles import FINGERS, JOINTS, MHR70_RIGHT_FINGERS, MHR70_RIGHT_HAND_IDX, MHR70_RIGHT_WRIST, synthetic_right_keypoints

log = logging.getLogger("hand_mesh")

HERE = Path(__file__).resolve().parent
VENDOR_DIR = HERE / "vendor" / "sam-3d-body"
DEFAULT_HF_REPO = "facebook/sam-3d-body-vith"
CKPT_FILES = ("model_config.yaml", "model.ckpt", "assets/mhr_model.pt")


class BackendUnavailable(Exception):
    pass


# ---------------------------------------------------------------------------
# Mock
# ---------------------------------------------------------------------------

_MOCK_BASE = {
    "index": {"mcp": 48.0, "pip": 62.0, "dip": 18.0},
    "middle": {"mcp": 52.0, "pip": 68.0, "dip": 20.0},
    "ring": {"mcp": 55.0, "pip": 66.0, "dip": 19.0},
    "pinky": {"mcp": 58.0, "pip": 60.0, "dip": 16.0},
}


class MockBackend:
    """決まった結果を返す（画面と生成APIの開発用）。手のメッシュはカプセルの距離場から作る。"""

    name = "mock"
    model = "mock"
    device = "cpu"

    def __init__(self, reason: Optional[str] = None):
        self.reason = reason
        self._cache: dict = {}

    @property
    def model_loaded(self) -> bool:
        return True

    @property
    def status(self) -> str:
        return "ready"

    @staticmethod
    def _vec_to_angles(v: np.ndarray) -> dict:
        return {f: {j: float(v[i * 3 + k]) for k, j in enumerate(JOINTS)} for i, f in enumerate(FINGERS)}

    def infer_params(self, images: List[np.ndarray], hand_side: str) -> List[Optional[dict]]:
        """フレームの枚数と順番だけで決まる。手の姿勢は12個の角度を並べたもの。"""
        n = len(images)
        out = []
        for k in range(n):
            jitter = 3.0 * math.sin(1.7 * k + n)
            vec = np.array([_MOCK_BASE[f][j] + jitter * (1 + 0.3 * i) for i, f in enumerate(FINGERS) for j in JOINTS])
            c, s_ = math.cos(0.4 * k), math.sin(0.4 * k)
            rigid = np.array([[c, 0, s_], [0, 1, 0], [-s_, 0, c]])  # 見る向きを変える
            kps = synthetic_right_keypoints(self._vec_to_angles(vec), rigid)
            out.append({"shape": np.zeros(1), "scale": np.zeros(1), "hand": vec, "kps": kps})
        return out

    def forward(self, shape, scale, hand):
        key = tuple(np.round(np.asarray(hand), 1))
        if key not in self._cache:
            kps = synthetic_right_keypoints(self._vec_to_angles(np.asarray(hand)))
            verts, faces = _capsule_hand_mesh(kps * 1000.0)
            self._cache = {key: (verts / 1000.0, kps, faces)}  # 1つだけ覚えておく
        v, k, f = self._cache[key]
        return v.copy(), k.copy(), f.copy()


def _capsule_hand_mesh(kps_mm: np.ndarray):
    """キーポイント（右手、mm）から、カプセルをなめらかにつないだ閉じた手のメッシュを作る（モック用）。"""
    from skimage.measure import marching_cubes

    w = kps_mm[MHR70_RIGHT_WRIST]
    caps = []  # (a, b, 半径)
    radii = (9.0, 8.0, 7.5)
    for f in FINGERS:
        ids = MHR70_RIGHT_FINGERS[f]
        for i in range(3):
            caps.append((kps_mm[ids[i]], kps_mm[ids[i + 1]], radii[i]))
        caps.append((w, kps_mm[ids[0]], 13.0))  # 手のひら
    t = MHR70_RIGHT_FINGERS["thumb"]
    caps.append((w, kps_mm[t[0]], 14.0))
    for i in range(3):
        caps.append((kps_mm[t[i]], kps_mm[t[i + 1]], (11.0, 10.0, 9.0)[i]))
    caps.append((kps_mm[MHR70_RIGHT_FINGERS["index"][0]], kps_mm[MHR70_RIGHT_FINGERS["pinky"][0]], 12.0))
    fwd = kps_mm[MHR70_RIGHT_FINGERS["middle"][0]] - w
    fwd = fwd / np.linalg.norm(fwd)
    caps.append((w, w - fwd * 60.0, 24.0))  # 前腕（手首で切られる）
    pts_all = np.concatenate([np.stack([a, b]) for a, b, _ in caps])
    lo, hi = pts_all.min(0) - 30.0, pts_all.max(0) + 30.0
    step = 3.0  # 粗めでよい（細分割で滑らかになる。モック用）
    axes = [np.arange(lo[i], hi[i] + step, step) for i in range(3)]
    grid = np.stack(np.meshgrid(*axes, indexing="ij"), -1)
    p = grid.reshape(-1, 3)
    d = None
    k = 4.0  # なめらかにつなぐ幅（mm）
    for a, b, r in caps:
        ab = b - a
        tt = np.clip(((p - a) @ ab) / max(ab @ ab, 1e-9), 0, 1)
        di = np.linalg.norm(p - (a + tt[:, None] * ab), axis=1) - r
        if d is None:
            d = di
            continue
        h = np.clip(0.5 + 0.5 * (di - d) / k, 0, 1)  # なめらかな min
        d = di * (1 - h) + d * h - k * h * (1 - h)
    field = np.pad(d.reshape(grid.shape[:3]), 1, constant_values=50.0)
    v, f, _, _ = marching_cubes(field, 0.0, spacing=(step, step, step))
    v += lo - step
    return v, f


# ---------------------------------------------------------------------------
# SAM 3D Body
# ---------------------------------------------------------------------------


def _describe_hf_error(e: Exception, repo: str) -> str:
    try:
        from huggingface_hub.errors import GatedRepoError, LocalEntryNotFoundError, RepositoryNotFoundError
    except Exception:  # pragma: no cover
        GatedRepoError = LocalEntryNotFoundError = RepositoryNotFoundError = ()  # type: ignore
    from huggingface_hub import get_token

    if isinstance(e, GatedRepoError):
        if not get_token():
            return f"Hugging Face token not found: run `hf auth login` (access to {repo} is gated)"
        return f"access to {repo} not granted yet (gated repo): request access on huggingface.co and wait for approval"
    if isinstance(e, RepositoryNotFoundError):
        if not get_token():
            return f"Hugging Face token not found: run `hf auth login` ({repo})"
        return f"repository {repo} not found or not accessible with the current token"
    if isinstance(e, LocalEntryNotFoundError):
        return f"cannot download {repo} (offline?) and no local copy: {e}"
    return f"{type(e).__name__}: {e}"


class Sam3dBackend:
    name = "sam3d"
    model = "sam-3d-body"

    def __init__(self):
        self.repo = os.environ.get("HAND_MESH_HF_REPO", DEFAULT_HF_REPO)
        self.ckpt_dir = os.environ.get("HAND_MESH_CHECKPOINT_DIR") or None
        self.box_scale = float(os.environ.get("HAND_MESH_BOX_SCALE", "1.0"))
        self.device = "cuda"
        self._status = "not_loaded"
        self.reason: Optional[str] = None
        self._model = None
        self._transform_hand = None
        self._gpu_lock = threading.Lock()

    @property
    def model_loaded(self) -> bool:
        return self._model is not None

    @property
    def status(self) -> str:
        return self._status

    # -- loading -----------------------------------------------------------
    def _resolve_checkpoint(self) -> Path:
        if self.ckpt_dir:
            d = Path(self.ckpt_dir)
            missing = [f for f in CKPT_FILES if not (d / f).exists()]
            if missing:
                raise BackendUnavailable(f"HAND_MESH_CHECKPOINT_DIR={d} is missing {missing}")
            return d
        from huggingface_hub import hf_hub_download

        self._status = "downloading"
        paths = []
        try:
            for f in CKPT_FILES:  # uses the token cached by `hf auth login`
                paths.append(hf_hub_download(repo_id=self.repo, filename=f))
        except Exception as e:  # noqa: BLE001
            raise BackendUnavailable(_describe_hf_error(e, self.repo)) from e
        return Path(paths[0]).parent

    def load(self) -> None:
        t0 = time.time()
        try:
            import torch

            if not torch.cuda.is_available():
                raise BackendUnavailable("CUDA is not available (SAM 3D Body needs an NVIDIA GPU)")
            if str(VENDOR_DIR) not in sys.path:
                sys.path.insert(0, str(VENDOR_DIR))
            os.environ.setdefault("MOMENTUM_ENABLED", "0")  # use the TorchScript MHR in the checkpoint
            # Import first so a broken install is reported before a 2+ GB download.
            from sam_3d_body.data.transforms import (
                Compose,
                GetBBoxCenterScale,
                TopdownAffine,
                VisionTransformWrapper,
            )
            from sam_3d_body.models.meta_arch import SAM3DBody
            from sam_3d_body.utils.checkpoint import load_state_dict
            from sam_3d_body.utils.config import get_config
            from torchvision.transforms import ToTensor

            ckpt_dir = self._resolve_checkpoint()
            self._status = "loading"
            cfg = get_config(str(ckpt_dir / "model_config.yaml"))
            cfg.defrost()
            cfg.MODEL.MHR_HEAD.MHR_MODEL_PATH = str(ckpt_dir / "assets" / "mhr_model.pt")
            if cfg.MODEL.BACKBONE.get("FLASH_ATTN", False):
                try:
                    import flash_attn  # noqa: F401
                except ImportError:
                    cfg.MODEL.BACKBONE.FLASH_ATTN = False
            cfg.freeze()

            model = SAM3DBody(cfg)
            ckpt = torch.load(str(ckpt_dir / "model.ckpt"), map_location="cpu", weights_only=False)
            load_state_dict(model, ckpt.get("state_dict", ckpt), strict=False)
            del ckpt
            model = model.to("cuda").eval()

            # Same hand-crop transform as SAM3DBodyEstimator.transform_hand
            self._transform_hand = Compose(
                [
                    GetBBoxCenterScale(padding=0.9),
                    TopdownAffine(input_size=cfg.MODEL.IMAGE_SIZE, use_udp=False),
                    VisionTransformWrapper(ToTensor()),
                ]
            )
            self._model = model
            self.device = f"cuda:0 ({torch.cuda.get_device_name(0)})"
            self._status = "ready"
            self.reason = None
            log.info("SAM 3D Body loaded from %s in %.1fs", self.repo if not self.ckpt_dir else ckpt_dir, time.time() - t0)
        except BackendUnavailable as e:
            self._status = "failed"
            self.reason = str(e)
            raise
        except Exception as e:  # noqa: BLE001
            self._status = "failed"
            self.reason = f"{type(e).__name__}: {e}"
            raise BackendUnavailable(self.reason) from e

    # -- inference ---------------------------------------------------------
    def _box(self, h: int, w: int) -> np.ndarray:
        # Frames are already cropped around the hand (MediaPipe box + 20%), so the
        # whole frame (optionally scaled about its centre) is the hand box. No detector.
        side_w, side_h = w * self.box_scale, h * self.box_scale
        cx, cy = w / 2.0, h / 2.0
        return np.array([[cx - side_w / 2, cy - side_h / 2, cx + side_w / 2, cy + side_h / 2]], dtype=np.float32)

    def infer_params(self, images: List[np.ndarray], hand_side: str) -> List[Optional[dict]]:
        """フレームごとに、手のデコーダの形・比率・手の姿勢とキーポイントを返す。"""
        if self._model is None:
            raise BackendUnavailable(self.reason or f"model is {self._status}")
        import torch
        from sam_3d_body.data.utils.prepare_batch import prepare_batch
        from sam_3d_body.utils import recursive_to

        results: List[Optional[dict]] = []
        with self._gpu_lock, torch.no_grad():
            for img in images:
                if hand_side == "left":
                    img = np.ascontiguousarray(img[:, ::-1])  # 手のデコーダは右手だけ
                h, w = img.shape[:2]
                batch = prepare_batch(img, self._transform_hand, self._box(h, w))
                batch = recursive_to(batch, "cuda")
                self._model._initialize_batch(batch)
                out = self._model.forward_step(batch, decoder_type="hand")["mhr_hand"]
                kp3d = out["pred_keypoints_3d"][0].float().cpu().numpy()
                kp2d_crop = out["pred_keypoints_2d_cropped"][0].float().cpu().numpy()
                params = {k: out[k][0].float().cpu().numpy() for k in ("shape", "scale", "hand")}
                del batch, out
                hand2d = kp2d_crop[MHR70_RIGHT_HAND_IDX]
                # 上流の確かめ方（run_inference の CRITERIA 3）：手のキーポイントが切り抜きの中にある
                if not np.all(np.isfinite(kp3d[MHR70_RIGHT_HAND_IDX])) or np.abs(hand2d).max() >= 0.5:
                    results.append(None)
                else:
                    results.append({**params, "kps": kp3d})
        return results

    def forward(self, shape, scale, hand):
        """中央値のパラメータから1つの手を作り直す（体の向き・体の姿勢・表情は0。手首を基準にした向き）。"""
        if self._model is None:
            raise BackendUnavailable(self.reason or f"model is {self._status}")
        import torch

        head = self._model.head_pose_hand
        dev = "cuda"
        t = lambda a: torch.as_tensor(np.asarray(a), dtype=torch.float32, device=dev)[None]  # noqa: E731
        z = lambda n: torch.zeros(1, n, device=dev)  # noqa: E731
        with self._gpu_lock, torch.no_grad():
            verts, j3d, _jc, _params, _rots = head.mhr_forward(
                global_trans=z(3), global_rot=z(3), body_pose_params=z(133),
                hand_pose_params=t(hand), scale_params=t(scale), shape_params=t(shape), expr_params=z(72),
                return_keypoints=True, return_joint_coords=True, return_model_params=True, return_joint_rotations=True)
            v = verts[0].float().cpu().numpy()
            k = j3d[0, :70].float().cpu().numpy()
            f = head.faces.cpu().numpy()
        return v, k, f


# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------


class BackendManager:
    """HAND_MESH_BACKEND = auto (default) | sam3d | mock.

    auto : try SAM 3D Body in the background; on failure fall back to mock (logged).
    sam3d: SAM 3D Body only; while loading/failed, /v1/hand returns MESH_UNAVAILABLE.
    mock : mock only.
    """

    def __init__(self, requested: Optional[str] = None):
        self.requested = (requested or os.environ.get("HAND_MESH_BACKEND") or "auto").strip().lower()
        if self.requested not in ("auto", "sam3d", "mock"):
            raise ValueError(f"HAND_MESH_BACKEND must be sam3d|mock (got {self.requested!r})")
        self.sam3d: Optional[Sam3dBackend] = None
        self.active = None
        self.fallback_reason: Optional[str] = None
        if self.requested == "mock":
            self.active = MockBackend()
        else:
            self.sam3d = Sam3dBackend()

    def start(self, background: bool = True) -> None:
        if self.sam3d is None:
            log.info("hand-mesh backend: mock (HAND_MESH_BACKEND=mock)")
            return
        if background:
            threading.Thread(target=self._load, name="sam3d-loader", daemon=True).start()
        else:
            self._load()

    def _load(self) -> None:
        try:
            self.sam3d.load()
            self.active = self.sam3d
            log.info("hand-mesh backend: sam3d (%s)", self.sam3d.device)
        except BackendUnavailable as e:
            if self.requested == "auto":
                self.fallback_reason = str(e)
                self.active = MockBackend(reason=str(e))
                log.warning("SAM 3D Body unavailable -> FALLING BACK TO MOCK backend. Reason: %s", e)
            else:
                log.error("SAM 3D Body unavailable (HAND_MESH_BACKEND=sam3d, no fallback): %s", e)

    def current(self):
        """Backend to use now, or raise BackendUnavailable."""
        if self.active is not None:
            return self.active
        s = self.sam3d
        if s.status == "failed":
            raise BackendUnavailable(s.reason or "SAM 3D Body failed to load")
        raise BackendUnavailable(f"SAM 3D Body is {s.status}")

    def health(self) -> dict:
        b = self.active
        s = self.sam3d
        info = {
            "ok": b is not None,
            "backend": b.name if b is not None else "sam3d",
            "device": b.device if b is not None else (s.device if s else "cpu"),
            "model_loaded": bool(b is not None and b.model_loaded),
            "model": b.model if b is not None else "sam-3d-body",
            "requested_backend": self.requested,
        }
        if s is not None:
            info["sam3d"] = {"status": s.status, "repo": s.repo, "reason": s.reason}
        if self.fallback_reason:
            info["fallback_reason"] = self.fallback_reason
        return info
