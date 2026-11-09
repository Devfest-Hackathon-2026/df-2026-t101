"""エラーの形（docs/api.md §5）。message は画面にそのまま出せる日本語にする。"""
from __future__ import annotations

from typing import Any

# code → (HTTPの番号, 既定の文, 再試行してよいか)
ERRORS: dict[str, tuple[int, str, bool]] = {
    "INVALID_ARGUMENT": (400, "入力の形が正しくありません", False),
    "UNAUTHENTICATED": (401, "ログインしてください", False),
    "FORBIDDEN": (403, "この操作はできません", False),
    "NOT_FOUND": (404, "見つかりませんでした", False),
    "CONFLICT": (409, "ほかの処理が進んでいます。少し待ってからもう一度試してください", True),
    "STALE_DESIGN": (409, "形が新しくなっています。画面を読み込み直してください", False),
    "CONSENT_REQUIRED": (422, "撮影の前に、同意の画面で「同意して進む」を押してください", False),
    "MEASUREMENT_INVALID": (422, "採寸の値に問題がありました。撮り直してください", False),
    "REQUIREMENTS_INVALID": (422, "質問の答えに問題がありました", False),
    "REVIEWER_NOT_ALLOWED": (422, "このメールアドレスのOTには頼めません", False),
    "CHECKLIST_INCOMPLETE": (422, "確認の項目にすべてチェックを入れてください", False),
    "DESIGN_INFEASIBLE": (422, "この条件では形を作れませんでした", False),
    "RATE_LIMITED": (429, "今日の回数の上限に達しました。明日もう一度試してください", False),
    "GENERATION_DISABLED": (503, "いまは形を作る機能を止めています", False),
    "AI_UNAVAILABLE": (503, "AIにつながりませんでした。少し待ってからもう一度試してください", True),
    "AI_OUTPUT_INVALID": (502, "AIの答えを読み取れませんでした。もう一度試してください", True),
    "RENDER_FAILED": (500, "形を作れませんでした", True),
    "RENDER_TIMEOUT": (500, "形を作るのに時間がかかりすぎました", True),
    "GENERATION_TIMEOUT": (500, "時間がかかりすぎたので止めました。もう一度試してください", True),
    "INTERNAL": (500, "サーバーで問題が起きました", True),
}


class ApiError(Exception):
    def __init__(self, code: str, message: str | None = None, details: Any = None, status: int | None = None,
                 retryable: bool | None = None):
        st, msg, rt = ERRORS.get(code, (500, "サーバーで問題が起きました", True))
        super().__init__(message or msg)
        self.code = code
        self.status = status or st
        self.message = message or msg
        self.details = details if details is not None else []
        self.retryable = rt if retryable is None else retryable

    def body(self, request_id: str) -> dict:
        return {"error": {"code": self.code, "message": self.message, "details": self.details,
                          "retryable": self.retryable, "request_id": request_id}}
