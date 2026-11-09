"""OpenSCAD の実行（generation-pipeline.md §6.3・§6.4）。

- -D の値は型付きの値だけから作る（数値は小数第3位まで、文字列は英数字と決まった記号だけ）
- ファイルのパスは作業フォルダの絶対パス（区切りは /）
- 1回60秒で打ち切る（RENDER_TIMEOUT）
"""
from __future__ import annotations

import re
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

from .consts import SCAD_DIR, openscad_bin
from .errors import GeometryError

TIMEOUT_S = 60
_SAFE_STR = re.compile(r"^[A-Za-z0-9_./:\-# ]*$")


def fmt(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, np.integer)):
        return str(int(v))
    if isinstance(v, (float, np.floating)):
        if not np.isfinite(v):
            raise GeometryError("RENDER_FAILED", "数値が有限ではありません")
        return f"{float(v):.3f}".rstrip("0").rstrip(".") if abs(v) >= 1e-9 else "0"
    if isinstance(v, str):
        if not _SAFE_STR.match(v):
            raise GeometryError("RENDER_FAILED", f"使えない文字を含む値です: {v!r}")
        return '"' + v + '"'
    if isinstance(v, np.ndarray):
        return fmt(v.tolist())
    if isinstance(v, (list, tuple)):
        return "[" + ",".join(fmt(x) for x in v) + "]"
    raise GeometryError("RENDER_FAILED", f"-D に渡せない型です: {type(v).__name__}")


def posix(p) -> str:
    return str(Path(p).resolve()).replace("\\", "/")


def run(defs: dict, out_path: str | Path, entry: str = "main.scad", extra: list | None = None) -> str:
    out = posix(out_path)
    cmd = [openscad_bin(), "--backend=Manifold", "-o", out]
    if out.endswith(".stl"):
        cmd += ["--export-format", "binstl"]
    for k, v in defs.items():
        cmd += ["-D", f"{k}={fmt(v)}"]
    cmd += list(extra or [])
    cmd.append(posix(SCAD_DIR / entry))
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT_S)
    except subprocess.TimeoutExpired:
        raise GeometryError("RENDER_TIMEOUT", "OpenSCAD が60秒で終わりませんでした")
    if r.returncode != 0 or not Path(out).exists() or Path(out).stat().st_size == 0:
        tail = (r.stderr or "").strip().splitlines()[-6:]
        raise GeometryError("RENDER_FAILED", "OpenSCAD で形を描けませんでした", [{"stderr": tail}])
    if out.endswith(".stl"):
        drop_slivers(out)
    return out


def drop_slivers(path: str) -> int:
    """OpenSCAD（Manifold）が残す、面積も体積もない小さな切れ端（三角形2枚など）を取り除く。取り除いた数を返す。"""
    import trimesh
    m = trimesh.load(path, force="mesh")
    parts = m.split(only_watertight=False)
    if len(parts) <= 1:
        return 0
    keep = [p for p in parts if p.area >= 1.0 or abs(p.volume) >= 1.0]
    if not keep or len(keep) == len(parts):
        return 0
    (trimesh.util.concatenate(keep) if len(keep) > 1 else keep[0]).export(path)
    return len(parts) - len(keep)


def render_views(files: dict, hand_file: str, rod: tuple, rod_d: float, color: str,
                 cams: dict, outdir: Path, size: int = 768) -> list[str]:
    """確認用画像（view.scad）。cams は {名前: (eye[3], center[3])}。並行して描く。"""
    base = {"hand_file": posix(hand_file), "cover_color": color, "rod_d": rod_d,
            "rod_a": [round(float(x), 2) for x in rod[0]], "rod_b": [round(float(x), 2) for x in rod[1]]}
    if files.get("cover"):
        base["cover_file"] = posix(files["cover"])
    if files.get("c_clip"):
        base["clip_file"] = posix(files["c_clip"])
    if files.get("tpu_sleeve"):
        base["sleeve_file"] = posix(files["tpu_sleeve"])

    def one(item):
        name, (eye, center) = item
        cam = ",".join(f"{float(x):.2f}" for x in list(eye) + list(center))
        out = outdir / f"{name}.png"
        run(base, out, entry="view.scad",
            extra=[f"--camera={cam}", "--viewall", "--autocenter", f"--imgsize={size},{size}",
                   "--projection=p", "--colorscheme=Tomorrow"])
        return str(out)

    with ThreadPoolExecutor(max_workers=4) as ex:
        return list(ex.map(one, cams.items()))
