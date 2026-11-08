"""範囲チェック R1〜R5（docs/generation-pipeline.md §4、parts-library.md §4.8）。
ルールの元は scad/catalog.json（唯一の正）。描いたあとの検査 R6 は geometry 側。"""
from __future__ import annotations

import copy
import json
from dataclasses import dataclass, field
from functools import lru_cache
from typing import Any

from .config import CATALOG_PATH

REQUIRED_PARTS = ("cover", "air_holes", "strap_slits", "rail", "c_clip")
SHELL_PARAMS = {("cover", "cover_thickness_mm"), ("cover", "palm_cut_offset_mm"), ("cover", "wrist_cut_mm"),
                ("cover", "edge_radius_mm")}


@lru_cache(maxsize=1)
def catalog() -> dict:
    return json.loads(CATALOG_PATH.read_text(encoding="utf-8"))


def reload_catalog() -> None:
    catalog.cache_clear()


def fixed(name: str, default: float) -> float:
    return float(catalog().get("fixed", {}).get(name, default))


def part_defs() -> dict[str, dict]:
    return {p["id"]: p for p in catalog()["parts"]}


def param_def(part_id: str, name: str) -> dict | None:
    p = part_defs().get(part_id)
    if not p:
        return None
    return next((q for q in p.get("params", []) if q["name"] == name), None)


def is_shell_param(part_id: str, name: str) -> bool:
    d = param_def(part_id, name)
    return bool(d.get("shell")) if d else (part_id, name) in SHELL_PARAMS


def ai_params(part_id: str) -> list[dict]:
    """Gemini が扱う引数（サーバーと固定は除く）"""
    p = part_defs().get(part_id, {})
    return [q for q in p.get("params", []) if q.get("decided_by") not in ("server", "fixed")]


@dataclass
class Param:
    part_id: str
    name: str
    value: Any
    source: str = "default"
    reason_ja: str = ""
    baseline: Any = None
    clamped: bool = False
    override_by_user: bool = False

    def key(self) -> tuple[str, str]:
        return (self.part_id, self.name)


@dataclass
class CheckResult:
    params: list[Param]
    violations: list[dict] = field(default_factory=list)   # 聞き直しのために Gemini へ渡す
    clamped: list[dict] = field(default_factory=list)      # 自動で直したもの（OT画面で目立たせる）
    fatal: str | None = None                              # AI_OUTPUT_INVALID / DESIGN_INFEASIBLE / OUT_OF_SCOPE


def to_dict(params: list[Param]) -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    for p in params:
        out.setdefault(p.part_id, {})[p.name] = p.value
    return out


def baseline_params(baseline: list[dict], selected_parts: list[str]) -> list[Param]:
    """基準値から引数の一覧を作る（Gemini の答えがない引数はこれを使う）"""
    out = []
    for b in baseline:
        if b["part_id"] in selected_parts:
            out.append(Param(b["part_id"], b["name"], b["value"], b.get("source", "default"), "", b["value"]))
    return out


def _coerce(d: dict, v: Any) -> Any:
    t = d.get("type", "number")
    if t == "boolean":
        if isinstance(v, str):
            return v.lower() in ("true", "1", "yes")
        return bool(v)
    if t == "integer":
        return int(round(float(v)))
    if t == "enum":
        ch = d.get("choices") or []
        if ch and all(isinstance(c, (int, float)) for c in ch):
            return float(v) if not float(v).is_integer() else int(float(v))
        return v
    return round(float(v), 2)


def check(params: list[Param], *, selected_parts: list[str], hand: dict, requirements: dict,
          user_override_keys: set[tuple[str, str]] = frozenset(), allow_clamp: bool = True) -> CheckResult:
    """R1〜R5。allow_clamp=False なら直さずに違反だけ返す（聞き直しの1回目）"""
    params = copy.deepcopy(params)
    res = CheckResult(params=params)
    defs = part_defs()

    # R1：部品と引数がカタログにある、必須の部品がそろう
    missing = [p for p in REQUIRED_PARTS if p not in selected_parts]
    unknown = [p for p in selected_parts if p not in defs]
    if missing or unknown:
        res.fatal = "AI_OUTPUT_INVALID"
        res.violations.append({"rule": "R1", "message": f"必須の部品が足りない {missing} / 知らない部品 {unknown}"})
        return res
    kept = []
    for p in params:
        d = param_def(p.part_id, p.name)
        if d is None or p.part_id not in selected_parts:
            res.violations.append({"rule": "R1", "message": f"カタログにない引数 {p.part_id}.{p.name}"})
            continue
        if d.get("decided_by") == "fixed":
            # 固定の引数（ベルトの本数、クリップの壁の厚さなど）は版に持たせず、形を作るときはカタログの既定値を使う。
            # 前は基準値に無いので R3 をすり抜け、AI や画面が変えた値がそのまま通っていた（2026-11-08 のレビュー）
            if p.value != d.get("default"):
                res.violations.append({"rule": "R3", "message": f"{p.part_id}.{p.name}={p.value} は固定の値（{d.get('default')}）なので変えられない"})
                if allow_clamp:
                    res.clamped.append({"part_id": p.part_id, "name": p.name, "from": p.value, "to": d.get("default"), "rule": "R3"})
            continue
        try:
            p.value = _coerce(d, p.value)
        except (TypeError, ValueError):
            res.violations.append({"rule": "R1", "message": f"{p.part_id}.{p.name} の値の型が違う: {p.value!r}"})
            p.value = p.baseline if p.baseline is not None else d.get("default")
        kept.append(p)
    res.params = params = kept

    def clamp(p: Param, value: Any, rule: str, why: str):
        res.violations.append({"rule": rule, "message": f"{p.part_id}.{p.name}={p.value} は {why}"})
        if allow_clamp:
            res.clamped.append({"part_id": p.part_id, "name": p.name, "from": p.value, "to": value, "rule": rule})
            p.value = value
            p.clamped = True

    for p in params:
        d = param_def(p.part_id, p.name)
        # R3：サーバーが決める引数は基準値に戻す
        if d.get("decided_by") in ("server", "fixed", "interview") and p.baseline is not None and p.value != p.baseline:
            clamp(p, p.baseline, "R3", "サーバーか聞き取りが決める値なので変えられない")
            continue
        # R2：範囲と選択肢
        ch = d.get("choices")
        if ch:
            if p.value not in ch:
                clamp(p, p.baseline if p.baseline in ch else d.get("default", ch[0]), "R2", f"選択肢 {ch} にない")
        elif d.get("type") in ("number", "integer"):
            lo, hi = d.get("min"), d.get("max")
            if lo is not None and p.value < lo:
                clamp(p, lo, "R2", f"最小 {lo} より小さい")
            elif hi is not None and p.value > hi:
                clamp(p, hi, "R2", f"最大 {hi} より大きい")
        # R3：AI が変えてよい幅（ユーザーの指示は除く）
        delta = d.get("ai_delta")
        if (delta is not None and p.baseline is not None and p.key() not in user_override_keys
                and isinstance(p.value, (int, float)) and abs(p.value - p.baseline) > delta + 1e-9):
            edge = p.baseline + delta if p.value > p.baseline else p.baseline - delta
            clamp(p, round(edge, 2), "R3", f"基準値 {p.baseline} から ±{delta} を超えた")

    vals = {p.key(): p for p in params}

    def get(part, name, default=None):
        q = vals.get((part, name))
        return q.value if q else default

    # R5：安全（ユーザーの指示でも当てはめる）
    wrist_free = fixed("WRIST_FREE_MM", 25)
    min_edge = fixed("MIN_EDGE_RADIUS_MM", 1.5)
    if (q := vals.get(("cover", "wrist_cut_mm"))) and q.value < wrist_free:
        res.violations.append({"rule": "R5", "message": f"手首を覆わないよう wrist_cut_mm は {wrist_free} 以上"})
        res.clamped.append({"part_id": "cover", "name": "wrist_cut_mm", "from": q.value, "to": wrist_free, "rule": "R5"})
        q.value, q.clamped = wrist_free, True
    if (q := vals.get(("cover", "edge_radius_mm"))) and q.value < min_edge:
        res.violations.append({"rule": "R5", "message": f"ふちの丸みは {min_edge} 以上"})
        res.clamped.append({"part_id": "cover", "name": "edge_radius_mm", "from": q.value, "to": min_edge, "rule": "R5"})
        q.value, q.clamped = min_edge, True

    # R4：組み合わせ（直す順番は §4 の表）
    l09 = float(hand.get("wrist_to_middle_mcp_mm") or 90)
    tool_d = float(get("c_clip", "tool_d_mm", requirements.get("tool_d_mm") or 8.5))
    rules = [
        (("cover", "edge_radius_mm"), lambda: get("cover", "edge_radius_mm", 2) <= get("cover", "cover_thickness_mm", 2.5) * 1.5,
         lambda: round(get("cover", "cover_thickness_mm", 2.5) * 1.5, 2), "ふちの丸みが厚みの1.5倍を超えた"),
        (("cover", "wrist_cut_mm"), lambda: get("cover", "wrist_cut_mm", 30) <= max(wrist_free, l09 - 15),
         lambda: round(max(wrist_free, l09 - 15), 1), "手首側を切る位置が指の付け根に近すぎる"),
        (("c_clip", "opening_ratio"), lambda: get("c_clip", "opening_ratio", 0.75) * tool_d < tool_d - 0.5,
         lambda: round(min(0.80, (tool_d - 0.6) / tool_d), 3), "クリップの開きが広すぎて道具が抜ける"),
        (("c_clip", "tpu_sleeve"), lambda: not get("c_clip", "tpu_sleeve", False) or tool_d >= 4,
         lambda: False, "細すぎる道具にはTPUの筒を入れられない"),
    ]
    for key, ok, fix, why in rules:
        if key in vals and not ok():
            q = vals[key]
            res.violations.append({"rule": "R4", "message": f"{key[0]}.{key[1]}: {why}"})
            if allow_clamp:
                to = fix()
                res.clamped.append({"part_id": key[0], "name": key[1], "from": q.value, "to": to, "rule": "R4"})
                q.value, q.clamped = to, True
    if allow_clamp and any(not ok() for key, ok, _, _ in rules if key in vals):
        res.fatal = "DESIGN_INFEASIBLE"
    if requirements.get("tool_shaft_shape") == "flat":
        res.fatal = "DESIGN_INFEASIBLE"
        res.violations.append({"rule": "R4", "message": "平たい柄は、いまのC字クリップでは挟めません"})
    return res


def merge_changes(params: list[Param], changes: list[dict], *, source: str = "ai",
                  override_by_user: bool = False) -> tuple[list[Param], list[tuple[str, str]]]:
    """Gemini や画面の変更を当てる。返すのは新しい一覧と、変わった引数のキー"""
    params = copy.deepcopy(params)
    idx = {p.key(): p for p in params}
    changed = []
    for c in changes:
        k = (c["part_id"], c["name"])
        if k in idx:
            p = idx[k]
            if p.value != c["value"]:
                p.value, p.source = c["value"], source
                p.reason_ja = c.get("reason_ja", p.reason_ja)
                p.override_by_user = p.override_by_user or override_by_user
                p.clamped = False
                changed.append(k)
        elif param_def(*k):
            params.append(Param(k[0], k[1], c["value"], source, c.get("reason_ja", ""), None, False, override_by_user))
            changed.append(k)
    return params, changed


def param_records(params: list[Param]) -> list[dict]:
    """版に記録する形（data-model.md §2.5 の params）"""
    out = []
    for p in params:
        d = param_def(p.part_id, p.name) or {}
        rec = {"part_id": p.part_id, "name": p.name, "value": p.value, "unit": d.get("unit"),
               "range": [d.get("min"), d.get("max")] if d.get("min") is not None else None,
               "baseline": p.baseline, "source": p.source, "reason_ja": p.reason_ja,
               "clamped": p.clamped, "override_by_user": p.override_by_user}
        if d.get("choices"):
            rec["choices"] = d["choices"]
        out.append(rec)
    return out


def params_from_records(records: list[dict]) -> list[Param]:
    return [Param(r["part_id"], r["name"], r["value"], r.get("source", "default"), r.get("reason_ja", ""),
                  r.get("baseline"), r.get("clamped", False), r.get("override_by_user", False)) for r in records]
