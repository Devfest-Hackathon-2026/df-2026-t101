"""フレームごとの推定を1つの手にまとめ、手の部分を切り出して、手の座標系に置く（docs/api.md §4、ADR-0010）。

1. 有効なフレームの shape・scale・hand の中央値で手を作り直す
2. 関節の角度が、まとめた手から30度を超えて外れたフレームを外して、もう一度まとめる
3. 手首の面で手の部分を切り出し、切り口をふさいで閉じた面にし、ループ細分割を1回かける
4. 手の座標系（measurement.md §8.1）に置く。左手なら鏡像に戻す。単位は mm、大きさは未補正
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Sequence, Tuple

import numpy as np
import trimesh

from angles import FINGERS, JOINTS, MHR70_RIGHT_FINGERS, MHR70_RIGHT_WRIST, _iqr, frame_flexion, to_canonical_left

OUTLIER_DEG = 30.0
CUT_OFFSET_M = 0.005      # 手首から5mm指側で切る
KEEP_RADIUS_RATIO = 1.4   # 手首から「手の長さ×1.4」より遠い所は捨てる
MIDDLE_MCP = MHR70_RIGHT_FINGERS["middle"][0]

Forward = Callable[[np.ndarray, np.ndarray, np.ndarray], Tuple[np.ndarray, np.ndarray, np.ndarray]]


class FusionError(Exception):
    pass


@dataclass
class Fused:
    verts_m: np.ndarray       # まとめた体（または手）のメッシュの頂点（m）
    faces: np.ndarray
    kps_m: np.ndarray         # MHR70 のキーポイント（m）。右手
    frame_angles: List[dict]  # 使ったフレームごとの角度
    frames_used: int
    frames_dropped: int = 0
    warnings: List[str] = field(default_factory=list)


def _angles(kps: np.ndarray) -> Optional[dict]:
    try:
        return frame_flexion(to_canonical_left(kps))
    except ValueError:
        return None


def _max_dev(a: dict, b: dict) -> float:
    return max(abs(a[f][j] - b[f][j]) for f in FINGERS for j in JOINTS)


def fuse(frames: Sequence[Optional[dict]], forward: Forward) -> Fused:
    """frames：フレームごとの {"shape","scale","hand","kps"}（手が出なければ None）。"""
    valid = []
    for fr in frames:
        if fr is None:
            continue
        ang = _angles(fr["kps"])
        if ang is not None:
            valid.append((fr, ang))
    if not valid:
        raise FusionError("NO_HAND_DETECTED")
    warnings = []
    if len(valid) < len(frames):
        warnings.append("MESH_FRAMES_DROPPED")  # 手の姿勢が出なかったフレームがある

    def run(items):
        med = {k: np.median(np.stack([fr[k] for fr, _ in items]), axis=0) for k in ("shape", "scale", "hand")}
        verts, kps, faces = forward(med["shape"], med["scale"], med["hand"])
        ang = _angles(kps)
        if ang is None:
            raise FusionError("NO_HAND_DETECTED")
        return verts, kps, faces, ang

    verts, kps, faces, fused_ang = run(valid)
    kept = [(fr, a) for fr, a in valid if _max_dev(a, fused_ang) <= OUTLIER_DEG]
    dropped = len(valid) - len(kept)
    if dropped and kept:
        verts, kps, faces, fused_ang = run(kept)
        warnings.append("MESH_OUTLIER_FRAMES")  # 角度が大きく外れたフレームを外した
    else:
        kept, dropped = valid, 0
    return Fused(verts, faces, kps, [a for _, a in kept], len(kept), dropped, warnings)


def fingers_from(fused: Fused) -> dict:
    """角度：まとめた手の関節から。ばらつき：フレームごとの角度の四分位範囲（0.1度に丸める）。"""
    fa = _angles(fused.kps_m)
    out = {}
    for f in FINGERS:
        out[f] = {
            "flexion_deg": {j: round(float(fa[f][j]), 1) for j in JOINTS},
            "iqr_deg": {j: round(_iqr([fr[f][j] for fr in fused.frame_angles]), 1) if len(fused.frame_angles) > 1 else 0.0
                        for j in JOINTS},
            "frames_used": fused.frames_used,
        }
    return out


# ---------------------------------------------------------------- 切り出しとふさぎ


def _boundary_loops(faces: np.ndarray) -> List[List[int]]:
    """面の向きに沿った境界の輪（ふさぐときに面の向きを保つため）。"""
    count = defaultdict(int)
    for f in faces:
        for a, b in ((f[0], f[1]), (f[1], f[2]), (f[2], f[0])):
            count[(min(a, b), max(a, b))] += 1
    nxt = {}
    for f in faces:
        for a, b in ((f[0], f[1]), (f[1], f[2]), (f[2], f[0])):
            if count[(min(a, b), max(a, b))] == 1:
                nxt[a] = b
    loops, seen = [], set()
    for start in list(nxt):
        if start in seen:
            continue
        loop, cur = [start], nxt[start]
        seen.add(start)
        while cur != start and cur not in seen and cur in nxt:
            loop.append(cur)
            seen.add(cur)
            cur = nxt[cur]
        if len(loop) >= 3:
            loops.append(loop)
    return loops


def cut_hand(verts: np.ndarray, faces: np.ndarray, kps: np.ndarray) -> trimesh.Trimesh:
    """手首の面で手の部分だけを切り出し、切り口を重心への扇でふさぐ。"""
    w = kps[MHR70_RIGHT_WRIST]
    n = kps[MIDDLE_MCP] - w
    n = n / np.linalg.norm(n)
    hand_len = max(np.linalg.norm(kps[i] - w) for i in range(21, 41))
    s = (verts - w) @ n
    d = np.linalg.norm(verts - w, axis=1)
    keep = (s > CUT_OFFSET_M) & (d < hand_len * KEEP_RADIUS_RATIO)
    if keep.sum() < 100:
        raise FusionError("HAND_CUT_EMPTY")
    idx = np.full(len(verts), -1)
    idx[keep] = np.arange(int(keep.sum()))
    m = trimesh.Trimesh(verts[keep], idx[faces[keep[faces].all(1)]], process=True)
    m = max(m.split(only_watertight=False), key=lambda p: len(p.faces))
    v, f = m.vertices.copy(), m.faces.copy()
    for loop in _boundary_loops(f):
        c = len(v)
        v = np.vstack([v, v[loop].mean(0)])
        f = np.vstack([f, [[loop[(i + 1) % len(loop)], loop[i], c] for i in range(len(loop))]])
    capped = trimesh.Trimesh(v, f, process=True)
    if not capped.is_watertight:
        raise FusionError("HAND_NOT_WATERTIGHT")
    if capped.volume < 0:
        capped.invert()
    return capped


def hand_frame(kps: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    """measurement.md §8.1 の手の座標系（R の行が x・y・z、原点は手首）。"""
    w = kps[MHR70_RIGHT_WRIST]
    x = kps[MHR70_RIGHT_FINGERS["pinky"][0]] - kps[MHR70_RIGHT_FINGERS["index"][0]]
    x = x / np.linalg.norm(x)
    y = kps[MIDDLE_MCP] - w
    y = y - x * (y @ x)
    y = y / np.linalg.norm(y)
    return np.stack([x, y, np.cross(x, y)]), w


def joints_dict(kps_mm: np.ndarray) -> Dict[str, list]:
    r = lambda p: [round(float(c), 2) for c in p]  # noqa: E731
    out = {"wrist": r(kps_mm[MHR70_RIGHT_WRIST])}
    for f, ids in MHR70_RIGHT_FINGERS.items():
        out[f] = [r(kps_mm[i]) for i in ids]  # 付け根・PIP（親指はMCP→IP）・DIP・指先
    return out


def build_hand_mesh(fused: Fused, hand_side: str, subdivide: int = 1) -> dict:
    """手の部分を切り出し、手の座標系（mm、未補正）に置いたメッシュと関節を返す。"""
    hand = cut_hand(fused.verts_m, fused.faces, fused.kps_m)
    if subdivide:
        hand = hand.subdivide_loop(iterations=subdivide)
    v, f, k = hand.vertices.copy(), hand.faces.copy(), fused.kps_m.copy()
    if hand_side == "left":
        # 右手として推定したので、鏡像に戻して実際の左手にする。面の向きも裏返す
        v[:, 0] *= -1.0
        k[:, 0] *= -1.0
        f = f[:, ::-1].copy()
    R, w = hand_frame(k)
    v_mm = (v - w) @ R.T * 1000.0
    k_mm = (k - w) @ R.T * 1000.0
    mesh = trimesh.Trimesh(v_mm, f, process=False)
    if mesh.volume < 0:
        mesh.invert()
    return {
        "vertices": mesh.vertices,
        "faces": mesh.faces,
        "joints_mm": joints_dict(k_mm),
        "stats": {"vertices": int(len(mesh.vertices)), "faces": int(len(mesh.faces)), "watertight": bool(mesh.is_watertight)},
    }
