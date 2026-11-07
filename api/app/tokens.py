"""hand-mesh の結果トークンの確かめ（impl_contract §3、docs/api.md §3.3）。
形：v1.{case_id}.{iso8601_utc}.{angles_sha256}.{mesh_sha256}.{hmac_hex}
署名の対象："v1|{case_id}|{ts}|{angles_sha256}|{mesh_sha256}"（HMAC-SHA256）"""
from __future__ import annotations

import hashlib
import hmac
import json

from .config import settings


def angles_sha256(fingers: dict) -> str:
    return hashlib.sha256(json.dumps(fingers, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def parse(token: str) -> dict | None:
    parts = token.split(".")
    # 日時に "." が入らない形（秒まで、Z付き）を前提にする。ケースIDにも "." は入らない
    if len(parts) != 6 or parts[0] != "v1":
        return None
    _, case_id, ts, a_sha, m_sha, mac = parts
    return {"case_id": case_id, "ts": ts, "angles_sha256": a_sha, "mesh_sha256": m_sha, "hmac": mac}


def verify(token: str, case_id: str) -> dict | None:
    """署名とケースIDが合えば中身を返す。合わなければ None"""
    t = parse(token or "")
    if not t or t["case_id"] != case_id:
        return None
    msg = f"v1|{t['case_id']}|{t['ts']}|{t['angles_sha256']}|{t['mesh_sha256']}".encode()
    expect = hmac.new(settings.mesh_hmac_key, msg, hashlib.sha256).hexdigest()
    return t if hmac.compare_digest(expect, t["hmac"]) else None
