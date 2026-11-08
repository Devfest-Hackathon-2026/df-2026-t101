"""形の入口の中身：prepare_measurement（採寸の保存）と make_design（形を作る）。"""
from __future__ import annotations

import hashlib

SHELL_RULES_VERSION = "2026-11-07b"  # 指を覆わない（基節から先を捨てる）、手のひら側の平面を付け根＋8mmまで
import json
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
import trimesh

from . import checks as CK
from .baseline import make_baseline
from .consts import FIELD_VERSION, LONG_FINGERS, catalog, fixed
from .errors import GeometryError
from .field import Field, compute_field
from .glb import read_glb, write_glb
from .handframe import (capsules, curl_sign, finger_radii, joints_to_json, mirror_z, palm_length, parse_joints,
                        rail_direction, to_actual_joints, to_canonical_joints, to_canonical_mesh, wrist_cut_default, z_pip, palm_cut_base)
from .placement import outer_surface, place_holes, place_rail, place_slits, tool_rod
from .scad import posix, render_views, run
from .scale import check_mcp_order, compute_scale
from .shell import build_keepout, build_shell, shell_cut_values


def _sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def _palm_normal_actual(hand_side: str) -> np.ndarray:
    return np.array([0.0, 0.0, 1.0]) if hand_side == "left" else np.array([0.0, 0.0, -1.0])


def _to_actual_point(p, hand_side):
    p = np.asarray(p, dtype=float)
    return p if hand_side == "left" else mirror_z(p)


# ---------------------------------------------------------------------------
# 採寸の保存
# ---------------------------------------------------------------------------

def prepare_measurement(raw_glb: bytes, measurement: dict, hand_side: str, requirements: dict | None = None) -> dict:
    """生メッシュ（未補正、実際の手の座標）＋採寸JSON(2.2) → 実寸の手のメッシュと目印と基準値。
    requirements（聞き取り）を渡すと、c_clip の基準値（道具の太さ・角度）も入る。"""
    try:
        V, F, extras = read_glb(raw_glb)
    except Exception as e:  # noqa: BLE001
        raise GeometryError("MEASUREMENT_INVALID", "手のメッシュを読めませんでした", [{"error": str(e)}])
    if "joints_mm" not in extras:
        raise GeometryError("MEASUREMENT_INVALID", "手のメッシュに関節（extras.joints_mm）がありません")
    J = parse_joints(extras["joints_mm"])
    sc = compute_scale(measurement, J)
    k = sc["k"]
    Vs = V * k
    Js = {kk: v * k for kk, v in J.items()}
    check_mcp_order(Js)
    Jc = to_canonical_joints(Js, hand_side)
    Vc, Fc = to_canonical_mesh(Vs, F, hand_side)
    radii = finger_radii(Vc, Jc)
    warnings = list(sc["warnings"])
    if curl_sign(Jc) < -10.0:
        warnings.append("HAND_FRAME_SUSPECT")   # 正準形で指が手の甲側に曲がっている（座標の向きの誤りのおそれ）
    c = float(fixed("HAND_CLEARANCE_MM"))
    t_def = 2.5
    mid, u, d = rail_direction(Jc)
    rail_pt = mid + d * (radii["index"][0] + c + t_def)
    L = palm_length(Jc)
    y_s = 0.55 * L
    band = np.abs(Vc[:, 1] - y_s) < 3.0
    xs = Vc[band, 0] if band.any() else Vc[:, 0]
    landmarks = {
        "frame": "hand_actual",
        "palm_normal": _palm_normal_actual(hand_side).tolist(),
        "palm_cut_base_mm": round(palm_cut_base(Jc), 2),
        "wrist_to_middle_mcp_mm": round(L, 2),
        "x_index_mcp_mm": round(float(Jc["index"][0][0]), 2),
        "rail_anchor": {"point_mm": [round(float(v), 2) for v in _to_actual_point(rail_pt, hand_side)],
                        "direction": [round(float(v), 4) for v in _to_actual_point(u, hand_side)],
                        "outward": [round(float(v), 4) for v in _to_actual_point(d, hand_side)]},
        "slit_zones": {"thumb_side": [round(float(xs.min() - c), 1), round(y_s, 1)],
                       "pinky_side": [round(float(xs.max() + c), 1), round(y_s, 1)]},
        "finger_radii_mm": radii,
    }
    extras_out = dict(extras)
    extras_out.update({"joints_mm": joints_to_json(Js), "scale_factor": round(k, 5), "hand_side": hand_side})
    scaled = write_glb(Vs, F, extras_out)
    wc = wrist_cut_default(Jc, float(fixed("WRIST_FREE_MM")))
    return {
        "scaled_glb": scaled,
        "scale_factor": round(k, 5),
        "scale_source": sc["scale_source"],
        "scale_spread_ratio": sc["scale_spread_ratio"],
        "joints_mm": joints_to_json(Js),
        "cover_landmarks": landmarks,
        "capsules": capsules(Jc, radii),          # 正準形（Gemini への要約・目安）
        "baseline": make_baseline(wc, requirements),
        "warnings": warnings,
    }


# ---------------------------------------------------------------------------
# 形を作る
# ---------------------------------------------------------------------------

class DictCache:
    """テストと開発用の窓口（メモリ）。C は Storage に読み書きする同じ形の窓口を渡す。"""

    def __init__(self):
        self.data = {}

    def get(self, key):
        return self.data.get(key)

    def put(self, key, value: bytes):
        self.data[key] = value


class DirCache:
    """フォルダに置く窓口（開発用）。キーをそのままパスにする。"""

    def __init__(self, root):
        self.root = Path(root)

    def get(self, key):
        p = self.root / key
        return p.read_bytes() if p.exists() else None

    def put(self, key, value: bytes):
        p = self.root / key
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(value)


def _defaults(part_id: str) -> dict:
    for p in catalog()["parts"]:
        if p["id"] == part_id:
            return {q["name"]: q["default"] for q in p["params"] if q["default"] is not None}
    return {}


def _merged(params: dict, part_id: str) -> dict:
    d = _defaults(part_id)
    d.update(params.get(part_id) or {})
    return d


def _stl_bytes(m: trimesh.Trimesh) -> bytes:
    return m.export(file_type="stl")


def _load_stl(b: bytes) -> trimesh.Trimesh:
    import io
    return trimesh.load(io.BytesIO(b), file_type="stl", force="mesh")


def _mesh_to_actual(m: trimesh.Trimesh, hand_side: str) -> trimesh.Trimesh:
    if hand_side == "left":
        return m.copy()
    v, f = to_canonical_mesh(np.asarray(m.vertices), np.asarray(m.faces), hand_side)
    return trimesh.Trimesh(v, f, process=False)


_mesh_to_canonical = _mesh_to_actual


def _print_matrix(bounds_actual: np.ndarray, hand_side: str) -> np.ndarray:
    """カバーを刷る向き：手のひらの法線を −Z（手のひら側の切り口が下）にし、底を z=0、中心を原点の上に。"""
    R = np.diag([1.0, -1.0, -1.0]) if hand_side == "left" else np.eye(3)
    corners = np.array(np.meshgrid(*[[bounds_actual[0][i], bounds_actual[1][i]] for i in range(3)])).T.reshape(-1, 3)
    rc = corners @ R.T
    lo, hi = rc.min(0), rc.max(0)
    t = np.array([-(lo[0] + hi[0]) / 2, -(lo[1] + hi[1]) / 2, -lo[2] + 0.0])
    M = np.eye(4)
    M[:3, :3] = R
    M[:3, 3] = t
    return M


def make_design(scaled_glb: bytes, joints_mm: dict, hand_side: str, params: dict, workdir: str, cache,
                quality: str = "preview", parts: tuple = ("cover", "c_clip"), color: str = "#2A9D8F") -> dict:
    t0 = time.time()
    timings = {}
    wd = Path(workdir)
    wd.mkdir(parents=True, exist_ok=True)
    V, F, extras = read_glb(scaled_glb)
    J = parse_joints(joints_mm)
    Jc = to_canonical_joints(J, hand_side)
    Vc, Fc = to_canonical_mesh(V, F, hand_side)
    hand_c = trimesh.Trimesh(Vc, Fc, process=False)
    if hand_c.volume < 0:
        hand_c.invert()
    radii = finger_radii(Vc, Jc)
    mesh_sha = _sha(scaled_glb)
    fver = f"{FIELD_VERSION}:{mesh_sha[:16]}"

    cover_p = _merged(params, "cover")
    holes_p = _merged(params, "air_holes")
    slits_p = _merged(params, "strap_slits")
    clip_p = _merged(params, "c_clip")
    want_sleeve = bool(clip_p.get("tpu_sleeve")) or "tpu_sleeve" in parts
    c = float(fixed("HAND_CLEARANCE_MM"))
    cover_p.setdefault("wrist_cut_mm", wrist_cut_default(Jc, float(fixed("WRIST_FREE_MM"))))
    cover_p["clearance_mm"] = c

    # 距離場（採寸の版ごとに1回）
    field = None
    raw = cache.get("sdf")
    if raw:
        try:
            field = Field.from_bytes(raw)
            if field.version != fver:
                field = None
        except Exception:  # noqa: BLE001
            field = None
    if field is None:
        ts = time.time()
        field = compute_field(Vc, Fc, Jc, radii)
        field.version = fver
        cache.put("sdf", field.to_bytes())
        timings["field_ms"] = int((time.time() - ts) * 1000)

    # 殻（殻の引数が同じなら使い回す）
    # "r" は切り方の決まりの版。決まりを変えたら上げる（前の決まりの殻を使い回さないため）
    key_src = json.dumps({"r": SHELL_RULES_VERSION, "f": fver, "c": c, "t": cover_p["cover_thickness_mm"], "o": cover_p["palm_cut_offset_mm"],
                          "w": round(float(cover_p["wrist_cut_mm"]), 2), "e": cover_p["edge_radius_mm"]}, sort_keys=True)
    shell_key = "shell/" + _sha(key_src.encode())[:24]
    cut = shell_cut_values(cover_p, Jc, radii)
    info = {"removed_fragments_cm3": 0.0}
    sb = cache.get(shell_key)
    if sb:
        shell_a = _load_stl(sb)
        shell_c = _mesh_to_canonical(shell_a, hand_side)
    else:
        ts = time.time()
        shell_c, info = build_shell(field, Jc, radii, cover_p)
        if len(shell_c.faces) == 0:
            raise GeometryError("RENDER_FAILED", "カバーの殻を作れませんでした（手にかかる所がない）")
        shell_a = _mesh_to_actual(shell_c, hand_side)
        sb = _stl_bytes(shell_a)
        cache.put(shell_key, sb)
        timings["shell_ms"] = int((time.time() - ts) * 1000)
    shell_sha = _sha(sb)
    kkey = f"keepout/c{c:.2f}"
    kb = cache.get(kkey)
    if not kb:
        kb = _stl_bytes(_mesh_to_actual(build_keepout(field, c), hand_side))
        cache.put(kkey, kb)
    (wd / "cover_shell.stl").write_bytes(sb)
    (wd / "cover_keepout.stl").write_bytes(kb)
    hand_a = trimesh.Trimesh(V, F, process=False)
    hand_a.export(wd / "hand.stl")

    # 位置（正準形で計算 → 実際の手の座標へ）
    ts = time.time()
    href = CK.HandRef(hand_c)
    t = float(cover_p["cover_thickness_mm"])
    ov, on = outer_surface(shell_c, href.tree, c, t)
    from scipy.spatial import cKDTree
    otree = cKDTree(ov)
    rail = place_rail(Jc, radii, ov, on, c, t)
    sl = place_slits(Jc, ov, on, otree, {**slits_p, "_t": t}, float(cover_p["edge_radius_mm"]))
    avoid = [(rail["anchor"], float(fixed("RAIL_WIDTH_MM")) + 6.0)]
    avoid += [(p, float(sl["width"]) / 2 + 2.0) for p in sl["centers"]]
    ho = place_holes(Jc, ov, on, otree, holes_p, float(cover_p["wrist_cut_mm"]), avoid)
    timings["placement_ms"] = int((time.time() - ts) * 1000)

    def A(p):  # 点・向きを実際の手の座標へ
        return [round(float(x), 3) for x in _to_actual_point(p, hand_side)]

    fr = np.array([_to_actual_point(v, hand_side) for v in rail["frame"]])
    fr[0] = np.cross(fr[1], fr[2])          # 鏡像のあとも右手系に
    defs = {
        "quality": quality, "hand": hand_side,
        "cover_shell_file": posix(wd / "cover_shell.stl"), "cover_keepout_file": posix(wd / "cover_keepout.stl"),
        "cover_cover_thickness_mm": t,
        "air_holes_diameter_mm": float(holes_p["diameter_mm"]),
        "air_holes_centers": [A(p) for p in ho["centers"]], "air_holes_normals": [A(n) for n in ho["normals"]],
        "strap_slits_strap_width_mm": float(sl["width"]), "strap_slits_strap_thickness_mm": float(sl["thickness"]),
        "strap_slits_centers": [A(p) for p in sl["centers"]], "strap_slits_normals": [A(n) for n in sl["normals"]],
        "strap_slits_axes": [A(a) for a in sl["axes"]],
        "cover_palm_plane": [*[float(x) for x in _palm_normal_actual(hand_side)], round(float(cut["palm_plane_z"]) + 0.25, 3)],  # 殻の面に触れて切れ端ができないよう0.25mm先で切る
        "rail_origin": A(rail["origin"]), "rail_frame": [[round(float(x), 5) for x in r] for r in fr],
        "c_clip_tool_d_mm": float(clip_p["tool_d_mm"]), "c_clip_wall_mm": float(clip_p["wall_mm"]),
        "c_clip_opening_ratio": float(clip_p["opening_ratio"]), "c_clip_height_mm": float(clip_p["height_mm"]),
        "c_clip_angle_deg": int(clip_p["angle_deg"]), "c_clip_grip_ribs": bool(clip_p["grip_ribs"]),
        "c_clip_tpu_sleeve": bool(clip_p.get("tpu_sleeve", False)),
    }
    angle = int(clip_p["angle_deg"])
    pm = _print_matrix(shell_a.bounds, hand_side)

    # OpenSCAD（部品ごとに並行して描く）
    jobs = {}
    if quality == "print":
        if "cover" in parts:
            jobs["cover"] = ({**defs, "mode": "cover", "cover_print_matrix": pm.round(5).tolist()}, wd / "print_cover.stl")
        if "c_clip" in parts:
            jobs["c_clip"] = ({**defs, "mode": "clip"}, wd / f"print_clip_{angle}.stl")
        if want_sleeve:
            jobs["tpu_sleeve"] = ({**defs, "mode": "sleeve"}, wd / "print_sleeve.stl")
    else:
        if "cover" in parts:
            jobs["cover"] = ({**defs, "mode": "assembled", "part": "cover"}, wd / "cover_preview.stl")
        if "c_clip" in parts:
            jobs["c_clip"] = ({**defs, "mode": "assembled", "part": "c_clip"}, wd / "clip_preview.stl")
        if want_sleeve:
            jobs["tpu_sleeve"] = ({**defs, "mode": "assembled", "part": "tpu_sleeve"}, wd / "sleeve_preview.stl")
    # 検査用：刷る向きのクリップ（速い）
    jobs["_clip_print_check"] = ({**defs, "mode": "clip", "quality": "preview"}, wd / "_clip_check.stl")
    ts = time.time()
    with ThreadPoolExecutor(max_workers=4) as ex:
        futs = {k: ex.submit(run, d, p) for k, (d, p) in jobs.items()}
        files = {k: f.result() for k, f in futs.items()}
    timings["openscad_ms"] = int((time.time() - ts) * 1000)
    clip_check = files.pop("_clip_print_check")

    # 検査（正準形で）
    ts = time.time()
    results = []
    if "cover" in files:
        cm = trimesh.load(files["cover"], force="mesh")
        # R6b：0.5cm³ 未満の破片（OpenSCAD が残す体積のない切れ端など）は取り除き、ファイルを書き直す
        ps = cm.split(only_watertight=False)
        if len(ps) > 1:
            big = [p for p in ps if abs(p.volume) >= 500.0 or p.area >= 200.0]
            small = [p for p in ps if p not in big]
            if big and small:
                cm = trimesh.util.concatenate(big) if len(big) > 1 else big[0]
                cm.export(files["cover"])
                results.append({"rule": "R6b_fragments", "ok": True,
                                "value": {"removed": len(small), "volume_mm3": round(sum(abs(p.volume) for p in small), 2)},
                                "message_ja": f"小さな切れ端を {len(small)} 個取り除きました", "severity": "info"})
        if quality == "print":
            cm.apply_transform(np.linalg.inv(pm))
        cm_c = _mesh_to_canonical(cm, hand_side)
        results += CK.check_cover(cm_c, href, cut)
    results += CK.check_clip(trimesh.load(clip_check, force="mesh"), clip_p)
    timings["checks_ms"] = int((time.time() - ts) * 1000)
    violations = [{"rule": r["rule"], "message_ja": r["message_ja"], "fix_hint": r.get("fix_hint")}
                  for r in results if not r["ok"] and r.get("severity") == "error"]
    if ho["dropped"]:
        results.append({"rule": "R6e_holes", "ok": True, "value": {"dropped": ho["dropped"]},
                        "message_ja": f"空気穴を {ho['dropped']} 個減らしました（置ける場所が足りないため）", "severity": "info"})
    if sl["skipped"]:
        results.append({"rule": "R6e_slits", "ok": False, "value": sl["skipped"],
                        "message_ja": "ベルトのスリットを置けない所がありました", "severity": "warning"})

    # 確認用画像（プレビューのときだけ）
    views = []
    if quality != "print":
        ts = time.time()
        rod_c = tool_rod({"frame": rail["frame"], "origin": rail["origin"]}, clip_p)
        rod = (_to_actual_point(rod_c[0], hand_side), _to_actual_point(rod_c[1], hand_side))
        center = np.asarray(shell_a.bounds).mean(axis=0)
        n = _palm_normal_actual(hand_side)
        D = 350.0
        iso = np.array([-1.0, 0.6, 0.0]) - n
        iso /= np.linalg.norm(iso)
        cams = {"top": (center - n * D, center), "radial": (center + np.array([-D, 0, 0]), center),
                "front": (center + np.array([0, D, 0]), center), "iso": (center + iso * D, center)}
        vfiles = {k: files.get(k) for k in ("cover", "c_clip", "tpu_sleeve")}
        views = render_views(vfiles, str(wd / "hand.stl"), rod, float(clip_p["tool_d_mm"]), color, cams, wd)
        timings["views_ms"] = int((time.time() - ts) * 1000)
    timings["total_ms"] = int((time.time() - t0) * 1000)
    return {
        "files": files,
        "views": views,
        "cover_shell_sha256": shell_sha,
        "checks": results,
        "violations": violations,
        "timings_ms": timings,
        "placement": {"rail_origin": defs["rail_origin"], "rail_frame": defs["rail_frame"],
                      "air_holes": len(ho["centers"]), "strap_slits": len(sl["centers"])},
        "shell_info": {k: v for k, v in info.items() if k != "cut"},
    }


# ---------------------------------------------------------------------------
# 試し刷り3（clearance_test）：すき間 c を 1.0／1.5／2.0 で比べる小さな殻
# ---------------------------------------------------------------------------

def make_clearance_test(scaled_glb: bytes, joints_mm: dict, hand_side: str, workdir: str, cache=None,
                        clearances=(1.0, 1.5, 2.0), thickness: float = 2.0, radius: float = 16.0) -> dict:
    """人差し指と中指の付け根の関節の山のまわり（半径 radius）だけを、c ごとに切り出した殻（実際の手の座標のSTL）。
    scad/test_pieces/clearance_test.scad に -D c10_file=... などで渡して並べる。"""
    from .shell import PALM_FACE_DEG, DEG_TO_MM, smax
    cache = cache or DictCache()
    wd = Path(workdir)
    wd.mkdir(parents=True, exist_ok=True)
    V, F, _ = read_glb(scaled_glb)
    Jc = to_canonical_joints(parse_joints(joints_mm), hand_side)
    Vc, Fc = to_canonical_mesh(V, F, hand_side)
    radii = finger_radii(Vc, Jc)
    fver = f"{FIELD_VERSION}:{_sha(scaled_glb)[:16]}"
    raw = cache.get("sdf")
    field = Field.from_bytes(raw) if raw else None
    if field is None or field.version != fver:
        field = compute_field(Vc, Fc, Jc, radii)
        field.version = fver
        cache.put("sdf", field.to_bytes())
    ax = field.axes()
    G = np.stack(np.meshgrid(*ax, indexing="ij"), -1)
    center = (Jc["index"][0] + Jc["middle"][0]) / 2
    ball = np.linalg.norm(G - center, axis=-1) - radius
    ang = np.degrees(np.arccos(np.clip(field.nz.astype(np.float32) / 127.0, -1, 1)))
    palm = (PALM_FACE_DEG - ang) * DEG_TO_MM
    out = {}
    from .shell import _mc_mesh
    for c in clearances:
        band = np.maximum(c - field.sdf, field.sdf - (c + thickness))
        f = smax(smax(band, ball, 1.5), palm, 1.5).astype(np.float32)
        m = _mc_mesh(field, f)
        ps = m.split(only_watertight=False)
        if ps:
            m = max(ps, key=lambda p: abs(p.volume))
        m = _mesh_to_actual(m, hand_side)
        name = f"clearance_c{int(round(c * 10)):02d}.stl"
        m.export(wd / name)
        out[f"c{int(round(c * 10)):02d}"] = str(wd / name)
    return out
