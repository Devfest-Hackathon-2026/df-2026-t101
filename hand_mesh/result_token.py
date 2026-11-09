"""結果トークン（docs/api.md §4、impl の受け渡しの決まり §3）。

形：v1.{case_id}.{iso8601_utc}.{angles_sha256}.{mesh_sha256}.{hmac_hex}
署名の対象："v1|{case_id}|{ts}|{angles_sha256}|{mesh_sha256}"（HMAC-SHA256）
生成APIは同じ関数で確かめる（メッシュ復元を通らない角度やメッシュを受け付けないため）。
"""

from __future__ import annotations

import hashlib
import hmac
import json
from datetime import datetime, timezone
from typing import Optional


def angles_sha256(fingers: dict) -> str:
    # 生成API（api/app/tokens.py）と同じ書き方にする（ensure_ascii は既定のまま）
    canon = json.dumps(fingers, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canon.encode("utf-8")).hexdigest()


def bytes_sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sign(key: str, case_id: str, ts: str, a_sha: str, m_sha: str) -> str:
    msg = f"v1|{case_id}|{ts}|{a_sha}|{m_sha}".encode("utf-8")
    return hmac.new(key.encode("utf-8"), msg, hashlib.sha256).hexdigest()


def make_token(key: str, case_id: str, fingers: dict, mesh_sha256: str, ts: Optional[str] = None) -> str:
    if "." in case_id or "|" in case_id:
        raise ValueError("case_id must not contain '.' or '|'")
    ts = ts or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    a_sha = angles_sha256(fingers)
    return f"v1.{case_id}.{ts}.{a_sha}.{mesh_sha256}.{_sign(key, case_id, ts, a_sha, mesh_sha256)}"


def verify_token(key: str, token: str, case_id: str, fingers: Optional[dict] = None,
                 mesh_sha256: Optional[str] = None) -> dict:
    """署名と、ケースID・角度・メッシュのハッシュが合うかを確かめる。合わなければ ValueError。"""
    parts = token.split(".")
    if len(parts) != 6 or parts[0] != "v1":
        raise ValueError("bad token format")
    _, t_case, ts, a_sha, m_sha, sig = parts
    if not hmac.compare_digest(sig, _sign(key, t_case, ts, a_sha, m_sha)):
        raise ValueError("bad signature")
    if t_case != case_id:
        raise ValueError("case_id mismatch")
    if fingers is not None and angles_sha256(fingers) != a_sha:
        raise ValueError("angles mismatch")
    if mesh_sha256 is not None and mesh_sha256 != m_sha:
        raise ValueError("mesh mismatch")
    return {"case_id": t_case, "ts": ts, "angles_sha256": a_sha, "mesh_sha256": m_sha}
