"""採寸の保存（docs/api.md §3.3、measurement.md §12）の確かめと、角度の出し直し。"""
from __future__ import annotations

import hashlib
import json
import math
import statistics
from functools import lru_cache

import numpy as np
from jsonschema import Draft202012Validator

from .config import CONSENT_TEXT_VERSION, SCHEMA_DIR
from .errors import ApiError
from . import tokens

FINGERS = ("index", "middle", "ring", "pinky")
PALM_SEGMENTS = {"wrist_to_index_mcp_mm": ("0", "5"), "wrist_to_middle_mcp_mm": ("0", "9"),
                 "wrist_to_pinky_mcp_mm": ("0", "17"), "hand_width_mcp_mm": ("5", "17")}


@lru_cache(maxsize=1)
def _validator() -> Draft202012Validator:
    schema = json.loads((SCHEMA_DIR / "measurement.schema.json").read_text(encoding="utf-8"))
    return Draft202012Validator(schema)


def _finite(o, path="$") -> list[str]:
    bad = []
    if isinstance(o, float) and not math.isfinite(o):
        bad.append(path)
    elif isinstance(o, dict):
        for k, v in o.items():
            bad += _finite(v, f"{path}.{k}")
    elif isinstance(o, list):
        for i, v in enumerate(o):
            bad += _finite(v, f"{path}[{i}]")
    return bad


def validate(m: dict, case: dict, case_id: str) -> tuple[dict, list[str]]:
    """スキーマ・項目の間の制約・同意・トークン。合わなければ 422。返すのはトークンの中身と追加の警告"""
    errs = [{"field": "/".join(str(p) for p in e.absolute_path) or "$", "constraint": e.validator, "message": e.message[:200]}
            for e in _validator().iter_errors(m)]
    if errs:
        raise ApiError("MEASUREMENT_INVALID", details=errs[:20])
    d = []
    for p in _finite(m):
        d.append({"field": p, "constraint": "finite"})
    for f in FINGERS:
        if sum(m["fingers"][f]["lengths_mm"]) > 180:
            d.append({"field": f"fingers.{f}.lengths_mm", "constraint": "sum<=180"})
    xs = [m["palm"]["mcp_positions_mm"][f][0] for f in FINGERS]
    if any(b <= a for a, b in zip(xs, xs[1:])):
        d.append({"field": "palm.mcp_positions_mm", "constraint": "x increasing index→pinky"})
    cap = m["capture"]
    if cap.get("frames_sampled") is not None and cap["frames_used"] > cap["frames_sampled"]:
        d.append({"field": "capture.frames_used", "constraint": "<= frames_sampled"})
    if cap["mode"] == "photos" and cap["frames_used"] > 2:
        d.append({"field": "capture.frames_used", "constraint": "photos <= 2"})
    if cap["mesh_frames_sent"] > cap["frames_used"]:
        d.append({"field": "capture.mesh_frames_sent", "constraint": "<= frames_used"})
    warnings: list[str] = []
    mp = m.get("manual_points") or []
    if mp:
        for fr in mp:
            if fr["frame_index"] >= cap["frames_used"]:
                d.append({"field": "manual_points.frame_index", "constraint": "< frames_used"})
        for key, (a, b) in PALM_SEGMENTS.items():
            vals = [math.dist(fr["points"][a], fr["points"][b]) / fr["px_per_mm"] for fr in mp]
            if abs(statistics.median(vals) - m["palm"][key]) > 1.0:
                d.append({"field": f"palm.{key}", "constraint": "manual_points median within 1mm",
                          "message": f"直した点からの値 {statistics.median(vals):.1f} と送られた値 {m['palm'][key]:.1f} が合わない"})
        warnings.append("POINTS_MANUAL")
    if d:
        raise ApiError("MEASUREMENT_INVALID", details=d)
    if not case.get("mesh_consent_at") or case.get("consent_text_version") != CONSENT_TEXT_VERSION:
        raise ApiError("CONSENT_REQUIRED")
    t = tokens.verify(cap["mesh_result_token"], case_id)
    if not t:
        raise ApiError("MEASUREMENT_INVALID", details=[{"field": "capture.mesh_result_token", "constraint": "signature"}])
    return t, warnings


def check_mesh(raw: bytes | None, token: dict) -> None:
    if raw is None:
        raise ApiError("MEASUREMENT_INVALID", details=[{"field": "capture.mesh_id", "constraint": "mesh exists"}])
    if hashlib.sha256(raw).hexdigest() != token["mesh_sha256"]:
        raise ApiError("MEASUREMENT_INVALID", details=[{"field": "capture.mesh_id", "constraint": "mesh_sha256"}])


def flexion_from_joints(joints: dict, hand_side: str) -> dict:
    """関節の位置から曲がり角（measurement.md §6 と同じ定義、手のひら側が正）を出す"""
    w = np.array(joints["wrist"], float)
    x = np.array(joints["pinky"][0], float) - np.array(joints["index"][0], float)
    y = np.array(joints["middle"][0], float) - w
    x /= np.linalg.norm(x)
    y -= x * (y @ x)
    y /= np.linalg.norm(y)
    z = np.cross(x, y)
    palm = z if hand_side == "left" else -z  # §8.1：左手では z が手のひら側、右手では手の甲側
    out = {}
    for f in FINGERS:
        pts = [w] + [np.array(p, float) for p in joints[f]]
        ang = {}
        for name, i in (("mcp", 1), ("pip", 2), ("dip", 3)):
            a, b = pts[i] - pts[i - 1], pts[i + 1] - pts[i]
            un = math.degrees(math.atan2(np.linalg.norm(np.cross(a, b)), a @ b))
            # 曲がる向き：b が a より手のひら側へ向いていれば正
            sign = 1.0 if (b / np.linalg.norm(b) - a / np.linalg.norm(a)) @ palm >= 0 else -1.0
            ang[name] = round(sign * un, 1)
        out[f] = ang
    return out
