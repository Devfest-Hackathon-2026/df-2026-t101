"""部品の基準値（parts-library.md §5）。catalog.json の「AIが扱う引数」を全部入れる（範囲チェックの基準値になる）。

source：measured（採寸から）・rule（決まった式）・interview（聞き取り）・default（catalog の既定値）
"""
from __future__ import annotations

from .consts import catalog

AI_SIDE = ("ai", "measured", "rule", "interview", "default")
# 道具の立て具合（机に対する傾き。ADR-0013、2026-11-08）。筆は立て気味、ペンは少し寝かせる。スプーンは未検証なので同じ60
ANGLE_BY_TOOL = {"brush": 70, "pen": 60, "spoon": 60}


def make_baseline(wrist_cut_mm: float, requirements: dict | None = None) -> list[dict]:
    req = requirements or {}
    out = []
    for part in catalog()["parts"]:
        for p in part["params"]:
            if p["decided_by"] not in AI_SIDE:
                continue
            name, pid = p["name"], part["id"]
            value, source = p["default"], "default"
            if pid == "cover" and name == "wrist_cut_mm":
                value, source = round(float(wrist_cut_mm), 1), "measured"
            elif pid == "c_clip" and name == "tool_d_mm":
                if req.get("tool_d_mm") is not None:
                    value, source = float(req["tool_d_mm"]), "interview"
            elif pid == "c_clip" and name == "angle_deg":
                t = req.get("tool_type")
                if t in ANGLE_BY_TOOL:
                    value, source = ANGLE_BY_TOOL[t], "rule"
            if value is None:
                continue
            out.append({"part_id": pid, "name": name, "value": value, "source": source})
    return out
