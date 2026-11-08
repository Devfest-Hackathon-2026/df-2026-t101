"""形の計算（api/app/geometry）のテスト。OpenSCAD を使うものは test_geometry_scad.py。"""
from __future__ import annotations

import copy
from pathlib import Path

import numpy as np
import pytest
import trimesh

from app.geometry import GeometryError, prepare_measurement
from app.geometry.checks import HandRef, check_cover
from app.geometry.field import Field, compute_field
from app.geometry.glb import read_glb, write_glb
from app.geometry.handframe import (curl_sign, finger_radii, parse_joints, to_canonical_joints, to_canonical_mesh)
from app.geometry.shell import _mc_mesh, build_keepout

FIX = Path(__file__).parent / "fixtures"


def fixture_glb(name="hand_raw_fist"):
    p = FIX / f"{name}.glb"
    if not p.exists():
        pytest.skip(f"{p.name} がありません（担当 E1 の試験用メッシュ）")
    return p.read_bytes()


def make_measurement(J, k=1.15, hand_side="right"):
    L = lambda a, b: float(np.linalg.norm(a - b)) * k  # noqa: E731
    return {
        "schema_version": "2.2", "hand_side": hand_side,
        "palm": {"wrist_to_index_mcp_mm": L(J["wrist"], J["index"][0]),
                 "wrist_to_middle_mcp_mm": L(J["wrist"], J["middle"][0]),
                 "wrist_to_pinky_mcp_mm": L(J["wrist"], J["pinky"][0]),
                 "hand_width_mcp_mm": L(J["index"][0], J["pinky"][0]), "mcp_positions_mm": {}},
        "fingers": {f: {"lengths_mm": [L(J[f][s], J[f][s + 1]) for s in range(3)]}
                    for f in ("index", "middle", "ring", "pinky")},
    }


def test_glb_roundtrip_keeps_extras():
    m = trimesh.creation.icosphere(subdivisions=2, radius=10)
    data = write_glb(m.vertices, m.faces, {"joints_mm": {"wrist": [0, 0, 0]}, "hand_side": "left"})
    V, F, ex = read_glb(data)
    assert ex["hand_side"] == "left" and ex["joints_mm"]["wrist"] == [0, 0, 0]
    assert V.shape == m.vertices.shape and F.shape == m.faces.shape


def test_canonical_frame_curls_to_palm_side():
    V, F, ex = read_glb(fixture_glb())
    J = parse_joints(ex["joints_mm"])
    Jc = to_canonical_joints(J, ex.get("hand_side", "right"))
    assert curl_sign(Jc) > 0      # 正準形では指先が手のひら側（+z）へ曲がる
    Vc, Fc = to_canonical_mesh(V, F, "right")
    assert trimesh.Trimesh(Vc, Fc, process=False).volume > 0   # 鏡像でも面は外向き


def test_prepare_measurement_scale_and_landmarks():
    raw = fixture_glb()
    V, F, ex = read_glb(raw)
    J = parse_joints(ex["joints_mm"])
    r = prepare_measurement(raw, make_measurement(J, 1.15), "right", {"tool_d_mm": 9.5, "tool_type": "brush"})
    assert abs(r["scale_factor"] - 1.15) < 1e-6
    assert "MESH_SCALE_INCONSISTENT" not in r["warnings"]
    assert r["scale_source"] == "auto"
    V2, F2, ex2 = read_glb(r["scaled_glb"])
    assert np.allclose(V2, V * 1.15, atol=1e-3)
    assert ex2["joints_mm"]["index"][0][0] == pytest.approx(J["index"][0][0] * 1.15, abs=0.01)
    lm = r["cover_landmarks"]
    assert lm["frame"] == "hand_actual" and lm["palm_normal"] == [0.0, 0.0, -1.0]
    names = {(b["part_id"], b["name"]): b for b in r["baseline"]}
    assert names[("c_clip", "tool_d_mm")]["value"] == 9.5 and names[("c_clip", "tool_d_mm")]["source"] == "interview"
    assert names[("c_clip", "angle_deg")]["value"] == 70     # 筆＝70度（道具の立て具合。ADR-0013）
    assert names[("cover", "wrist_cut_mm")]["source"] == "measured"
    assert names[("cover", "wrist_cut_mm")]["value"] >= 25


def test_scale_inconsistent_and_out_of_range():
    raw = fixture_glb()
    J = parse_joints(read_glb(raw)[2]["joints_mm"])
    m = make_measurement(J, 1.15)
    for f in m["fingers"]:
        m["fingers"][f]["lengths_mm"] = [x * 1.4 for x in m["fingers"][f]["lengths_mm"]]
    assert "MESH_SCALE_INCONSISTENT" in prepare_measurement(raw, m, "right")["warnings"]
    with pytest.raises(GeometryError) as e:
        prepare_measurement(raw, make_measurement(J, 3.0), "right")
    assert e.value.code == "MEASUREMENT_INVALID"


def test_manual_points_must_match_palm_lengths():
    raw = fixture_glb()
    J = parse_joints(read_glb(raw)[2]["joints_mm"])
    m = make_measurement(J, 1.0)
    s = 4.0  # px/mm
    pts = {"0": J["wrist"][:2], "5": J["index"][0][:2], "9": J["middle"][0][:2], "13": J["ring"][0][:2],
           "17": J["pinky"][0][:2]}
    # 2D の点（x, y）だけなので、z を無視した長さにそろえる
    frame = {"frame_index": 0, "view": "top", "px_per_mm": s,
             "points": {k: [float(v[0] * s + 500), float(v[1] * s + 500)] for k, v in pts.items()}, "moved": [0]}
    m2 = copy.deepcopy(m)
    m2["manual_points"] = [frame]
    flat = lambda a, b: float(np.linalg.norm(a[:2] - b[:2]))  # noqa: E731
    m2["palm"].update({"wrist_to_index_mcp_mm": flat(J["wrist"], J["index"][0]),
                       "wrist_to_middle_mcp_mm": flat(J["wrist"], J["middle"][0]),
                       "wrist_to_pinky_mcp_mm": flat(J["wrist"], J["pinky"][0]),
                       "hand_width_mcp_mm": flat(J["index"][0], J["pinky"][0])})
    r = prepare_measurement(raw, m2, "right")
    assert r["scale_source"] == "manual_points" and "POINTS_MANUAL" in r["warnings"]
    m2["palm"]["hand_width_mcp_mm"] += 5.0
    with pytest.raises(GeometryError):
        prepare_measurement(raw, m2, "right")


def _sphere_field(r=20.0):
    s = trimesh.creation.icosphere(subdivisions=4, radius=r)
    J = {"wrist": np.zeros(3)}
    for i, f in enumerate(("thumb", "index", "middle", "ring", "pinky")):
        J[f] = np.array([[-200.0 + i, 0, 0]] * 4) + np.arange(4)[:, None] * [0, 1.0, 0]
    radii = {f: [5.0, 5.0, 5.0] for f in J if f != "wrist"}
    # 箱の切り方が球にかからないよう、関節は遠くに置き、手首の切り口・手のひら側の切り口の判定を外す
    from app.geometry import field as FM
    lo = s.vertices.min(0) - 12
    hi = s.vertices.max(0) + 12
    old = FM.field_bounds
    FM.field_bounds = lambda *a, **k: (lo, hi)
    try:
        return compute_field(s.vertices, s.faces, J, radii), s
    finally:
        FM.field_bounds = old


def test_field_sphere_keepout_and_band_volume():
    f, s = _sphere_field(20.0)
    assert isinstance(f, Field)
    c, t = 1.5, 2.5
    keep = build_keepout(f, c)
    assert keep.is_watertight
    assert keep.volume == pytest.approx(4 / 3 * np.pi * (20 + c) ** 3, rel=0.03)
    band = _mc_mesh(f, np.maximum(c - f.sdf, f.sdf - (c + t)).astype(np.float32))
    expect = 4 / 3 * np.pi * ((20 + c + t) ** 3 - (20 + c) ** 3)
    assert band.volume == pytest.approx(expect, rel=0.05)
    # 保存と読み込み
    g = Field.from_bytes(f.to_bytes())
    assert np.allclose(g.sdf, f.sdf) and g.voxel == f.voxel


def test_checks_catch_palm_and_wrist_violations():
    raw = fixture_glb()
    V, F, ex = read_glb(raw)
    J = parse_joints(ex["joints_mm"])
    Jc = to_canonical_joints(J, "right")
    Vc, Fc = to_canonical_mesh(V, F, "right")
    hand = trimesh.Trimesh(Vc, Fc, process=False)
    href = HandRef(hand, n=50_000)
    cut = {"c": 1.5, "t": 2.5, "palm_plane_z": 5.0}
    # 手の甲の上の箱（正しい）→ 通る
    top = trimesh.creation.box(extents=[20, 20, 2]).apply_translation([-10, 60, Vc[:, 2].min() - 5])
    res = {r["rule"]: r for r in check_cover(top, href, cut)}
    assert res["R6c"]["ok"] and res["R6d"]["ok"] and res["R6a"]["ok"]
    # 手のひら側の面より先に出た箱 → R6c で止まる
    bad = trimesh.creation.box(extents=[10, 10, 4]).apply_translation([-10, 60, 12.0])
    assert not {r["rule"]: r for r in check_cover(bad, href, cut)}["R6c"]["ok"]
    # 手首から25mm以内に入った箱 → R6d で止まる
    wrist = trimesh.creation.box(extents=[10, 10, 2]).apply_translation([-10, 15, Vc[:, 2].min() - 5])
    assert not {r["rule"]: r for r in check_cover(wrist, href, cut)}["R6d"]["ok"]


def test_finger_radii_reasonable():
    V, F, ex = read_glb(fixture_glb())
    J = parse_joints(ex["joints_mm"])
    Jc = to_canonical_joints(J, "right")
    Vc, _ = to_canonical_mesh(V, F, "right")
    r = finger_radii(Vc, Jc)
    for f in ("index", "middle", "ring", "pinky"):
        assert 3.0 <= r[f][0] <= 15.0


def _placement_for(name="hand_raw_fist", strap_count=1):
    """試験用の手でカバーの殻を作り、レールとスリットの位置を出す（正準形）。"""
    from scipy.spatial import cKDTree

    from app.geometry.placement import outer_surface, place_rail, place_slits
    from app.geometry.shell import build_shell, shell_cut_values
    raw = fixture_glb(name)
    J = parse_joints(read_glb(raw)[2]["joints_mm"])
    pm = prepare_measurement(raw, make_measurement(J, 1.15), "right", {"tool_d_mm": 9.5, "tool_type": "brush"})
    params = {}
    for b in pm["baseline"]:
        params.setdefault(b["part_id"], {})[b["name"]] = b["value"]
    V, F, _ = read_glb(pm["scaled_glb"])
    Jc = to_canonical_joints(parse_joints(pm["joints_mm"]), "right")
    Vc, Fc = to_canonical_mesh(V, F, "right")
    radii = finger_radii(Vc, Jc)
    cover_p = {**params["cover"], "clearance_mm": 1.5}
    c, t = 1.5, float(cover_p["cover_thickness_mm"])
    field = compute_field(Vc, Fc, Jc, radii)
    shell_c, _ = build_shell(field, Jc, radii, cover_p)
    href = HandRef(trimesh.Trimesh(Vc, Fc, process=False))
    ov, on = outer_surface(shell_c, href.tree, c, t)
    cut = shell_cut_values(cover_p, Jc, radii)
    rail = place_rail(Jc, radii, ov, on, c, t)
    sl = place_slits(Jc, ov, on, cKDTree(ov), {**params["strap_slits"], "strap_count": strap_count, "_t": t},
                     float(cover_p["edge_radius_mm"]), palm_z=cut["palm_plane_z"],
                     hand=trimesh.Trimesh(Vc, Fc, process=False), radii=radii, wrist_cut=float(cover_p["wrist_cut_mm"]))
    return Jc, cut, rail, sl


@pytest.mark.parametrize("name", ["hand_raw_fist", "hand_raw_right"])
def test_slit_y_follows_strap_window(name):
    """1本のベルトは、手ごとの「手のひらだけを通る通り道」（親指の下・指先の手前）の真ん中にスリットを置く。
    見つからない手では決まった割合の位置に置き、そのことを window に残す（2026-11-08）"""
    Jc, cut, rail, sl = _placement_for(name)
    win = sl["window"]
    assert win and win["source"] in ("thumb_gap", "fallback")
    ys = [float(c[1]) for c in sl["centers"]]
    assert all(abs(y - win["slit_y"]) < 2.5 for y in ys), (ys, win)   # 側面の点を拾うので ±1.5mm ＋ 壁の中ほどへの寄せ
    if win["source"] == "thumb_gap":
        # スリットは通り道の中（範囲の外へ寄せて「通せる」と言わない。2026-11-08 のレビュー）
        assert win["y_from"] <= win["slit_y"] <= win["y_to"], win
        y_mcp = min(float(Jc[f][0][1]) for f in ("index", "middle", "ring", "pinky"))
        assert win["slit_y"] < y_mcp      # 付け根の関節より手首側（カバーの中）
    else:
        assert win.get("reason")          # 見つからなかった理由を残す


def test_strap_window_on_simple_shapes():
    """通り道の判定そのもの：手のひら（箱）の手のひら側に、浮いた親指（円柱）がある所は通せ、ぴったり付いた所は通せない"""
    from app.geometry.placement import strap_window
    palm = trimesh.creation.box(extents=[80, 120, 30]); palm.apply_translation([0, 60, 0])            # z −15〜+15
    # 親指：y 0〜60 は手のひらに付いている（z 15〜27）、y 60〜120 は 8mm 浮いている（z 23〜35）
    th_on = trimesh.creation.cylinder(radius=6, height=60); th_on.apply_transform(trimesh.transformations.rotation_matrix(np.pi / 2, [1, 0, 0]))
    th_on.apply_translation([-25, 30, 21])
    th_off = trimesh.creation.cylinder(radius=6, height=60); th_off.apply_transform(trimesh.transformations.rotation_matrix(np.pi / 2, [1, 0, 0]))
    th_off.apply_translation([-25, 90, 29])
    hand = trimesh.util.concatenate([palm, th_on, th_off])
    far = np.array([500.0, 500, 500])
    Jc = {"wrist": np.zeros(3), "thumb": np.array([[-25, 0, 21], [-25, 60, 21], [-25, 60.01, 29], [-25, 120, 29]], float)}
    for f in ("index", "middle", "ring", "pinky"):
        Jc[f] = np.array([far, far + 1, far + 2, far + 3])
    radii = {"thumb": [6, 6, 6], **{f: [5, 5, 5] for f in ("index", "middle", "ring", "pinky")}}
    win = strap_window(hand, Jc, radii, 5, 115)
    assert win is not None and win["y_from"] >= 58 and win["y_to"] >= 110, win


@pytest.mark.parametrize("name", ["hand_raw_fist", "hand_raw_right"])
def test_slits_sit_on_side_walls_near_palm_edge(name):
    """スリットは側面（向きが横寄り）の、手のひら側のふちから決まった距離の高さに開く（2026-11-08。
    前は手の甲側の角に置いていて、親指側のスリットがレールの真下に来て塞がれた）。"""
    Jc, cut, rail, sl = _placement_for(name)
    assert sl["skipped"] == [] and len(sl["centers"]) == 2
    inset = 2.0 + (2.0 + 1.5) / 2 + 2.0 + 0.5           # MIN_WALL ＋ スリットの半分 ＋ 丸み ＋ 余裕
    for cen, n, side in zip(sl["centers"], sl["normals"], (-1, 1)):
        assert side * n[0] > 0.5 and abs(n[2]) <= 0.75, f"スリットの向きが横ではない: {n}"
        # 高さは決めた所の ±1.5mm で点を探し、さらに壁の中ほど（t/2）へ寄せるので、合わせて 3mm まで
        assert abs(cen[2] - (cut["palm_plane_z"] - inset)) <= 3.0, (cen, cut["palm_plane_z"])


def test_slit_rail_clearance_detects_overlap_on_short_walls():
    """試験用の2つの手は側面が低く（手のひら側を切る面が手の甲に近い）、スリットの高さにレールの台の角が来る。
    その重なりを距離（負）として検出できること。実際の手（側面15mm）では +2.7mm だった（11/8 の本番のケース）。"""
    from app.geometry.placement import slit_rail_clearance
    _, _, rail, sl = _placement_for("hand_raw_fist")
    assert slit_rail_clearance(sl, rail) < 2.0
    _, _, rail, sl = _placement_for("hand_raw_right", strap_count=2)
    assert len(sl["centers"]) == 4 and slit_rail_clearance(sl, rail) < 2.0


def test_slit_rail_clearance_box_geometry():
    """距離の計算そのもの：レールの座標でスリットの箱を置き、台の箱との距離が合うこと。"""
    from app.geometry.placement import RAIL_FOOT_MM, rail_height, rail_outer_w, slit_rail_clearance
    rail = {"origin": np.zeros(3), "frame": np.eye(3)}
    base = {"width": 25.0, "thickness": 2.0, "axes": [np.array([0.0, 1.0, 0.0])]}
    hx = rail_outer_w() / 2
    # 台の横（+X）に、壁の向きが X のスリット：穴の箱は X に ±(t/2+1)＝±2.25。中心を hx+2.25+5 に置けば距離 5
    sl = {**base, "centers": [np.array([hx + 2.25 + 5.0, 0.0, -3.0])], "normals": [np.array([1.0, 0.0, 0.0])]}
    assert slit_rail_clearance(sl, rail, wall_t=2.5) == pytest.approx(5.0, abs=0.05)
    # 土台の下（−Z）に、壁の向きが Z のスリット：箱の上端が土台の底より 3 下
    zb = -(rail_height() + RAIL_FOOT_MM)
    sl = {**base, "centers": [np.array([0.0, 0.0, zb - 3.0 - 2.25])], "normals": [np.array([0.0, 0.0, 1.0])]}
    assert slit_rail_clearance(sl, rail, wall_t=2.5) == pytest.approx(3.0, abs=0.05)
    # 台の中に中心があれば負
    sl = {**base, "centers": [np.array([0.0, 0.0, -2.0])], "normals": [np.array([1.0, 0.0, 0.0])]}
    assert slit_rail_clearance(sl, rail) < 0
