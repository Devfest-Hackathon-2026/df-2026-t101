"""道具の留め具（万力式）の寸法（scad/parts/vise_holder.scad・holder_base.scad の関数と同じ式）。道具の棒の位置と検査に使う。

2026-11-24 に C字クリップから万力式に置き換えた。部品の ID・引数は今まで通り c_clip（tool_d_mm・angle_deg）。
レールの座標（X＝横、Y＝手首→指先、Z＝外向き）。正準形（左手の向き：手のひら側が +z、親指側が −x）で計算するので
side は −1（左手）。実際の右手の形は X の符号が逆（鏡像）になる。
"""
from __future__ import annotations

import math

import numpy as np

S2 = math.sqrt(0.5)
CANONICAL_SIDE = -1    # 正準形は左手の向き

# vise_holder.scad と同じ値
VISE_LAT_MM = 26.0         # 穴が太さ 12mm 用のとき、受け具の中心を親指側へ出す量
VISE_DOWN_MM = 6.0         # 手のひら側へ下げる量
VISE_FWD_MM = 5.0          # 指先側へ進める量
VISE_RANGE_MM = 2.5        # 挟める太さの幅（tool_d から上下に）
VISE_DMAX_MIN_MM = 12.0    # 穴の大きさの下限（ねじ M12 が通る大きさ）
VISE_DMIN_MIN_MM = 2.5


def frame_rail(side: int = CANONICAL_SIDE) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """レールの座標で見た、手の甲向き up・親指側 lat・指先向き fwd"""
    up = np.array([S2 * side, 0.0, S2])
    lat = np.array([-S2 * side, 0.0, S2])
    fwd = np.array([0.0, 1.0, 0.0])
    return up, lat, fwd


def vise_dmax(tool_d: float) -> float:
    return max(VISE_DMAX_MIN_MM, float(tool_d) + VISE_RANGE_MM)


def vise_dmin(tool_d: float) -> float:
    return max(VISE_DMIN_MIN_MM, float(tool_d) - VISE_RANGE_MM)


def _r(dmax: float) -> float:
    return dmax / 2 + 0.5


def vise_lat(dmax: float) -> float:
    """受け具の中心の親指側への量。手の側の端が、穴がいちばん小さいときと同じ所に来るよう外へずらす"""
    return VISE_LAT_MM + math.sqrt(2) * (_r(dmax) - _r(VISE_DMAX_MIN_MM))


def vise_tool_x(d: float, dmax: float) -> float:
    """太さ d の道具が V 字に収まったときの中心（受け具の局所 X。+X が親指側）"""
    return -_r(dmax) * math.sqrt(2) + d / math.sqrt(2)


def clip_axis_rail(clip: dict, side: int = CANONICAL_SIDE) -> np.ndarray:
    """道具の軸（先の向き）。tilt＝机に対する傾き"""
    up, _, fwd = frame_rail(side)
    t = math.radians(float(clip["angle_deg"]))
    return fwd * math.cos(t) - up * math.sin(t)


def clip_center_rail(clip: dict, side: int = CANONICAL_SIDE) -> np.ndarray:
    """基準の太さ（tool_d_mm）の道具を挟んだときの、道具の軸の上の点（受け具の高さの真ん中）"""
    up, lat, fwd = frame_rail(side)
    td = float(clip["tool_d_mm"])
    dmax = vise_dmax(td)
    return lat * (vise_lat(dmax) + vise_tool_x(td, dmax)) - up * VISE_DOWN_MM + fwd * VISE_FWD_MM


def grip_range_mm(clip: dict) -> tuple[float, float]:
    """1つの留め具で挟める太さ（下限、上限）"""
    td = float(clip["tool_d_mm"])
    return vise_dmin(td), vise_dmax(td)
