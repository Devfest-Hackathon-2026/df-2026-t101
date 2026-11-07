"""スリット・空気穴・レールの位置と向き（parts-library.md §5）。正準形で計算する。

殻の外面の点は「手から c + t/2 より遠い頂点」とみなす（内面は手から c の所）。
"""
from __future__ import annotations

import numpy as np
import trimesh
from scipy.spatial import cKDTree

from .consts import LONG_FINGERS, fixed
from .handframe import palm_length, rail_direction

RAIL_HEIGHT = None  # rail.scad の rail_height()：溝の深さ＋溝の下の肉


def rail_height() -> float:
    return float(fixed("RAIL_DEPTH_MM")) + 2.0


def outer_surface(shell: trimesh.Trimesh, hand_tree: cKDTree, c: float, t: float):
    d, _ = hand_tree.query(shell.vertices)
    sel = d > c + t * 0.5
    return shell.vertices[sel], shell.vertex_normals[sel]


def _surface_has_ring(center, normal, outer_tree, radius, tol=1.6, n=12) -> bool:
    """中心のまわりの半径 radius の円の上に、殻の外面があるか（穴やスリットがふちにかからないか）。"""
    n_ = normal / (np.linalg.norm(normal) or 1.0)
    a = np.cross(n_, [1.0, 0, 0])
    if np.linalg.norm(a) < 0.3:
        a = np.cross(n_, [0, 1.0, 0])
    a /= np.linalg.norm(a)
    b = np.cross(n_, a)
    ang = np.linspace(0, 2 * np.pi, n, endpoint=False)
    ring = center + radius * (np.cos(ang)[:, None] * a + np.sin(ang)[:, None] * b)
    d, _ = outer_tree.query(ring)
    return bool(np.all(d < tol))


def place_rail(Jc: dict, radii: dict, outer_v, outer_n, c: float, t: float) -> dict:
    mid, u, dvec = rail_direction(Jc)
    # 基節の中点から外向きの光線の近くにある外面の頂点のうち、一番遠いもの
    rel = outer_v - mid
    s = rel @ dvec
    perp = np.linalg.norm(rel - s[:, None] * dvec, axis=1)
    sel = (s > 0) & (perp < 3.0)
    if sel.any():
        i = np.argmax(np.where(sel, s, -np.inf))
        anchor = outer_v[i]
    else:
        anchor = mid + dvec * (radii["index"][0] + c + t)
    z_r = dvec
    y_r = u
    x_r = np.cross(y_r, z_r)
    origin = anchor + z_r * rail_height()   # レールの上面（溝の口）の中心
    return {"anchor": anchor, "origin": origin, "frame": np.stack([x_r, y_r, z_r])}


def place_slits(Jc: dict, outer_v, outer_n, outer_tree, params: dict, edge_r: float) -> dict:
    L = palm_length(Jc)
    count = int(params.get("strap_count", 1))
    ys = [0.55 * L] if count == 1 else [0.45 * L, 0.70 * L]
    w = float(params.get("strap_width_mm", 25))
    th = float(params.get("strap_thickness_mm", 2.0))
    centers, normals, axes, skipped = [], [], [], []
    inset = fixed("MIN_WALL_MM") + (th + 1.5) / 2 + edge_r + 0.5
    t = float(params.get("_t", 2.5))
    for y in ys:
        band = np.abs(outer_v[:, 1] - y) < 1.2
        if band.sum() < 5:
            skipped.append({"y": round(float(y), 1), "reason": "殻がその高さにない"})
            continue
        bv, bn = outer_v[band], outer_n[band]
        for side in (-1, 1):                     # -1：親指側（x が小さい）、+1：小指側
            x_edge = float((side * bv[:, 0]).max() * side)
            target = x_edge - side * inset
            cand = np.abs(bv[:, 0] - target) < 1.5
            if not cand.any():
                skipped.append({"y": round(float(y), 1), "side": side, "reason": "スリットの場所がない"})
                continue
            ci = np.where(cand)[0]
            j = ci[np.argmin(bv[ci, 2])]        # 手の甲の側（z が小さい）の点
            n = bn[j] / (np.linalg.norm(bn[j]) or 1.0)
            centers.append(bv[j] - n * (t / 2))   # 壁の中ほど
            normals.append(n)
            axes.append(np.array([0.0, 1.0, 0.0]))
    return {"centers": centers, "normals": normals, "axes": axes, "skipped": skipped,
            "width": w, "thickness": th}


def place_holes(Jc: dict, outer_v, outer_n, outer_tree, params: dict, wrist_cut: float,
                avoid: list[tuple[np.ndarray, float]]) -> dict:
    count = int(params.get("count", 6))
    d = float(params.get("diameter_mm", 6.0))
    if count <= 0:
        return {"centers": [], "normals": [], "dropped": 0}
    y_lo = wrist_cut + 8.0
    y_hi = min(float(Jc[f][0][1]) for f in LONG_FINGERS) - 10.0
    if y_hi <= y_lo:
        return {"centers": [], "normals": [], "dropped": count}
    # 手の甲の外面（法線が −z 寄り）の頂点を候補にする
    top = (outer_n[:, 2] < -0.5) & (outer_v[:, 1] >= y_lo) & (outer_v[:, 1] <= y_hi)
    cv, cn = outer_v[top], outer_n[top]
    if len(cv) == 0:
        return {"centers": [], "normals": [], "dropped": count}
    # 2mm 格子で間引く
    key = np.round(cv[:, :2] / 2.0).astype(int)
    _, first = np.unique(key, axis=0, return_index=True)
    cv, cn = cv[first], cn[first]
    ok = []
    knuckles = [Jc[f][0] for f in LONG_FINGERS]
    for i, p in enumerate(cv):
        if any(np.linalg.norm(p[:2] - k[:2]) < 6.0 + d / 2 + 4.0 for k in knuckles):
            continue
        if any(np.linalg.norm(p - q) < 6.0 + d / 2 + r for q, r in avoid):
            continue
        if not _surface_has_ring(p, cn[i], outer_tree, d / 2 + fixed("MIN_WALL_MM")):
            continue
        ok.append(i)
    if not ok:
        return {"centers": [], "normals": [], "dropped": count}
    cv, cn = cv[ok], cn[ok]
    # 互いに離れた点を選ぶ（いちばん遠い点を順に選ぶ）
    chosen = [int(np.argmin(np.linalg.norm(cv[:, :2] - cv[:, :2].mean(0), axis=1)))]
    while len(chosen) < count:
        dmin = np.min(np.linalg.norm(cv[:, None, :] - cv[chosen][None, :, :], axis=2), axis=1)
        j = int(np.argmax(dmin))
        if dmin[j] < d + 4.0:
            break
        chosen.append(j)
    centers = [cv[j] for j in chosen]
    normals = [cn[j] / np.linalg.norm(cn[j]) for j in chosen]
    return {"centers": centers, "normals": normals, "dropped": count - len(centers)}


def tool_rod(rail: dict, clip: dict) -> tuple[np.ndarray, np.ndarray]:
    """確認用画像の道具の棒（正準形）。輪の中心から、輪の軸の向きに前へ120mm、後ろへ30mm。"""
    from .clipgeom import clip_center_rail, clip_axis_rail
    M = np.eye(4)
    M[:3, :3] = rail["frame"].T
    M[:3, 3] = rail["origin"]
    c = clip_center_rail(clip)
    a = clip_axis_rail(clip)
    cw = M[:3, :3] @ c + M[:3, 3]
    aw = M[:3, :3] @ a
    return cw - 30.0 * aw, cw + 120.0 * aw
