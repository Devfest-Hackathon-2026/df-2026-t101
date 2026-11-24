"""OpenSCAD を使う形のテスト（道具の留め具＝万力式、通しの make_design）。OpenSCAD がなければ飛ばす。"""
from __future__ import annotations

import shutil
from pathlib import Path

import numpy as np
import pytest
import trimesh

from app.geometry import DirCache, make_design, prepare_measurement
from app.geometry.checks import check_clip
from app.geometry.consts import openscad_bin
from app.geometry.glb import read_glb
from app.geometry.handframe import parse_joints
from app.geometry.scad import run

from test_geometry import fixture_glb, make_measurement

if not (Path(openscad_bin()).exists() or shutil.which(openscad_bin())):
    pytest.skip("OpenSCAD がありません", allow_module_level=True)


VISE = "vise_main.scad"   # 道具の留め具（万力式。2026-11-24 に C字クリップから置き換えた）


@pytest.mark.parametrize("angle", [60, 70, 80])
@pytest.mark.parametrize("hand", ["right", "left"])
def test_vise_prints_as_holder_and_screw(tmp_path, angle, hand):
    out = run({"mode": "clip", "c_clip_tool_d_mm": 9.5, "c_clip_angle_deg": angle, "hand": hand},
              tmp_path / f"vise_{hand}_{angle}.stl", entry=VISE)
    m = trimesh.load(out, force="mesh")
    assert m.is_watertight and len(m.split(only_watertight=False)) == 2      # 受け具とねじ
    assert abs(m.bounds[0][2]) < 0.05        # 机の面（z=0）に乗る
    res = {r["rule"]: r for r in check_clip(m, {"tool_d_mm": 9.5, "angle_deg": angle})}
    assert res["R6f"]["ok"], res["R6f"]
    assert res["R6f"]["value"]["grip_min_mm"] == 7.0 and res["R6f"]["value"]["grip_max_mm"] == 12.0


def test_vise_left_extends_to_the_other_side(tmp_path):
    """左手の留め具は、レールの座標で親指側（+X）へ張り出す（右手は −X）。鏡に映さずに描くので、形の大きさは同じ"""
    def asm(hand):
        return trimesh.load(run({"mode": "assembled", "part": "c_clip", "c_clip_tool_d_mm": 9.5, "c_clip_angle_deg": 70,
                                 "hand": hand}, tmp_path / f"{hand}.stl", entry=VISE), force="mesh")
    r, l = asm("right"), asm("left")
    assert r.bounds[0][0] < -20 and l.bounds[1][0] > 20
    assert np.allclose(r.bounds[:, 1:], l.bounds[:, 1:], atol=0.3)
    assert np.allclose(-r.bounds[::-1, 0], l.bounds[:, 0], atol=0.3)
    assert abs(r.volume - l.volume) < 20.0


@pytest.mark.parametrize("tool_d", [3.5, 9.5, 20.0])
def test_vise_tool_axis_sits_in_the_v(tmp_path, tool_d):
    """clipgeom の道具の軸（Python）が、OpenSCAD の受け具の V 字に収まる所（V 字の面から半径の距離）にある"""
    from app.geometry.clipgeom import clip_axis_rail, clip_center_rail
    clip = {"tool_d_mm": tool_d, "angle_deg": 70}
    m = trimesh.load(run({"mode": "assembled", "part": "c_clip", "c_clip_tool_d_mm": tool_d, "c_clip_angle_deg": 70,
                          "hand": "right"}, tmp_path / "asm.stl", entry=VISE), force="mesh")
    c, a = clip_center_rail(clip, side=1), clip_axis_rail(clip, side=1)
    from scipy.spatial import cKDTree
    tree = cKDTree(m.sample(200000, seed=1) if hasattr(m, "sample") else m.vertices)
    d, _ = tree.query([c + a * t for t in (-6.0, 0.0, 6.0)])
    assert np.all(np.abs(d - tool_d / 2) < 0.6), d


def test_vise_grows_for_thick_tools(tmp_path):
    def plate(d):
        return trimesh.load(run({"mode": "clip", "c_clip_tool_d_mm": d, "c_clip_angle_deg": 70}, tmp_path / f"p{d}.stl",
                                entry=VISE), force="mesh")
    small, big = plate(8.5), plate(18.0)
    assert big.volume > small.volume and big.extents[0] > small.extents[0]
    assert {r["rule"]: r for r in check_clip(big, {"tool_d_mm": 18.0, "angle_deg": 70})}["R6f"]["ok"]


def test_make_design_fist_cover_and_clip(tmp_path):
    raw = fixture_glb("hand_raw_fist")
    J = parse_joints(read_glb(raw)[2]["joints_mm"])
    pm = prepare_measurement(raw, make_measurement(J, 1.15), "right", {"tool_d_mm": 9.5, "tool_type": "brush"})
    params = {}
    for b in pm["baseline"]:
        params.setdefault(b["part_id"], {})[b["name"]] = b["value"]
    cache = DirCache(tmp_path / "cache")
    r = make_design(pm["scaled_glb"], pm["joints_mm"], "right", params, str(tmp_path / "job"), cache)
    checks = {c["rule"]: c for c in r["checks"]}
    for rule in ("R6a", "R6b", "R6c", "R6d", "R6e", "R6f"):
        assert checks[rule]["ok"], (rule, checks[rule])
    assert r["violations"] == []
    # 万力式（2026-11-24）は道具の軸が C字クリップより親指側の外にあるので、筆（70度）でも台をスリットから
    # 離れるまでずらせて、道具は握った指に当たらない（C字のときは、ずらせずにスリットがふさがっていた）
    assert checks["R6h"]["ok"] and r["placement"]["rail_shift_mm"] > 0
    assert checks["R6e_slit_open"]["ok"], checks["R6e_slit_open"]
    cover = trimesh.load(r["files"]["cover"], force="mesh")
    assert cover.is_watertight and len(cover.split(only_watertight=False)) == 1
    assert len(r["views"]) == 4 and all(Path(v).exists() for v in r["views"])
    assert r["placement"]["air_holes"] >= 3 and r["placement"]["strap_slits"] == 2
    # 道具の軸（実際の手の座標）：単位ベクトルで、右手では手のひら側（−z）へ下がる。中心はレールの近く
    t = r["tool"]
    assert abs(np.linalg.norm(t["axis"]) - 1) < 1e-3 and t["axis"][2] < -0.8 and t["tip_mm"] == 120
    assert np.linalg.norm(np.array(t["center"]) - np.array(r["placement"]["rail_origin"])) < 30
    # 2回目は距離場と殻を使い回すので速い
    r2 = make_design(pm["scaled_glb"], pm["joints_mm"], "right", params, str(tmp_path / "job2"), cache, quality="print")
    assert "field_ms" not in r2["timings_ms"] and "shell_ms" not in r2["timings_ms"]
    assert r2["cover_shell_sha256"] == r["cover_shell_sha256"]
    pc = trimesh.load(r2["files"]["cover"], force="mesh")
    assert pc.bounds[0][2] == pytest.approx(0.0, abs=0.6)   # 刷る向き：底が机の面
    assert {c["rule"]: c for c in r2["checks"]}["R6c"]["ok"]


def test_make_design_rail_slides_off_thumb_slit(tmp_path):
    """側面が低い手で親指側のスリットにレールの台がかかるとき、60度（ペン）なら台を手の甲側へずらし、
    描いたあとのカバーで親指側のスリットが開いている。道具は手に当たらない（2026-11-10。本番でふさがれていた）"""
    raw = fixture_glb("hand_raw_right")
    J = parse_joints(read_glb(raw)[2]["joints_mm"])
    pm = prepare_measurement(raw, make_measurement(J, 1.15), "right", {"tool_d_mm": 9.0, "tool_type": "pen"})
    params = {}
    for b in pm["baseline"]:
        params.setdefault(b["part_id"], {})[b["name"]] = b["value"]
    assert params["c_clip"]["angle_deg"] == 60
    r = make_design(pm["scaled_glb"], pm["joints_mm"], "right", params, str(tmp_path / "job"), DirCache(tmp_path / "cache"))
    checks = {c["rule"]: c for c in r["checks"]}
    assert r["placement"]["rail_shift_mm"] > 0
    assert checks["R6e_slit_rail"]["ok"], checks["R6e_slit_rail"]
    assert checks["R6e_slit_open"]["ok"], checks["R6e_slit_open"]
    assert checks["R6h"]["ok"], checks["R6h"]
    assert r["violations"] == []


def test_make_design_extra_clip_shares_cover(tmp_path):
    raw = fixture_glb("hand_raw_fist")
    J = parse_joints(read_glb(raw)[2]["joints_mm"])
    pm = prepare_measurement(raw, make_measurement(J, 1.15), "right", {"tool_d_mm": 9.5, "tool_type": "brush"})
    params = {}
    for b in pm["baseline"]:
        params.setdefault(b["part_id"], {})[b["name"]] = b["value"]
    cache = DirCache(tmp_path / "cache")
    base = make_design(pm["scaled_glb"], pm["joints_mm"], "right", params, str(tmp_path / "a"), cache)
    extra = {**params["c_clip"], "tool_d_mm": 12.0, "angle_deg": 60}
    r = make_design(pm["scaled_glb"], pm["joints_mm"], "right", params, str(tmp_path / "b"), cache, extra_clips={"a2": extra})
    e = r["extra_clips"]["a2"]
    assert r["cover_shell_sha256"] == base["cover_shell_sha256"]
    assert Path(e["file"]).exists() and e["clip"]["tool_d_mm"] == 12.0 and e["clip"]["angle_deg"] == 60
    assert {c["rule"] for c in e["checks"]} >= {"R6f", "R6h"}
    assert r["violations"] == base["violations"]
    rp = make_design(pm["scaled_glb"], pm["joints_mm"], "right", params, str(tmp_path / "c"), cache, quality="print", extra_clips={"a2": extra})
    m = trimesh.load(rp["extra_clips"]["a2"]["file"], force="mesh")
    assert m.is_watertight and abs(m.bounds[0][2]) < 0.05      # 刷る向き：机の面に乗る
    assert len(m.split(only_watertight=False)) == 2            # 受け具とねじ
