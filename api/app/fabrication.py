"""架空の受託者と印刷の決まり、重さ・時間・金額の目安
（docs/superpowers/specs/2026-11-21-in-app-ordering-design.md §6.1・§6.2）。
受託者は架空の見本なので、Firestore ではなくリポジトリの data/fabrication.json に置く。"""
from __future__ import annotations

import io
import json
import math
from functools import lru_cache
from pathlib import Path

_PATH = Path(__file__).resolve().parent / "data" / "fabrication.json"


@lru_cache(maxsize=1)
def config() -> dict:
    return json.loads(_PATH.read_text(encoding="utf-8"))


def fabricators() -> list[dict]:
    return list(config()["fabricators"])


def fabricator(fid: str) -> dict | None:
    return next((f for f in config()["fabricators"] if f["id"] == fid), None)


def part_of(print_key: str) -> str:
    """印刷用のキーの頭で部品を決める（c_clip_a2 なども c_clip）"""
    for part in ("c_clip", "tpu_sleeve", "cover"):
        if print_key == part or print_key.startswith(part + "_"):
            return part
    return print_key


def material_of(print_key: str) -> str:
    m = config()["materials"].get(part_of(print_key))
    return m["name"] if m else ""


def estimate_part(stl: bytes, print_key: str) -> dict:
    """STL の体積から、重さ（g）と印刷時間（分）の目安を出す。係数は仮（1回刷った結果で合わせる）"""
    import trimesh

    mesh = trimesh.load(io.BytesIO(stl), file_type="stl")
    vol = abs(float(mesh.volume))
    c = config()
    density = c["materials"].get(part_of(print_key), {"density_g_cm3": 1.24})["density_g_cm3"]
    est = c["estimate"]
    grams = vol / 1000.0 * density * est["mass_factor"]
    minutes = grams * est["minutes_per_gram"] + est["setup_minutes"]
    return {"volume_mm3": vol, "grams": grams, "minutes": minutes}


def round10(yen: float) -> int:
    """10円単位の四捨五入"""
    return int(math.floor(yen / 10 + 0.5) * 10)


def quote(fab: dict, grams: dict[str, float], print_keys: list[str], quantity: int, felt: bool) -> dict:
    """金額の目安。parts = 基本料 + 1gあたり × 選んだ部品の重さの合計 × 個数、felt = フェルト料 × 個数"""
    total_g = sum(float(grams.get(k, 0.0)) for k in print_keys)
    parts_yen = round10(fab["base_fee_yen"] + fab["yen_per_gram"] * total_g * quantity)
    felt_yen = round10(fab["felt_fee_yen"] * quantity) if felt else 0
    return {"parts_yen": parts_yen, "felt_yen": felt_yen, "total_yen": parts_yen + felt_yen}


def color_of(hex_: str | None) -> dict:
    return {"hex": hex_, "name_ja": config()["colors"].get(hex_ or "", "")}
