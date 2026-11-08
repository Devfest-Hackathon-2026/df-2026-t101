"""OpenSCAD を使う形のテスト（クリップ、通しの make_design）。OpenSCAD がなければ飛ばす。"""
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


@pytest.mark.parametrize("angle", [60, 70, 80])
@pytest.mark.parametrize("hand", ["right", "left"])
def test_clip_prints_as_one_piece(tmp_path, angle, hand):
    out = run({"mode": "clip", "c_clip_tool_d_mm": 9.5, "c_clip_angle_deg": angle, "hand": hand}, tmp_path / f"clip_{hand}_{angle}.stl")
    m = trimesh.load(out, force="mesh")
    assert m.is_watertight and len(m.split(only_watertight=False)) == 1
    assert abs(m.bounds[0][2]) < 0.05        # 机の面（z=0）に乗る
    clip = {"tool_d_mm": 9.5, "opening_ratio": 0.75, "wall_mm": 2.0, "height_mm": 12, "angle_deg": angle}
    res = {r["rule"]: r for r in check_clip(m, clip)}
    assert res["R6f"]["ok"]


def test_clip_left_is_mirror_of_right(tmp_path):
    """左手のクリップは、レールの座標で X の符号を変えた鏡像（横張り出しの向きが逆）"""
    from app.geometry.cliplib import MIRROR_X
    r = trimesh.load(run({"mode": "assembled", "part": "c_clip", "c_clip_tool_d_mm": 9.5, "c_clip_angle_deg": 70, "hand": "right"}, tmp_path / "r.stl"), force="mesh")
    l = trimesh.load(run({"mode": "assembled", "part": "c_clip", "c_clip_tool_d_mm": 9.5, "c_clip_angle_deg": 70, "hand": "left"}, tmp_path / "l.stl"), force="mesh")
    assert r.bounds[0][0] < -20 and l.bounds[1][0] > 20          # 右手は −X（親指側）へ、左手は +X へ張り出す
    r.apply_transform(MIRROR_X)
    assert np.allclose(r.bounds, l.bounds, atol=0.05) and abs(r.volume - l.volume) < 1.0


def test_clip_opening_too_wide_is_caught(tmp_path):
    out = run({"mode": "clip", "c_clip_tool_d_mm": 9.5, "c_clip_opening_ratio": 0.95}, tmp_path / "clip_wide.stl")
    m = trimesh.load(out, force="mesh")
    clip = {"tool_d_mm": 9.5, "opening_ratio": 0.95, "wall_mm": 2.0, "height_mm": 12, "angle_deg": 70}
    assert not {r["rule"]: r for r in check_clip(m, clip)}["R6f"]["ok"]


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
    cover = trimesh.load(r["files"]["cover"], force="mesh")
    assert cover.is_watertight and len(cover.split(only_watertight=False)) == 1
    assert len(r["views"]) == 4 and all(Path(v).exists() for v in r["views"])
    assert r["placement"]["air_holes"] >= 3 and r["placement"]["strap_slits"] == 2
    # 道具の軸（実際の手の座標）：単位ベクトルで、右手では手のひら側（−z）へ下がる。中心はレールの近く
    t = r["tool"]
    assert abs(np.linalg.norm(t["axis"]) - 1) < 1e-3 and t["axis"][2] < -0.8 and t["tip_mm"] == 100
    assert np.linalg.norm(np.array(t["center"]) - np.array(r["placement"]["rail_origin"])) < 30
    # 2回目は距離場と殻を使い回すので速い
    r2 = make_design(pm["scaled_glb"], pm["joints_mm"], "right", params, str(tmp_path / "job2"), cache, quality="print")
    assert "field_ms" not in r2["timings_ms"] and "shell_ms" not in r2["timings_ms"]
    assert r2["cover_shell_sha256"] == r["cover_shell_sha256"]
    pc = trimesh.load(r2["files"]["cover"], force="mesh")
    assert pc.bounds[0][2] == pytest.approx(0.0, abs=0.6)   # 刷る向き：底が机の面
    assert {c["rule"]: c for c in r2["checks"]}["R6c"]["ok"]
