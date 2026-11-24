"""画面だけで試すモード（--dart-define=MOCK_API=true）の3Dの見本を、今の形の計算で作り直す。

作るもの（app/web/demo/）：
- hand.glb                 実寸の手のメッシュ（試験用の握った手 api/tests/fixtures/hand_raw_fist.glb を実寸にしたもの）
- cover.stl                カバー（手の座標。プレビュー用）
- c_clip_{60,70,80}.stl    角度ごとの留め具（万力式。手の座標。レールに差した位置に、受け具とねじ）
- cover.print.stl          カバー（刷る向き）
- c_clip_{60,70,80}.print.stl  留め具（刷る並び。受け具とねじ）
- iso.png                  確認用画像（70度）

使い方（リポジトリの直下から。api/requirements.txt の依存と、OpenSCAD の開発版が要る）：
  OPENSCAD_BIN=/Applications/OpenSCAD.app/Contents/MacOS/OpenSCAD python scripts/make_demo_assets.py
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "api"))

import numpy as np  # noqa: E402

from app.geometry import DirCache, make_design, prepare_measurement  # noqa: E402
from app.geometry.glb import read_glb  # noqa: E402
from app.geometry.handframe import parse_joints  # noqa: E402

FINGERS = ("index", "middle", "ring", "pinky")
ANGLES = (60, 70, 80)   # 道具の立て具合（catalog.json の c_clip.angle_deg の choices）


def measurement_from_joints(J: dict, k: float) -> dict:
    """生メッシュの関節を k 倍した長さを「測った値」にする（tests/test_geometry.py の make_measurement と同じ）"""
    L = lambda a, b: float(np.linalg.norm(a - b)) * k  # noqa: E731
    return {
        "schema_version": "2.2", "hand_side": "right",
        "palm": {"wrist_to_index_mcp_mm": L(J["wrist"], J["index"][0]),
                 "wrist_to_middle_mcp_mm": L(J["wrist"], J["middle"][0]),
                 "wrist_to_pinky_mcp_mm": L(J["wrist"], J["pinky"][0]),
                 "hand_width_mcp_mm": L(J["index"][0], J["pinky"][0]), "mcp_positions_mm": {}},
        "fingers": {f: {"lengths_mm": [L(J[f][s], J[f][s + 1]) for s in range(3)]} for f in FINGERS},
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=REPO / "app" / "web" / "demo")
    ap.add_argument("--raw", type=Path, default=REPO / "api" / "tests" / "fixtures" / "hand_raw_fist.glb")
    ap.add_argument("--scale", type=float, default=1.15, help="生メッシュに掛ける倍率（測った長さ ÷ メッシュの長さ）")
    ap.add_argument("--tool-d", type=float, default=8.5, help="道具の太さ（mm）")
    a = ap.parse_args()

    raw = a.raw.read_bytes()
    J = parse_joints(read_glb(raw)[2]["joints_mm"])
    pm = prepare_measurement(raw, measurement_from_joints(J, a.scale), "right",
                             {"tool_d_mm": a.tool_d, "tool_type": "brush"})
    params: dict = {}
    for b in pm["baseline"]:
        params.setdefault(b["part_id"], {})[b["name"]] = b["value"]

    a.out.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="hsf_demo_"))
    cache = DirCache(work / "cache")   # 距離場と殻は角度が変わっても同じなので使い回す
    try:
        (a.out / "hand.glb").write_bytes(pm["scaled_glb"])
        # カバーの見本は1つ（70度）なので、60度・80度の留め具は、70度のカバーのレールに付けた「ほかの留め具」として描く
        # （角度ごとに描くと、万力式は角度でレールの台の位置が変わり、70度のカバーから浮いて見えた。2026-11-24）
        base = {**params, "c_clip": {**params.get("c_clip", {}), "angle_deg": 70}}
        others = {f"a{ang}": {"tool_d_mm": a.tool_d, "angle_deg": ang} for ang in ANGLES if ang != 70}
        tools = {}
        for quality in ("preview", "print"):
            r = make_design(pm["scaled_glb"], pm["joints_mm"], "right", base, str(work / quality), cache,
                            quality=quality, extra_clips=others)
            bad = [v["rule"] for v in r["violations"]]
            bad += [v["rule"] for x in r["extra_clips"].values() for v in x["violations"]]
            if bad:
                print(f"  警告：{quality} の検査に通らない所があります {bad}")
            suffix = "" if quality == "preview" else ".print"
            shutil.copy(r["files"]["c_clip"], a.out / f"c_clip_70{suffix}.stl")
            shutil.copy(r["files"]["cover"], a.out / f"cover{suffix}.stl")
            tools[70] = r["tool"]
            for aid, x in r["extra_clips"].items():
                shutil.copy(x["file"], a.out / f"c_clip_{aid[1:]}{suffix}.stl")
                tools[int(aid[1:])] = x["tool"]
            if quality == "preview":
                iso = next(v for v in r["views"] if Path(v).stem == "iso")
                shutil.copy(iso, a.out / "iso.png")
        # 画面だけで試すモード（mock_backend.dart の _demoTool）に写す、道具の軸（実際の手の座標）
        print("道具の軸：", json.dumps({k: tools[k] for k in sorted(tools)}))
        for old in ("c_clip_0.stl", "c_clip_20.stl", "c_clip_40.stl"):   # 前の角度（0／20／40）の見本
            (a.out / old).unlink(missing_ok=True)
        print(f"書き出し先：{a.out}")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
