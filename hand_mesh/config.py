"""設定（環境変数）。impl の受け渡しの決まり §2 と同じ名前を使う。"""

from __future__ import annotations

import os
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent

AUTH_MODE = os.environ.get("AUTH_MODE", "dev").strip().lower()          # dev | firebase
STORE_BACKEND = os.environ.get("STORE_BACKEND", "local").strip().lower()  # local | gcp
LOCAL_STORE_DIR = Path(os.environ.get("LOCAL_STORE_DIR") or (REPO / ".localstore"))
STORAGE_BUCKET = os.environ.get("STORAGE_BUCKET", "")
GOOGLE_CLOUD_PROJECT = os.environ.get("GOOGLE_CLOUD_PROJECT", "")

CONSENT_VERSION = "mesh-consent-2"

MAX_FRAMES = 8
MAX_FRAME_BYTES = int(os.environ.get("MESH_MAX_FRAME_BYTES", "200000"))
MAX_EXEC_SECONDS = float(os.environ.get("MESH_MAX_EXECUTION_SECONDS", "60"))

# 回数と費用の上限（docs/api.md §4）
PER_USER_DAILY = int(os.environ.get("MESH_PER_USER_DAILY", "20"))
GLOBAL_DAILY = int(os.environ.get("MESH_GLOBAL_DAILY", "100"))
DAILY_COST_LIMIT_USD = float(os.environ.get("DAILY_COST_LIMIT_USD", "15"))
MESH_COST_PER_CALL_USD = float(os.environ.get("MESH_COST_PER_CALL_USD", "0.40"))

CORS_REGEX = r"^https?://(localhost|127\.0\.0\.1)(:\d+)?$"
EXTRA_ORIGINS = [o.strip() for o in os.environ.get("HAND_MESH_CORS_ORIGINS", "").split(",") if o.strip()]


def hmac_key() -> str:
    """結果トークンの鍵。dev のときだけ決まった値を使ってよい。"""
    key = os.environ.get("MESH_RESULT_HMAC_KEY", "")
    if key:
        return key
    if AUTH_MODE == "dev":
        return "dev-only-key"
    raise RuntimeError("MESH_RESULT_HMAC_KEY is not set (required unless AUTH_MODE=dev)")
