"""実寸にした手の3Dメッシュの表面の寸法を、定規の値と比べて、長さの補正係数（measurement.md §10.3）の案を出す。

測るもの（どれも手の甲を上にして机に置いた姿勢）：
- こぶしの高さ：クリップが付く所（人差し指の付け根の少し手首寄りの、親指側の手の甲）の、机からの高さ
- 手首→中指の付け根：手の甲の側の、手首の上の皮膚から、中指の付け根の出っ張りのてっぺんまで（まっすぐ）
- 付け根の幅：人差し指の付け根の出っ張りから、小指の付け根の出っ張りまで

使い方（リポジトリの直下から。api/.venv を使う）：
  本番の直近のケース（読むだけ。gcloud auth application-default login が要る）
    api/.venv/bin/python scripts/check_hand_size.py --height 65 --dorsal 90 --width 70
  ケースを指定する      … --case c_xxxxxxxx
  手元のメッシュで試す  … --glb path/to/scaled.glb
"""
from __future__ import annotations

import argparse
import statistics
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "api"))

from app.geometry.glb import read_glb  # noqa: E402
from app.geometry.handframe import parse_joints, rail_direction, to_canonical_joints, to_canonical_mesh  # noqa: E402

PROJECT = "jijogu-hackathon-2026"
BUCKET = "jijogu-hackathon-2026-data"


def surface_metrics(glb: bytes, hand_side: str | None = None) -> dict:
    """正準形（手のひら側が +z、手の甲側が −z）で、手の甲の表面の寸法を測る"""
    V, F, ex = read_glb(glb)
    side = hand_side or ex.get("hand_side") or "right"
    Jc = to_canonical_joints(parse_joints(ex["joints_mm"]), side)
    Vc, _ = to_canonical_mesh(V, F, side)
    z_table = float(Vc[:, 2].max())   # 手のひら側のいちばん低い点＝机

    # クリップが付く所：レールと同じ（人差し指の中手骨の72%の点から、親指側と手の甲側の間の45度へ）
    mid, _, d = rail_direction(Jc)
    rel = Vc - mid
    s = rel @ d
    perp = np.linalg.norm(rel - s[:, None] * d, axis=1)
    skin = Vc[np.argmax(np.where((s > 0) & (perp < 3.0), s, -np.inf))]
    def knuckle_peak(p, r=18.0):
        """付け根の出っ張りのてっぺん：関節のまわりで、指先側（+y）と手の甲側（−z）の間の45度にいちばん出ている点"""
        near = Vc[np.linalg.norm(Vc - np.asarray(p), axis=1) < r]
        return near[np.argmax(near @ np.array([0.0, 1.0, -1.0]) / np.sqrt(2.0))]

    # 手首側：メッシュは手首の5mm先で切ってあるので、切り口のふちの手の甲側の点に、切った分（5mm）を足す
    y0 = float(Vc[:, 1].min())
    edge = Vc[Vc[:, 1] < y0 + 4.0]
    wrist_edge = edge[np.argmin(edge[:, 2])]
    mcp9_top = knuckle_peak(Jc["middle"][0])
    mcp5_top, mcp17_top = knuckle_peak(Jc["index"][0]), knuckle_peak(Jc["pinky"][0])
    return {
        "height_mm": round(z_table - float(skin[2]), 1),
        "dorsal_mm": round(float(np.linalg.norm(wrist_edge - mcp9_top)) + max(0.0, y0 - float(Jc["wrist"][1])), 1),
        "width_mm": round(float(np.linalg.norm(mcp5_top - mcp17_top)), 1),
        "joint_wrist_to_middle_mcp_mm": round(float(np.linalg.norm(Jc["wrist"] - Jc["middle"][0])), 1),
        "scale_factor": ex.get("scale_factor"),
    }


def load_from_production(case_id: str | None) -> tuple[bytes, dict, str]:
    from google.cloud import firestore, storage
    db = firestore.Client(project=PROJECT)
    if case_id:
        snap = db.collection("cases").document(case_id).get()
    else:
        snap = next(iter(db.collection("cases").order_by("measured_at", direction=firestore.Query.DESCENDING).limit(1).stream()))
    case = snap.to_dict() or {}
    hm = case.get("hand_model") or {}
    if not hm.get("mesh_path"):
        raise SystemExit(f"ケース {snap.id} には実寸の手のメッシュがありません（採寸を保存してから実行してください）")
    glb = storage.Client(project=PROJECT).bucket(BUCKET).blob(hm["mesh_path"]).download_as_bytes()
    return glb, case, snap.id


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--case")
    ap.add_argument("--glb", type=Path)
    ap.add_argument("--height", type=float, help="定規：こぶしの高さ（mm）")
    ap.add_argument("--dorsal", type=float, help="定規：手首→中指の付け根（mm）")
    ap.add_argument("--width", type=float, help="定規：付け根の幅（mm）。測り方がぶれやすいので、係数の案には使わない")
    a = ap.parse_args()

    if a.glb:
        glb, case, cid = a.glb.read_bytes(), {}, a.glb.name
    else:
        glb, case, cid = load_from_production(a.case)
    m = case.get("measurement") or {}
    lf_now = float((m.get("calibration") or {}).get("length_factor") or 1.0)
    side = m.get("hand_side")
    mt = surface_metrics(glb, side)
    palm = m.get("palm") or {}
    print(f"== {cid}  手 {side or '?'}  倍率 {mt['scale_factor']}  いまの補正係数 {lf_now}  "
          f"警告 {(m.get('quality') or {}).get('warnings')}")
    if palm:
        print(f"   採寸（関節の中心どうし）：手首→人差し指 {palm.get('wrist_to_index_mcp_mm')}・中指 {palm.get('wrist_to_middle_mcp_mm')}・"
              f"小指 {palm.get('wrist_to_pinky_mcp_mm')}・付け根の幅 {palm.get('hand_width_mcp_mm')} mm")
    print(f"   3Dの手（表面）：こぶしの高さ {mt['height_mm']}・手首→中指の付け根 {mt['dorsal_mm']}・付け根の幅 {mt['width_mm']} mm"
          f"（関節の中心どうしの 手首→中指 {mt['joint_wrist_to_middle_mcp_mm']} mm）")
    ratios = []
    for name, ruler, key in (("こぶしの高さ", a.height, "height_mm"), ("手首→中指の付け根", a.dorsal, "dorsal_mm"),
                             ("付け根の幅", a.width, "width_mm")):
        if ruler:
            r = ruler / mt[key]
            print(f"   {name}：定規 {ruler} ÷ 3D {mt[key]} = {r:.3f}")
            if key != "width_mm":
                ratios.append(r)
    if ratios:
        lf = lf_now * statistics.median(ratios)
        print(f"   → 補正係数の案：{lf:.3f}（いまの {lf_now} × 比の中央値 {statistics.median(ratios):.3f}）")


if __name__ == "__main__":
    main()
