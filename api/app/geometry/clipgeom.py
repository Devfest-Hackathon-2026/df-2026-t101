"""C字クリップの寸法（scad/parts/c_clip.scad の関数と同じ式）。道具の棒の位置と検査に使う。"""
from __future__ import annotations

import math

import numpy as np

from .consts import fixed

CLIP_PLATE_MM = 2.0
CLIP_OVERLAP = 0.8
RAIL_END_WALL_MM = 2.5


def inner_d(clip: dict) -> float:
    td = float(clip["tool_d_mm"])
    if clip.get("tpu_sleeve"):
        return (td - 0.2) + 2 * float(fixed("TPU_SLEEVE_WALL_MM"))
    return td - float(fixed("CLIP_INTERFERENCE_MM"))


def r_out(clip: dict) -> float:
    return inner_d(clip) / 2 + float(clip["wall_mm"])


def clip_axis_rail(clip: dict) -> np.ndarray:
    a = math.radians(float(clip["angle_deg"]))
    return np.array([0.0, math.cos(a), -math.sin(a)])


def clip_center_rail(clip: dict) -> np.ndarray:
    a = math.radians(float(clip["angle_deg"]))
    h = float(clip["height_mm"])
    plate_top = float(fixed("DOVETAIL_CLEARANCE_MM")) + CLIP_PLATE_MM
    y0 = -float(fixed("RAIL_LENGTH_MM")) / 2 + 0.5
    return np.array([0.0, y0 + h / 2, plate_top + r_out(clip) * math.cos(a) + (h / 2) * math.sin(a) - CLIP_OVERLAP])


def opening_mm(clip: dict) -> float:
    return float(clip["opening_ratio"]) * float(clip["tool_d_mm"])


def sleeve_dims(clip: dict) -> dict:
    td = float(clip["tool_d_mm"])
    ri = td - 0.2
    return {"inner_d_mm": round(ri, 2), "outer_d_mm": round(ri + 2 * float(fixed("TPU_SLEEVE_WALL_MM")), 2),
            "length_mm": float(clip["height_mm"])}
