"""AI が書いた、利用者に見せる文（*_ja）に、項目名や英語の値（tool_type=spoon など）が混ざらないこと（2026-11-10。
形を確かめる画面に「スプーン(tool_type=spoon)で食べる。(activity=eat)」と出ていた）"""
from __future__ import annotations

import pytest

from app import gemini
from app.gemini import clean_ja


@pytest.mark.parametrize("raw,want", [
    ("スプーン(tool_type=spoon)で食べる。(activity=eat)", "スプーンで食べる。"),
    ("ペン（tool_type=pen）で字を書く（activity=write）ので60度にしました", "ペンで字を書くので60度にしました"),
    ("手首から中指の付け根まで78mm（hand.wrist_to_middle_mcp_mm=78）なので", "手首から中指の付け根まで78mmなので"),
    ("道具の太さ tool_d_mm=9 に合わせました", "道具の太さ 9 に合わせました"),
    ("角度は (angle_deg) 70度です。", "角度は 70度です。"),
])
def test_clean_ja_removes_field_names(raw, want):
    assert clean_ja(raw) == want


@pytest.mark.parametrize("text", [
    "PLA（ポリ乳酸）は熱に弱いので、熱いお湯につけないでください",
    "クリップの角度 60度（おすすめ）",
    "R6h の検査で、道具が手に当たりました",
    "材料は PETG（使えれば）がおすすめです",
    "C字クリップ（70度）",
])
def test_clean_ja_keeps_normal_text(text):
    assert clean_ja(text) == text


def test_run_cleans_only_ja_fields():
    """Gemini の答えのうち *_ja の文だけを掃除する（tool_type などの値そのものは変えない）"""
    out = {"angle_deg": 60, "tool_type": "spoon", "reason_ja": "スプーン(tool_type=spoon)で食べる。(activity=eat)",
           "params": [{"name": "angle_deg", "reason_ja": "字を書く（activity=write）ため"}]}
    assert gemini.settings.gemini_mode != "live"          # テストは見本の答え（mock_fn）を使う
    r = gemini._run("attachment", {}, {}, gemini.Usage(), mock_fn=lambda: out)
    assert r["tool_type"] == "spoon" and r["angle_deg"] == 60
    assert r["reason_ja"] == "スプーンで食べる。"
    assert r["params"][0]["reason_ja"] == "字を書くため"


def test_prompts_do_not_ask_for_field_names():
    """プロンプト自体が「項目名を挙げる」「（activity）（tool_type）」と書いていたのが原因。今の版にはない"""
    sys_text = gemini._prompt("system")
    assert "hand.wrist_to_middle_mcp_mm=78" not in sys_text
    assert "英語の項目名" in sys_text
    for name in ("attachment", "dimension"):
        t = gemini._prompt(name)
        assert "（activity）" not in t and "（tool_type）" not in t, name
