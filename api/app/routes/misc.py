"""部品カタログ・OTの一覧・開発用のファイルの読み出し（docs/api.md §3.8・§3.10、impl_contract §2）"""
from __future__ import annotations

import mimetypes

from fastapi import APIRouter, Depends
from fastapi.responses import Response

from .. import validator
from ..auth import User, current_user, is_therapist
from ..config import settings
from ..errors import ApiError
from ..store import db, files

router = APIRouter()


@router.get("/health")
@router.get("/healthz")  # Cloud Run では /healthz は Google 側に横取りされるので、本番は /health を使う
def healthz():
    return {"ok": True, "gemini_mode": settings.gemini_mode, "store": settings.store_backend, "auth": settings.auth_mode}


@router.get("/v1/parts")
def parts(user: User = Depends(current_user)):
    c = validator.catalog()
    return {"version": c.get("version"), "parts": [
        {"id": p["id"], "required": p.get("required", False), "variants": p.get("variants", ["standard"]),
         "description_ja": p.get("description_ja", ""),
         "params": [{k: q.get(k) for k in ("name", "unit", "type", "default", "min", "max", "choices", "decided_by",
                                            "description_ja")} for q in p.get("params", [])]}
        for p in c["parts"]]}


@router.get("/v1/therapists")
def therapists(user: User = Depends(current_user)):
    return {"therapists": [{"email": email, "name": t.get("name", email), "display_name": t.get("name", email)}
                           for email, t in db.list("therapists")]}


def _can_read(path: str, user: User) -> bool:
    """data-model.md §4.2 と同じ判定（開発用。本番は Storage のルールが判定する）"""
    parts = path.split("/")
    if parts[0] != "cases" or len(parts) < 3:
        return False  # internal/ と、それ以外の場所は誰も読めない
    case = db.get(f"cases/{parts[1]}") or {}
    owner = case.get("owner_uid") == user.uid
    ot = bool(user.email and case.get("reviewer_email") == user.email and is_therapist(user))
    if not (owner or ot):
        return False
    if len(parts) >= 4 and parts[2] == "hand" and parts[3] == "raw":
        return False  # 未補正のメッシュはブラウザから読めない
    if "print" in parts:
        did = parts[3] if len(parts) > 3 else ""
        d = db.get(f"cases/{parts[1]}/designs/{did}") or {}
        return (d.get("approval") or {}).get("status") == "approved" or (case.get("demo") and d.get("print_prepared_at"))
    return True


@router.get("/v1/files/{path:path}")
def get_file(path: str, user: User = Depends(current_user)):
    if settings.store_backend != "local":
        raise ApiError("NOT_FOUND", "本番では Storage から読んでください")
    if not _can_read(path, user):
        raise ApiError("FORBIDDEN")
    data = files.get(path)
    if data is None:
        raise ApiError("NOT_FOUND")
    ctype = "model/gltf-binary" if path.endswith(".glb") else (mimetypes.guess_type(path)[0] or "application/octet-stream")
    return Response(content=data, media_type=ctype, headers={"Cache-Control": "no-store"})
