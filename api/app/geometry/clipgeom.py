"""C字クリップの寸法（scad/parts/c_clip.scad の関数と同じ式）。道具の棒の位置と検査に使う。

レールの座標（X＝横、Y＝手首→指先、Z＝外向き）。正準形（左手の向き：手のひら側が +z、親指側が −x）で計算するので
side は −1（左手）。実際の右手の形は X の符号が逆（鏡像）になる。2026-11-08 に「横張り出し」の形に変えた。
"""
from __future__ import annotations

import math

import numpy as np

from .consts import fixed

CLIP_PLATE_MM = 2.0
CLIP_LAT_MM = 20.0     # 輪の中心を、レールの上面の中心から親指側へ出す量
CLIP_DOWN_MM = 6.0     # 手のひら側へ下げる量
CLIP_FWD_MM = 5.0      # 指先側へ進める量
RAIL_END_WALL_MM = 2.5
S2 = math.sqrt(0.5)
CANONICAL_SIDE = -1    # 正準形は左手の向き


def frame_rail(side: int = CANONICAL_SIDE) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """レールの座標で見た、手の甲向き up・親指側 lat・指先向き fwd"""
    up = np.array([S2 * side, 0.0, S2])
    lat = np.array([-S2 * side, 0.0, S2])
    fwd = np.array([0.0, 1.0, 0.0])
    return up, lat, fwd


def inner_d(clip: dict) -> float:
    td = float(clip["tool_d_mm"])
    if clip.get("tpu_sleeve"):
        return (td - 0.2) + 2 * float(fixed("TPU_SLEEVE_WALL_MM"))
    return td - float(fixed("CLIP_INTERFERENCE_MM"))


def r_out(clip: dict) -> float:
    return inner_d(clip) / 2 + float(clip["wall_mm"])


def clip_axis_rail(clip: dict, side: int = CANONICAL_SIDE) -> np.ndarray:
    """道具の軸（先の向き）。tilt＝机に対する傾き"""
    up, _, fwd = frame_rail(side)
    t = math.radians(float(clip["angle_deg"]))
    return fwd * math.cos(t) - up * math.sin(t)


def clip_center_rail(clip: dict, side: int = CANONICAL_SIDE) -> np.ndarray:
    up, lat, fwd = frame_rail(side)
    return lat * CLIP_LAT_MM - up * CLIP_DOWN_MM + fwd * CLIP_FWD_MM


def opening_mm(clip: dict) -> float:
    return float(clip["opening_ratio"]) * float(clip["tool_d_mm"])


def sleeve_dims(clip: dict) -> dict:
    td = float(clip["tool_d_mm"])
    ri = td - 0.2
    return {"inner_d_mm": round(ri, 2), "outer_d_mm": round(ri + 2 * float(fixed("TPU_SLEEVE_WALL_MM")), 2),
            "length_mm": float(clip["height_mm"])}
