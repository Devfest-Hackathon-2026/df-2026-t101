from app.attachments import normalize_tools, primary_index


def test_normalize_tools_from_legacy_fields():
    t = normalize_tools({"activity": "draw", "tool_type": "brush", "tool_d_mm": 9.5, "tool_shaft_size": None,
                         "tool_shaft_shape": "round"})
    assert len(t) == 1 and t[0]["tool_d_mm"] == 9.5 and t[0]["tool_d_source"] == "user"


def test_normalize_tools_category_and_order():
    t = normalize_tools({"tools": [
        {"activity": "write", "tool_type": "pen", "tool_d_mm": None, "tool_shaft_size": "thin", "tool_shaft_shape": "round"},
        {"activity": "eat", "tool_type": "spoon", "tool_d_mm": None, "tool_shaft_size": "unknown", "tool_shaft_shape": "round"}]})
    assert [x["tool_type"] for x in t] == ["pen", "spoon"]
    assert t[0]["tool_d_mm"] == 6.0 and t[1]["tool_d_mm"] == 11.5 and t[1]["tool_d_source"] == "category"


def test_primary_is_first_round_tool():
    t = normalize_tools({"tools": [
        {"activity": "eat", "tool_type": "spoon", "tool_d_mm": 10, "tool_shaft_size": None, "tool_shaft_shape": "flat"},
        {"activity": "write", "tool_type": "pen", "tool_d_mm": 9, "tool_shaft_size": None, "tool_shaft_shape": "round"}]})
    assert primary_index(t) == 1
    assert primary_index([t[0]]) is None


# --- Task 2: 取り付け具を組み立てる ---
import copy

from app.attachments import (attachment_label, attachment_params, build_attachments, clip_params, clip_stem,
                             next_attachment_id, print_key)
from app.validator import Param

REQ2 = {"tools": [
    {"activity": "draw", "tool_type": "brush", "tool_d_mm": 9.5, "tool_d_source": "user", "tool_shaft_size": None, "tool_shaft_shape": "round"},
    {"activity": "eat", "tool_type": "spoon", "tool_d_mm": 11.5, "tool_d_source": "category", "tool_shaft_size": "thick", "tool_shaft_shape": "round"}]}


def test_build_attachments_two_round_tools():
    atts, skipped = build_attachments(REQ2)
    assert [a["id"] for a in atts] == ["a1", "a2"] and skipped == []
    assert atts[0]["primary"] and not atts[1]["primary"]
    assert (atts[0]["angle_deg"], atts[1]["angle_deg"]) == (70, 60)


def test_flat_tool_is_skipped_and_primary_moves():
    req = {"tools": [{**REQ2["tools"][1], "tool_shaft_shape": "flat"}, REQ2["tools"][0]]}
    atts, skipped = build_attachments(req)
    assert [a["id"] for a in atts] == ["a2"] and atts[0]["primary"]
    assert skipped[0]["tool_type"] == "spoon" and "太柄スポンジ" in skipped[0]["reason_ja"]
    assert skipped[0]["reason_ja"] == "スプーン：平たい柄はクリップで挟めません。太柄スポンジなどで丸くしてください"


def test_build_attachments_legacy_requirements_without_tools():
    atts, skipped = build_attachments({"activity": "draw", "tool_type": "brush", "tool_d_mm": 9.5,
                                       "tool_shaft_size": None, "tool_shaft_shape": "round"})
    assert len(atts) == 1 and skipped == []
    assert atts[0]["id"] == "a1" and atts[0]["primary"] and atts[0]["tool_d_mm"] == 9.5 and atts[0]["angle_deg"] == 70


def test_names_single_and_duplicate():
    a1 = {"id": "a1", "tool_type": "pen", "tool_d_mm": 8.5, "angle_deg": 60, "primary": True}
    a2 = {"id": "a2", "tool_type": "pen", "tool_d_mm": 12.0, "angle_deg": 60, "primary": False}
    assert clip_stem(a1, [a1]) == "c_clip_60"
    assert clip_stem(a2, [a1, a2]) == "c_clip_pen_60_d1200"
    assert print_key(a1) == "c_clip" and print_key(a2) == "c_clip_a2"
    assert attachment_label(a2, [a1, a2]) == "ペン 12mm" and attachment_label(a1, [a1]) == "ペン"
    assert next_attachment_id([a1, a2]) == "a3"


def test_clip_params_and_attachment_params():
    att = {"id": "a2", "tool_type": "pen", "tool_d_mm": 12.0, "angle_deg": 80}
    assert clip_params({"tool_d_mm": 8.5, "angle_deg": 60, "x": 1}, att) == {"tool_d_mm": 12.0, "angle_deg": 80, "x": 1}
    params = [Param("c_clip", "tool_d_mm", 8.5, baseline=8.5), Param("c_clip", "angle_deg", 60, baseline=60),
              Param("cover", "t", 2.0, baseline=2.0)]
    orig = copy.deepcopy(params)
    out = attachment_params(params, att)
    assert params == orig
    d = {p.key(): p for p in out}
    assert d[("c_clip", "tool_d_mm")].value == 12.0 and d[("c_clip", "tool_d_mm")].baseline == 12.0
    assert d[("c_clip", "angle_deg")].value == 80 and d[("c_clip", "angle_deg")].baseline == 60
    assert d[("cover", "t")].value == 2.0


def test_mock_dimension_returns_angle_per_attachment():
    from app import gemini
    u = gemini.Usage()
    out = gemini.dimension({"tool_type": "brush", "activity": "draw"}, {}, [], [], None, u,
                           attachments=[{"attachment_id": "a2", "tool_type": "spoon", "activity": "eat", "tool_d_mm": 11.5}])
    assert out["attachments"] == [{"attachment_id": "a2", "angle_deg": 60, "reason_ja": out["attachments"][0]["reason_ja"]}]
    assert out["attachments"][0]["reason_ja"]


def test_mock_attachment_angle():
    from app import gemini
    a = gemini.attachment_angle({}, {}, {"tool_type": "brush", "activity": "draw"}, gemini.Usage())
    assert a["angle_deg"] == 70 and a["reason_ja"]
    assert gemini.attachment_angle({}, {}, {"tool_type": "unknown"}, gemini.Usage())["angle_deg"] == 60


def test_prompt_versions_and_schemas():
    from app import gemini
    from app.gemini import schemas
    assert gemini.PROMPT_VERSIONS["dimension"] == "v3" and gemini.PROMPT_VERSIONS["attachment"] == "v2"
    assert gemini.THINKING["attachment"] == "LOW"
    assert set(schemas.ATTACHMENT["required"]) == {"angle_deg", "reason_ja"}
    assert "attachments" in schemas.DIMENSION["properties"] and "attachments" not in schemas.DIMENSION["required"]
    assert "$attachments" in gemini._prompt("dimension") and "$attachment" in gemini._prompt("attachment")
