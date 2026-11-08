"""C字クリップの固定STLのライブラリ（ADR-0012 の補足、2026-11-08）。

クリップは毎回 OpenSCAD で描かず、**先に作っておいたSTL**から選んで持ってくる。
形は道具の太さ（4.0〜16.0mm を 0.25mm 刻み）と角度（0／20／40度）だけで決まり、
壁の厚さ・開きの幅・輪の高さ・内側の溝は catalog.json の既定値で固定する（AI は変えない）。

- 置き場所：`scad/library/c_clip/`（コンテナのビルドで作る。git には入れない）。環境変数 `CLIP_LIBRARY_DIR` で変えられる
- ファイル：`<variant>.print.stl`（刷る向き、print 品質）、`<variant>.rail.stl`（レールの座標に組んだ形、preview 品質）、`index.json`
- 使い方：`lookup(clip_params)` が合うものを返す。なければ None（従来どおり OpenSCAD で描く）
- 作り方：`python -m app.geometry.cliplib --out scad/library/c_clip`（OpenSCAD が要る。並行4）
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

from .consts import SCAD_DIR, catalog

D_MIN, D_MAX, D_STEP = 4.0, 16.0, 0.25
ANGLES = (60, 70, 80)   # 道具の立て具合（机に対する傾き。ADR-0013、2026-11-08）
FIXED_NAMES = ("wall_mm", "opening_ratio", "height_mm", "grip_ribs", "tpu_sleeve")


def lib_dir() -> Path:
    env = os.environ.get("CLIP_LIBRARY_DIR")
    return Path(env) if env else SCAD_DIR / "library" / "c_clip"


def fixed_params() -> dict:
    """ライブラリのクリップで固定している引数（catalog.json の既定値）"""
    for p in catalog()["parts"]:
        if p["id"] == "c_clip":
            return {q["name"]: q["default"] for q in p["params"] if q["name"] in FIXED_NAMES}
    raise KeyError("c_clip がカタログにありません")


def snap_d(tool_d: float) -> float | None:
    """道具の太さを刻みに合わせる（範囲の外なら None）。しめしろの誤差は ±0.125mm まで"""
    d = round(round(float(tool_d) / D_STEP) * D_STEP, 2)
    if d < D_MIN - 1e-9 or d > D_MAX + 1e-9:
        return None
    return d


def variant(d: float, angle: int) -> str:
    return f"c_clip_d{int(round(d * 100)):04d}_a{int(angle):02d}"


def grid() -> list[float]:
    n = int(round((D_MAX - D_MIN) / D_STEP)) + 1
    return [round(D_MIN + i * D_STEP, 2) for i in range(n)]


def matches_fixed(clip: dict) -> bool:
    fx = fixed_params()
    for k, v in fx.items():
        got = clip.get(k, v)
        if isinstance(v, bool):
            if bool(got) != v:
                return False
        elif abs(float(got) - float(v)) > 1e-6:
            return False
    return True


def lookup(clip: dict, base: Path | None = None) -> dict | None:
    """引数に合うライブラリのクリップ。{"variant", "print", "rail", "tool_d_snapped"}。なければ None"""
    base = base or lib_dir()
    if not matches_fixed(clip):
        return None
    d = snap_d(clip["tool_d_mm"])
    angle = int(clip.get("angle_deg", 20))
    if d is None or angle not in ANGLES:
        return None
    name = variant(d, angle)
    p, r = base / f"{name}.print.stl", base / f"{name}.rail.stl"
    if not (p.exists() and r.exists()):
        return None
    return {"variant": name, "print": str(p), "rail": str(r), "tool_d_snapped": d}


MIRROR_X = np.diag([-1.0, 1.0, 1.0, 1.0])   # 左手用：レールの座標で X の符号を変える（鏡像。trimesh が面の向きも直す）


def place_in_rail(rail_stl: str | Path, rail_origin, rail_frame, out_path: str | Path, mirror: bool = False) -> str:
    """レールの座標で作ったクリップを、実際の手の座標（rail_origin・rail_frame：行が X・Y・Z の向き）へ置いて書く。
    ライブラリは右手の形なので、左手なら mirror=True で X を反転してから置く"""
    import trimesh
    m = trimesh.load(str(rail_stl), force="mesh")
    if mirror:
        m.apply_transform(MIRROR_X)
    M = np.eye(4)
    M[:3, :3] = np.asarray(rail_frame, dtype=float).T
    M[:3, 3] = np.asarray(rail_origin, dtype=float)
    m.apply_transform(M)
    m.export(str(out_path))
    return str(out_path)


def copy_print(print_stl: str | Path, out_path: str | Path, mirror: bool = False) -> str:
    """印刷用STLを持ってくる。左手なら X を反転して書く（刷る向きの座標も X＝レールの横なので、そのまま反転できる）"""
    if not mirror:
        Path(out_path).write_bytes(Path(print_stl).read_bytes())
        return str(out_path)
    import trimesh
    m = trimesh.load(str(print_stl), force="mesh")
    m.apply_transform(MIRROR_X)
    m.export(str(out_path))
    return str(out_path)


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _repair_if_open(path: Path) -> bool:
    """OpenSCAD（Manifold）の出力が閉じていなければ、小さな穴を埋めて書き直す。直したら True"""
    import trimesh
    m = trimesh.load(str(path), force="mesh")
    if m.is_watertight:
        return False
    trimesh.repair.fill_holes(m)
    if not m.is_watertight:
        m.merge_vertices(digits_vertex=3)
        trimesh.repair.fill_holes(m)
    if m.is_watertight:
        m.export(str(path))
        return True
    return False


def build(out_dir: Path, ds: list[float] | None = None, angles=ANGLES, workers: int = 4, force: bool = False) -> dict:
    """ライブラリを作る（あるものは飛ばす）。index.json に引数・sha256・検査（R6f）を書く"""
    from . import checks as CK
    from .scad import run
    import trimesh
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    fx = fixed_params()
    ds = ds or grid()
    index_path = out_dir / "index.json"
    index = json.loads(index_path.read_text(encoding="utf-8")) if index_path.exists() else {"variants": {}}

    def one(item):
        d, angle = item
        name = variant(d, angle)
        p, r = out_dir / f"{name}.print.stl", out_dir / f"{name}.rail.stl"
        if not force and p.exists() and r.exists() and name in index["variants"]:
            return name, None
        defs = {"hand": "right", "c_clip_tool_d_mm": d, "c_clip_angle_deg": int(angle),
                "c_clip_wall_mm": float(fx["wall_mm"]), "c_clip_opening_ratio": float(fx["opening_ratio"]),
                "c_clip_height_mm": float(fx["height_mm"]), "c_clip_grip_ribs": bool(fx["grip_ribs"]),
                "c_clip_tpu_sleeve": bool(fx["tpu_sleeve"])}
        t0 = time.time()
        run({**defs, "mode": "clip", "quality": "print"}, p)
        run({**defs, "mode": "assembled", "part": "c_clip", "quality": "preview"}, r)
        repaired = [x for x in (p, r) if _repair_if_open(x)]
        clip = {"tool_d_mm": d, "angle_deg": int(angle), **fx}
        res = CK.check_clip(trimesh.load(str(p), force="mesh"), clip)
        return name, {"tool_d_mm": d, "angle_deg": int(angle), **fx, "print_sha256": _sha(p), "rail_sha256": _sha(r),
                      "checks": [{k: v for k, v in c.items() if k in ("rule", "ok", "value")} for c in res],
                      "repaired": [x.name for x in repaired], "ms": int((time.time() - t0) * 1000)}

    items = [(d, a) for d in ds for a in angles]
    made = 0
    with ThreadPoolExecutor(max_workers=workers) as ex:
        for name, info in ex.map(one, items):
            if info is not None:
                index["variants"][name] = info
                made += 1
    index["fixed"] = fx
    index["grid"] = {"d_min": D_MIN, "d_max": D_MAX, "d_step": D_STEP, "angles": list(angles)}
    index["catalog_version"] = catalog().get("version")
    index_path.write_text(json.dumps(index, ensure_ascii=False, indent=1), encoding="utf-8")
    return {"made": made, "total": len(items), "dir": str(out_dir)}


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description="C字クリップの固定STLのライブラリを作る")
    ap.add_argument("--out", default=str(lib_dir()))
    ap.add_argument("--d", type=float, nargs="*", help="作る太さ（省略すると全部）")
    ap.add_argument("--angles", type=int, nargs="*", default=list(ANGLES))
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args(argv)
    t0 = time.time()
    r = build(Path(a.out), ds=a.d, angles=tuple(a.angles), workers=a.workers, force=a.force)
    print(f"{r['made']}/{r['total']} variants made in {time.time() - t0:.0f}s -> {r['dir']}")


if __name__ == "__main__":
    main()
