"""描いたあとの検査 R6a〜R6g（generation-pipeline.md §4）。座標は正準形で見る。

R6c の「手のひらを向いた面の上にカバーがない」は、カバーの頂点ごとに一番近い手の面の向きで判定する
（作るときの決まりと同じ考え方。近くにあるだけの面まで数えると、指の横のふちで誤って止まるため）。
"""
from __future__ import annotations

import math

import numpy as np
import trimesh
from scipy.spatial import cKDTree

from .clipgeom import opening_mm
from .consts import fixed

PALM_FACE_CHECK_DEG = 50.0


class HandRef:
    """検査用：手の面の点と法線（正準形）。"""

    def __init__(self, hand: trimesh.Trimesh, n: int = 200_000):
        pts, fidx = trimesh.sample.sample_surface(hand, n, seed=1)
        self.pts = np.vstack([pts, hand.vertices])
        self.nrm = np.vstack([hand.face_normals[fidx], hand.vertex_normals])
        self.tree = cKDTree(self.pts)

    def dist(self, P: np.ndarray):
        d, i = self.tree.query(P, workers=-1)
        plane = np.abs(((P - self.pts[i]) * self.nrm[i]).sum(1))
        # 近い所は平面までの距離（点の拾い方に左右されない）
        return np.where(d < 2.0, plane, d), i


def _item(rule, ok, value, message_ja, fix_hint=None, severity="error"):
    return {"rule": rule, "ok": bool(ok), "value": value, "message_ja": message_ja,
            "fix_hint": fix_hint, "severity": severity}


def overhang_area(mesh: trimesh.Trimesh, down: np.ndarray, ignore_below: float | None = None) -> float:
    """down の向きに 45度を超えて張り出す面の面積（mm²）。"""
    n = mesh.face_normals
    cos45 = math.cos(math.radians(45))
    sel = (n @ down) > cos45
    if ignore_below is not None:
        h = mesh.triangles_center @ down
        sel &= h < (h.max() - ignore_below)
    return float(mesh.area_faces[sel].sum())


def check_cover(cover: trimesh.Trimesh, hand_ref: HandRef, cut: dict, bed=None) -> list[dict]:
    out = []
    bed = bed or fixed("BED_MM")
    wt = cover.is_watertight
    vol = float(cover.volume) if wt else 0.0
    ext = sorted(cover.extents.tolist())
    fits = all(e <= b for e, b in zip(ext, sorted(bed)))
    out.append(_item("R6a", wt and vol > 0 and fits, {"watertight": wt, "volume_mm3": round(vol, 1),
                     "extents_mm": [round(e, 1) for e in cover.extents]},
                     "カバーが閉じた立体で、造形できる大きさに収まる" if (wt and fits) else "カバーが閉じた立体でないか、造形サイズを超えています"))
    parts = cover.split(only_watertight=False)
    out.append(_item("R6b", len(parts) == 1, {"parts": len(parts)},
                     "カバーが1つのかたまり" if len(parts) == 1 else f"カバーが {len(parts)} 個に分かれています"))
    V = cover.vertices
    over = float((V[:, 2] - cut["palm_plane_z"]).max())
    d, idx = hand_ref.dist(V)
    nz = hand_ref.nrm[idx, 2]
    on_palm = (nz > math.cos(math.radians(PALM_FACE_CHECK_DEG))) & (d < cut["c"] + cut["t"] + 1.0)
    ok_c = over <= 0.3 and int(on_palm.sum()) == 0
    out.append(_item("R6c", ok_c, {"over_palm_plane_mm": round(over, 2), "vertices_over_palm_face": int(on_palm.sum())},
                     "手のひら側が開いている" if ok_c else "手のひら側にカバーがかかっています",
                     fix_hint="palm_cut_offset_mm を手の甲側へ"))
    ymin = float(V[:, 1].min())
    wf = float(fixed("WRIST_FREE_MM"))
    out.append(_item("R6d", ymin >= wf - 0.3, {"min_y_mm": round(ymin, 2), "limit_mm": wf},
                     "手首を覆っていない" if ymin >= wf - 0.3 else "手首にカバーがかかっています",
                     fix_hint="wrist_cut_mm を指先側へ"))
    dmin = float(d.min())
    out.append(_item("R6e", dmin >= cut["c"] - 0.3, {"min_dist_to_hand_mm": round(dmin, 2), "clearance_mm": cut["c"],
                     "thickness_mm": cut["t"]},
                     "手に食い込まない（厚さは作り方で t 以上）" if dmin >= cut["c"] - 0.3 else "カバーが手に近すぎます"))
    # R6g：刷る向き（手のひら側の切り口が下 ＝ 正準形の +z が下）での外側の張り出し（記録だけ）
    outer = trimesh.Trimesh(V, cover.faces, process=False)
    fc = outer.triangles_center
    dc, _ = hand_ref.dist(fc)
    n = outer.face_normals
    sel = ((n @ np.array([0, 0, 1.0])) > math.cos(math.radians(45))) & (dc > cut["c"] + cut["t"] * 0.6)
    area = float(outer.area_faces[sel].sum())
    out.append(_item("R6g", True, {"outer_overhang_mm2": round(area, 1)},
                     "外側の張り出しは少ない" if area <= 300 else "外側にもサポートが要るおそれがあります（印刷ガイドに出す）",
                     severity="info"))
    return out


def check_clip(clip_print: trimesh.Trimesh, clip: dict) -> list[dict]:
    out = []
    op = opening_mm(clip)
    td = float(clip["tool_d_mm"])
    ok_open = op < td - 0.5
    wt = clip_print.is_watertight
    parts = len(clip_print.split(only_watertight=False))
    area = overhang_area(clip_print, np.array([0, 0, -1.0]))
    # 机に接する底（z≈0）と入口の面取りは数えないので、底の面は除く
    n = clip_print.face_normals
    bottom = (clip_print.triangles_center[:, 2] < 0.3) & (n[:, 2] < -0.99)
    area -= float(clip_print.area_faces[bottom].sum())
    out.append(_item("R6f", ok_open and wt and parts == 1,
                     {"opening_mm": round(op, 2), "tool_d_mm": td, "watertight": wt, "parts": parts,
                      "overhang_mm2": round(area, 1)},
                     "クリップの開きは道具より狭く、1つのかたまり" if ok_open else "クリップの開きが広すぎて道具が抜けます"))
    if area > 50.0:
        out.append(_item("R6f_overhang", True, {"overhang_mm2": round(area, 1)},
                         "この角度のクリップは、サポートが要るかもしれません（印刷ガイドに出す）", severity="info"))
    return out


TOOL_TIP_MM = 100.0    # クリップから道具の先まで（ペン・筆の目安）
TOOL_REAR_MM = 50.0    # クリップから道具の後ろの端まで
TOOL_HAND_GAP_MM = 2.0   # 道具の面と手の間にほしいすき間
TOOL_COVER_GAP_MM = 1.0


def check_tool_path(hand_ref: HandRef, cover: trimesh.Trimesh | None, rail: dict, clip: dict, Jc: dict) -> list[dict]:
    """R6h：道具の通り道（正準形。手のひら側が +z）。クリップの位置から道具の軸を引き、
    手・カバーに当たらないか、机（手のひら側のいちばん低い点）に先が届くかを見る（2026-11-08。
    手の甲の上に付けた道具がどの角度でも指の背に当たり、机にも届かなかった件から）。"""
    from .clipgeom import clip_axis_rail, clip_center_rail
    Fm = np.asarray(rail["frame"], dtype=float)
    c = Fm.T @ clip_center_rail(clip) + np.asarray(rail["origin"], dtype=float)
    a = Fm.T @ clip_axis_rail(clip)
    r = float(clip["tool_d_mm"]) / 2
    ts = np.arange(-TOOL_REAR_MM, TOOL_TIP_MM + 0.5, 1.0)
    P = c[None, :] + ts[:, None] * a[None, :]
    dh, _ = hand_ref.dist(P)
    gap_hand = float(dh.min() - r)
    gap_cover = None
    if cover is not None and len(cover.vertices):
        dc, _ = cKDTree(cover.vertices).query(P, workers=-1)
        gap_cover = float(dc.min() - r)
    z_table = float(hand_ref.pts[:, 2].max())          # 手のひら側のいちばん低い点＝机
    reach = (z_table - c[2]) / a[2] if a[2] > 1e-6 else math.inf
    tilt = math.degrees(math.asin(float(np.clip(a[2], -1, 1))))
    tip = c + reach * a if math.isfinite(reach) else None
    mcp = Jc["index"][0]
    ok = gap_hand >= TOOL_HAND_GAP_MM and (gap_cover is None or gap_cover >= TOOL_COVER_GAP_MM) and reach <= TOOL_TIP_MM
    value = {"gap_hand_mm": round(gap_hand, 1), "gap_cover_mm": None if gap_cover is None else round(gap_cover, 1),
             "tilt_deg": round(tilt, 0), "reach_mm": None if not math.isfinite(reach) else round(float(reach), 0),
             "tip_from_index_mcp_mm": None if tip is None else [round(float(v), 0) for v in (tip - mcp)[:2]]}
    msg = "道具は手・カバーに当たらず、先が机に届く" if ok else \
        ("道具が手かカバーに当たります" if (gap_hand < TOOL_HAND_GAP_MM or (gap_cover is not None and gap_cover < TOOL_COVER_GAP_MM))
         else "道具の先が机に届きません（寝すぎ）")
    return [_item("R6h", ok, value, msg, fix_hint="c_clip.angle_deg を立てる", severity="warning")]
