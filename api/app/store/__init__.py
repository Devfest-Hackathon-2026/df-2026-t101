"""Firestore と Cloud Storage の窓口。開発中（STORE_BACKEND=local）は .localstore/ のファイルで代わりにする。
local の形は scratchpad の impl_contract.md §2 と同じ（hand-mesh と同じフォルダを共有する）。"""
from __future__ import annotations

import json
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from ..config import settings


def now() -> datetime:
    return datetime.now(timezone.utc)


def parse_time(v: Any) -> datetime | None:
    """Firestore の日時（datetime）と、local の ISO 文字列のどちらでも読む"""
    if v is None:
        return None
    if isinstance(v, datetime):
        return v if v.tzinfo else v.replace(tzinfo=timezone.utc)
    try:
        d = datetime.fromisoformat(str(v).replace("Z", "+00:00"))
        return d if d.tzinfo else d.replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def _json_default(o: Any):
    if isinstance(o, datetime):
        return o.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
    raise TypeError(type(o))


def _deep_merge(base: dict, patch: dict) -> dict:
    out = dict(base)
    for k, v in patch.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict) and not v.get("__replace__"):
            out[k] = _deep_merge(out[k], v)
        else:
            out[k] = {kk: vv for kk, vv in v.items() if kk != "__replace__"} if isinstance(v, dict) else v
    return out


# ---------------------------------------------------------------- Firestore の代わり
class LocalDB:
    """`.localstore/db/<path>.json`。サブコレクションはフォルダの入れ子"""

    def __init__(self, root: Path):
        self.root = root / "db"
        self.lock = threading.RLock()

    def _p(self, path: str) -> Path:
        return self.root / (path.strip("/") + ".json")

    def get(self, path: str) -> dict | None:
        p = self._p(path)
        with self.lock:
            if not p.exists():
                return None
            return json.loads(p.read_text(encoding="utf-8"))

    def set(self, path: str, data: dict) -> None:
        p = self._p(path)
        with self.lock:
            p.parent.mkdir(parents=True, exist_ok=True)
            tmp = p.with_suffix(".tmp")
            tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1, default=_json_default), encoding="utf-8")
            tmp.replace(p)

    def update(self, path: str, patch: dict) -> dict:
        with self.lock:
            cur = self.get(path) or {}
            new = _deep_merge(cur, json.loads(json.dumps(patch, default=_json_default)))
            self.set(path, new)
            return new

    def delete(self, path: str) -> None:
        with self.lock:
            p = self._p(path)
            if p.exists():
                p.unlink()

    def list(self, collection: str) -> list[tuple[str, dict]]:
        d = self.root / collection.strip("/")
        with self.lock:
            if not d.is_dir():
                return []
            return [(f.stem, json.loads(f.read_text(encoding="utf-8"))) for f in sorted(d.glob("*.json"))]

    def transaction(self, fn: Callable[["LocalDB"], Any]) -> Any:
        """local では1つの鍵で順番に実行する（Firestore のトランザクションの代わり）"""
        with self.lock:
            return fn(self)


class FirestoreDB:
    def __init__(self):
        from google.cloud import firestore  # 遅延 import（local では要らない）
        self._fs = firestore
        self.client = firestore.Client(project=settings.project)

    def _ref(self, path: str):
        return self.client.document(path.strip("/"))

    def get(self, path: str) -> dict | None:
        snap = self._ref(path).get()
        return snap.to_dict() if snap.exists else None

    def set(self, path: str, data: dict) -> None:
        self._ref(path).set(data)

    def update(self, path: str, patch: dict) -> dict:
        # "__replace__" の印が付いた入れ子の値は、まるごと置き換える（merge だと古いキーが残るため）
        merge = {k: v for k, v in patch.items() if not (isinstance(v, dict) and v.get("__replace__"))}
        repl = {k: {kk: vv for kk, vv in v.items() if kk != "__replace__"} for k, v in patch.items()
                if isinstance(v, dict) and v.get("__replace__")}
        ref = self._ref(path)
        if merge:
            ref.set(merge, merge=True)
        if repl:
            if not ref.get().exists:
                ref.set({})
            ref.update(repl)
        return self.get(path) or {}

    def delete(self, path: str) -> None:
        self._ref(path).delete()

    def list(self, collection: str) -> list[tuple[str, dict]]:
        return [(d.id, d.to_dict()) for d in self.client.collection(collection.strip("/")).stream()]

    def transaction(self, fn: Callable[[Any], Any]) -> Any:
        tx = self.client.transaction()
        outer = self

        class _Tx:
            def get(self, path):
                snap = outer._ref(path).get(transaction=tx)
                return snap.to_dict() if snap.exists else None

            def set(self, path, data):
                tx.set(outer._ref(path), data)

            def update(self, path, patch):
                tx.set(outer._ref(path), patch, merge=True)

            def delete(self, path):
                tx.delete(outer._ref(path))

        @self._fs.transactional
        def run(transaction):
            return fn(_Tx())

        return run(tx)


# ---------------------------------------------------------------- Cloud Storage の代わり
class LocalFiles:
    def __init__(self, root: Path):
        self.root = root / "storage"

    def path(self, key: str) -> Path:
        p = (self.root / key.strip("/")).resolve()
        if self.root.resolve() not in p.parents:
            raise ValueError("不正なパス")
        return p

    def put(self, key: str, data: bytes, content_type: str = "application/octet-stream") -> None:
        p = self.path(key)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)

    def get(self, key: str) -> bytes | None:
        p = self.path(key)
        return p.read_bytes() if p.exists() else None

    def exists(self, key: str) -> bool:
        return self.path(key).exists()

    def copy(self, src: str, dst: str) -> None:
        self.put(dst, self.get(src) or b"")

    def delete_prefix(self, prefix: str) -> int:
        base = self.path(prefix)
        n = 0
        if base.is_dir():
            for f in sorted(base.rglob("*"), reverse=True):
                if f.is_file():
                    f.unlink(); n += 1
                else:
                    f.rmdir()
            base.rmdir()
        elif base.exists():
            base.unlink(); n = 1
        return n


class GcsFiles:
    def __init__(self, bucket: str):
        from google.cloud import storage
        self.bucket = storage.Client(project=settings.project).bucket(bucket)

    def put(self, key: str, data: bytes, content_type: str = "application/octet-stream") -> None:
        self.bucket.blob(key).upload_from_string(data, content_type=content_type)

    def get(self, key: str) -> bytes | None:
        b = self.bucket.blob(key)
        return b.download_as_bytes() if b.exists() else None

    def exists(self, key: str) -> bool:
        return self.bucket.blob(key).exists()

    def copy(self, src: str, dst: str) -> None:
        self.bucket.copy_blob(self.bucket.blob(src), self.bucket, dst)

    def delete_prefix(self, prefix: str) -> int:
        blobs = list(self.bucket.list_blobs(prefix=prefix))
        for b in blobs:
            b.delete()
        return len(blobs)


def _make():
    if settings.store_backend == "gcp":
        if not settings.storage_bucket:
            raise RuntimeError("STORAGE_BUCKET が設定されていません")
        return FirestoreDB(), GcsFiles(settings.storage_bucket)
    settings.local_store_dir.mkdir(parents=True, exist_ok=True)
    return LocalDB(settings.local_store_dir), LocalFiles(settings.local_store_dir)


db, files = _make()


class Cache:
    """形の計算（geometry）に渡す、使い回しの窓口。geometry は "sdf"・"keepout/c1.50"・"shell/<24桁>" のような
    短いキーを使うので、ケースと採寸の版ごとの場所 internal/cases/{caseId}/cover/{measurementId}/ を前に付ける"""

    def __init__(self, prefix: str):
        self.prefix = prefix.rstrip("/") + "/"

    def get(self, key: str) -> bytes | None:
        return files.get(self.prefix + key)

    def put(self, key: str, data: bytes) -> None:
        files.put(self.prefix + key, data)
