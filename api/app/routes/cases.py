"""ケース・聞き取り・同意・回収（docs/api.md §3.1〜§3.2.2・§3.9）"""
from __future__ import annotations

import json
import uuid
from functools import lru_cache

from fastapi import APIRouter, Body, Depends
from jsonschema import Draft202012Validator

from .. import gemini, ops
from ..attachments import normalize_tools, primary_index, requirement_assumptions
from ..auth import User, current_user
from ..config import CONSENT_TEXT_VERSION, SCHEMA_DIR
from ..errors import ApiError
from ..store import db, files, now
from .common import case_view, owned_case, readable_case

router = APIRouter()


@lru_cache(maxsize=1)
def _req_validator():
    return Draft202012Validator(json.loads((SCHEMA_DIR / "requirements.schema.json").read_text(encoding="utf-8")))


@router.post("/v1/cases", status_code=201)
def create_case(body: dict = Body(default={}), user: User = Depends(current_user)):
    case_id = "c_" + uuid.uuid4().hex[:8]
    t = now()
    db.set(f"cases/{case_id}", {"owner_uid": user.uid, "title": (body.get("title") or "道具づくり")[:60],
                                "status": "interviewing", "demo": ops.demo_mode(), "requirements": {},
                                "turn_count": 0, "created_at": t, "updated_at": t, "active_operation": None})
    return {"case_id": case_id, "status": "interviewing"}


@router.get("/v1/cases")
def list_cases(user: User = Depends(current_user)):
    out = [case_view(cid, c) for cid, c in db.list("cases") if c.get("owner_uid") == user.uid]
    out.sort(key=lambda c: str(c.get("updated_at", "")), reverse=True)
    return {"cases": out}


@router.get("/v1/cases/{case_id}")
def get_case(case_id: str, user: User = Depends(current_user)):
    return case_view(case_id, readable_case(case_id, user))


@router.delete("/v1/cases/{case_id}")
def delete_case(case_id: str, user: User = Depends(current_user)):
    """ケースを消す（docs/data-model.md §5）。手のメッシュ・STL・画像・版・チャットもまとめて消す。
    形を作っている途中（有効な処理中の印がある）なら 409。Storage を先に消し、ケースの文書は最後に消す
    （途中で失敗しても、ケースが残っていれば、もう一度消せる）"""
    case = owned_case(case_id, user)
    ops.assert_no_active(case)
    n_files = files.delete_prefix(f"cases/{case_id}/") + files.delete_prefix(f"internal/cases/{case_id}/")
    for sub in ("designs", "messages"):
        for doc_id, _ in db.list(f"cases/{case_id}/{sub}"):
            db.delete(f"cases/{case_id}/{sub}/{doc_id}")
    db.delete(f"cases/{case_id}")
    return {"deleted": True, "case_id": case_id, "files_deleted": n_files}


@router.put("/v1/cases/{case_id}/requirements")
def put_requirements(case_id: str, body: dict = Body(...), user: User = Depends(current_user)):
    case = owned_case(case_id, user)
    ops.assert_no_active(case)
    errs = [{"field": "/".join(map(str, e.absolute_path)) or "$", "message": e.message[:200]}
            for e in _req_validator().iter_errors(body)]
    if errs:
        raise ApiError("REQUIREMENTS_INVALID", details=errs)
    measured_side = (case.get("measurement") or {}).get("hand_side")
    if measured_side and body.get("hand_side") and body["hand_side"] != measured_side:
        # 採寸は左右ごとに座標が違う（保存したメッシュを逆向きに正準化すると、手のひら側を覆う形になり検査も通ってしまう。11/8）
        raise ApiError("CONFLICT", "手の左右を変えるには、採寸（撮影）からやり直してください")
    old = case.get("requirements") or {}
    tools = normalize_tools(body)
    pi = primary_index(tools)
    primary = tools[pi if pi is not None else 0]
    req = {**body, "tools": tools, "notes": old.get("notes", []), "activity_ja": old.get("activity_ja"),
           "assumptions": requirement_assumptions(tools)}
    for k in ("activity", "tool_type", "tool_d_mm", "tool_d_source", "tool_shaft_size", "tool_shaft_shape"):
        req[k] = primary[k]
    status = case["status"]
    if req.get("activity") != "other" or req.get("activity_ja"):
        status = "measuring" if status in ("interviewing", "measuring") else status
    db.update(f"cases/{case_id}", {"requirements": {**req, "__replace__": True}, "status": status, "updated_at": now()})
    return {"requirements": req, "case_status": status}


@router.post("/v1/cases/{case_id}/interview")
def interview(case_id: str, body: dict = Body(...), user: User = Depends(current_user)):
    case = owned_case(case_id, user)
    ops.assert_no_active(case)
    msg = (body.get("message") or "").strip()
    if not msg or len(msg) > 500:
        raise ApiError("INVALID_ARGUMENT", "500文字までで書いてください")
    turn = int(case.get("turn_count", 0)) + 1
    if turn > 3:
        raise ApiError("INVALID_ARGUMENT", "チャットは3回までです")
    ops.require_generation_enabled()
    ops.count_usage(user.uid, "interviews")
    history = [m for _, m in db.list(f"cases/{case_id}/messages")]
    usage = gemini.Usage()
    out = gemini.interview(case.get("requirements") or {}, history, msg, turn, usage)
    t = now()
    db.set(f"cases/{case_id}/messages/m{turn:02d}u", {"role": "user", "text": msg, "created_at": t})
    db.set(f"cases/{case_id}/messages/m{turn:02d}a", {"role": "assistant", "text": out["message_ja"],
                                                      "choices": out.get("choices", []), "created_at": t})
    req = dict(case.get("requirements") or {})
    req["notes"] = (req.get("notes") or []) + [n for n in out.get("notes", []) if n not in (req.get("notes") or [])]
    status = case["status"]
    if out.get("activity_ja"):
        req["activity_ja"] = out["activity_ja"]
        if req.get("activity") == "other" and req.get("tool_type"):
            status = "measuring"
    db.update(f"cases/{case_id}", {"requirements": {**req, "__replace__": True}, "turn_count": turn,
                                   "status": status, "updated_at": t})
    if usage.calls:
        ops.add_gemini_cost(usage.as_dict())
    return {"turn": out, "requirements": {"notes": req["notes"]}, "case_status": status, "turn_count": turn}


@router.post("/v1/cases/{case_id}/consent")
def consent(case_id: str, body: dict = Body(...), user: User = Depends(current_user)):
    owned_case(case_id, user)
    if body.get("mesh_consent") is True:
        if body.get("consent_text_version") != CONSENT_TEXT_VERSION:
            raise ApiError("INVALID_ARGUMENT", "同意の文が新しくなっています。画面を読み込み直してください")
        db.update(f"cases/{case_id}", {"mesh_consent_at": now(), "consent_text_version": CONSENT_TEXT_VERSION,
                                       "updated_at": now()})
        return {"mesh_consent": True, "consent_text_version": CONSENT_TEXT_VERSION}
    db.update(f"cases/{case_id}", {"mesh_consent_at": None, "consent_text_version": None, "updated_at": now()})
    return {"mesh_consent": False}


@router.post("/v1/cases/{case_id}/recover")
def recover(case_id: str, user: User = Depends(current_user)):
    readable_case(case_id, user)
    recovered = ops.recover(case_id)
    case = db.get(f"cases/{case_id}")
    return {"case_status": case["status"], "current_design_id": case.get("current_design_id"),
            "active_operation": case.get("active_operation"), "recovered": recovered}
