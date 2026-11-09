"""取り付け具（道具ごとのクリップ）の元になる、道具の一覧の正規化（docs/adr/0014-multiple-attachments.md）。
app.geometry は import しない（テストが差し替えるため）"""
from __future__ import annotations

import copy

from .validator import Param

TOOL_JA = {"brush": "筆", "pen": "ペン", "spoon": "スプーン"}
ANGLE_BY_TOOL = {"brush": 70, "pen": 60, "spoon": 60}
SHAFT_D = {"thin": 6.0, "medium": 8.5, "thick": 11.5}
DEFAULT_D = {"brush": 8.5, "pen": 8.5, "spoon": 11.5}
MAX_ATTACHMENTS = 4

_TOOL_KEYS = ("activity", "tool_type", "tool_d_mm", "tool_shaft_size", "tool_shaft_shape")


def flat_reason(tool_type: str | None) -> str:
    """平たい柄の道具につける知らせ"""
    name = TOOL_JA.get(tool_type, "道具")
    return f"{name}：平たい柄はクリップで挟めません。太柄スポンジなどで丸くしてください"


ESTIMATED_D = "道具の太さは推定です。刷る前に太さを確かめてください"


def normalize_tool(t: dict) -> dict:
    """道具1つの太さを決める（数値があれば user、なければ区分から推定して category）"""
    out = {k: t.get(k) for k in _TOOL_KEYS}
    assumptions: list[str] = []
    if out["tool_d_mm"] is not None:
        out["tool_d_source"] = "user"
    else:
        size = out["tool_shaft_size"] or "unknown"
        out["tool_d_mm"] = SHAFT_D.get(size, DEFAULT_D.get(out["tool_type"], 8.5))
        out["tool_d_source"] = "category"
        assumptions.append(ESTIMATED_D)
    if out["tool_shaft_shape"] == "flat":
        assumptions.append(flat_reason(out["tool_type"]))
    out["assumptions"] = assumptions
    return out


def normalize_tools(body: dict) -> list[dict]:
    """body["tools"] があればそれを、なければ今までの項目から1つの道具を作って正規化する"""
    raw = body.get("tools")
    if not raw:
        raw = [body]
    return [normalize_tool(t) for t in raw]


def stored_tools(req: dict) -> list[dict]:
    """ケースに保存した要求の道具の一覧。tools のない古い要求は今までの項目から1つ作る
    （保存した太さは区分から推定した値のことがあるので、tool_d_source と「推定」の知らせを引き継ぐ）"""
    if req.get("tools"):
        return req["tools"]
    t = normalize_tool(req)
    if req.get("tool_d_mm") is not None and req.get("tool_d_source") == "category":
        t["tool_d_source"] = "category"
        if ESTIMATED_D not in t["assumptions"]:
            t["assumptions"].insert(0, ESTIMATED_D)
    return [t]


def requirement_assumptions(tools: list[dict]) -> list[str]:
    """要求の assumptions。道具が複数のときは道具の名前をつける（平たい柄の文は元から名前つき）"""
    out: list[str] = []
    for t in tools:
        name = TOOL_JA.get(t.get("tool_type"), "道具")
        for a in t.get("assumptions") or []:
            named = len(tools) > 1 and not a.startswith(name + "：")
            out.append(f"{name}：{a}" if named else a)
    return out


def primary_index(tools: list[dict]) -> int | None:
    """最初の丸い柄の位置。なければ None"""
    for i, t in enumerate(tools):
        if t.get("tool_shaft_shape") != "flat":
            return i
    return None


def build_attachments(requirements: dict) -> tuple[list[dict], list[dict]]:
    """道具の一覧から、丸い柄は取り付け具に、平たい柄は skipped にする"""
    tools = stored_tools(requirements)
    primary = primary_index(tools)
    atts: list[dict] = []
    skipped: list[dict] = []
    for i, t in enumerate(tools):
        if t.get("tool_shaft_shape") == "flat":
            skipped.append({"tool_index": i, "tool_type": t.get("tool_type"), "reason_ja": flat_reason(t.get("tool_type"))})
            continue
        atts.append({
            "id": f"a{i + 1}", "tool_index": i, "tool_type": t.get("tool_type"), "activity": t.get("activity"),
            "tool_d_mm": t.get("tool_d_mm"), "tool_d_source": t.get("tool_d_source"),
            "angle_deg": ANGLE_BY_TOOL.get(t.get("tool_type"), 60), "angle_source": "rule",
            "reason_ja": "", "primary": i == primary,
        })
    return atts, skipped


def next_attachment_id(attachments: list[dict]) -> str:
    """a のあとの数字の最大＋1"""
    nums = [int(a["id"][1:]) for a in attachments if str(a.get("id", "")).startswith("a") and a["id"][1:].isdigit()]
    return f"a{max(nums, default=0) + 1}"


def clip_params(base_c_clip: dict, att: dict) -> dict:
    return {**base_c_clip, "tool_d_mm": att["tool_d_mm"], "angle_deg": att["angle_deg"]}


def attachment_params(params: list[Param], att: dict) -> list[Param]:
    """params の写しを作り、この取り付け具の太さと角度に置き換える"""
    out = copy.deepcopy(params)
    for p in out:
        if p.part_id != "c_clip":
            continue
        if p.name == "tool_d_mm":
            p.value = att["tool_d_mm"]
            p.baseline = att["tool_d_mm"]
        elif p.name == "angle_deg":
            p.value = att["angle_deg"]
    return out


def _has_same_tool(att: dict, attachments: list[dict]) -> bool:
    return any(o["id"] != att["id"] and o["tool_type"] == att["tool_type"] for o in attachments)


def clip_stem(att: dict, attachments: list[dict]) -> str:
    """STLのファイル名の元。1つなら今まで通り c_clip_{角度}"""
    if len(attachments) <= 1:
        return f"c_clip_{att['angle_deg']}"
    stem = f"c_clip_{att['tool_type']}_{att['angle_deg']}"
    if _has_same_tool(att, attachments):
        stem += f"_d{round(att['tool_d_mm'] * 100):04d}"
    return stem


def print_key(att: dict) -> str:
    return "c_clip" if att.get("primary") else f"c_clip_{att['id']}"


def attachment_label(att: dict, attachments: list[dict]) -> str:
    name = TOOL_JA.get(att["tool_type"], "道具")
    if _has_same_tool(att, attachments):
        return f"{name} {att['tool_d_mm']:g}mm"
    return name
