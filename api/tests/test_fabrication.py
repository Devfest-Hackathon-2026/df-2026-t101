"""架空の受託者と印刷の決まり、目安と金額の計算（docs/superpowers/specs/2026-11-21-in-app-ordering-design.md §6.1・§6.2）"""
from __future__ import annotations

import io
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import trimesh  # noqa: E402

from app import fabrication as fx  # noqa: E402


def _stl(x, y, z) -> bytes:
    buf = io.BytesIO()
    trimesh.creation.box((x, y, z)).export(buf, file_type="stl")
    return buf.getvalue()


def test_three_fictional_fabricators():
    fs = fx.fabricators()
    assert [f["id"] for f in fs] == ["umikaze", "hoshizora", "komorebi"]
    assert all(f["fictional"] is True for f in fs)
    assert fx.fabricator("nope") is None
    assert fx.fabricator("umikaze")["name"] == "うみかぜ3D工房"


def test_part_and_material_from_print_key():
    assert fx.part_of("cover") == "cover" and fx.material_of("cover") == "PLA"
    assert fx.part_of("c_clip_a2") == "c_clip" and fx.material_of("c_clip") == "PETG"
    assert fx.material_of("c_clip_brush_70") == "PETG"
    assert fx.material_of("tpu_sleeve") == "TPU"


def test_estimate_part_uses_density_and_factor():
    e = fx.estimate_part(_stl(10, 10, 10), "cover")  # 1000 mm³
    assert abs(e["volume_mm3"] - 1000) < 1e-6
    assert abs(e["grams"] - 1.0 * 1.24 * 0.9) < 1e-6
    assert abs(e["minutes"] - (e["grams"] * 5.0 + 5)) < 1e-6


def test_quote_matches_figma_mock():
    umikaze = fx.fabricator("umikaze")
    g = {"cover": 18.0, "c_clip": 4.0}
    assert fx.quote(umikaze, g, ["cover", "c_clip"], 1, False) == {"parts_yen": 1240, "felt_yen": 0, "total_yen": 1240}
    assert fx.quote(umikaze, g, ["cover", "c_clip"], 1, True)["total_yen"] == 1440
    assert fx.quote(umikaze, g, ["c_clip"], 2, False)["parts_yen"] == 960  # 800 + 20×4×2
    assert fx.quote(umikaze, g, ["cover"], 2, True)["felt_yen"] == 400


def test_round10_half_up():
    assert fx.round10(1234.9) == 1230 and fx.round10(1235) == 1240


def test_color_name():
    assert fx.color_of("#2A9D8F") == {"hex": "#2A9D8F", "name_ja": "ティール"}
    assert fx.color_of("#123456")["name_ja"] == ""
    assert fx.color_of(None) == {"hex": None, "name_ja": ""}
