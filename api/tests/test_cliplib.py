"""C字クリップの固定STLのライブラリ（app/geometry/cliplib.py）のテスト。OpenSCAD を使うものは、なければ飛ばす。"""
from __future__ import annotations

import hashlib
import shutil
from pathlib import Path

import numpy as np
import pytest
import trimesh

from app.geometry import cliplib
from app.geometry.consts import openscad_bin

HAS_SCAD = Path(openscad_bin()).exists() or bool(shutil.which(openscad_bin()))


def test_snap_and_variant_names():
    assert cliplib.snap_d(8.5) == 8.5
    assert cliplib.snap_d(8.6) == 8.5
    assert cliplib.snap_d(8.63) == 8.75
    assert cliplib.snap_d(3.5) is None and cliplib.snap_d(16.4) is None
    assert cliplib.variant(8.5, 20) == "c_clip_d0850_a20"
    assert cliplib.variant(12.25, 0) == "c_clip_d1225_a00"
    g = cliplib.grid()
    assert g[0] == 4.0 and g[-1] == 16.0 and len(g) == 49


def test_lookup_requires_fixed_params_and_files(tmp_path):
    base = {"tool_d_mm": 8.5, "angle_deg": 70, **cliplib.fixed_params()}
    assert cliplib.lookup(base, tmp_path) is None                                  # ファイルがない
    for ext in ("print", "rail"):
        (tmp_path / f"c_clip_d0850_a70.{ext}.stl").write_bytes(b"x")
    hit = cliplib.lookup(base, tmp_path)
    assert hit and hit["variant"] == "c_clip_d0850_a70" and hit["tool_d_snapped"] == 8.5
    assert cliplib.lookup({**base, "tool_d_mm": 8.6}, tmp_path)["tool_d_snapped"] == 8.5   # 刻みに丸める
    assert cliplib.lookup({**base, "wall_mm": 2.4}, tmp_path) is None               # 固定の値と違えば使わない
    assert cliplib.lookup({**base, "angle_deg": 30}, tmp_path) is None


@pytest.mark.skipif(not HAS_SCAD, reason="OpenSCAD がありません")
def test_build_and_make_design_uses_library(tmp_path, monkeypatch):
    from app.geometry import DirCache, make_design, prepare_measurement
    from app.geometry.glb import read_glb
    from app.geometry.handframe import parse_joints
    from app.geometry.scad import run
    from test_geometry import fixture_glb, make_measurement

    lib = tmp_path / "lib"
    r = cliplib.build(lib, ds=[9.5], angles=(70,), workers=2)
    assert r["made"] == 1
    index = (lib / "index.json").read_text(encoding="utf-8")
    assert "c_clip_d0950_a70" in index and '"R6f"' in index
    monkeypatch.setenv("CLIP_LIBRARY_DIR", str(lib))

    raw = fixture_glb("hand_raw_fist")
    J = parse_joints(read_glb(raw)[2]["joints_mm"])
    pm = prepare_measurement(raw, make_measurement(J, 1.15), "right", {"tool_d_mm": 9.5, "tool_type": "brush"})
    params = {}
    for b in pm["baseline"]:
        params.setdefault(b["part_id"], {})[b["name"]] = b["value"]
    cache = DirCache(tmp_path / "cache")
    res = make_design(pm["scaled_glb"], pm["joints_mm"], "right", params, str(tmp_path / "job"), cache)
    assert res["clip"]["source"] == "library" and res["clip"]["variant"] == "c_clip_d0950_a70"
    assert {c["rule"]: c for c in res["checks"]}["R6f"]["ok"]
    # レールに置いた形が、OpenSCAD で組んだときと同じ所に来る（右手）
    ours = trimesh.load(res["files"]["c_clip"], force="mesh")
    ref_path = run({"mode": "assembled", "part": "c_clip", "c_clip_tool_d_mm": 9.5, "c_clip_angle_deg": 70, "hand": "right",
                    "rail_origin": res["placement"]["rail_origin"], "rail_frame": res["placement"]["rail_frame"]},
                   tmp_path / "ref_clip.stl")
    ref = trimesh.load(ref_path, force="mesh")
    assert np.allclose(ours.bounds, ref.bounds, atol=0.3), (ours.bounds, ref.bounds)
    # 印刷用は、ライブラリのファイルそのもの
    res2 = make_design(pm["scaled_glb"], pm["joints_mm"], "right", params, str(tmp_path / "job2"), cache, quality="print")
    assert hashlib.sha256(Path(res2["files"]["c_clip"]).read_bytes()).hexdigest() == \
        hashlib.sha256((lib / "c_clip_d0950_a70.print.stl").read_bytes()).hexdigest()
    # 左手：ライブラリ（右手の形）を鏡像にして置く。OpenSCAD で左手として組んだものと同じ所に来る
    resL = make_design(pm["scaled_glb"], pm["joints_mm"], "left", params, str(tmp_path / "jobL"), DirCache(tmp_path / "cacheL"))
    assert resL["clip"]["source"] == "library"
    oursL = trimesh.load(resL["files"]["c_clip"], force="mesh")
    refL = trimesh.load(run({"mode": "assembled", "part": "c_clip", "c_clip_tool_d_mm": 9.5, "c_clip_angle_deg": 70, "hand": "left",
                             "rail_origin": resL["placement"]["rail_origin"], "rail_frame": resL["placement"]["rail_frame"]},
                            tmp_path / "ref_clip_L.stl"), force="mesh")
    assert np.allclose(oursL.bounds, refL.bounds, atol=0.3), (oursL.bounds, refL.bounds)
    # 角度 45 はライブラリにないので、従来どおり描く
    params["c_clip"]["angle_deg"] = 45
    res3 = make_design(pm["scaled_glb"], pm["joints_mm"], "right", params, str(tmp_path / "job3"), cache)
    assert res3["clip"]["source"] == "generated"
