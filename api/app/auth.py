"""認証（docs/api.md §1）。本番は Firebase の ID トークン、開発は X-User ヘッダー。"""
from __future__ import annotations

from dataclasses import dataclass

from fastapi import Request

from .config import settings
from .errors import ApiError
from .store import db, now


@dataclass
class User:
    uid: str
    email: str | None = None
    email_verified: bool = False
    name: str | None = None


_fb_ready = False


def _verify_firebase(token: str) -> dict:
    global _fb_ready
    import firebase_admin
    from firebase_admin import auth as fb_auth

    if not _fb_ready:
        if not firebase_admin._apps:
            firebase_admin.initialize_app(options={"projectId": settings.project} if settings.project else None)
        _fb_ready = True
    return fb_auth.verify_id_token(token)


def current_user(request: Request) -> User:
    if settings.auth_mode == "dev":
        uid = request.headers.get("X-User", "").strip()
        if not uid:
            raise ApiError("UNAUTHENTICATED")
        # 開発中はメールも名乗れる（OT役の試験のため）
        email = (request.headers.get("X-User-Email") or f"{uid}@dev.local").lower()
        user = User(uid=uid, email=email, email_verified=True, name=uid)
    else:
        h = request.headers.get("Authorization", "")
        if not h.startswith("Bearer "):
            raise ApiError("UNAUTHENTICATED")
        try:
            claims = _verify_firebase(h[7:])
        except Exception:  # noqa: BLE001 - トークンの中身はログに出さない
            raise ApiError("UNAUTHENTICATED")
        user = User(uid=claims["uid"], email=(claims.get("email") or "").lower() or None,
                    email_verified=bool(claims.get("email_verified")), name=claims.get("name"))
    if db.get(f"users/{user.uid}") is None:  # 初めて呼んだときに作る（data-model.md §2.1）
        db.set(f"users/{user.uid}", {"display_name": user.name, "email": user.email, "created_at": now()})
    return user


def is_therapist(user: User) -> bool:
    return bool(user.email and user.email_verified and db.get(f"therapists/{user.email}"))
