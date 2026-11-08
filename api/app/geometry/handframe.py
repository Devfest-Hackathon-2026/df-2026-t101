"""手の座標系の道具：関節の読み方、正準形、メッシュから指の太さ・カプセル、カバーの目印。

座標（measurement.md §8.1）：原点＝手首、x＝人差し指の付け根→小指の付け根、y＝手首→中指の付け根から x 成分を除く、z＝x×y。
左手では z が手のひら側、右手では手の甲側になる。計算をそろえるため、右手は **z の符号を変えて** 正準形にする
（x を変える書き方もあるが、x を変えると「人差し指→小指」の向きが逆になり z も手の甲側のまま。z を変えると、
x・y はそのままで、z が手のひら側になる。どちらも鏡像で、ここでは z を変える）。
"""
from __future__ import annotations

import numpy as np

from .consts import FINGERS, LONG_FINGERS


def parse_joints(j: dict) -> dict:
    """{"wrist":[x,y,z], "index":[[4点]], ...} を numpy に。"""
    out = {"wrist": np.asarray(j["wrist"], dtype=float)}
    for f in FINGERS:
        pts = np.asarray(j[f], dtype=float)
        if pts.shape != (4, 3):
            raise ValueError(f"関節 {f} の形が違います: {pts.shape}")
        out[f] = pts
    return out


def joints_to_json(J: dict, nd: int = 2) -> dict:
    out = {"wrist": [round(float(v), nd) for v in J["wrist"]]}
    for f in FINGERS:
        out[f] = [[round(float(v), nd) for v in p] for p in J[f]]
    return out


def mirror_z(p: np.ndarray) -> np.ndarray:
    q = np.array(p, dtype=float, copy=True)
    q[..., 2] *= -1
    return q


def to_canonical_joints(J: dict, hand_side: str) -> dict:
    if hand_side == "left":
        return {k: np.array(v, copy=True) for k, v in J.items()}
    return {k: mirror_z(v) for k, v in J.items()}


def to_canonical_mesh(vertices: np.ndarray, faces: np.ndarray, hand_side: str):
    """鏡像のときは三角形の向きも裏返す（そのままだと面が内向きになる）。"""
    if hand_side == "left":
        return np.array(vertices, copy=True), np.array(faces, copy=True)
    return mirror_z(vertices), np.asarray(faces)[:, ::-1].copy()


# 正準形↔実際の手は同じ操作（z の反転）
to_actual_mesh = to_canonical_mesh
to_actual_joints = to_canonical_joints


def curl_sign(Jc: dict) -> float:
    """正準形で、指先が付け根より手のひら側（+z）にあるか（握るほど大きい）。確かめ用。"""
    return float(np.mean([Jc[f][3][2] - Jc[f][0][2] for f in LONG_FINGERS]))


def segments(Jc: dict):
    """指の区間の一覧 [(finger, idx, a, b)]（idx 0=基節 1=中節 2=末節）。"""
    out = []
    for f in FINGERS:
        for s in range(3):
            out.append((f, s, Jc[f][s], Jc[f][s + 1]))
    return out


def seg_dist(P: np.ndarray, a: np.ndarray, b: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """点群 P から線分 ab までの距離と、線分の上の位置 t（0〜1）。"""
    ab = b - a
    L2 = float(ab @ ab) or 1e-9
    t = np.clip(((P - a) @ ab) / L2, 0.0, 1.0)
    d = np.linalg.norm(P - (a + t[:, None] * ab), axis=1)
    return d, t


def finger_radii(vertices: np.ndarray, Jc: dict) -> dict:
    """メッシュから区間ごとの太さ（半径、mm）。measurement.md §7.3：区間に一番近い頂点のうち、
    区間の真ん中（両端から20%以上離れた所）の、軸からの距離の中央値。"""
    segs = segments(Jc)
    D = np.stack([seg_dist(vertices, a, b)[0] for _, _, a, b in segs], axis=1)
    near = D.argmin(axis=1)
    defaults = {0: 9.0, 1: 8.0, 2: 7.0}
    out = {f: [0.0, 0.0, 0.0] for f in FINGERS}
    for k, (f, s, a, b) in enumerate(segs):
        sel = near == k
        if sel.sum() >= 8:
            d, t = seg_dist(vertices[sel], a, b)
            mid = (t >= 0.2) & (t <= 0.8)
            vals = d[mid] if mid.sum() >= 5 else d
            r = float(np.median(vals))
        else:
            r = defaults[s]
        out[f][s] = round(min(max(r, 3.0), 18.0), 2)
    return out


def capsules(Jc: dict, radii: dict) -> list:
    return [{"finger": f, "segment": ["proximal", "middle", "distal"][s],
             "p1_mm": [round(float(v), 2) for v in a], "p2_mm": [round(float(v), 2) for v in b],
             "radius_mm": radii[f][s]} for f, s, a, b in segments(Jc)]


def palm_length(Jc: dict) -> float:
    """手首→中指の付け根（|0-9|）。"""
    return float(np.linalg.norm(Jc["middle"][0] - Jc["wrist"]))


def z_pip(Jc: dict) -> float:
    return float(np.mean([Jc[f][1][2] for f in LONG_FINGERS]))


def palm_cut_base(Jc: dict, palm_half_mm: float = 8.0) -> float:
    """手のひら側を切る平面の基準の高さ（正準形の z）。PIP の高さと、付け根の関節の中心＋palm_half_mm の浅い方"""
    z_mcp = float(np.mean([Jc[f][0][2] for f in ("index", "middle", "ring", "pinky")]))
    return min(z_pip(Jc), z_mcp + palm_half_mm)


RAIL_ALONG_METACARPAL = 0.72  # 手首→人差し指の付け根の、この割合の所にレールを置く（こぶしの山の少し手前）


def rail_direction(Jc: dict) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """人差し指の中手骨（手首→付け根）の上の点、レールの向き u、外向き d。正準形。
    指は覆わないので、レールは基節ではなく中手骨の上に置く（2026-11-07）。
    u は手の y（手首→指先）、d は親指側（−x）と手の甲側（−z）のちょうど間（45度）で固定する（2026-11-08。前は u を
    中手骨の向きにしていたが、人差し指の中手骨は手の y から約30度開いているので、クリップの「横」「前」が手ごとに
    ずれた。手の軸に合わせておけば、先に作っておいた固定STLのクリップが、どの手でも同じ向きでこぶしの横に来る）。"""
    a, b = Jc["wrist"], Jc["index"][0]
    u = np.array([0.0, 1.0, 0.0])
    d = np.array([-1.0, 0.0, -1.0]) / np.sqrt(2.0)
    return a + (b - a) * RAIL_ALONG_METACARPAL, u, d


def wrist_cut_default(Jc: dict, wrist_free: float) -> float:
    L = palm_length(Jc)
    return float(min(max(0.40 * L, wrist_free), max(wrist_free, L - 15.0)))
