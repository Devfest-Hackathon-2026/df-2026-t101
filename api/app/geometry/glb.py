"""GLB（glTF のバイナリ）の読み書き。頂点・三角形と、最上位の extras（joints_mm など）を扱う。

trimesh の書き出しは extras を入れられないので、書いたあとに JSON の塊へ extras を足す。
"""
from __future__ import annotations

import io
import json
import struct

import numpy as np
import trimesh

_MAGIC = 0x46546C67  # "glTF"
_JSON = 0x4E4F534A
_BIN = 0x004E4942


def _split(data: bytes) -> tuple[dict, bytes]:
    magic, version, length = struct.unpack_from("<III", data, 0)
    if magic != _MAGIC:
        raise ValueError("GLB ではありません")
    off = 12
    js, bin_ = None, b""
    while off < length:
        clen, ctype = struct.unpack_from("<II", data, off)
        chunk = data[off + 8: off + 8 + clen]
        if ctype == _JSON:
            js = json.loads(chunk.decode("utf-8"))
        elif ctype == _BIN:
            bin_ = chunk
        off += 8 + clen
    if js is None:
        raise ValueError("GLB に JSON がありません")
    return js, bin_


def _join(js: dict, bin_: bytes) -> bytes:
    jb = json.dumps(js, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    jb += b" " * ((4 - len(jb) % 4) % 4)
    bb = bin_ + b"\x00" * ((4 - len(bin_) % 4) % 4)
    total = 12 + 8 + len(jb) + (8 + len(bb) if bb else 0)
    out = struct.pack("<III", _MAGIC, 2, total) + struct.pack("<II", len(jb), _JSON) + jb
    if bb:
        out += struct.pack("<II", len(bb), _BIN) + bb
    return out


def read_glb(data: bytes) -> tuple[np.ndarray, np.ndarray, dict]:
    """(頂点 float64 [n,3], 三角形 int [m,3], extras) を返す。"""
    js, _ = _split(data)
    extras = js.get("extras") or {}
    m = trimesh.load(io.BytesIO(data), file_type="glb", force="mesh", process=False)
    return np.asarray(m.vertices, dtype=np.float64), np.asarray(m.faces, dtype=np.int64), extras


def write_glb(vertices: np.ndarray, faces: np.ndarray, extras: dict | None = None) -> bytes:
    m = trimesh.Trimesh(np.asarray(vertices, dtype=np.float64), np.asarray(faces), process=False)
    data = m.export(file_type="glb")
    if not extras:
        return data
    js, bin_ = _split(data)
    js["extras"] = extras
    return _join(js, bin_)
