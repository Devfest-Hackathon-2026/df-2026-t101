"""形の計算のエラー。C（生成API）はこれを受けて api.md のエラーの形にする。"""
from __future__ import annotations


class GeometryError(Exception):
    """code は api.md のエラーコード（MEASUREMENT_INVALID・RENDER_FAILED・RENDER_TIMEOUT など）。"""

    def __init__(self, code: str, message_ja: str, details: list | None = None):
        super().__init__(f"{code}: {message_ja}")
        self.code = code
        self.message_ja = message_ja
        self.details = details or []
