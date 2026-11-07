"""GLB の読み書き。手のメッシュと、関節などの付帯情報（最上位の extras）を1つのファイルにする。

GLB の形：12バイトの見出し → JSON のかたまり → バイナリのかたまり。
extras は glTF の最上位の "extras" に入れる（docs/api.md §4、impl の受け渡しの決まり §3）。
"""

from __future__ import annotations

import json
import struct
from typing import Any, Dict, Tuple

import numpy as np
import trimesh


def write_glb(vertices: np.ndarray, faces: np.ndarray, extras: Dict[str, Any]) -> bytes:
    """頂点（mm）と三角形を GLB にし、最上位の extras を足す。"""
    mesh = trimesh.Trimesh(np.asarray(vertices, dtype=np.float64), np.asarray(faces, dtype=np.int64), process=False)

    def add_extras(tree: dict) -> None:
        tree["extras"] = extras

    return trimesh.exchange.gltf.export_glb(trimesh.Scene(mesh), tree_postprocessor=add_extras)


def read_json_chunk(data: bytes) -> dict:
    """GLB の JSON のかたまりを読む。"""
    if len(data) < 20 or data[:4] != b"glTF":
        raise ValueError("not a GLB file")
    _magic, _version, _length = struct.unpack_from("<4sII", data, 0)
    chunk_len, chunk_type = struct.unpack_from("<I4s", data, 12)
    if chunk_type != b"JSON":
        raise ValueError("first GLB chunk is not JSON")
    return json.loads(data[20:20 + chunk_len].decode("utf-8"))


def read_extras(data: bytes) -> Dict[str, Any]:
    return read_json_chunk(data).get("extras", {})


def read_glb(data: bytes) -> Tuple[trimesh.Trimesh, Dict[str, Any]]:
    """GLB から1つのメッシュ（全部の部分をまとめたもの）と extras を返す。"""
    import io

    scene = trimesh.load(io.BytesIO(data), file_type="glb", force="scene", process=False)
    geoms = list(scene.dump()) if hasattr(scene, "dump") else [scene]
    mesh = trimesh.util.concatenate(geoms) if len(geoms) > 1 else geoms[0]
    return mesh, read_extras(data)
