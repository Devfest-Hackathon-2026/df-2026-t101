"""処理中の印（docs/api.md §1.1）と、回数・費用の上限（§1、data-model.md §2.6）。"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

from .config import settings
from .errors import ApiError
from .store import db, files, now, parse_time

OP_TTL = timedelta(seconds=300)
JST = timezone(timedelta(hours=9))


# ---------------------------------------------------------------- 停止スイッチ
def ensure_dev_runtime() -> None:
    """開発（local）では、共通の設定がなければ作る。本番は管理者がコンソールで入れる"""
    if settings.store_backend == "local" and db.get("settings/runtime") is None:
        db.set("settings/runtime", {"generation_enabled": True, "demo_mode": True})


def require_generation_enabled() -> None:
    if not settings.generation_enabled_env:
        raise ApiError("GENERATION_DISABLED")
    try:
        rt = db.get("settings/runtime") or {}
    except Exception:  # noqa: BLE001 - 読めないときも止める
        raise ApiError("GENERATION_DISABLED")
    if rt.get("generation_enabled") is not True:
        raise ApiError("GENERATION_DISABLED")


def demo_mode() -> bool:
    return bool((db.get("settings/runtime") or {}).get("demo_mode"))


# ---------------------------------------------------------------- 回数と費用
def _day() -> str:
    return datetime.now(JST).strftime("%Y%m%d")


LIMITS = {"designs": "limit_designs_per_user", "refines": "limit_refines_per_user",
          "interviews": "limit_interviews_per_user"}


def count_usage(uid: str, kind: str) -> None:
    """開始前に上限を確かめ、回数を1つ増やす（kind: designs / refines / interviews）"""
    day = _day()

    def tx(t):
        g = t.get(f"usage/{day}") or {}
        u = t.get(f"usage/{day}/users/{uid}") or {}
        if u.get(kind, 0) >= getattr(settings, LIMITS[kind]):
            raise ApiError("RATE_LIMITED")
        if kind == "designs" and g.get("designs", 0) >= settings.limit_designs_total:
            raise ApiError("RATE_LIMITED")
        if g.get("estimated_cost_usd", 0.0) >= settings.daily_cost_limit_usd:
            raise ApiError("RATE_LIMITED", "今日の費用の上限に達しました。明日もう一度試してください")
        t.update(f"usage/{day}", {kind: g.get(kind, 0) + 1})
        t.update(f"usage/{day}/users/{uid}", {kind: u.get(kind, 0) + 1})

    db.transaction(tx)


# Argon の定価（$/100万トークン）。2026-11-30 までの紹介価格ではなく定価で見積もる（non-functional.md §2.1）
PRICE_IN, PRICE_OUT = 4.0, 20.0


def add_gemini_cost(usage: dict) -> None:
    day = _day()
    cost = usage.get("input_tokens", 0) / 1e6 * PRICE_IN + usage.get("output_tokens", 0) / 1e6 * PRICE_OUT

    def tx(t):
        g = t.get(f"usage/{day}") or {}
        t.update(f"usage/{day}", {
            "input_tokens": g.get("input_tokens", 0) + usage.get("input_tokens", 0),
            "output_tokens": g.get("output_tokens", 0) + usage.get("output_tokens", 0),
            "gemini_cost_usd": round(g.get("gemini_cost_usd", 0.0) + cost, 6),
            "estimated_cost_usd": round(g.get("estimated_cost_usd", 0.0) + cost, 6),
        })

    db.transaction(tx)


# ---------------------------------------------------------------- 処理中の印
def _recover_case(t, case_id: str, case: dict) -> bool:
    """期限切れの印を、kind ごとに戻す。戻したら True"""
    op = case.get("active_operation")
    if not op:
        return False
    exp = parse_time(op.get("expires_at"))
    if exp and exp > now():
        return False
    kind = op.get("kind")
    did = case.get("current_design_id")
    if kind in ("design", "refine") and op.get("design_id"):
        d = t.get(f"cases/{case_id}/designs/{op['design_id']}") or {}
        if d.get("status") in ("queued", "running"):
            t.update(f"cases/{case_id}/designs/{op['design_id']}",
                     {"status": "failed", "error": {"code": "GENERATION_INTERRUPTED",
                                                    "message": "途中で止まりました。もう一度作ってください"}})
        t.update(f"cases/{case_id}", {"status": "previewing" if did else "designing"})
    elif kind in ("review_request", "prepare_print") and did:
        files.delete_prefix(f"internal/cases/{case_id}/designs/{did}/print")
        t.update(f"cases/{case_id}/designs/{did}", {"approval": {"status": "none"}})
        t.update(f"cases/{case_id}", {"status": "previewing"})
    t.update(f"cases/{case_id}", {"active_operation": None})
    return True


def recover(case_id: str) -> bool:
    def tx(t):
        case = t.get(f"cases/{case_id}")
        return bool(case) and _recover_case(t, case_id, case)
    return db.transaction(tx)


def begin(case_id: str, kind: str, design_id: str | None = None) -> str:
    """処理を始める。有効な印があれば 409。期限切れなら回収してから始める"""
    op_id = "op_" + uuid.uuid4().hex[:12]

    def tx(t):
        case = t.get(f"cases/{case_id}")
        if not case:
            raise ApiError("NOT_FOUND")
        # Firestore のトランザクションは、書いたあとに読めない（ReadAfterWriteError）。回収したら手元の dict で判定する
        if _recover_case(t, case_id, case):
            case = {**case, "active_operation": None}
        if case.get("active_operation"):
            raise ApiError("CONFLICT")
        start = now()
        t.update(f"cases/{case_id}", {"active_operation": {
            "operation_id": op_id, "kind": kind, "design_id": design_id,
            "started_at": start, "expires_at": start + OP_TTL}})
        return op_id

    return db.transaction(tx)


def is_mine(case_id: str, op_id: str) -> bool:
    case = db.get(f"cases/{case_id}") or {}
    op = case.get("active_operation") or {}
    return op.get("operation_id") == op_id


def end(case_id: str, op_id: str) -> None:
    def tx(t):
        case = t.get(f"cases/{case_id}") or {}
        if (case.get("active_operation") or {}).get("operation_id") == op_id:
            t.update(f"cases/{case_id}", {"active_operation": None})
    db.transaction(tx)


def assert_no_active(case: dict) -> None:
    """採寸・聞き取りの保存は、有効な印があるあいだ 409"""
    op = case.get("active_operation")
    if op and (parse_time(op.get("expires_at")) or now()) > now():
        raise ApiError("CONFLICT")
