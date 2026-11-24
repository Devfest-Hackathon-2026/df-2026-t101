"""2026-11-24 のレビューで見つかった不具合の確かめ。

- チャットの2回目以降が本番で必ず 500 だった（11/10 のログ）。Firestore から読んだ会話の created_at が日時の型で、
  プロンプトに入れる json.dumps が失敗していた。手元の保存（local）は文字列で保存するので、テストでは起きなかった
- 同じ回の会話は、ID の並び（m01a < m01u）で AI の答えが先に来ていた
- 処理中の印の期限（300秒）が、本番の生成の期限（REQUEST_TIMEOUT_S=840）より短く、16秒ごとの /recover が
  まだ動いている生成を失敗にしていた
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from app import gemini, ops
from app.config import settings
from app.routes.cases import interview_history


def test_prompt_json_accepts_datetimes():
    t = datetime(2026, 11, 10, 4, 33, tzinfo=timezone.utc)
    s = gemini._j([{"role": "user", "text": "こんにちは", "created_at": t}])
    assert "こんにちは" in s


def test_interview_history_user_first_and_plain():
    t = datetime(2026, 11, 10, 4, 33, tzinfo=timezone.utc)
    msgs = [  # Firestore の stream は ID の順（m01a が m01u より先）
        ("m01a", {"role": "assistant", "text": "答え1", "choices": ["はい"], "created_at": t}),
        ("m01u", {"role": "user", "text": "質問1", "created_at": t}),
        ("m02a", {"role": "assistant", "text": "答え2", "choices": [], "created_at": t}),
        ("m02u", {"role": "user", "text": "質問2", "created_at": t}),
    ]
    h = interview_history(msgs)
    assert [m["text"] for m in h] == ["質問1", "答え1", "質問2", "答え2"]
    assert all("created_at" not in m for m in h)
    assert h[1]["choices"] == ["はい"]
    gemini._j(h)  # プロンプトに入れられる


def test_operation_lock_outlives_generation_deadline():
    # /recover が、まだ期限内の生成を期限切れとして回収しないこと
    assert ops.OP_TTL >= timedelta(seconds=settings.request_timeout_s + 30)
