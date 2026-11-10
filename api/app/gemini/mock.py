"""開発用のモック。本物と同じ形の答えを、入力から決まった手順で作る（AIの代わりではない）。"""
from __future__ import annotations

import re

from ..attachments import ANGLE_BY_TOOL, TOOL_JA   # 道具の立て具合（机に対する傾き。ADR-0013）


def interview(requirements: dict, message: str, turn: int) -> dict:
    if re.search(r"固定|伸ばし|矯正|装具", message):
        return {"status": "out_of_scope", "message_ja": "指を伸ばしたり固定したりするもの（装具）は作れません。作業療法士に相談してください。",
                "choices": [], "notes": [], "suggested_changes": [], "out_of_scope_reason": "orthosis"}
    notes = [message.strip()[:80]] if message.strip() else []
    if turn >= 3 or re.search(r"以上|分|時間", message):
        return {"status": "done", "message_ja": "わかりました。メモに残して、形に生かします。", "choices": [],
                "notes": notes, "suggested_changes": [], "out_of_scope_reason": "none"}
    return {"status": "ask", "message_ja": "メモに残しました。1回に何分くらい使いますか？",
            "choices": ["15分くらい", "30分くらい", "1時間以上"], "notes": notes, "suggested_changes": [],
            "out_of_scope_reason": "none"}


def select(requirements: dict) -> dict:
    tool = requirements.get("tool_type", "brush")
    parts = [
        {"part_id": "cover", "variant": "standard", "reason_ja": "握った形のまま、手の甲側からかぶせられる形にしました"},
        {"part_id": "air_holes", "variant": "standard", "reason_ja": "蒸れにくいよう、手の甲に空気穴を開けます"},
        {"part_id": "strap_slits", "variant": "standard", "reason_ja": "ベルトで手のひら側を通して留めます"},
        {"part_id": "rail", "variant": "standard", "reason_ja": "人差し指の横にクリップを差し込みます"},
        {"part_id": "c_clip", "variant": "standard",
         "reason_ja": f"道具（{ {'brush': '筆', 'pen': 'ペン', 'spoon': 'スプーン'}.get(tool, '道具') }）の太さに合わせたクリップにします"},
    ]
    return {"parts": parts}


def attachment_angle(attachment: dict) -> dict:
    """取り付け具1つの角度を道具から選ぶ（道具が分からなければ60度）"""
    tool = attachment.get("tool_type")
    v = ANGLE_BY_TOOL.get(tool, 60)
    act = {"draw": "絵を描く", "write": "字を書く", "eat": "食べる"}.get(attachment.get("activity"))
    if tool in TOOL_JA and act:
        return {"angle_deg": v, "reason_ja": f"{TOOL_JA[tool]}で{act}ので、{v}度にしました"}
    return {"angle_deg": v, "reason_ja": f"道具に合わせて{v}度にしました"}


def dimension(requirements: dict, param_defs: list, attachments: list | None = None) -> dict:
    """基準値のまま返し、角度だけ道具から選ぶ"""
    out = []
    for d in param_defs:
        v = d.get("baseline", d.get("default"))
        src, why = d.get("source") or "default", "基準値のままにしました"
        if d["part_id"] == "c_clip" and d["name"] == "angle_deg":
            v = ANGLE_BY_TOOL.get(requirements.get("tool_type"), 20)
            # 利用者に見せる文なので、英語の値（brush・draw など）は書かない（2026-11-10）
            tool_ja = TOOL_JA.get(requirements.get("tool_type"), "道具")
            act_ja = {"draw": "絵を描く", "write": "字を書く", "eat": "食べる"}.get(requirements.get("activity"))
            src, why = "ai", (f"{tool_ja}で{act_ja}ので、{v}度にしました" if act_ja else f"{tool_ja}に合わせて{v}度にしました")
        if d["part_id"] == "c_clip" and d["name"] == "opening_ratio" and requirements.get("donning_by") == "helper":
            src, why = "ai", "家族や支援者が着け外しするので、押し込みやすさを優先しました"
        out.append({"part_id": d["part_id"], "name": d["name"], "value": v, "source": src, "reason_ja": why})
    res = {"params": out, "summary_ja": "こぶしの外側に沿うカバーと、道具の太さに合わせたクリップにしました。手のひら側と手首は開けてあります。"}
    if attachments:
        res["attachments"] = [{"attachment_id": a["attachment_id"], **attachment_angle(a)} for a in attachments]
    return res


def review(params: list, round_no: int) -> dict:
    checks = [{"id": f"C{i}", "pass": True, "note_ja": "問題ありません"} for i in range(1, 6)]
    return {"verdict": "ok", "checks": checks, "issues": [], "changes": []}


def refine(params: list, instruction: str) -> dict:
    cur = {(p["part_id"], p["name"]): p["value"] for p in params}
    ch = []

    def scale(part, name, up, pct):
        v = cur.get((part, name))
        if isinstance(v, (int, float)):
            step = max(abs(v) * pct, 0.2)
            ch.append({"part_id": part, "name": name, "value": round(v + (step if up else -step), 1),
                       "reason_ja": "指示に合わせて変えました"})

    pct = 0.05 if "少し" in instruction else 0.15 if "かなり" in instruction else 0.10
    if re.search(r"厚く|丈夫", instruction):
        scale("cover", "cover_thickness_mm", True, pct)
    elif re.search(r"薄く|軽く", instruction):
        scale("cover", "cover_thickness_mm", False, pct)
    elif re.search(r"丸く", instruction):
        scale("cover", "edge_radius_mm", True, pct)
    elif re.search(r"寝かせ", instruction):
        a = cur.get(("c_clip", "angle_deg"), 70)
        ch.append({"part_id": "c_clip", "name": "angle_deg", "value": max(60, a - 10), "reason_ja": "角度を1段寝かせました"})
    elif re.search(r"立て", instruction):
        a = cur.get(("c_clip", "angle_deg"), 70)
        ch.append({"part_id": "c_clip", "name": "angle_deg", "value": min(80, a + 10), "reason_ja": "角度を1段立てました"})
    elif re.search(r"きつく", instruction):
        scale("c_clip", "wall_mm", True, 0.1)
    elif re.search(r"ゆるく", instruction):
        scale("c_clip", "wall_mm", False, 0.1)
    elif re.search(r"蒸れ", instruction):
        n = cur.get(("air_holes", "count"), 6)
        ch.append({"part_id": "air_holes", "name": "count", "value": min(10, int(n) + 2), "reason_ja": "空気穴を増やしました"})
    elif re.search(r"2本", instruction):
        # ベルトは1本に固定（2本にするとスリットがカバーのふちにかかる。2026-11-08）
        return {"changes": [], "message_ja": "ベルトは1本です（2本にするとスリットがカバーのふちにかかるため）。",
                "clarify_ja": "", "override_by_user": False}
    if not ch:
        return {"changes": [], "message_ja": "", "clarify_ja": "どこをどう変えたいか、もう少し教えてください（例：もう少し厚く）", "override_by_user": False}
    return {"changes": ch, "message_ja": "指示に合わせて直しました。", "clarify_ja": "", "override_by_user": False}
