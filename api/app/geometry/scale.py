"""倍率 k：1円玉で測った手の甲の4区間 ÷ メッシュの関節の間の長さ（measurement.md §7.1・§8.2）。"""
from __future__ import annotations

import numpy as np

from .consts import LONG_FINGERS
from .errors import GeometryError

# 手の甲の4区間：(名前, 採寸JSONの palm の項目, 点の番号の組)
PALM4 = (
    ("0-5", "wrist_to_index_mcp_mm", (0, 5)),
    ("0-9", "wrist_to_middle_mcp_mm", (0, 9)),
    ("0-17", "wrist_to_pinky_mcp_mm", (0, 17)),
    ("5-17", "hand_width_mcp_mm", (5, 17)),
)
_MP_TO_JOINT = {0: ("wrist", None), 5: ("index", 0), 9: ("middle", 0), 13: ("ring", 0), 17: ("pinky", 0)}


def _joint(J: dict, mp: int) -> np.ndarray:
    name, i = _MP_TO_JOINT[mp]
    return J[name] if i is None else J[name][i]


def _manual_lengths(manual_points: list) -> dict:
    """直した点（フレームごとの px と px_per_mm）から4区間の長さ（フレームの中央値）。"""
    vals = {k: [] for k, _, _ in PALM4}
    for fr in manual_points:
        s = float(fr["px_per_mm"])
        pts = {int(k): np.asarray(v, dtype=float) for k, v in fr["points"].items()}
        for key, _, (a, b) in PALM4:
            vals[key].append(float(np.linalg.norm(pts[a] - pts[b])) / s)
    return {k: float(np.median(v)) for k, v in vals.items() if v}


def compute_scale(measurement: dict, J: dict) -> dict:
    """J は未補正のメッシュの関節（mm）。返す: k・出どころ・ばらつき・警告。"""
    palm = measurement["palm"]
    measured = {key: float(palm[field]) for key, field, _ in PALM4}
    warnings: list[str] = []
    details: list[dict] = []
    manual = measurement.get("manual_points") or []
    source = "auto"
    if manual:
        source = "manual_points"
        ml = _manual_lengths(manual)
        for key, field, _ in PALM4:
            if key in ml and abs(ml[key] - measured[key]) > 1.0:
                details.append({"field": f"palm.{field}", "reason": "manual_points から計算した長さと 1mm より違う",
                                "expected": round(ml[key], 2), "got": measured[key]})
        if details:
            raise GeometryError("MEASUREMENT_INVALID", "直した点と手の甲の長さが合いません", details)
        if "POINTS_MANUAL" not in warnings:
            warnings.append("POINTS_MANUAL")

    ratios = {}
    for key, field, (a, b) in PALM4:
        mesh_len = float(np.linalg.norm(_joint(J, a) - _joint(J, b)))
        if mesh_len < 1e-6:
            raise GeometryError("MEASUREMENT_INVALID", "メッシュの関節が重なっています", [{"segment": key}])
        ratios[key] = measured[key] / mesh_len
    rv = np.array(list(ratios.values()))
    k = float(np.median(rv))
    if not (0.5 <= k <= 2.0):
        raise GeometryError("MEASUREMENT_INVALID", "倍率が範囲外です（点の取り違えか、1円玉の誤検出のおそれ）",
                            [{"field": "scale_factor", "value": round(k, 3), "range": [0.5, 2.0]}])
    q1, q3 = np.percentile(rv, [25, 75])
    palm_spread = float((q3 - q1) / k)

    # 指の区間（確かめだけ）
    fr = []
    for f in LONG_FINGERS:
        lens = (measurement.get("fingers", {}).get(f) or {}).get("lengths_mm")
        if not lens:
            continue
        for s in range(3):
            ml = float(np.linalg.norm(J[f][s + 1] - J[f][s]))
            if ml > 1e-6 and lens[s] > 0:
                fr.append(lens[s] / ml)
    finger_med = float(np.median(fr)) if fr else k
    spread = abs(finger_med - k) / k
    if palm_spread > 0.10 or spread > 0.15:
        warnings.append("MESH_SCALE_INCONSISTENT")
    return {"k": k, "scale_source": source, "scale_spread_ratio": round(spread, 4),
            "palm_ratio_iqr": round(palm_spread, 4), "ratios": {kk: round(v, 4) for kk, v in ratios.items()},
            "warnings": warnings}


def check_mcp_order(J: dict) -> None:
    """付け根が人差し指から小指へ x の増加順に並ぶか（実際の手の座標）。"""
    xs = [float(J[f][0][0]) for f in LONG_FINGERS]
    if not all(xs[i] < xs[i + 1] for i in range(3)):
        raise GeometryError("MEASUREMENT_INVALID", "メッシュの指の付け根の並びがおかしいです",
                            [{"field": "joints_mm", "mcp_x": [round(x, 1) for x in xs]}])
