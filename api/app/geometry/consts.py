"""固定値とパス。値は scad/catalog.json の "fixed" を唯一の正として読む（common.scad も同じ値）。"""
from __future__ import annotations

import json
import os
import platform
from functools import lru_cache
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SCAD_DIR = REPO / "scad"
CATALOG_PATH = SCAD_DIR / "catalog.json"


@lru_cache(maxsize=1)
def catalog() -> dict:
    return json.loads(CATALOG_PATH.read_text(encoding="utf-8"))


def fixed(name: str):
    return catalog()["fixed"][name]


def openscad_bin() -> str:
    env = os.environ.get("OPENSCAD_BIN")
    if env:
        return env
    if platform.system() == "Windows":
        return r"C:\Program Files\OpenSCAD (Nightly)\openscad.exe"
    return "openscad"


FINGERS = ("thumb", "index", "middle", "ring", "pinky")
LONG_FINGERS = ("index", "middle", "ring", "pinky")
# 距離場の形式の版。計算の仕方を変えたら上げる（キャッシュを無効にするため）
FIELD_VERSION = "f1"
