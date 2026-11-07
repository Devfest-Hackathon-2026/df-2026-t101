"""誰が呼んだか（AUTH_MODE）。

dev：X-User ヘッダーをユーザーIDとして使う（トークンの検証はしない。開発専用）
firebase：Authorization: Bearer <Firebase の IDトークン> を firebase_admin で確かめる
"""

from __future__ import annotations

from typing import Optional

import config

_fb_app = None


def _verify_firebase(token: str) -> str:
    global _fb_app
    import firebase_admin  # 使うときだけ読み込む
    from firebase_admin import auth as fb_auth

    if _fb_app is None:
        _fb_app = firebase_admin.initialize_app(options={"projectId": config.GOOGLE_CLOUD_PROJECT} if config.GOOGLE_CLOUD_PROJECT else None)
    return fb_auth.verify_id_token(token)["uid"]


def user_id(headers) -> Optional[str]:
    """ユーザーIDを返す。分からなければ None。"""
    if config.AUTH_MODE == "firebase":
        h = headers.get("authorization", "")
        if not h.lower().startswith("bearer "):
            return None
        try:
            return _verify_firebase(h[7:].strip())
        except Exception:  # noqa: BLE001 - 失敗の中身は返さない
            return None
    uid = headers.get("x-user", "").strip()
    return uid or None
