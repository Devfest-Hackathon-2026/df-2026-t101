"""2026-11-24 の最適化の確かめ（Firestore・Cloud Storage の往復を減らす）。本物の Firestore・GCS には繋がず、
呼ばれた操作を数える仮のクライアントで確かめる。

- FirestoreDB.update は、書いたあとに文書を読み直していた（呼ぶ側は戻り値を使っていない。1回の生成で10〜15回）
- GcsFiles.get は、あるか確かめてから読む2往復だった
- current_user は、リクエストのたびに users/{uid} を読んでいた
"""
from __future__ import annotations

import pytest
from google.api_core.exceptions import NotFound

# app はテストの中で読み込む（test_api_flow.py が先に環境変数を決めてから app を読むので、ここで先に読まない）


class _Snap:
    def __init__(self, data):
        self._d = data
        self.exists = data is not None

    def to_dict(self):
        return self._d


class _Ref:
    def __init__(self, log, store, path):
        self.log, self.store, self.path = log, store, path

    def get(self, **_):
        self.log.append(("get", self.path))
        return _Snap(self.store.get(self.path))

    def set(self, data, merge=False):
        self.log.append(("set", self.path, merge))
        self.store[self.path] = {**(self.store.get(self.path) or {}), **data} if merge else dict(data)

    def update(self, data):
        self.log.append(("update", self.path))
        if self.path not in self.store:
            raise NotFound("no doc")
        self.store[self.path] = {**self.store[self.path], **data}


class _Client:
    def __init__(self):
        self.log, self.store = [], {}

    def document(self, path):
        return _Ref(self.log, self.store, path)


def _fdb():
    from app.store import FirestoreDB
    db = object.__new__(FirestoreDB)
    db.client = _Client()
    return db


def test_firestore_update_does_not_read_back():
    db = _fdb()
    db.client.store["cases/c1"] = {"a": 1}
    db.update("cases/c1", {"b": 2})
    assert [x[0] for x in db.client.log] == ["set"]
    assert db.client.store["cases/c1"] == {"a": 1, "b": 2}


def test_firestore_update_replace_without_extra_read():
    db = _fdb()
    db.client.store["cases/c1"] = {"requirements": {"old": 1}, "x": 1}
    db.update("cases/c1", {"requirements": {"new": 2, "__replace__": True}, "y": 3})
    assert ("get", "cases/c1") not in db.client.log
    assert db.client.store["cases/c1"]["requirements"] == {"new": 2}
    assert db.client.store["cases/c1"]["y"] == 3


def test_firestore_update_replace_on_missing_doc_creates_it():
    db = _fdb()
    db.update("cases/new", {"requirements": {"new": 2, "__replace__": True}})
    assert db.client.store["cases/new"] == {"requirements": {"new": 2}}


class _Blob:
    def __init__(self, log, data):
        self.log, self.data = log, data

    def exists(self):
        self.log.append("exists")
        return self.data is not None

    def download_as_bytes(self):
        self.log.append("download")
        if self.data is None:
            raise NotFound("no blob")
        return self.data


class _Bucket:
    def __init__(self, blobs):
        self.log, self.blobs = [], blobs

    def blob(self, key):
        return _Blob(self.log, self.blobs.get(key))


def _gcs(blobs):
    from app.store import GcsFiles
    f = object.__new__(GcsFiles)
    f.bucket = _Bucket(blobs)
    return f


def test_gcs_get_is_one_round_trip():
    f = _gcs({"a/b.stl": b"xyz"})
    assert f.get("a/b.stl") == b"xyz"
    assert f.bucket.log == ["download"]


def test_gcs_get_missing_returns_none():
    f = _gcs({})
    assert f.get("nope") is None
    assert f.bucket.log == ["download"]


class _Req:
    def __init__(self, uid):
        self.headers = {"X-User": uid}


def test_current_user_reads_users_doc_once_per_process(monkeypatch):
    from app import auth
    assert auth.settings.auth_mode == "dev"
    calls, docs = [], {}

    def get(path):
        calls.append(path)
        return docs.get(path)

    def set_(path, data):
        docs[path] = data

    monkeypatch.setattr(auth.db, "get", get)
    monkeypatch.setattr(auth.db, "set", set_)
    auth._known_users.discard("perf-u1")
    for _ in range(3):
        assert auth.current_user(_Req("perf-u1")).uid == "perf-u1"
    assert calls.count("users/perf-u1") == 1
    assert "users/perf-u1" in docs  # 初めての人は今までどおり作る


@pytest.mark.parametrize("existing", [True, False])
def test_current_user_still_creates_missing_users(monkeypatch, existing):
    from app import auth
    docs = {"users/perf-u2": {"display_name": "x"}} if existing else {}
    monkeypatch.setattr(auth.db, "get", lambda p: docs.get(p))
    monkeypatch.setattr(auth.db, "set", lambda p, d: docs.__setitem__(p, d))
    auth._known_users.discard("perf-u2")
    auth.current_user(_Req("perf-u2"))
    assert "users/perf-u2" in docs
