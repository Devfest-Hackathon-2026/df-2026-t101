"""形を作る・直す・OTに頼む・承認・デモの印刷用データ（docs/api.md §3.4〜§3.7・§3.11）"""
from __future__ import annotations

import copy
import json
from functools import lru_cache

from fastapi import APIRouter, Body, Depends
from jsonschema import Draft202012Validator

from .. import ops, pipeline, validator
from ..attachments import MAX_ATTACHMENTS, flat_reason, stored_tools
from ..auth import User, current_user, is_therapist
from ..config import SCHEMA_DIR
from ..errors import ApiError
from ..store import db, now
from .common import owned_case, readable_case

router = APIRouter()
CHECKLIST = ("dimensions_reviewed", "edges_safe", "not_an_orthosis", "palm_open_wrist_free", "no_mouth_contact",
             "user_informed")
REFINE_KINDS = ("instruction", "param_changes", "clip_angle_deg", "tool_d_mm", "add_attachment", "style")


def _design(case_id: str, design_id: str) -> dict:
    d = db.get(f"cases/{case_id}/designs/{design_id}")
    if not d:
        raise ApiError("NOT_FOUND")
    return {**d, "design_id": design_id}


@lru_cache(maxsize=1)
def _tool_item() -> dict:
    """requirements.schema.json の tools の1つ"""
    return json.loads((SCHEMA_DIR / "requirements.schema.json").read_text(encoding="utf-8"))["properties"]["tools"]["items"]


@lru_cache(maxsize=1)
def _tool_validator():
    """足す道具の形（requirements.schema.json の tools の1つ。太さの範囲は _check_tool_d で確かめる）"""
    item = copy.deepcopy(_tool_item())
    item["properties"]["tool_d_mm"] = {"type": ["number", "null"]}
    return Draft202012Validator(item)


def _check_tool_d(v) -> float:
    """人が入れる柄の太さは、要求の範囲（requirements.schema.json。3.5〜20mm）。カタログの範囲（c_clip.tool_d_mm）にも収める"""
    d = validator.param_def("c_clip", "tool_d_mm") or {}
    s = _tool_item()["properties"]["tool_d_mm"]
    lo, hi = max(s.get("minimum", 3.5), d.get("min", 3.0)), min(s.get("maximum", 20.0), d.get("max", 20.0))
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not lo <= v <= hi:
        raise ApiError("INVALID_ARGUMENT", f"柄の太さは {lo:g}〜{hi:g}mm で入れてください")
    return v


def _check_new_tool(t, atts: list[dict], req: dict) -> dict:
    """足す道具を、版を作る前に確かめる（数・形・太さの範囲・平たい柄）"""
    if not isinstance(t, dict):
        raise ApiError("INVALID_ARGUMENT")
    errs = [{"field": "/".join(map(str, e.absolute_path)) or "$", "message": e.message[:200]}
            for e in _tool_validator().iter_errors(t)]
    if errs:
        raise ApiError("INVALID_ARGUMENT", details=errs)
    if t.get("tool_d_mm") is not None:
        _check_tool_d(t["tool_d_mm"])
    if t["tool_shaft_shape"] == "flat":
        raise ApiError("INVALID_ARGUMENT", flat_reason(t["tool_type"]))
    # 要求の道具の一覧も4つまで（requirements.schema.json）なので、平たい柄の道具も数に入れる
    if len(atts) >= MAX_ATTACHMENTS or len(stored_tools(req)) >= MAX_ATTACHMENTS:
        raise ApiError("INVALID_ARGUMENT", f"取り付け具は{MAX_ATTACHMENTS}つまでです")
    return {k: t.get(k) for k in ("activity", "tool_type", "tool_d_mm", "tool_shaft_size", "tool_shaft_shape")}


@router.post("/v1/cases/{case_id}/designs")
def create_design(case_id: str, body: dict = Body(default={}), user: User = Depends(current_user)):
    owned_case(case_id, user)
    ops.require_generation_enabled()
    ops.count_usage(user.uid, "designs")
    return pipeline.run(case_id, origin="initial", style=body.get("style"))


@router.get("/v1/cases/{case_id}/designs/{design_id}")
def get_design(case_id: str, design_id: str, user: User = Depends(current_user)):
    readable_case(case_id, user)
    _design(case_id, design_id)
    return {"design": pipeline.design_view(case_id, design_id)}


@router.post("/v1/cases/{case_id}/designs/{design_id}/refine")
def refine(case_id: str, design_id: str, body: dict = Body(...), user: User = Depends(current_user)):
    case = owned_case(case_id, user)
    d = _design(case_id, design_id)
    keys = [k for k in REFINE_KINDS if body.get(k) is not None]
    if len(keys) != 1:
        raise ApiError("INVALID_ARGUMENT", "・".join(REFINE_KINDS) + " のどれか1つだけを送ってください")
    if case.get("current_design_id") != design_id:
        raise ApiError("STALE_DESIGN")
    k = keys[0]
    aid = body.get("attachment_id")
    if aid is not None:
        if not isinstance(aid, str):
            raise ApiError("INVALID_ARGUMENT", "attachment_id は文字列で送ってください")
        if k in ("add_attachment", "style"):
            raise ApiError("INVALID_ARGUMENT", "取り付け具を足すときと色を変えるときは attachment_id を送らないでください")
    if k == "style":
        style = {**(d.get("style") or {}), **body["style"]}
        if style.get("pattern", "none") == (d.get("style") or {}).get("pattern", "none"):
            db.update(f"cases/{case_id}/designs/{design_id}", {"style": style})  # 色だけなら版を作らない
            return {"design": pipeline.design_view(case_id, design_id)}
        raise ApiError("INVALID_ARGUMENT", "模様の変更は、いまは使えません")
    if d.get("status") not in ("ready", "needs_attention"):
        raise ApiError("CONFLICT", "この版はまだ直せません")
    # 取り付け具を選ぶ（なければ主な取り付け具）。版にない ID は受け付けない
    req = case.get("requirements") or {}
    atts = pipeline._attachments_of(d, req)
    if aid is not None and aid not in {a["id"] for a in atts}:
        raise ApiError("INVALID_ARGUMENT", "この版にない取り付け具です")
    # 版を作る前に、送られた値を確かめる（回数にも数えない）
    if k == "instruction":
        text = str(body["instruction"]).strip()
        if not text or len(text) > 300:
            raise ApiError("INVALID_ARGUMENT", "300文字までで書いてください")
    elif k == "param_changes":
        ch = body["param_changes"]
        if not isinstance(ch, list) or not ch or len(ch) > 10 or not all(isinstance(c, dict) for c in ch):
            raise ApiError("INVALID_ARGUMENT")
    elif k == "clip_angle_deg":
        a = int(body["clip_angle_deg"])
        choices = (validator.param_def("c_clip", "angle_deg") or {}).get("choices") or [60, 70, 80]   # カタログが唯一の正
        if a not in choices:
            raise ApiError("INVALID_ARGUMENT", "角度は " + "・".join(str(c) for c in choices) + " のどれかです")
    elif k == "tool_d_mm":
        tool_d = float(_check_tool_d(body["tool_d_mm"]))
    else:
        tool = _check_new_tool(body["add_attachment"], atts, req)
    ops.require_generation_enabled()
    ops.count_usage(user.uid, "refines")
    if k == "instruction":
        return pipeline.run(case_id, origin="refine_text", parent=d, instruction=text, attachment_id=aid)
    if k == "param_changes":
        angle = [c for c in ch if c.get("part_id") == "c_clip" and c.get("name") == "angle_deg"]
        if angle and len(ch) == 1:
            return pipeline.run(case_id, origin="refine_clip_angle", parent=d, clip_angle=int(angle[0]["value"]),
                                attachment_id=aid)
        return pipeline.run(case_id, origin="refine_params", parent=d, param_changes=ch, attachment_id=aid)
    if k == "clip_angle_deg":
        return pipeline.run(case_id, origin="refine_clip_angle", parent=d, clip_angle=a, attachment_id=aid)
    if k == "tool_d_mm":
        return pipeline.run(case_id, origin="refine_tool_d", parent=d, tool_d=tool_d, attachment_id=aid)
    return pipeline.run(case_id, origin="refine_add_attachment", parent=d, add_attachment=tool)


@router.post("/v1/cases/{case_id}/review-request")
def review_request(case_id: str, body: dict = Body(...), user: User = Depends(current_user)):
    case = owned_case(case_id, user)
    email = (body.get("reviewer_email") or "").strip().lower()
    design_id = body.get("design_id") or case.get("current_design_id")
    if not db.get(f"therapists/{email}"):
        raise ApiError("REVIEWER_NOT_ALLOWED")
    d = _design(case_id, design_id)
    if case.get("current_design_id") != design_id or d.get("status") not in ("ready", "needs_attention"):
        raise ApiError("STALE_DESIGN")
    op = ops.begin(case_id, "review_request", design_id)
    try:
        pr = pipeline.prepare_print(case_id, design_id, "review_request")
        t = now()
        db.update(f"cases/{case_id}/designs/{design_id}", {
            "geometry_hash": pr["geometry_hash"], "print_sha256": pr["print_sha256"], "print_internal": pr["internal_keys"],
            "approval": {"status": "requested", "reviewer_email": email, "requested_at": t,
                         "geometry_hash": pr["geometry_hash"], "print_sha256": pr["print_sha256"],
                         "message_ja": (body.get("message_ja") or "")[:300]}})
        db.update(f"cases/{case_id}", {"reviewer_email": email, "status": "in_review", "updated_at": t})
    finally:
        ops.end(case_id, op)
    from ..config import settings
    return {"case_status": "in_review", "review_url": f"{settings.app_base_url}/#/review/{case_id}"}


@router.post("/v1/cases/{case_id}/designs/{design_id}/approval")
def approval(case_id: str, design_id: str, body: dict = Body(...), user: User = Depends(current_user)):
    case = db.get(f"cases/{case_id}")
    if not case:
        raise ApiError("NOT_FOUND")
    if not (user.email and case.get("reviewer_email") == user.email and is_therapist(user)):
        raise ApiError("FORBIDDEN")
    d = _design(case_id, design_id)
    ap = d.get("approval") or {}
    if case.get("current_design_id") != design_id or ap.get("status") != "requested" \
            or body.get("geometry_hash") != d.get("geometry_hash"):
        raise ApiError("STALE_DESIGN")
    decision = body.get("decision")
    if decision not in ("approve", "reject"):
        raise ApiError("INVALID_ARGUMENT")
    checklist = body.get("checklist") or {}
    if decision == "approve" and not all(checklist.get(k) is True for k in CHECKLIST):
        raise ApiError("CHECKLIST_INCOMPLETE")
    op = ops.begin(case_id, "approval", design_id)
    try:
        t = now()
        result = {"status": "approved" if decision == "approve" else "rejected", "reviewer_email": user.email,
                  "decided_at": t, "comment_ja": (body.get("comment_ja") or "")[:500], "checklist": checklist}
        out = {"approval": result, "files": {}}
        if decision == "approve":
            prints = pipeline.publish_print(case_id, design_id, d.get("print_internal") or {}, d.get("print_sha256") or {})
            db.update(f"cases/{case_id}/designs/{design_id}", {"approval": result, "files": {"print": prints}})
            db.update(f"cases/{case_id}", {"status": "approved", "updated_at": t})
            out["files"] = {"print": prints}
            out["case_status"] = "approved"
        else:
            db.update(f"cases/{case_id}/designs/{design_id}", {"approval": result})
            db.update(f"cases/{case_id}", {"status": "changes_requested", "updated_at": t})
            out["case_status"] = "changes_requested"
        return out
    finally:
        ops.end(case_id, op)


@router.post("/v1/cases/{case_id}/designs/{design_id}/prepare-print")
def prepare_print(case_id: str, design_id: str, user: User = Depends(current_user)):
    case = owned_case(case_id, user)
    if not case.get("demo"):
        raise ApiError("FORBIDDEN", "デモのケースだけ、OTの確認なしで印刷用のデータを作れます")
    d = _design(case_id, design_id)
    if case.get("current_design_id") != design_id or d.get("status") not in ("ready", "needs_attention"):
        raise ApiError("STALE_DESIGN")
    if [v for v in (d.get("review") or {}).get("unresolved_issues", []) if v.get("severity") == "high"]:
        raise ApiError("RENDER_FAILED", "安全の検査に通っていないので、印刷用のデータは作れません")
    op = ops.begin(case_id, "prepare_print", design_id)
    try:
        pr = pipeline.prepare_print(case_id, design_id, "prepare_print")
        prints = pipeline.publish_print(case_id, design_id, pr["internal_keys"], pr["print_sha256"])
        db.update(f"cases/{case_id}/designs/{design_id}", {
            "print_prepared_at": now(), "print_sha256": pr["print_sha256"], "geometry_hash": pr["geometry_hash"],
            "files": {"print": prints}})
        return {"files": {"print": prints}, "demo_notice_ja": "デモ用：OTの確認を省略しています。実際に使う前には必ずOTの確認が必要です"}
    finally:
        ops.end(case_id, op)
