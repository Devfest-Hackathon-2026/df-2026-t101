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
RAIL_WALL_MM = 2.5   # common.scad の RAIL_WALL_MM（溝のまわりの肉）
RAIL_BASE_MM = 2.0   # common.scad の RAIL_BASE_MM（溝の底の下の肉）
RAIL_FOOT_MM = 6.0   # common.scad の RAIL_FOOT_MM（殻の中へ入り込ませる土台）


def rail_height() -> float:
    return float(fixed("RAIL_DEPTH_MM")) + RAIL_BASE_MM


def rail_outer_w() -> float:
    """レールの台の外の幅（common.scad の rail_outer_w()）"""
    import math
    bottom = float(fixed("RAIL_WIDTH_MM")) + 2 * float(fixed("RAIL_DEPTH_MM")) / math.tan(math.radians(float(fixed("RAIL_DOVETAIL_DEG"))))
    return bottom + 2 * RAIL_WALL_MM


def slit_rail_clearance(sl: dict, rail: dict, wall_t: float = 2.5) -> float:
    """スリットの穴（壁の中の部分）とレールの台（土台を含む箱）の、いちばん近い所の距離（mm）。
    重なっていれば負。レールの座標（原点＝上面の中心、X＝横、Y＝長さ、Z＝外向き）で、
    スリットの箱の面を細かく点にして、箱（軸に沿う）までの距離を取る。"""
    if not sl["centers"]:
        return float("inf")
    hx, hy = rail_outer_w() / 2, float(fixed("RAIL_LENGTH_MM")) / 2
    z_lo, z_hi = -(rail_height() + RAIL_FOOT_MM), 0.0
    half = np.array([hx, hy, (z_hi - z_lo) / 2])
    mid = np.array([0.0, 0.0, (z_hi + z_lo) / 2])
    Fm = np.asarray(rail["frame"])
    best = float("inf")
    g = np.linspace(-1, 1, 7)
    for cen, n, a in zip(sl["centers"], sl["normals"], sl["axes"]):
        n = np.asarray(n, float) / (np.linalg.norm(n) or 1.0)
        a0 = np.asarray(a, float) - (np.asarray(a, float) @ n) * n
        a0 /= (np.linalg.norm(a0) or 1.0)
        x = np.cross(a0, n)
        # 穴の箱：長い辺 ±(幅+1)/2、短い辺 ±(厚み+1.5)/2、壁の向きに ±(壁の厚み/2 + 1)
        e = np.array([(sl["thickness"] + 1.5) / 2, (sl["width"] + 1.0) / 2, wall_t / 2 + 1.0])
        U, Vv, W = np.meshgrid(g, g, g, indexing="ij")
        on_face = (np.abs(U) == 1) | (np.abs(Vv) == 1) | (np.abs(W) == 1)
        P = (np.asarray(cen, float)[None, :] + (U[on_face, None] * e[0]) * x + (Vv[on_face, None] * e[1]) * a0
             + (W[on_face, None] * e[2]) * n)
        R = (P - np.asarray(rail["origin"], float)) @ Fm.T - mid      # レールの座標、箱の中心を原点に
        q = np.abs(R) - half
        outside = np.linalg.norm(np.maximum(q, 0.0), axis=1)
        inside = np.minimum(q.max(axis=1), 0.0)
        best = min(best, float((outside + inside).min()))
    return best


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


SLIT_MAX_NZ = 0.7   # スリットを抜く向きの縦成分の上限（これより下向きなら横へ寄せる。ベルトは横〜斜め下へ出る）


def place_slits(Jc: dict, outer_v, outer_n, outer_tree, params: dict, edge_r: float, palm_z: float) -> dict:
    """ベルトのスリット（measurement.md §8.3・parts-library.md §5）。
    親指側・小指側の**側面**の、手のひら側のふちから inset（ふちの肉＋丸み＋スリットの半分）だけ手の甲側の高さで、
    いちばん外側の点に開ける。ベルトはそこから手のひらの下へ回る。手の甲側の角（レールの台がある所）には置かない
    （2026-11-08。前は角の手の甲側の点に置いていて、親指側のスリットがレールの真下に来て塞がれた）。
    側面が低くて（手のひら側を切る面が手の甲に近い）その高さに殻がなければ、置けなかったことを skipped に残す。
    palm_z：手のひら側を切る面の高さ（正準形。手のひら側が +z）。"""
    L = palm_length(Jc)
    count = int(params.get("strap_count", 1))
    ys = [0.55 * L] if count == 1 else [0.45 * L, 0.70 * L]
    w = float(params.get("strap_width_mm", 25))
    th = float(params.get("strap_thickness_mm", 2.0))
    centers, normals, axes, skipped = [], [], [], []
    inset = fixed("MIN_WALL_MM") + (th + 1.5) / 2 + edge_r + 0.5
    t = float(params.get("_t", 2.5))
    for y in ys:
        band = np.abs(outer_v[:, 1] - y) < 1.5
        if band.sum() < 5:
            skipped.append({"y": round(float(y), 1), "reason": "殻がその高さにない"})
            continue
        bv, bn = outer_v[band], outer_n[band]
        for side in (-1, 1):                     # -1：親指側（x が小さい）、+1：小指側
            sv = side * bv[:, 0] > 0
            if sv.sum() < 5:
                skipped.append({"y": round(float(y), 1), "side": side, "reason": "その側に殻がない"})
                continue
            v, n = bv[sv], bn[sv]
            # その側のふち（手のひら側の端）の高さ：いちばん外側の x から 6mm 以内の点の中で、いちばん手のひら側
            x_edge = float((side * v[:, 0]).max() * side)
            near = v[np.abs(v[:, 0] - x_edge) < 6.0]
            z_edge = min(float(near[:, 2].max()), float(palm_z))
            z_c = z_edge - inset
            at = np.abs(v[:, 2] - z_c) < 1.5
            if not at.any():
                skipped.append({"y": round(float(y), 1), "side": side, "reason": "側面が低く、スリットの高さに殻がない"})
                continue
            ci = np.where(at)[0]
            outer = ci[side * v[ci, 0] >= (side * v[ci, 0]).max() - 1.0]   # その高さで外側（1mm 以内）の点
            j = outer[np.argmin(np.abs(v[outer, 2] - z_c))]                 # の中で、決めた高さにいちばん近い点
            n_s = n[j] / (np.linalg.norm(n[j]) or 1.0)
            n_cut = n_s
            if abs(n_s[2]) > SLIT_MAX_NZ:                 # 下向きが強ければ、縦を SLIT_MAX_NZ に固定して横を伸ばす
                h = n_s[:2] / (np.linalg.norm(n_s[:2]) or 1.0)
                n_cut = np.array([*(h * np.sqrt(1.0 - SLIT_MAX_NZ ** 2)), np.sign(n_s[2]) * SLIT_MAX_NZ])
            centers.append(v[j] - n_s * (t / 2))     # 壁の中ほど
            normals.append(n_cut)
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
