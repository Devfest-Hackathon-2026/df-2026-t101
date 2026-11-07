"""カバーの殻と、内側を守る立体（generation-pipeline.md §6.2 の手順7〜10）。どれも正準形で作る。

殻の層：c ≤ sdf ≤ c+t。捨てる所（parts-library.md §4.1）を、なめらかな最大（半径 edge_radius_mm）でつなぐ：
  手のひら側の平面／手のひら・指の腹を向いた面の上／中節・末節の上／手首側／人差し指の外側／親指のまわり
"""
from __future__ import annotations

import numpy as np
import trimesh
from skimage.measure import marching_cubes

from .consts import LONG_FINGERS, fixed
from .field import Field
from .handframe import seg_dist

PALM_FACE_DEG = 60.0        # 一番近い面の向きが +z からこの角度以内なら捨てる
DEG_TO_MM = 0.2             # 角度の差を長さに直す（ほかの場と同じ尺度にするため。仮）


def smax(a: np.ndarray, b: np.ndarray, k: float) -> np.ndarray:
    """なめらかな最大（k は丸みの半径）。共通部分のふちが丸くなる。"""
    h = np.clip(0.5 - 0.5 * (b - a) / k, 0.0, 1.0)
    return b * (1 - h) + a * h + k * h * (1 - h)


def _grid_points(field: Field, mask: np.ndarray) -> np.ndarray:
    idx = np.argwhere(mask)
    return field.origin + idx * field.voxel


def _phalanx_field(P: np.ndarray, Jc: dict) -> np.ndarray:
    """基節・手の甲の骨より、中節・末節に近い所が正（捨てる）。二等分の面で分かれるので、PIP関節の山は半分残る。"""
    W = Jc["wrist"]
    d_prox = np.full(len(P), np.inf)
    d_dist = np.full(len(P), np.inf)
    for f in LONG_FINGERS:
        J = Jc[f]
        d_prox = np.minimum(d_prox, seg_dist(P, W, J[0])[0])
        d_prox = np.minimum(d_prox, seg_dist(P, J[0], J[1])[0])
        d_dist = np.minimum(d_dist, seg_dist(P, J[1], J[2])[0])
        d_dist = np.minimum(d_dist, seg_dist(P, J[2], J[3])[0])
    return d_prox - d_dist


def _thumb_dist(P: np.ndarray, Jc: dict, radii: dict) -> np.ndarray:
    d = np.full(len(P), np.inf)
    for s in range(3):
        ds, _ = seg_dist(P, Jc["thumb"][s], Jc["thumb"][s + 1])
        d = np.minimum(d, ds - radii["thumb"][s])
    return d


def shell_cut_values(params: dict, Jc: dict, radii: dict) -> dict:
    """殻を切る面の値（正準形）。検査（checks）でも同じ値を使う。"""
    c = float(params.get("clearance_mm", fixed("HAND_CLEARANCE_MM")))
    t = float(params["cover_thickness_mm"])
    z_pip = float(np.mean([Jc[f][1][2] for f in LONG_FINGERS]))
    return {
        "c": c, "t": t,
        "edge_r": float(params["edge_radius_mm"]),
        "palm_plane_z": z_pip + float(params.get("palm_cut_offset_mm", 0.0)),
        "wrist_cut": float(params["wrist_cut_mm"]),
        "x_cut": float(Jc["index"][0][0] - (radii["index"][0] + c + t)),
        "thumb_clear": c + t + float(fixed("THUMB_EXTRA_MM")),
    }


def _mc_mesh(field: Field, values: np.ndarray, pad_value: float = 5.0) -> trimesh.Trimesh:
    v = np.pad(values, 1, constant_values=pad_value)
    verts, faces, _, _ = marching_cubes(v, level=0.0, spacing=(field.voxel,) * 3)
    verts = verts + field.origin - field.voxel
    m = trimesh.Trimesh(verts, faces, process=True)
    if m.volume < 0:          # 外向きの面にそろえる（裏返しの立体は、引くと足される）
        m.invert()
    return m


def build_shell(field: Field, Jc: dict, radii: dict, params: dict) -> tuple[trimesh.Trimesh, dict]:
    """返す: (殻のメッシュ（正準形）, 情報 {cut, removed_fragments_cm3, parts})"""
    cut = shell_cut_values(params, Jc, radii)
    c, t, k = cut["c"], cut["t"], cut["edge_r"]
    sdf = field.sdf
    band = np.maximum(c - sdf, sdf - (c + t))
    # 層の近く（丸みの分を含む）だけで、切る所の場を計算する（速さのため）
    mask = np.abs(sdf - (c + t / 2)) < (t / 2 + k + 1.0)
    P = _grid_points(field, mask)
    f = band[mask].astype(np.float64)
    nzv = field.nz[mask].astype(np.float64) / 127.0
    ang = np.degrees(np.arccos(np.clip(nzv, -1, 1)))
    cuts = [
        P[:, 2] - cut["palm_plane_z"],                         # 手のひら側の平面
        (PALM_FACE_DEG - ang) * DEG_TO_MM,                     # 手のひら・指の腹を向いた面の上
        _phalanx_field(P, Jc),                                  # 中節・末節の上
        cut["wrist_cut"] - P[:, 1],                             # 手首側
        cut["x_cut"] - P[:, 0],                                 # 人差し指の外側
        cut["thumb_clear"] - _thumb_dist(P, Jc, radii),         # 親指のまわり
    ]
    for g in cuts:
        f = smax(f, g, k)
    full = np.full(sdf.shape, 5.0, dtype=np.float32)
    full[mask] = f
    m = _mc_mesh(field, full)
    parts = m.split(only_watertight=False)
    if not parts:
        return m, {"cut": cut, "removed_fragments_cm3": 0.0, "parts": 0}
    vols = [abs(p.volume) for p in parts]
    keep = int(np.argmax(vols))
    removed = float(sum(v for i, v in enumerate(vols) if i != keep)) / 1000.0
    return parts[keep], {"cut": cut, "removed_fragments_cm3": round(removed, 3), "parts": len(parts)}


def build_keepout(field: Field, c: float) -> trimesh.Trimesh:
    """手を c だけ広げた立体（sdf < c）。レールの土台などが内側へ出た分を、最後にこれで削る。"""
    return _mc_mesh(field, (field.sdf - c).astype(np.float32))
