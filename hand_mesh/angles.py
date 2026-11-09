"""Finger flexion angles from 3D hand joints (docs/measurement.md §6, §8.1, §11).

Joint source: SAM 3D Body outputs the first 70 MHR keypoints ("MHR70",
vendor/sam-3d-body/sam_3d_body/metadata/mhr70.py). Its hand decoder only
predicts RIGHT hands (upstream flips the image for left hands, see
SAM3DBody.run_inference), so the backend mirrors left-hand images first and we
always read the right-hand keypoints.

MHR70 right-hand indices (names from mhr70.py; the skeleton links there connect
"right_wrist" -> "*_third_joint", so third = MCP, second = PIP, first = DIP):

    finger   MCP(third) PIP(second) DIP(first) TIP
    thumb       24         23          22       21   (not used)
    index       28         27          26       25
    middle      32         31          30       29
    ring        36         35          34       33
    pinky       40         39          38       37
    wrist = 41

Angle definition (measurement.md §6, method B "θ3D"):
    MCP: ∠(MCP − W, PIP − MCP), PIP: ∠(PIP − MCP, DIP − PIP), DIP: ∠(DIP − PIP, TIP − DIP)
    ∠(a, b) = atan2((a × b)·n, a·b), palm side positive.
n is the per-finger flexion axis of §8.2 (a = d0 × z, so that a × d0 = +z), with
z the palm-side normal of the canonical (left-hand) frame of §8.1.
"""

from __future__ import annotations

import math
from typing import Dict, Optional, Sequence

import numpy as np

FINGERS = ("index", "middle", "ring", "pinky")
JOINTS = ("mcp", "pip", "dip")

MHR70_RIGHT_WRIST = 41
# (MCP, PIP, DIP, TIP) per finger, MHR70 right hand
MHR70_RIGHT_FINGERS: Dict[str, tuple] = {
    "thumb": (24, 23, 22, 21),
    "index": (28, 27, 26, 25),
    "middle": (32, 31, 30, 29),
    "ring": (36, 35, 34, 33),
    "pinky": (40, 39, 38, 37),
}
MHR70_RIGHT_HAND_IDX = list(range(21, 42))


def _unit(v: np.ndarray) -> np.ndarray:
    n = float(np.linalg.norm(v))
    if not math.isfinite(n) or n < 1e-9:
        raise ValueError("degenerate vector")
    return v / n


def to_canonical_left(right_hand_pts: np.ndarray) -> np.ndarray:
    """Mirror right-hand points into the canonical left-hand form (§8.1: flip x)."""
    p = np.array(right_hand_pts, dtype=np.float64, copy=True)
    p[..., 0] *= -1.0
    return p


def palm_frame(pts: np.ndarray) -> tuple:
    """Hand frame of §8.1 for canonical (left-hand) MHR70 points. Returns (x, y, z)."""
    w = pts[MHR70_RIGHT_WRIST]
    m_index = pts[MHR70_RIGHT_FINGERS["index"][0]]
    m_middle = pts[MHR70_RIGHT_FINGERS["middle"][0]]
    m_pinky = pts[MHR70_RIGHT_FINGERS["pinky"][0]]
    x = _unit(m_pinky - m_index)
    y_raw = m_middle - w
    y = _unit(y_raw - np.dot(y_raw, x) * x)
    z = np.cross(x, y)  # palm side in the canonical left-hand form
    return x, y, z


def signed_angle_deg(a: np.ndarray, b: np.ndarray, n: np.ndarray) -> float:
    return math.degrees(math.atan2(float(np.dot(np.cross(a, b), n)), float(np.dot(a, b))))


def frame_flexion(canonical_pts: np.ndarray) -> Dict[str, Dict[str, float]]:
    """Per-finger MCP/PIP/DIP flexion (deg) for one frame of canonical MHR70 points."""
    pts = np.asarray(canonical_pts, dtype=np.float64)
    if pts.ndim != 2 or pts.shape[0] < 42 or pts.shape[1] != 3 or not np.all(np.isfinite(pts[21:42])):
        raise ValueError("invalid keypoints")
    _, _, z = palm_frame(pts)
    w = pts[MHR70_RIGHT_WRIST]
    out: Dict[str, Dict[str, float]] = {}
    for f in FINGERS:
        i_mcp, i_pip, i_dip, i_tip = MHR70_RIGHT_FINGERS[f]
        mcp, pip, dip, tip = pts[i_mcp], pts[i_pip], pts[i_dip], pts[i_tip]
        meta = mcp - w
        d0 = _unit(meta - np.dot(meta, z) * z)  # straight direction in the palm plane
        n = np.cross(d0, z)  # §8.2 rotation axis a (a × d0 = +z)
        s0, s1, s2, s3 = meta, pip - mcp, dip - pip, tip - dip
        out[f] = {
            "mcp": signed_angle_deg(s0, s1, n),
            "pip": signed_angle_deg(s1, s2, n),
            "dip": signed_angle_deg(s2, s3, n),
        }
    return out


def _iqr(vals: Sequence[float]) -> float:
    q75, q25 = np.percentile(np.asarray(vals, dtype=np.float64), [75, 25])
    return float(q75 - q25)


# ---------------------------------------------------------------------------
# Synthetic hand (forward kinematics of §8.2). Used by the mock backend and tests.
# ---------------------------------------------------------------------------

_SYN_MCP = {  # canonical left-hand frame, mm: x toward pinky, y toward fingers
    "index": (-24.0, 92.0, 0.0),
    "middle": (-4.0, 95.0, 0.0),
    "ring": (14.0, 90.0, 0.0),
    "pinky": (30.0, 82.0, 0.0),
}
_SYN_LEN = {
    "index": (40.0, 24.0, 18.0),
    "middle": (44.0, 28.0, 19.0),
    "ring": (41.0, 27.0, 19.0),
    "pinky": (33.0, 19.0, 17.0),
}


_SYN_THUMB = (  # 付け根・MCP・IP・指先（正準形の左手、mm）
    (-26.0, 30.0, 8.0),
    (-42.0, 50.0, 16.0),
    (-50.0, 68.0, 24.0),
    (-54.0, 84.0, 30.0),
)


def _rot(axis: np.ndarray, deg: float) -> np.ndarray:
    a = _unit(axis)
    t = math.radians(deg)
    k = np.array([[0, -a[2], a[1]], [a[2], 0, -a[0]], [-a[1], a[0], 0]])
    return np.eye(3) + math.sin(t) * k + (1 - math.cos(t)) * (k @ k)


def synthetic_right_keypoints(angles: Dict[str, Dict[str, float]], rigid: Optional[np.ndarray] = None) -> np.ndarray:
    """Build MHR70-shaped (70, 3) right-hand keypoints with the given flexion angles.

    MCP flexion is measured from wrist→MCP, so the straight finger direction d0 is
    taken along wrist→MCP (in the palm plane) to make the round-trip exact.
    `rigid` optionally applies a 3x3 rotation (camera pose) to all points.
    """
    pts = np.zeros((70, 3))
    z = np.array([0.0, 0.0, 1.0])
    pts[MHR70_RIGHT_WRIST] = 0.0
    for f in FINGERS:
        m = np.array(_SYN_MCP[f])
        d0 = _unit(m)
        a = np.cross(d0, z)
        th = angles[f]
        l1, l2, l3 = _SYN_LEN[f]
        j2 = m + l1 * (_rot(a, th["mcp"]) @ d0)
        j3 = j2 + l2 * (_rot(a, th["mcp"] + th["pip"]) @ d0)
        j4 = j3 + l3 * (_rot(a, th["mcp"] + th["pip"] + th["dip"]) @ d0)
        i_mcp, i_pip, i_dip, i_tip = MHR70_RIGHT_FINGERS[f]
        pts[i_mcp], pts[i_pip], pts[i_dip], pts[i_tip] = m, j2, j3, j4
    # 親指（角度には使わない。モックの手のメッシュと関節の表示のため）
    for i, p in zip(MHR70_RIGHT_FINGERS["thumb"], _SYN_THUMB):
        pts[i] = p
    pts = to_canonical_left(pts)  # canonical left -> real right hand
    if rigid is not None:
        pts = pts @ np.asarray(rigid).T
    return pts / 1000.0  # metres, like MHR
