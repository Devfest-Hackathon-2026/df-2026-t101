"""設定（環境変数）。docs/architecture.md §4.1。秘密の値はここに書かない。"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def _env(name: str, default: str | None = None) -> str | None:
    v = os.environ.get(name)
    return v if v not in (None, "") else default


def _int(name: str, default: int) -> int:
    try:
        return int(_env(name, str(default)))
    except ValueError:
        return default


def _float(name: str, default: float) -> float:
    try:
        return float(_env(name, str(default)))
    except ValueError:
        return default


@dataclass(frozen=True)
class Settings:
    auth_mode: str = field(default_factory=lambda: _env("AUTH_MODE", "dev"))            # dev | firebase
    store_backend: str = field(default_factory=lambda: _env("STORE_BACKEND", "local"))  # local | gcp
    local_store_dir: Path = field(default_factory=lambda: Path(_env("LOCAL_STORE_DIR", str(REPO_ROOT / ".localstore"))))
    storage_bucket: str | None = field(default_factory=lambda: _env("STORAGE_BUCKET"))
    project: str | None = field(default_factory=lambda: _env("GOOGLE_CLOUD_PROJECT"))
    gemini_mode: str = field(default_factory=lambda: _env("GEMINI_MODE", "mock"))       # mock | live
    gemini_location: str = field(default_factory=lambda: _env("GEMINI_LOCATION", "global"))
    gemini_model: str = field(default_factory=lambda: _env("GEMINI_MODEL", "gemini-4-argon"))
    hmac_key: str | None = field(default_factory=lambda: _env("MESH_RESULT_HMAC_KEY"))
    generation_enabled_env: bool = field(default_factory=lambda: _env("GENERATION_ENABLED", "true").lower() != "false")
    daily_cost_limit_usd: float = field(default_factory=lambda: _float("DAILY_COST_LIMIT_USD", 15.0))
    limit_designs_per_user: int = field(default_factory=lambda: _int("LIMIT_DESIGNS_PER_USER", 10))
    limit_refines_per_user: int = field(default_factory=lambda: _int("LIMIT_REFINES_PER_USER", 30))
    limit_interviews_per_user: int = field(default_factory=lambda: _int("LIMIT_INTERVIEWS_PER_USER", 60))
    limit_designs_total: int = field(default_factory=lambda: _int("LIMIT_DESIGNS_TOTAL", 100))
    request_timeout_s: int = field(default_factory=lambda: _int("REQUEST_TIMEOUT_S", 280))
    hosting_origins: str = field(default_factory=lambda: _env("HOSTING_ORIGINS", ""))  # カンマ区切り
    app_base_url: str = field(default_factory=lambda: _env("APP_BASE_URL", "http://localhost:5173"))

    @property
    def mesh_hmac_key(self) -> bytes:
        if self.hmac_key:
            return self.hmac_key.encode()
        if self.auth_mode == "dev":
            return b"dev-only-key"  # 開発だけ。本番は Secret Manager から渡す
        raise RuntimeError("MESH_RESULT_HMAC_KEY が設定されていません")


settings = Settings()

CONSENT_TEXT_VERSION = "mesh-consent-2"
SCAD_DIR = REPO_ROOT / "scad"
CATALOG_PATH = SCAD_DIR / "catalog.json"
SCHEMA_DIR = REPO_ROOT / "schemas"
PROMPT_DIR = Path(__file__).resolve().parent.parent / "prompts"
