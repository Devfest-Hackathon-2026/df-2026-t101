"""形を作る・直す・OTに頼む・承認・デモの印刷用データ（docs/api.md §3.4〜§3.7・§3.11）"""
from __future__ import annotations

from fastapi import APIRouter, Body, Depends

from .. import ops, pipeline
from ..auth import User, current_user, is_therapist
from ..errors import ApiError
from ..store import db, now
from .common import owned_case, readable_case

router = APIRouter()
CHECKLIST = ("dimensions_reviewed", "edges_safe", "not_an_orthosis", "palm_open_wrist_free", "no_mouth_contact",
             "user_informed")


def _design(case_id: str, design_id: str) -> dict:
    d = db.get(f"cases/{case_id}/designs/{design_id}")
    if not d:
        raise ApiError("NOT_FOUND")
    return {**d, "design_id": design_id}


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
    keys = [k for k in ("instruction", "param_changes", "clip_angle_deg", "style") if body.get(k) is not None]
    if len(keys) != 1:
        raise ApiError("INVALID_ARGUMENT", "instruction・param_changes・clip_angle_deg・style のどれか1つだけを送ってください")
    if case.get("current_design_id") != design_id:
        raise ApiError("STALE_DESIGN")
    k = keys[0]
    if k == "style":
        style = {**(d.get("style") or {}), **body["style"]}
        if style.get("pattern", "none") == (d.get("style") or {}).get("pattern", "none"):
            db.update(f"cases/{case_id}/designs/{design_id}", {"style": style})  # 色だけなら版を作らない
            return {"design": pipeline.design_view(case_id, design_id)}
        raise ApiError("INVALID_ARGUMENT", "模様の変更は、いまは使えません")
    if d.get("status") not in ("ready", "needs_attention"):
        raise ApiError("CONFLICT", "この版はまだ直せません")
    ops.require_generation_enabled()
    ops.count_usage(user.uid, "refines")
    if k == "instruction":
        text = str(body["instruction"]).strip()
        if not text or len(text) > 300:
            raise ApiError("INVALID_ARGUMENT", "300文字までで書いてください")
        return pipeline.run(case_id, origin="refine_text", parent=d, instruction=text)
    if k == "param_changes":
        ch = body["param_changes"]
        if not isinstance(ch, list) or not ch or len(ch) > 10:
            raise ApiError("INVALID_ARGUMENT")
        angle = [c for c in ch if c.get("part_id") == "c_clip" and c.get("name") == "angle_deg"]
        if angle and len(ch) == 1:
            return pipeline.run(case_id, origin="refine_clip_angle", parent=d, clip_angle=int(angle[0]["value"]))
        return pipeline.run(case_id, origin="refine_params", parent=d, param_changes=ch)
    a = int(body["clip_angle_deg"])
    if a not in (0, 20, 40):
        raise ApiError("INVALID_ARGUMENT", "角度は 0・20・40 のどれかです")
    return pipeline.run(case_id, origin="refine_clip_angle", parent=d, clip_angle=a)


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
