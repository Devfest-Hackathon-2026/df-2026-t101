"""エンドポイントで共通に使うもの（権限の確かめ）"""
from __future__ import annotations

from ..auth import User, is_therapist
from ..errors import ApiError
from ..store import db


def owned_case(case_id: str, user: User) -> dict:
    case = db.get(f"cases/{case_id}")
    if not case:
        raise ApiError("NOT_FOUND")
    if case.get("owner_uid") != user.uid:
        raise ApiError("FORBIDDEN")
    return case


def readable_case(case_id: str, user: User) -> dict:
    """持ち主か、依頼されたOT"""
    case = db.get(f"cases/{case_id}")
    if not case:
        raise ApiError("NOT_FOUND")
    if case.get("owner_uid") == user.uid:
        return case
    if user.email and case.get("reviewer_email") == user.email and is_therapist(user):
        return case
    raise ApiError("FORBIDDEN")


def case_view(case_id: str, case: dict) -> dict:
    keep = ("title", "status", "demo", "requirements", "turn_count", "measurement_id", "hand_model",
            "current_design_id", "active_operation", "reviewer_email", "mesh_consent_at", "consent_text_version",
            "created_at", "updated_at", "baseline")
    return {"case_id": case_id, **{k: case.get(k) for k in keep if k in case}}
