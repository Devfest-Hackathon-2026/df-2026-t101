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
    assert names[("c_clip", "angle_deg")]["value"] == 20
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
