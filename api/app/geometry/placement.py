"""スリット・空気穴・レールの位置と向き（parts-library.md §5）。正準形で計算する。

殻の外面の点は「手から c + t/2 より遠い頂点」とみなす（内面は手から c の所）。
"""
from __future__ import annotations

import numpy as np
import trimesh
from scipy.spatial import cKDTree

from .consts import LONG_FINGERS, fixed
from .handframe import palm_length, rail_direction, seg_dist

RAIL_WALL_MM = 2.5   # common.scad の RAIL_WALL_MM（溝のまわりの肉）
RAIL_BASE_MM = 2.0   # common.scad の RAIL_BASE_MM（溝の底の下の肉）
RAIL_FOOT_MM = 6.0   # common.scad の RAIL_FOOT_MM（殻の中へ入り込ませる土台）


def rail_height() -> float:
    return float(fixed("RAIL_DEPTH_MM")) + RAIL_BASE_MM


def rail_outer_w() -> float:
    """レールの台の外の幅（common.scad の rail_outer_w()）"""
    import math
    bottom = float(fixed("RAIL_WIDTH_MM")) + 2 * float(fixed("RAIL_DEPTH_MM")) / math.tan(math.radians(float(fixed("RAIL_DOVETAIL_DEG"))))
    return bottom + 2 * RAIL_WALL_MM


def slit_rail_clearance(sl: dict, rail: dict, wall_t: float = 2.5) -> float:
    """スリットの穴（壁の中の部分）とレールの台（土台を含む箱）の、いちばん近い所の距離（mm）。
    重なっていれば負。レールの座標（原点＝上面の中心、X＝横、Y＝長さ、Z＝外向き）で、
    スリットの箱の面を細かく点にして、箱（軸に沿う）までの距離を取る。"""
    if not sl["centers"]:
        return float("inf")
    hx, hy = rail_outer_w() / 2, float(fixed("RAIL_LENGTH_MM")) / 2
    z_lo, z_hi = -(rail_height() + float(rail.get("foot_mm", RAIL_FOOT_MM))), 0.0
    half = np.array([hx, hy, (z_hi - z_lo) / 2])
    mid = np.array([0.0, 0.0, (z_hi + z_lo) / 2])
    Fm = np.asarray(rail["frame"])
    best = float("inf")
    g = np.linspace(-1, 1, 7)
    for cen, n, a in zip(sl["centers"], sl["normals"], sl["axes"]):
        n = np.asarray(n, float) / (np.linalg.norm(n) or 1.0)
        a0 = np.asarray(a, float) - (np.asarray(a, float) @ n) * n
        a0 /= (np.linalg.norm(a0) or 1.0)
        x = np.cross(a0, n)
        # 穴の箱：長い辺 ±(幅+1)/2、短い辺 ±(厚み+1.5)/2、壁の向きに ±(壁の厚み/2 + 1)
        e = np.array([(sl["thickness"] + 1.5) / 2, (sl["width"] + 1.0) / 2, wall_t / 2 + 1.0])
        U, Vv, W = np.meshgrid(g, g, g, indexing="ij")
        on_face = (np.abs(U) == 1) | (np.abs(Vv) == 1) | (np.abs(W) == 1)
        P = (np.asarray(cen, float)[None, :] + (U[on_face, None] * e[0]) * x + (Vv[on_face, None] * e[1]) * a0
             + (W[on_face, None] * e[2]) * n)
        R = (P - np.asarray(rail["origin"], float)) @ Fm.T - mid      # レールの座標、箱の中心を原点に
        q = np.abs(R) - half
        outside = np.linalg.norm(np.maximum(q, 0.0), axis=1)
        inside = np.minimum(q.max(axis=1), 0.0)
        best = min(best, float((outside + inside).min()))
    return best


def outer_surface(shell: trimesh.Trimesh, hand_tree: cKDTree, c: float, t: float):
    d, _ = hand_tree.query(shell.vertices)
    sel = d > c + t * 0.5
    return shell.vertices[sel], shell.vertex_normals[sel]


def _surface_has_ring(center, normal, outer_tree, radius, tol=1.6, n=12) -> bool:
    """中心のまわりの半径 radius の円の上に、殻の外面があるか（穴やスリットがふちにかからないか）。"""
    n_ = normal / (np.linalg.norm(normal) or 1.0)
    a = np.cross(n_, [1.0, 0, 0])
    if np.linalg.norm(a) < 0.3:
        a = np.cross(n_, [0, 1.0, 0])
    a /= np.linalg.norm(a)
    b = np.cross(n_, a)
    ang = np.linspace(0, 2 * np.pi, n, endpoint=False)
    ring = center + radius * (np.cos(ang)[:, None] * a + np.sin(ang)[:, None] * b)
    d, _ = outer_tree.query(ring)
    return bool(np.all(d < tol))


def place_rail(Jc: dict, radii: dict, outer_v, outer_n, c: float, t: float, shift: float = 0.0) -> dict:
    """shift：光線の出どころを、手の甲の真ん中の向き（親指側の角から手の甲の上へ。−X）へずらす長さ（mm）。
    向き（frame）は変えない"""
    mid, u, dvec = rail_direction(Jc)
    mid = mid + np.cross(dvec, u) * shift
    # 基節の中点から外向きの光線の近くにある外面の頂点のうち、一番遠いもの
    rel = outer_v - mid
    s = rel @ dvec
    perp = np.linalg.norm(rel - s[:, None] * dvec, axis=1)
    sel = (s > 0) & (perp < 3.0)
    if sel.any():
        i = np.argmax(np.where(sel, s, -np.inf))
        anchor = outer_v[i]
    else:
        anchor = mid + dvec * (radii["index"][0] + c + t)
    z_r = dvec
    y_r = u
    x_r = np.cross(y_r, z_r)
    origin = anchor + z_r * rail_height()   # レールの上面（溝の口）の中心
    return {"anchor": anchor, "origin": origin, "frame": np.stack([x_r, y_r, z_r]),
            "shift_mm": float(shift), "lift_mm": 0.0, "foot_mm": RAIL_FOOT_MM}


SLIT_RAIL_GAP_MM = 1.0       # スリットの穴とレールの台（土台を含む）のあいだに残す距離（R6e_slit_rail と同じ）
RAIL_MAX_SHIFT_MM = 20.0     # レールをずらしてよい長さの上限
RAIL_MAX_FOOT_MM = 12.0      # ずらしたときに深くしてよい土台の上限


def _rail_seat(rail: dict, outer_v) -> tuple[float, float]:
    """台の底面（anchor を通り外向きに垂直な面）から見た、外面の高さ。
    返り値：溝の下で外面がいちばん高い所（底面より上に何mm）と、台の下で外面がいちばん低い所（底面より下に何mm）"""
    x, y, d = (np.asarray(v, float) for v in rail["frame"])
    hx, hy = rail_outer_w() / 2 - 0.5, float(fixed("RAIL_LENGTH_MM")) / 2 - 0.5
    groove_half = rail_outer_w() / 2 - RAIL_WALL_MM
    bury, low = -np.inf, np.inf
    for a in np.linspace(-hx, hx, 9):
        for b in np.linspace(-hy, hy, 7):
            p = np.asarray(rail["anchor"], float) + a * x + b * y
            rel = outer_v - p
            s = rel @ d
            perp = np.linalg.norm(rel - s[:, None] * d, axis=1)
            sel = (perp < 1.5) & (np.abs(s) < 20.0)
            if not sel.any():
                continue
            top = float(s[sel].max())
            low = min(low, top)
            if abs(a) <= groove_half + 0.5:
                bury = max(bury, top)
    return (bury if np.isfinite(bury) else 0.0), (-low if np.isfinite(low) else 0.0)


REF_TOOL_D_MM = 11.5   # ずらしてよいかを見る基準の道具の太さ（標準でいちばん太い「太い」。太さを直してもカバーが変わらないよう固定）


def _tool_paths(hand_ref, rail: dict, Jc: dict, angle: float) -> list[dict]:
    from .checks import check_tool_path
    return [check_tool_path(hand_ref, None, rail, {"tool_d_mm": REF_TOOL_D_MM, "angle_deg": angle}, Jc)[0]["value"]]


def _tool_not_worse(now: list[dict], before: list[dict]) -> bool:
    """どの角度でも、道具と手のすき間・机までの長さが、ずらす前より悪くならない（もともと足りていれば合格の範囲に収まる）"""
    from .checks import TOOL_HAND_GAP_MM, TOOL_TIP_MM
    for v, v0 in zip(now, before):
        if v["gap_hand_mm"] < min(TOOL_HAND_GAP_MM, v0["gap_hand_mm"]):
            return False
        reach, reach0 = v["reach_mm"], v0["reach_mm"]
        if reach0 is not None and (reach is None or reach > max(TOOL_TIP_MM, reach0)):
            return False
    return True


def place_rail_clear_of_slits(Jc: dict, radii: dict, outer_v, outer_n, c: float, t: float, sl: dict,
                              hand_ref=None, tool_angle: float = 70.0) -> dict:
    """レールの台がベルトのスリットにかかるなら、台を手の甲側へずらして離す（2026-11-10）。
    側面が低い手では、親指側の角にある台の土台が親指側のスリットの上にかぶさり、穴がふさがれていた。
    スリットはベルトの通り道（手ごと）で決まるので動かさず、台のほうを動かす。台の向き（frame）は変えないので、
    クリップと道具の角度、先に作っておいたクリップの形はそのまま使える。
    ずらすと台が面から傾くので、溝の下に殻が来ない高さまで持ち上げ（lift）、浮いた側は土台を深くして（foot）殻に届かせる。
    hand_ref（手の形）を渡すと、道具も一緒に動く（1mm ずらすごとに、握った指とのすき間が 0.5〜0.7mm 減る）ので、
    主な取り付け具の角度 tool_angle の基準の道具（太さ REF_TOOL_D_MM）が、手から TOOL_HAND_GAP_MM 以上離れ（ずらす前に
    足りなければ、それより近づかず）、机に届く所までしかずらさない。太さは基準の値で見るので、太さを直したり取り付け具を
    足したりしても、カバー（レールの位置）は変わらない。
    離しきれないなら、ずらさず今までの位置のまま（途中までずらしても穴はほとんど開かず、道具だけが手に近づいた。
    残った重なりは R6e_slit_rail・R6e_slit_open で知らせる）"""
    wall_t = float(t)
    rail0 = place_rail(Jc, radii, outer_v, outer_n, c, t)
    clear0 = slit_rail_clearance(sl, rail0, wall_t=wall_t)
    if clear0 >= SLIT_RAIL_GAP_MM:
        return rail0
    tools0 = _tool_paths(hand_ref, rail0, Jc, tool_angle) if hand_ref is not None else None
    d = np.asarray(rail0["frame"][2], float)
    for shift in np.arange(1.0, RAIL_MAX_SHIFT_MM + 0.01, 1.0):
        r = place_rail(Jc, radii, outer_v, outer_n, c, t, shift=float(shift))
        bury, floating = _rail_seat(r, outer_v)
        lift = max(0.0, bury - (RAIL_BASE_MM - 0.5))           # 溝の底より 0.5mm 下まで
        foot = max(RAIL_FOOT_MM, floating + lift + 1.0)         # 浮いた所でも殻に 1mm 入る
        if foot > RAIL_MAX_FOOT_MM:
            continue
        r.update(origin=np.asarray(r["anchor"], float) + d * (rail_height() + lift), lift_mm=float(lift),
                 foot_mm=float(foot), groove_bury_mm=float(bury - lift), float_mm=float(floating + lift))
        if tools0 is not None and not _tool_not_worse(_tool_paths(hand_ref, r, Jc, tool_angle), tools0):
            continue
        if slit_rail_clearance(sl, r, wall_t=wall_t) >= SLIT_RAIL_GAP_MM:
            return r
    return rail0


SLIT_MAX_NZ = 0.7   # スリットを抜く向きの縦成分の上限（これより下向きなら横へ寄せる。ベルトは横〜斜め下へ出る）
# スリットの y（手首→中指の付け根の長さに対する割合）。1本は 0.70（2026-11-08 に 0.55 から変えた：親指の付け根に
# ベルトがかかり、側面の低い所に来ていた。付け根の関節の手前まで寄せると、親指から 10mm ほど離れ、側面も高い）
SLIT_Y_FRACTIONS = {1: (0.70,), 2: (0.45, 0.72)}   # 2本のとき、と、手から通り道が見つからないときの位置

STRAP_GAP_MM = 3.0          # 親指の下にベルトをくぐらせるのに要るすき間（ベルトの厚み2mm＋余裕）
STRAP_BLOCK_TOL_MM = 4.0    # 断面の中で、ふさがっていても目をつぶる幅（メッシュのでこぼこ）
STRAP_PART_MARGIN_MM = 3.0  # 指・親指のカプセルの表面からこの距離以内の点を、その部位とみなす


def _section_points(hand, y: float, step: float = 0.5):
    """手のメッシュの y の断面を、線分に沿った点の列にする（正準形）。断面がなければ None"""
    sec = hand.section(plane_origin=[0.0, y, 0.0], plane_normal=[0.0, 1.0, 0.0])
    if sec is None:
        return None
    pts = []
    for e in sec.entities:
        v = sec.vertices[e.points]
        for a, b in zip(v[:-1], v[1:]):
            n = max(2, int(np.linalg.norm(b - a) / step))
            pts.append(a + np.linspace(0.0, 1.0, n)[:, None] * (b - a))
    return np.vstack(pts) if pts else None


def strap_window(hand, Jc: dict, radii: dict, y_lo: float, y_hi: float) -> dict | None:
    """手のひらだけを通るベルトの通り道（正準形。手のひら側が +z）。
    y ごとに断面を手のひら側から見上げ、x ごとに「いちばん手のひら側にある部位」を見る。
    - 指（曲げた指先など）が見えていれば、ベルトは指に乗るので通せない
    - 親指が見えていても、親指と手のひらのあいだに STRAP_GAP_MM 以上のすき間があれば、親指の下にくぐらせて通せる
    通せる y がいちばん長く続く範囲を返す（{"y_from", "y_to", "center"}）。なければ None。
    握りこぶしでは、手首寄りは親指が手のひらに付いていて、指先寄りは曲げた指先が来るので、そのあいだの狭い範囲になる（2026-11-08）"""
    if y_hi <= y_lo:
        return None

    def part(p):
        th = min(seg_dist(p[None], Jc["thumb"][i], Jc["thumb"][i + 1])[0][0] - radii["thumb"][i] for i in range(3))
        fg = min(seg_dist(p[None], Jc[f][i], Jc[f][i + 1])[0][0] - radii[f][i] for f in LONG_FINGERS for i in range(3))
        if th < STRAP_PART_MARGIN_MM and th <= fg:
            return "thumb"
        if fg < STRAP_PART_MARGIN_MM:
            return "finger"
        return "palm"

    ok_ys = []
    for y in np.arange(y_lo, y_hi + 0.01, 1.0):
        P = _section_points(hand, float(y))
        if P is None:
            continue
        blocked = 0.0
        for x in np.arange(P[:, 0].min() + 1.0, P[:, 0].max() - 1.0, 2.0):
            q = P[np.abs(P[:, 0] - x) < 0.6]
            if len(q) < 2:
                continue
            first = q[np.argmax(q[:, 2])]                     # いちばん手のひら側の点
            kind = part(first)
            if kind == "palm":
                continue
            zs = np.sort(q[:, 2])[::-1]                       # 手のひら側から順の交点
            cr = [zs[0]] + [z1 for z0, z1 in zip(zs[:-1], zs[1:]) if z0 - z1 > 1.0]
            passable = kind == "thumb" and len(cr) >= 3 and (cr[1] - cr[2]) >= STRAP_GAP_MM
            if not passable:
                blocked += 2.0
        if blocked <= STRAP_BLOCK_TOL_MM:
            ok_ys.append(float(y))
    if not ok_ys:
        return None
    runs, cur = [], [ok_ys[0]]
    for y in ok_ys[1:]:
        if y - cur[-1] <= 1.01:
            cur.append(y)
        else:
            runs.append(cur)
            cur = [y]
    runs.append(cur)
    best = max(runs, key=len)
    return {"y_from": round(best[0], 1), "y_to": round(best[-1], 1), "center": round((best[0] + best[-1]) / 2, 1)}


def place_slits(Jc: dict, outer_v, outer_n, outer_tree, params: dict, edge_r: float, palm_z: float,
                hand=None, radii: dict | None = None, wrist_cut: float | None = None) -> dict:
    """ベルトのスリット（measurement.md §8.3・parts-library.md §5）。
    親指側・小指側の**側面**の、手のひら側のふちから inset（ふちの肉＋丸み＋スリットの半分）だけ手の甲側の高さで、
    いちばん外側の点に開ける。ベルトはそこから手のひらの下へ回る。手の甲側の角（レールの台がある所）には置かない
    （2026-11-08。前は角の手の甲側の点に置いていて、親指側のスリットがレールの真下に来て塞がれた）。
    側面が低くて（手のひら側を切る面が手の甲に近い）その高さに殻がなければ、置けなかったことを skipped に残す。
    palm_z：手のひら側を切る面の高さ（正準形。手のひら側が +z）。
    1本のとき、hand（正準形の手のメッシュ）と radii を渡すと、y は手ごとの「手のひらだけを通る通り道」（strap_window）の
    真ん中にする（2026-11-08。ベルトは親指の下にくぐらせて手のひらだけを通し、面ファスナーで留める使い方のため）。
    見つからなければ SLIT_Y_FRACTIONS の位置にして、window に source="fallback" を残す。"""
    L = palm_length(Jc)
    count = int(params.get("strap_count", 1))
    w = float(params.get("strap_width_mm", 25))
    th = float(params.get("strap_thickness_mm", 2.0))
    centers, normals, axes, skipped = [], [], [], []
    inset = fixed("MIN_WALL_MM") + (th + 1.5) / 2 + edge_r + 0.5
    # 指先側の上限：カバーは付け根の関節の少し先で終わるので、スリットの端がそのふちの肉（MIN_WALL＋丸み）を残す所まで
    y_mcp_min = min(float(Jc[f][0][1]) for f in LONG_FINGERS)
    edge_keep = (w + 1.0) / 2 + fixed("MIN_WALL_MM") + edge_r
    y_max = y_mcp_min - edge_keep
    y_min = (float(wrist_cut) + edge_keep) if wrist_cut is not None else 0.0   # 手首側のふちも同じだけ残す
    ys = [min(f * L, y_max) for f in SLIT_Y_FRACTIONS[2 if count >= 2 else 1]]
    window = None
    if count < 2 and hand is not None and radii is not None:
        if y_min > y_max:
            # 手のひらが短く、ふちの肉を両側に残すとスリットを置ける所がない
            window = {"source": "fallback", "slit_y": round(ys[0], 1), "reason": "スリットを置ける範囲がない（手のひらが短い）"}
        else:
            # 通り道は「スリットの真ん中を置ける範囲」（両側のふちの肉を残す所）の中だけで探す。
            # 前は範囲の外で見つけてから端へ寄せ、通り道から外れた位置なのに「通せる」と出ていた（2026-11-08 のレビュー）
            win = strap_window(hand, Jc, radii, y_min, y_max)
            if win:
                ys = [float(win["center"])]
                window = {**win, "source": "thumb_gap", "slit_y": round(ys[0], 1),
                          "width_mm": round(win["y_to"] - win["y_from"] + 1.0, 1), "strap_width_mm": w}
            else:
                window = {"source": "fallback", "slit_y": round(ys[0], 1), "reason": "親指の下をくぐれる所が、スリットを置ける範囲にない"}
    t = float(params.get("_t", 2.5))
    for y in ys:
        band = np.abs(outer_v[:, 1] - y) < 1.5
        if band.sum() < 5:
            skipped.append({"y": round(float(y), 1), "reason": "殻がその高さにない"})
            continue
        bv, bn = outer_v[band], outer_n[band]
        for side in (-1, 1):                     # -1：親指側（x が小さい）、+1：小指側
            sv = side * bv[:, 0] > 0
            if sv.sum() < 5:
                skipped.append({"y": round(float(y), 1), "side": side, "reason": "その側に殻がない"})
                continue
            v, n = bv[sv], bn[sv]
            # その側のふち（手のひら側の端）の高さ：いちばん外側の x から 6mm 以内の点の中で、いちばん手のひら側
            x_edge = float((side * v[:, 0]).max() * side)
            near = v[np.abs(v[:, 0] - x_edge) < 6.0]
            z_edge = min(float(near[:, 2].max()), float(palm_z))
            z_c = z_edge - inset
            at = np.abs(v[:, 2] - z_c) < 1.5
            if not at.any():
                skipped.append({"y": round(float(y), 1), "side": side, "reason": "側面が低く、スリットの高さに殻がない"})
                continue
            ci = np.where(at)[0]
            outer = ci[side * v[ci, 0] >= (side * v[ci, 0]).max() - 1.0]   # その高さで外側（1mm 以内）の点
            j = outer[np.argmin(np.abs(v[outer, 2] - z_c))]                 # の中で、決めた高さにいちばん近い点
            n_s = n[j] / (np.linalg.norm(n[j]) or 1.0)
            n_cut = n_s
            if abs(n_s[2]) > SLIT_MAX_NZ:                 # 下向きが強ければ、縦を SLIT_MAX_NZ に固定して横を伸ばす
                h = n_s[:2] / (np.linalg.norm(n_s[:2]) or 1.0)
                n_cut = np.array([*(h * np.sqrt(1.0 - SLIT_MAX_NZ ** 2)), np.sign(n_s[2]) * SLIT_MAX_NZ])
            centers.append(v[j] - n_s * (t / 2))     # 壁の中ほど
            normals.append(n_cut)
            axes.append(np.array([0.0, 1.0, 0.0]))
    return {"centers": centers, "normals": normals, "axes": axes, "skipped": skipped,
            "width": w, "thickness": th, "window": window}


def place_holes(Jc: dict, outer_v, outer_n, outer_tree, params: dict, wrist_cut: float,
                avoid: list[tuple[np.ndarray, float]]) -> dict:
    count = int(params.get("count", 6))
    d = float(params.get("diameter_mm", 6.0))
    if count <= 0:
        return {"centers": [], "normals": [], "dropped": 0}
    y_lo = wrist_cut + 8.0
    y_hi = min(float(Jc[f][0][1]) for f in LONG_FINGERS) - 10.0
    if y_hi <= y_lo:
        return {"centers": [], "normals": [], "dropped": count}
    # 手の甲の外面（法線が −z 寄り）の頂点を候補にする
    top = (outer_n[:, 2] < -0.5) & (outer_v[:, 1] >= y_lo) & (outer_v[:, 1] <= y_hi)
    cv, cn = outer_v[top], outer_n[top]
    if len(cv) == 0:
        return {"centers": [], "normals": [], "dropped": count}
    # 2mm 格子で間引く
    key = np.round(cv[:, :2] / 2.0).astype(int)
    _, first = np.unique(key, axis=0, return_index=True)
    cv, cn = cv[first], cn[first]
    ok = []
    knuckles = [Jc[f][0] for f in LONG_FINGERS]
    for i, p in enumerate(cv):
        if any(np.linalg.norm(p[:2] - k[:2]) < 6.0 + d / 2 + 4.0 for k in knuckles):
            continue
        if any(np.linalg.norm(p - q) < 6.0 + d / 2 + r for q, r in avoid):
            continue
        if not _surface_has_ring(p, cn[i], outer_tree, d / 2 + fixed("MIN_WALL_MM")):
            continue
        ok.append(i)
    if not ok:
        return {"centers": [], "normals": [], "dropped": count}
    cv, cn = cv[ok], cn[ok]
    # 互いに離れた点を選ぶ（いちばん遠い点を順に選ぶ）
    chosen = [int(np.argmin(np.linalg.norm(cv[:, :2] - cv[:, :2].mean(0), axis=1)))]
    while len(chosen) < count:
        dmin = np.min(np.linalg.norm(cv[:, None, :] - cv[chosen][None, :, :], axis=2), axis=1)
        j = int(np.argmax(dmin))
        if dmin[j] < d + 4.0:
            break
        chosen.append(j)
    centers = [cv[j] for j in chosen]
    normals = [cn[j] / np.linalg.norm(cn[j]) for j in chosen]
    return {"centers": centers, "normals": normals, "dropped": count - len(centers)}


def tool_rod(rail: dict, clip: dict) -> tuple[np.ndarray, np.ndarray]:
    """確認用画像の道具の棒（正準形）。輪の中心から、輪の軸の向きに前へ120mm、後ろへ30mm。"""
    from .clipgeom import clip_center_rail, clip_axis_rail
    M = np.eye(4)
    M[:3, :3] = rail["frame"].T
    M[:3, 3] = rail["origin"]
    c = clip_center_rail(clip)
    a = clip_axis_rail(clip)
    cw = M[:3, :3] @ c + M[:3, 3]
    aw = M[:3, :3] @ a
    return cw - 30.0 * aw, cw + 120.0 * aw
