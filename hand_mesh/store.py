"""保存先（Storage）と記録（Firestore）。

STORE_BACKEND=local：リポジトリの .localstore/ を使う（生成APIと同じフォルダを共有する）
  - Storage の代わり：.localstore/storage/<Storage のパス>
  - Firestore の代わり：.localstore/db/<コレクション>/<ID>.json
STORE_BACKEND=gcp：Cloud Storage と Firestore（google-cloud-* は使うときだけ読み込む）
画像はどこにも書かない。書くのは、未補正の手のメッシュと、回数・費用だけ。
"""

from __future__ import annotations

import json
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

import config

JST = timezone(timedelta(hours=9))
_lock = threading.Lock()


class StoreError(Exception):
    pass


class LimitError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code, self.message = code, message


def _today() -> str:
    return datetime.now(JST).strftime("%Y%m%d")  # 日付は日本時間で区切る（data-model.md §2.6）


# ---------------------------------------------------------------- local


class LocalStore:
    def __init__(self, root: Optional[Path] = None):
        self.root = Path(root or config.LOCAL_STORE_DIR)

    def _doc_path(self, path: str) -> Path:
        return self.root / "db" / (path + ".json")

    def get_doc(self, path: str) -> Optional[dict]:
        p = self._doc_path(path)
        if not p.exists():
            return None
        return json.loads(p.read_text(encoding="utf-8"))

    def _put_doc(self, path: str, doc: dict) -> None:
        p = self._doc_path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(".tmp")
        tmp.write_text(json.dumps(doc, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(p)

    def put_object(self, path: str, data: bytes, content_type: str) -> None:
        p = self.root / "storage" / path
        try:
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
        except OSError as e:
            raise StoreError(str(e)) from e

    def reserve_call(self, uid: str) -> None:
        """上限を確かめ、回数と見積もり額を足す（1つのまとまった処理）。"""
        with _lock:
            rt = self.get_doc("settings/runtime")
            # local では設定がなければ動かす（開発のため）。gcp では設定なし＝止める
            if rt is not None and rt.get("generation_enabled") is False:
                raise LimitError("GENERATION_DISABLED", "いまは計算を止めています。")
            day = _today()
            usage = self.get_doc(f"usage/{day}") or {}
            user = self.get_doc(f"usage/{day}/users/{uid}") or {}
            _check_limits(usage, user)
            _add_call(usage, user)
            self._put_doc(f"usage/{day}", usage)
            self._put_doc(f"usage/{day}/users/{uid}", user)

    def add_gpu_seconds(self, uid: str, seconds: float) -> None:
        with _lock:
            day = _today()
            for path in (f"usage/{day}", f"usage/{day}/users/{uid}"):
                d = self.get_doc(path) or {}
                d["gpu_execution_seconds"] = round(d.get("gpu_execution_seconds", 0.0) + seconds, 2)
                self._put_doc(path, d)


def _check_limits(usage: dict, user: dict) -> None:
    if user.get("mesh_requests", 0) >= config.PER_USER_DAILY or usage.get("mesh_requests", 0) >= config.GLOBAL_DAILY:
        raise LimitError("RATE_LIMITED", "今日の回数の上限に達しました。明日もう一度お試しください。")
    if usage.get("estimated_cost_usd", 0.0) >= config.DAILY_COST_LIMIT_USD:
        raise LimitError("RATE_LIMITED", "今日の費用の上限に達しました。明日もう一度お試しください。")


def _add_call(usage: dict, user: dict) -> None:
    for d in (usage, user):
        d["mesh_requests"] = d.get("mesh_requests", 0) + 1
        d["gpu_cost_usd"] = round(d.get("gpu_cost_usd", 0.0) + config.MESH_COST_PER_CALL_USD, 4)
        d["estimated_cost_usd"] = round(d.get("gemini_cost_usd", 0.0) + d["gpu_cost_usd"], 4)


# ---------------------------------------------------------------- gcp


class GcpStore:
    def __init__(self):
        from google.cloud import firestore, storage  # 使うときだけ読み込む

        self._fs = firestore
        self.db = firestore.Client(project=config.GOOGLE_CLOUD_PROJECT or None)
        self.bucket = storage.Client(project=config.GOOGLE_CLOUD_PROJECT or None).bucket(config.STORAGE_BUCKET)

    def get_doc(self, path: str) -> Optional[dict]:
        snap = self.db.document(path).get()
        return snap.to_dict() if snap.exists else None

    def put_object(self, path: str, data: bytes, content_type: str) -> None:
        try:
            self.bucket.blob(path).upload_from_string(data, content_type=content_type)
        except Exception as e:  # noqa: BLE001
            raise StoreError(type(e).__name__) from e

    def reserve_call(self, uid: str) -> None:
        rt = self.get_doc("settings/runtime")
        if not rt or rt.get("generation_enabled") is not True:  # 設定なし・取得失敗では動かさない
            raise LimitError("GENERATION_DISABLED", "いまは計算を止めています。")
        day = _today()
        u_ref = self.db.document(f"usage/{day}")
        p_ref = self.db.document(f"usage/{day}/users/{uid}")
        fs = self._fs

        @fs.transactional
        def txn(t):
            usage = (u_ref.get(transaction=t).to_dict() or {})
            user = (p_ref.get(transaction=t).to_dict() or {})
            _check_limits(usage, user)
            _add_call(usage, user)
            t.set(u_ref, usage, merge=True)
            t.set(p_ref, user, merge=True)

        txn(self.db.transaction())

    def add_gpu_seconds(self, uid: str, seconds: float) -> None:
        day = _today()
        inc = self._fs.Increment(round(seconds, 2))
        for path in (f"usage/{day}", f"usage/{day}/users/{uid}"):
            self.db.document(path).set({"gpu_execution_seconds": inc}, merge=True)


_store = None


def get_store():
    global _store
    if _store is None:
        _store = GcpStore() if config.STORE_BACKEND == "gcp" else LocalStore()
    return _store


def reset_store(store=None) -> None:
    """テスト用：保存先を差し替える。"""
    global _store
    _store = store
