"""生成APIの通しのテスト（開発の設定：AUTH_MODE=dev、STORE_BACKEND=local、GEMINI_MODE=mock）。
形の計算（geometry）は仮のものに差し替える。本物の geometry の試験は test_geometry*.py（担当B）。"""
from __future__ import annotations

import hashlib
import hmac
import io
import json
import os
import sys
import tempfile
import types
from datetime import datetime, timezone
from pathlib import Path

import pytest

TMP = tempfile.mkdtemp(prefix="jijogu_test_store_")
# 1人1日の生成の上限（既定10回）は、このファイルの生成の数より少ないので上げる
os.environ.update({"AUTH_MODE": "dev", "STORE_BACKEND": "local", "LOCAL_STORE_DIR": TMP, "GEMINI_MODE": "mock",
                   "LIMIT_DESIGNS_PER_USER": "100"})
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import trimesh  # noqa: E402
from PIL import Image  # noqa: E402

FIX = Path(__file__).parent / "fixtures"


def _fake_geometry():
    """contract §4 と同じ形を返す仮の geometry"""
    m = types.ModuleType("app.geometry")

    class GeometryError(Exception):
        def __init__(self, code="MEASUREMENT_INVALID", message_ja=None, details=None):
            super().__init__(code)
            self.code, self.message_ja, self.details = code, message_ja, details or []

    def prepare_measurement(raw_glb, measurement, hand_side, requirements=None):
        joints = {"wrist": [0, 0, 0], "thumb": [[-20, 30, 5], [-30, 45, 10], [-35, 55, 15], [-38, 65, 18]]}
        for i, f in enumerate(("index", "middle", "ring", "pinky")):
            x = -25 + i * 17
            joints[f] = [[x, 80, 0], [x, 105, -20], [x, 100, -40], [x, 88, -48]]
        return {"scaled_glb": raw_glb, "scale_factor": 1.17, "scale_source": "palm4", "scale_spread_ratio": 0.04,
                "joints_mm": joints,
                "cover_landmarks": {"palm_cut_base_mm": 38.6, "wrist_to_middle_mcp_mm": 80.0,
                                    "rail_anchor": {"point_mm": [-31.5, 95.0, -6.0], "direction": [0, 0.6, 0.8]},
                                    "slit_zones": {"thumb_side": [-36, 44], "pinky_side": [44, 44]}},
                "baseline": [
                    {"part_id": "cover", "name": "cover_thickness_mm", "value": 2.5, "source": "default"},
                    {"part_id": "cover", "name": "palm_cut_offset_mm", "value": 0.0, "source": "default"},
                    {"part_id": "cover", "name": "wrist_cut_mm", "value": 32.0, "source": "measured"},
                    {"part_id": "cover", "name": "edge_radius_mm", "value": 2.0, "source": "default"},
                    {"part_id": "air_holes", "name": "count", "value": 6, "source": "default"},
                    {"part_id": "air_holes", "name": "diameter_mm", "value": 6.0, "source": "default"},
                    # 固定の引数（strap_count・クリップの壁/開き/高さ/溝/TPU）は本物の基準値（baseline.py）に入らないので、ここにも入れない
                    {"part_id": "strap_slits", "name": "strap_width_mm", "value": 25, "source": "default"},
                    {"part_id": "strap_slits", "name": "strap_thickness_mm", "value": 2.0, "source": "default"},
                    {"part_id": "c_clip", "name": "tool_d_mm", "value": 8.5, "source": "interview"},
                    {"part_id": "c_clip", "name": "angle_deg", "value": 70, "source": "rule"},
                    {"part_id": "c_clip", "name": "count", "value": 1, "source": "default"},
                ],
                "warnings": []}

    calls = []

    def make_design(scaled_glb, joints_mm, hand_side, params, workdir, cache, quality="preview", parts=("cover", "c_clip"),
                    color="#2A9D8F", extra_clips=None):
        calls.append({"params": params, "quality": quality, "parts": parts, "extra_clips": extra_clips})
        out = {}
        for p in parts:
            path = Path(workdir) / f"{p}_{quality}.stl"
            # 本物の OpenSCAD は同じ入力でも毎回少し違うSTLを出すので、仮のカバーも呼ぶたびに中身を変える
            h = 10 + 0.01 * len(calls) if p == "cover" else 10
            trimesh.creation.box((10, 10, h)).export(path)
            out[p] = str(path)
        extra = {}
        for aid, cp in (extra_clips or {}).items():
            path = Path(workdir) / f"c_clip_{aid}_{quality}.stl"
            trimesh.creation.box((10, 10, 10)).export(path)
            extra[aid] = {"file": str(path),
                          "tool": {"center": [0, 0, 0], "axis": [0, 0, -1], "tip_mm": 100.0, "rear_mm": 50.0,
                                   "diameter_mm": float(cp["tool_d_mm"])},
                          "clip": {"source": "generated", "variant": None, "tool_d_mm": float(cp["tool_d_mm"]),
                                   "angle_deg": int(cp["angle_deg"])},
                          "checks": [], "violations": []}
        views = []
        for name in ("front", "side", "top", "iso"):
            path = Path(workdir) / f"{name}.png"
            Image.new("RGB", (32, 24), (200, 200, 200)).save(path)
            views.append(str(path))
        return {"files": out, "views": views, "cover_shell_sha256": "ab" * 32, "checks": [], "violations": [],
                "timings_ms": {"openscad": 5}, "extra_clips": extra}

    m.GeometryError, m.prepare_measurement, m.make_design, m.calls = GeometryError, prepare_measurement, make_design, calls
    return m


GEOM = _fake_geometry()

from fastapi.testclient import TestClient  # noqa: E402
from app.main import app  # noqa: E402
from app import tokens  # noqa: E402
from app.store import db, files  # noqa: E402

H = {"X-User": "u1"}


def _token(case_id: str, mesh: bytes, fingers: dict) -> str:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    a = tokens.angles_sha256(fingers)
    s = hashlib.sha256(mesh).hexdigest()
    mac = hmac.new(b"dev-only-key", f"v1|{case_id}|{ts}|{a}|{s}".encode(), hashlib.sha256).hexdigest()
    return f"v1.{case_id}.{ts}.{a}.{s}.{mac}"


def _measurement(case_id: str, mesh_id: str, token: str, manual: bool = False) -> dict:
    finger = {"lengths_mm": [40.0, 25.0, 20.0], "flexion_deg": {"mcp": 60, "pip": 80, "dip": 20},
              "abduction_deg": 0.0, "angle_method": "mesh_recovery"}
    m = {
        "schema_version": "2.2", "hand_side": "right",
        "capture": {"mode": "video", "frames_used": 12, "frames_sampled": 40, "duration_s": 8.0, "mesh_consent": True,
                    "mesh_frames_sent": 6, "mesh_id": mesh_id, "mesh_result_token": token},
        "scale": {"reference": "jp_1yen", "diameter_mm": 20.0, "method": "coin_auto"},
        "fingers": {f: dict(finger) for f in ("index", "middle", "ring", "pinky")},
        "palm": {"mcp_positions_mm": {"index": [-25, 80], "middle": [-8, 82], "ring": [9, 80], "pinky": [26, 76]},
                 "hand_width_mcp_mm": 51.0, "wrist_to_middle_mcp_mm": 82.0, "wrist_to_index_mcp_mm": 84.0,
                 "wrist_to_pinky_mcp_mm": 80.0},
        "calibration": {"length_factor": 1.0, "source": "default"},
        "quality": {"warnings": []},
    }
    if manual:
        pts = {"0": [200.0, 400.0], "5": [200.0 - 25 * 4, 400.0 - 80 * 4], "9": [200.0 - 8 * 4, 400 - 82 * 4],
               "13": [200.0 + 9 * 4, 400 - 80 * 4], "17": [200.0 + 26 * 4, 400 - 76 * 4]}
        m["manual_points"] = [{"frame_index": 3, "view": "top", "px_per_mm": 4.0, "points": pts, "moved": [5]}]
        import math
        p = lambda a, b: math.dist(pts[a], pts[b]) / 4.0  # noqa: E731
        m["palm"].update({"wrist_to_index_mcp_mm": p("0", "5"), "wrist_to_middle_mcp_mm": p("0", "9"),
                          "wrist_to_pinky_mcp_mm": p("0", "17"), "hand_width_mcp_mm": p("5", "17")})
    return m


@pytest.fixture(scope="module")
def client():
    """形の計算を仮のものに差し替える（このファイルの中だけ。担当Bの本物のテストと混ざらないように）"""
    import app as app_pkg
    mp = pytest.MonkeyPatch()
    mp.setitem(sys.modules, "app.geometry", GEOM)
    mp.setattr(app_pkg, "geometry", GEOM, raising=False)
    with TestClient(app) as c:
        yield c
    mp.undo()


def _setup_case(client, tools=None) -> tuple[str, bytes, str]:
    """tools：(activity, tool_type, tool_d_mm, 柄の形) の組の一覧。None なら今までどおり筆1つ（tools を送らない）"""
    r = client.post("/v1/cases", json={"title": "筆のカバー"}, headers=H)
    assert r.status_code == 201, r.text
    cid = r.json()["case_id"]
    body = {"activity": "draw", "tool_type": "brush", "hand_side": "right", "tool_d_mm": 9.5, "tool_shaft_size": None,
            "tool_shaft_shape": "round", "finger_state": "fist", "donning_by": "helper", "capture_by": "helper"}
    if tools:
        items = [{"activity": a, "tool_type": t, "tool_d_mm": d, "tool_shaft_size": None, "tool_shaft_shape": s}
                 for a, t, d, s in tools]
        body.update({k: items[0][k] for k in ("activity", "tool_type", "tool_d_mm", "tool_shaft_shape")}, tools=items)
    r = client.put(f"/v1/cases/{cid}/requirements", headers=H, json=body)
    assert r.status_code == 200, r.text
    assert r.json()["case_status"] == "measuring"
    raw = (FIX / "hand_raw_right.glb").read_bytes()
    mesh_id = "hm_0123456789ab"
    files.put(f"cases/{cid}/hand/raw/{mesh_id}.glb", raw)
    return cid, raw, mesh_id


def _put_measurement(client, cid: str, raw: bytes, mesh_id: str) -> None:
    """同意して採寸を保存する"""
    client.post(f"/v1/cases/{cid}/consent", headers=H, json={"mesh_consent": True, "consent_text_version": "mesh-consent-2"})
    tok = _token(cid, raw, {"index": {"flexion_deg": {"mcp": 1}}})
    r = client.put(f"/v1/cases/{cid}/measurement", headers=H, json=_measurement(cid, mesh_id, tok))
    assert r.status_code == 200, r.text


def test_flow_measure_design_refine_print(client):
    cid, raw, mesh_id = _setup_case(client)
    tok = _token(cid, raw, {"index": {"flexion_deg": {"mcp": 1}}})
    # 同意がないと受け付けない
    r = client.put(f"/v1/cases/{cid}/measurement", headers=H, json=_measurement(cid, mesh_id, tok))
    assert r.status_code == 422 and r.json()["error"]["code"] == "CONSENT_REQUIRED"
    r = client.post(f"/v1/cases/{cid}/consent", headers=H, json={"mesh_consent": True, "consent_text_version": "mesh-consent-2"})
    assert r.status_code == 200
    # 書き換えたトークンは受け付けない
    bad = tok[:-1] + ("0" if tok[-1] != "0" else "1")
    r = client.put(f"/v1/cases/{cid}/measurement", headers=H, json=_measurement(cid, mesh_id, bad))
    assert r.status_code == 422 and r.json()["error"]["code"] == "MEASUREMENT_INVALID"
    r = client.put(f"/v1/cases/{cid}/measurement", headers=H, json=_measurement(cid, mesh_id, tok))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["case_status"] == "designing" and body["hand_model"]["mesh_path"].endswith(".glb")
    assert any(b["name"] == "tool_d_mm" and b["value"] == 9.5 for b in body["baseline"])  # 聞き取りの値が正
    # 実寸のメッシュは持ち主が読め、生メッシュは読めない
    assert client.get(f"/v1/files/{body['hand_model']['mesh_path']}", headers=H).status_code == 200
    assert client.get(f"/v1/files/cases/{cid}/hand/raw/{mesh_id}.glb", headers=H).status_code == 403
    assert client.get(f"/v1/files/{body['hand_model']['mesh_path']}", headers={"X-User": "u2"}).status_code == 403

    r = client.post(f"/v1/cases/{cid}/designs", headers=H, json={"style": {"color": "#2A9D8F", "pattern": "none"}})
    assert r.status_code == 200, r.text
    d = r.json()["design"]
    assert d["status"] == "ready", d
    assert set(d["files"]["parts"]) == {"cover", "c_clip"}
    assert d["files"]["parts"]["c_clip"]["preview_stl"].endswith("c_clip_70.preview.stl")
    angle = next(p for p in d["params"] if p["name"] == "angle_deg")
    assert angle["value"] == 70 and angle["source"] == "ai"
    did = d["design_id"]

    # 色だけの変更は版を作らない
    r = client.post(f"/v1/cases/{cid}/designs/{did}/refine", headers=H, json={"style": {"color": "#E76F51"}})
    assert r.status_code == 200 and r.json()["design"]["design_id"] == did
    # 角度だけの変更は新しい版（クリップの角度が変わる）
    r = client.post(f"/v1/cases/{cid}/designs/{did}/refine", headers=H, json={"clip_angle_deg": 80})
    assert r.status_code == 200, r.text
    d2 = r.json()["design"]
    assert d2["design_id"] != did and d2["revision"] == 2 and d2["clip_angle_deg"] == 80
    assert d2["files"]["parts"]["c_clip"]["preview_stl"].endswith("c_clip_80.preview.stl")
    # 古い版は直せない
    r = client.post(f"/v1/cases/{cid}/designs/{did}/refine", headers=H, json={"clip_angle_deg": 60})
    assert r.status_code == 409
    # 言葉の微調整（モック）
    r = client.post(f"/v1/cases/{cid}/designs/{d2['design_id']}/refine", headers=H, json={"instruction": "もう少し厚く"})
    assert r.status_code == 200, r.text
    d3 = r.json()["design"]
    th = next(p for p in d3["params"] if p["name"] == "cover_thickness_mm")
    assert th["value"] > 2.5
    # あいまいな指示は確認の質問を返す
    r = client.post(f"/v1/cases/{cid}/designs/{d3['design_id']}/refine", headers=H, json={"instruction": "いい感じに"})
    assert r.status_code == 200 and r.json().get("clarify_ja")

    # 印刷用のデータ：承認の前は読めない。デモのケースは作れる
    r = client.post(f"/v1/cases/{cid}/designs/{d3['design_id']}/prepare-print", headers=H)
    assert r.status_code == 200, r.text
    prints = r.json()["files"]["print"]
    assert set(prints) == {"cover", "c_clip"}
    assert client.get(f"/v1/files/{prints['cover']}", headers=H).status_code == 200
    assert GEOM.calls[-1]["quality"] == "print"


def test_manual_points_and_mismatch(client):
    cid, raw, mesh_id = _setup_case(client)
    client.post(f"/v1/cases/{cid}/consent", headers=H, json={"mesh_consent": True, "consent_text_version": "mesh-consent-2"})
    tok = _token(cid, raw, {})
    m = _measurement(cid, mesh_id, tok, manual=True)
    r = client.put(f"/v1/cases/{cid}/measurement", headers=H, json=m)
    assert r.status_code == 200, r.text
    assert "POINTS_MANUAL" in r.json()["warnings"] and r.json()["hand_model"]["scale_source"] == "manual_points"
    m["palm"]["hand_width_mcp_mm"] += 3.0  # 直した点と合わない値
    r = client.put(f"/v1/cases/{cid}/measurement", headers=H, json=m)
    assert r.status_code == 422


def test_review_and_approval(client):
    cid, raw, mesh_id = _setup_case(client)
    client.post(f"/v1/cases/{cid}/consent", headers=H, json={"mesh_consent": True, "consent_text_version": "mesh-consent-2"})
    client.put(f"/v1/cases/{cid}/measurement", headers=H, json=_measurement(cid, mesh_id, _token(cid, raw, {})))
    d = client.post(f"/v1/cases/{cid}/designs", headers=H, json={}).json()["design"]
    db.set("therapists/ot@example.com", {"name": "OT役"})
    db.update(f"cases/{cid}", {"demo": False})
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/prepare-print", headers=H)
    assert r.status_code == 403  # デモでないケースは OT の確認が要る
    r = client.post(f"/v1/cases/{cid}/review-request", headers=H, json={"reviewer_email": "ot@example.com", "design_id": d["design_id"]})
    assert r.status_code == 200, r.text
    ot = {"X-User": "ot1", "X-User-Email": "ot@example.com"}
    dd = client.get(f"/v1/cases/{cid}/designs/{d['design_id']}", headers=ot).json()["design"]
    ghash = dd["geometry_hash"]
    # 承認の前は print/ を読めない
    assert client.get(f"/v1/files/cases/{cid}/designs/{d['design_id']}/print/cover.stl", headers=H).status_code in (403, 404)
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/approval", headers=ot,
                    json={"decision": "approve", "geometry_hash": ghash, "checklist": {"dimensions_reviewed": True}})
    assert r.status_code == 422 and r.json()["error"]["code"] == "CHECKLIST_INCOMPLETE"
    ck = {k: True for k in ("dimensions_reviewed", "edges_safe", "not_an_orthosis", "palm_open_wrist_free",
                            "no_mouth_contact", "user_informed")}
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/approval", headers=ot,
                    json={"decision": "approve", "geometry_hash": ghash, "checklist": ck})
    assert r.status_code == 200, r.text
    assert r.json()["case_status"] == "approved"
    assert client.get(f"/v1/files/{r.json()['files']['print']['cover']}", headers=H).status_code == 200


def test_review_approval_publishes_one_print_per_attachment(client):
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round"), ("eat", "spoon", 12.0, "round")])
    _request_review(client, cid, d["design_id"])
    ot = {"X-User": "ot1", "X-User-Email": "ot@example.com"}
    ghash = client.get(f"/v1/cases/{cid}/designs/{d['design_id']}", headers=ot).json()["design"]["geometry_hash"]
    ck = {k: True for k in ("dimensions_reviewed", "edges_safe", "not_an_orthosis", "palm_open_wrist_free",
                            "no_mouth_contact", "user_informed")}
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/approval", headers=ot,
                    json={"decision": "approve", "geometry_hash": ghash, "checklist": ck})
    assert r.status_code == 200, r.text
    pr = r.json()["files"]["print"]
    assert set(pr) == {"cover", "c_clip", "c_clip_a2"}
    assert all(client.get(f"/v1/files/{k}", headers=H).status_code == 200 for k in pr.values())


def test_errors_and_conflict(client):
    assert client.post("/v1/cases", json={}).status_code == 401
    cid, raw, mesh_id = _setup_case(client)
    r = client.put(f"/v1/cases/{cid}/requirements", headers=H, json={"activity": "fly"})
    assert r.status_code == 422 and r.json()["error"]["request_id"]
    from app import ops
    op = ops.begin(cid, "design", "d_x")
    r = client.put(f"/v1/cases/{cid}/requirements", headers=H, json={
        "activity": "draw", "tool_type": "brush", "hand_side": "right", "tool_d_mm": 9.5, "tool_shaft_shape": "round",
        "finger_state": "fist", "donning_by": "helper", "capture_by": "helper"})
    assert r.status_code == 409
    ops.end(cid, op)
    r = client.post(f"/v1/cases/{cid}/interview", headers=H, json={"message": "指を伸ばして固定したい"})
    assert r.status_code == 200 and r.json()["turn"]["status"] == "out_of_scope"


def test_delete_case(client):
    """ケースを消すと、手のメッシュ・版・チャット・印刷用のファイルもまとめて消える（data-model.md §5）"""
    cid, raw, mesh_id = _setup_case(client)
    client.post(f"/v1/cases/{cid}/consent", headers=H, json={"mesh_consent": True, "consent_text_version": "mesh-consent-2"})
    client.put(f"/v1/cases/{cid}/measurement", headers=H, json=_measurement(cid, mesh_id, _token(cid, raw, {})))
    d = client.post(f"/v1/cases/{cid}/designs", headers=H, json={}).json()["design"]
    client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/prepare-print", headers=H)
    db.set(f"cases/{cid}/messages/m1u", {"role": "user", "text": "テスト"})
    files.put(f"internal/cases/{cid}/cover/x/sdf", b"x")
    assert files.exists(f"cases/{cid}/hand/raw/{mesh_id}.glb")
    # 持ち主でない人は消せない
    assert client.delete(f"/v1/cases/{cid}", headers={"X-User": "someone-else"}).status_code == 403
    # 形を作っている途中は消せない
    from app import ops
    op = ops.begin(cid, "design", "d_x")
    assert client.delete(f"/v1/cases/{cid}", headers=H).status_code == 409
    ops.end(cid, op)
    r = client.delete(f"/v1/cases/{cid}", headers=H)
    assert r.status_code == 200, r.text
    assert r.json()["deleted"] is True and r.json()["files_deleted"] > 0
    assert db.get(f"cases/{cid}") is None
    assert db.list(f"cases/{cid}/designs") == [] and db.list(f"cases/{cid}/messages") == []
    assert not files.exists(f"cases/{cid}/hand/raw/{mesh_id}.glb")
    assert not files.exists(f"internal/cases/{cid}/cover/x/sdf")
    assert client.get(f"/v1/cases/{cid}", headers=H).status_code == 404
    assert cid not in [c["case_id"] for c in client.get("/v1/cases", headers=H).json()["cases"]]
    # もう一度消そうとすると 404
    assert client.delete(f"/v1/cases/{cid}", headers=H).status_code == 404


def test_token_interop_with_hand_mesh():
    """hand-mesh が作ったトークンを、生成APIが確かめられる（impl_contract §3）"""
    import importlib.util
    spec = importlib.util.spec_from_file_location("hm_rt", Path(__file__).resolve().parents[2] / "hand_mesh" / "result_token.py")
    rt = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rt)
    fingers = {"index": {"flexion_deg": {"mcp": 4.3, "pip": 63.2, "dip": 24.9}}}
    t = rt.make_token("dev-only-key", "c_abc12345", fingers, "f" * 64)
    v = tokens.verify(t, "c_abc12345")
    assert v and v["mesh_sha256"] == "f" * 64 and v["angles_sha256"] == tokens.angles_sha256(fingers)
    assert tokens.verify(t, "c_other") is None


def _glb_with_extras(extras: dict) -> bytes:
    """小さな球の GLB の最上位に extras を入れる（geometry は偽物に差し替えているので、ここで組む）"""
    import struct
    data = trimesh.creation.icosphere(subdivisions=1).export(file_type="glb")
    clen = struct.unpack_from("<I", data, 12)[0]
    js = json.loads(data[20:20 + clen])
    js["extras"] = extras
    jb = json.dumps(js, separators=(",", ":")).encode()
    jb += b" " * ((4 - len(jb) % 4) % 4)
    rest = data[20 + clen:]
    return struct.pack("<III", 0x46546C67, 2, 20 + len(jb) + len(rest)) + struct.pack("<II", len(jb), 0x4E4F534A) + jb + rest


def test_mock_mesh_rejected_outside_dev():
    """hand-mesh のモックの手は、本番（allow_mock=False）では署名が合っていても受け付けない"""
    from app import measure
    from app.errors import ApiError
    for model, ok_in_prod in (("mock", False), ("sam-3d-body", True)):
        raw = _glb_with_extras({"model": model, "joints_mm": {}})
        token = {"mesh_sha256": hashlib.sha256(raw).hexdigest()}
        measure.check_mesh(raw, token, allow_mock=True)          # 開発ではどちらも通る
        if ok_in_prod:
            measure.check_mesh(raw, token, allow_mock=False)
        else:
            with pytest.raises(ApiError) as e:
                measure.check_mesh(raw, token, allow_mock=False)
            assert e.value.code == "MEASUREMENT_INVALID"


def test_hand_side_cannot_change_after_measurement(client):
    """採寸のあとで聞き取りの左右を変えると 409（保存したメッシュを逆向きに正準化してしまうため。11/8）"""
    cid, raw, mesh_id = _setup_case(client)
    client.post(f"/v1/cases/{cid}/consent", headers=H, json={"mesh_consent": True, "consent_text_version": "mesh-consent-2"})
    tok = _token(cid, raw, {"index": {"flexion_deg": {"mcp": 1}}})
    assert client.put(f"/v1/cases/{cid}/measurement", headers=H, json=_measurement(cid, mesh_id, tok)).status_code == 200
    body = {"activity": "draw", "tool_type": "brush", "hand_side": "left", "tool_d_mm": 9.5, "tool_shaft_size": None,
            "tool_shaft_shape": "round", "finger_state": "fist", "donning_by": "helper", "capture_by": "helper"}
    r = client.put(f"/v1/cases/{cid}/requirements", headers=H, json=body)
    assert r.status_code == 409 and r.json()["error"]["code"] == "CONFLICT"
    body["hand_side"] = "right"   # 同じ左右なら保存できる
    assert client.put(f"/v1/cases/{cid}/requirements", headers=H, json=body).status_code == 200


def test_unexpected_error_marks_design_failed(client, monkeypatch):
    """形の計算が ApiError 以外の例外で落ちても、版は running のまま残らず failed になり、次の生成ができる（11/8）"""
    cid, raw, mesh_id = _setup_case(client)
    client.post(f"/v1/cases/{cid}/consent", headers=H, json={"mesh_consent": True, "consent_text_version": "mesh-consent-2"})
    tok = _token(cid, raw, {"index": {"flexion_deg": {"mcp": 1}}})
    assert client.put(f"/v1/cases/{cid}/measurement", headers=H, json=_measurement(cid, mesh_id, tok)).status_code == 200
    import app.pipeline as pl   # make_design の例外は _make で RENDER_FAILED に包まれるので、その後ろ（画像の保存）で落とす
    good = pl._upload_preview

    def boom(*a, **k):
        raise RuntimeError("boom")
    monkeypatch.setattr(pl, "_upload_preview", boom)
    r = client.post(f"/v1/cases/{cid}/designs", headers=H, json={"style": {"color": "#2A9D8F", "pattern": "none"}})
    assert r.status_code == 500 and r.json()["error"]["code"] == "INTERNAL"
    c = client.get(f"/v1/cases/{cid}", headers=H).json()
    d = client.get(f"/v1/cases/{cid}/designs/{c['current_design_id']}", headers=H).json()["design"]
    assert d["status"] == "failed" and d["error"]["code"] == "INTERNAL"
    monkeypatch.setattr(pl, "_upload_preview", good)
    r = client.post(f"/v1/cases/{cid}/designs", headers=H, json={"style": {"color": "#2A9D8F", "pattern": "none"}})
    assert r.status_code == 200 and r.json()["design"]["status"] == "ready"


def test_fixed_params_cannot_be_changed():
    """固定の引数（ベルトの本数・クリップの壁の厚さ）は、AI や画面が変えても R1 で捨て、カタログの既定値で作る（2026-11-08）"""
    from app import validator
    base = [validator.Param("strap_slits", "strap_width_mm", 25, "default", "", 25)]
    params, changed = validator.merge_changes(base, [{"part_id": "strap_slits", "name": "strap_count", "value": 2},
                                                     {"part_id": "c_clip", "name": "wall_mm", "value": 2.6}])
    assert len(changed) == 2
    res = validator.check(params, selected_parts=list(validator.REQUIRED_PARTS), hand={}, requirements={})
    keys = {(p.part_id, p.name) for p in res.params}
    assert ("strap_slits", "strap_count") not in keys and ("c_clip", "wall_mm") not in keys
    assert {(c["part_id"], c["name"]) for c in res.clamped} >= {("strap_slits", "strap_count"), ("c_clip", "wall_mm")}
    assert validator.to_dict(res.params).get("strap_slits", {}).get("strap_count") is None   # 形はカタログの既定（1本）で作る


_REQ_KEYS = ("activity", "tool_type", "hand_side", "tool_d_mm", "tool_shaft_size", "tool_shaft_shape",
             "finger_state", "donning_by", "capture_by", "tools")
_TOOL_KEYS = ("activity", "tool_type", "tool_d_mm", "tool_shaft_size", "tool_shaft_shape")


def _req_body(req: dict) -> dict:
    """スキーマにある項目だけを残す（サーバーが足す notes・assumptions・tool_d_source などを落とす）"""
    out = {k: req[k] for k in _REQ_KEYS if k in req}
    if "tools" in out:
        out["tools"] = [{k: t[k] for k in _TOOL_KEYS if k in t} for t in out["tools"]]
    return out


def test_requirements_with_tools_fills_legacy_from_primary(client):
    cid = client.post("/v1/cases", json={}, headers=H).json()["case_id"]
    r = client.put(f"/v1/cases/{cid}/requirements", headers=H, json={
        "activity": "eat", "tool_type": "spoon", "hand_side": "right", "tool_d_mm": 10, "tool_shaft_size": None,
        "tool_shaft_shape": "flat", "finger_state": "fist", "donning_by": "helper", "capture_by": "helper",
        "tools": [{"activity": "eat", "tool_type": "spoon", "tool_d_mm": 10, "tool_shaft_size": None, "tool_shaft_shape": "flat"},
                  {"activity": "write", "tool_type": "pen", "tool_d_mm": 9, "tool_shaft_size": None, "tool_shaft_shape": "round"}]})
    req = r.json()["requirements"]
    assert r.status_code == 200 and len(req["tools"]) == 2
    assert req["tool_type"] == "pen" and req["tool_d_mm"] == 9 and req["tool_shaft_shape"] == "round"
    assert any(a.startswith("スプーン：平たい柄は") for a in req["assumptions"])
    # 5つは多すぎる
    body = {**_req_body(req), "tools": [_req_body(req)["tools"][1]] * 5}
    assert client.put(f"/v1/cases/{cid}/requirements", headers=H, json=body).status_code == 422  # REQUIREMENTS_INVALID
    # 返ってきた要求をそのまま送り直せる
    assert client.put(f"/v1/cases/{cid}/requirements", headers=H, json=_req_body(req)).status_code == 200


def test_design_with_two_tools_makes_two_clips(client):
    cid, raw, mesh_id = _setup_case(client, tools=[("draw", "brush", 9.5, "round"), ("eat", "spoon", 11.5, "round")])
    _put_measurement(client, cid, raw, mesh_id)
    d = client.post(f"/v1/cases/{cid}/designs", json={}, headers=H).json()["design"]
    atts = d["attachments"]
    assert [a["tool_type"] for a in atts] == ["brush", "spoon"] and atts[0]["primary"]
    assert atts[0]["files"]["preview_stl"] == d["files"]["parts"]["c_clip"]["preview_stl"]
    assert atts[0]["files"]["preview_stl"].endswith("c_clip_brush_70.preview.stl")
    assert atts[1]["files"]["preview_stl"].endswith("c_clip_spoon_60.preview.stl")
    assert all(files.get(a["files"]["preview_stl"]) for a in atts)
    assert d["clip_angle_deg"] == 70


def test_single_tool_design_keeps_old_names(client):
    cid, raw, mesh_id = _setup_case(client)          # 今までどおり道具1つ
    _put_measurement(client, cid, raw, mesh_id)
    d = client.post(f"/v1/cases/{cid}/designs", json={}, headers=H).json()["design"]
    assert len(d["attachments"]) == 1 and d["files"]["parts"]["c_clip"]["preview_stl"].endswith("c_clip_70.preview.stl")


def test_flat_tool_is_left_out_with_notice(client):
    cid, raw, mesh_id = _setup_case(client, tools=[("eat", "spoon", 10, "flat"), ("write", "pen", 9, "round")])
    _put_measurement(client, cid, raw, mesh_id)
    d = client.post(f"/v1/cases/{cid}/designs", json={}, headers=H).json()["design"]
    assert [a["tool_type"] for a in d["attachments"]] == ["pen"] and d["status"] == "needs_attention"
    assert any("太柄スポンジ" in i["description_ja"] for i in d["review"]["unresolved_issues"])


def test_same_tool_twice_gets_distinct_files(client):
    """同じ道具・太さ・角度が2つあっても、プレビュー用STLの名前は重ならない"""
    cid, raw, mesh_id = _setup_case(client, tools=[("write", "pen", 9, "round"), ("write", "pen", 9, "round")])
    _put_measurement(client, cid, raw, mesh_id)
    d = client.post(f"/v1/cases/{cid}/designs", json={}, headers=H).json()["design"]
    names = [a["files"]["preview_stl"] for a in d["attachments"]]
    assert len(names) == 2 and len(set(names)) == 2 and all(files.get(n) for n in names)
    assert [a["print_key"] for a in d["attachments"]] == ["c_clip", "c_clip_a2"]


def test_failed_extra_clip_is_left_out(client, monkeypatch):
    """主でないクリップが R6f に落ちたら、そのクリップだけ外して知らせる"""
    cid, raw, mesh_id = _setup_case(client, tools=[("draw", "brush", 9.5, "round"), ("eat", "spoon", 11.5, "round")])
    _put_measurement(client, cid, raw, mesh_id)
    good = GEOM.make_design

    def bad_extra(*a, **k):
        res = good(*a, **k)
        for ex in res["extra_clips"].values():
            ex["violations"] = [{"rule": "R6f", "message_ja": "クリップの開きが狭すぎます", "fix_hint": None}]
        return res
    monkeypatch.setattr(GEOM, "make_design", bad_extra)
    d = client.post(f"/v1/cases/{cid}/designs", json={}, headers=H).json()["design"]
    assert [a["tool_type"] for a in d["attachments"]] == ["brush"] and d["status"] == "needs_attention"
    assert d["attachments"][0]["files"]["preview_stl"].endswith("c_clip_70.preview.stl")
    assert any(i["description_ja"].startswith("スプーンのクリップは作れませんでした（") for i in d["review"]["unresolved_issues"])


def test_failed_primary_clip_promotes_next(client, monkeypatch):
    """主なクリップが R6f に落ちたら外し、次の取り付け具を主に繰り上げて今までの項目をうめ直す"""
    cid, raw, mesh_id = _setup_case(client, tools=[("draw", "brush", 9.5, "round"), ("eat", "spoon", 11.5, "round")])
    _put_measurement(client, cid, raw, mesh_id)
    good = GEOM.make_design

    def bad_primary(scaled_glb, joints_mm, hand_side, params, *a, **k):
        res = good(scaled_glb, joints_mm, hand_side, params, *a, **k)
        if params["c_clip"]["tool_d_mm"] == 9.5:
            res["violations"] = [{"rule": "R6f", "message_ja": "クリップの開きが狭すぎます", "fix_hint": None}]
        return res
    monkeypatch.setattr(GEOM, "make_design", bad_primary)
    r = client.post(f"/v1/cases/{cid}/designs", json={}, headers=H)
    assert r.status_code == 200, r.text
    d = r.json()["design"]
    atts = d["attachments"]
    assert [a["tool_type"] for a in atts] == ["spoon"] and atts[0]["primary"] and atts[0]["print_key"] == "c_clip"
    assert d["clip_angle_deg"] == 60 and d["status"] == "needs_attention"
    c_clip = {p["name"]: p["value"] for p in d["params"] if p["part_id"] == "c_clip"}
    assert c_clip["tool_d_mm"] == 11.5 and c_clip["angle_deg"] == 60
    assert d["files"]["parts"]["c_clip"]["preview_stl"].endswith("c_clip_60.preview.stl")
    assert any(i["description_ja"].startswith("筆のクリップは作れませんでした（") for i in d["review"]["unresolved_issues"])


def test_unrenderable_extra_clip_is_left_out(client, monkeypatch):
    """主でないクリップだけが描けない（OpenSCAD の失敗）なら、そのクリップだけ外して版を作る"""
    cid, raw, mesh_id = _setup_case(client, tools=[("draw", "brush", 9.5, "round"), ("eat", "spoon", 11.5, "round")])
    _put_measurement(client, cid, raw, mesh_id)
    good = GEOM.make_design

    def fail_spoon(*a, **k):
        if "a2" in (k.get("extra_clips") or {}):
            raise GEOM.GeometryError("RENDER_FAILED")
        return good(*a, **k)
    monkeypatch.setattr(GEOM, "make_design", fail_spoon)
    r = client.post(f"/v1/cases/{cid}/designs", json={}, headers=H)
    assert r.status_code == 200, r.text
    d = r.json()["design"]
    assert [a["tool_type"] for a in d["attachments"]] == ["brush"] and d["status"] == "needs_attention"
    assert any(i["description_ja"] == "スプーンのクリップは作れませんでした（形を描けませんでした）"
               for i in d["review"]["unresolved_issues"])


def test_refine_angle_keeps_all_attachments(client):
    """取り付け具が2つの版の角度を変えても、取り付け具の一覧は残り、主な取り付け具が今までの項目とそろう"""
    cid, raw, mesh_id = _setup_case(client, tools=[("draw", "brush", 9.5, "round"), ("eat", "spoon", 11.5, "round")])
    _put_measurement(client, cid, raw, mesh_id)
    d = client.post(f"/v1/cases/{cid}/designs", json={}, headers=H).json()["design"]
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H, json={"clip_angle_deg": 80})
    assert r.status_code == 200, r.text
    d2 = r.json()["design"]
    atts = d2["attachments"]
    assert [a["tool_type"] for a in atts] == ["brush", "spoon"] and atts[0]["angle_deg"] == 80 == d2["clip_angle_deg"]
    assert atts[0]["files"]["preview_stl"] == d2["files"]["parts"]["c_clip"]["preview_stl"]
    assert atts[0]["files"]["preview_stl"].endswith("c_clip_brush_80.preview.stl")
    assert f"/designs/{d2['design_id']}/" in atts[1]["files"]["preview_stl"] and files.get(atts[1]["files"]["preview_stl"])
    assert files.get(d2["files"]["parts"]["cover"]["preview_stl"]) == files.get(d["files"]["parts"]["cover"]["preview_stl"])


# ---------------------------------------------------------------- 足す・取り付け具ごとに直す（ADR-0014 §4）
def _design_with_tools(client, tools) -> tuple[str, dict]:
    """道具の一覧でケースを作り、採寸して、最初の版を作る"""
    cid, raw, mesh_id = _setup_case(client, tools=tools)
    _put_measurement(client, cid, raw, mesh_id)
    r = client.post(f"/v1/cases/{cid}/designs", json={}, headers=H)
    assert r.status_code == 200, r.text
    return cid, r.json()["design"]


def _request_review(client, cid: str, design_id: str) -> None:
    """test_review_and_approval と同じ手順で OT に頼む"""
    db.set("therapists/ot@example.com", {"name": "OT役"})
    db.update(f"cases/{cid}", {"demo": False})
    r = client.post(f"/v1/cases/{cid}/review-request", headers=H, json={"reviewer_email": "ot@example.com", "design_id": design_id})
    assert r.status_code == 200, r.text


def test_add_attachment_keeps_cover_and_resets_approval(client):
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round")])
    cover_before = files.get(d["files"]["parts"]["cover"]["preview_stl"])
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H,
                    json={"add_attachment": {"activity": "eat", "tool_type": "spoon", "tool_d_mm": 12.0,
                                             "tool_shaft_size": None, "tool_shaft_shape": "round"}})
    n = r.json()["design"]
    assert n["design_id"] != d["design_id"] and [a["id"] for a in n["attachments"]] == ["a1", "a2"]
    assert db.get(f"cases/{cid}/designs/{n['design_id']}")["cover_shell_sha256"] == db.get(f"cases/{cid}/designs/{d['design_id']}")["cover_shell_sha256"]
    assert files.get(n["files"]["parts"]["cover"]["preview_stl"]) == cover_before
    assert n["files"]["parts"]["cover"]["preview_stl"] != d["files"]["parts"]["cover"]["preview_stl"]   # 新しい版の場所に置く
    assert n["approval"]["status"] == "none"
    assert [t["tool_type"] for t in db.get(f"cases/{cid}")["requirements"]["tools"]] == ["brush", "spoon"]


def test_add_attachment_refused_without_new_version(client):
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round")] * 1)
    for bad in ({"tool_d_mm": 25.0, "tool_shaft_shape": "round"}, {"tool_d_mm": 9.0, "tool_shaft_shape": "flat"}):
        r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H,
                        json={"add_attachment": {"activity": "write", "tool_type": "pen", "tool_shaft_size": None, **bad}})
        assert r.status_code == 400
    assert db.get(f"cases/{cid}")["current_design_id"] == d["design_id"]
    assert len(db.get(f"cases/{cid}")["requirements"]["tools"]) == 1


def test_fifth_attachment_is_refused(client):
    cid, d = _design_with_tools(client, [("draw", "brush", 8, "round"), ("write", "pen", 9, "round"),
                                         ("eat", "spoon", 11, "round"), ("other", "brush", 10, "round")])
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H,
                    json={"add_attachment": {"activity": "write", "tool_type": "pen", "tool_d_mm": 12, "tool_shaft_size": None, "tool_shaft_shape": "round"}})
    assert r.status_code == 400 and db.get(f"cases/{cid}")["current_design_id"] == d["design_id"]


def _cover_bytes(d: dict) -> bytes:
    return files.get(d["files"]["parts"]["cover"]["preview_stl"])


def test_angle_and_thickness_change_one_attachment(client):
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round"), ("write", "pen", 8.5, "round")])
    n = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H,
                    json={"clip_angle_deg": 80, "attachment_id": "a2"}).json()["design"]
    assert [a["angle_deg"] for a in n["attachments"]] == [70, 80] and n["clip_angle_deg"] == 70
    m = client.post(f"/v1/cases/{cid}/designs/{n['design_id']}/refine", headers=H,
                    json={"tool_d_mm": 9.0, "attachment_id": "a2"}).json()["design"]
    assert m["attachments"][1]["tool_d_mm"] == 9.0
    assert db.get(f"cases/{cid}")["requirements"]["tools"][1]["tool_d_mm"] == 9.0
    # 取り付け具だけを直した版は、カバーのプレビュー用STLの中身が前の版と同じ（描き直しても中身は変えない）
    assert _cover_bytes(n) == _cover_bytes(d) and _cover_bytes(m) == _cover_bytes(d)
    p = client.post(f"/v1/cases/{cid}/designs/{m['design_id']}/refine", headers=H,
                    json={"clip_angle_deg": 60}).json()["design"]   # 主な取り付け具の角度
    assert _cover_bytes(p) == _cover_bytes(d)


def test_cover_param_change_renders_new_cover(client):
    """カバーの値を変えた版は、カバーのプレビュー用STLを描き直したものにする（前の版のものを使わない）"""
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round"), ("eat", "spoon", 11.5, "round")])
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H,
                    json={"param_changes": [{"part_id": "cover", "name": "cover_thickness_mm", "value": 3.0}]})
    assert r.status_code == 200, r.text
    n = r.json()["design"]
    assert _cover_bytes(n) != _cover_bytes(d)


def test_duplicate_tool_names_are_distinct(client):
    cid, d = _design_with_tools(client, [("write", "pen", 8.5, "round")])
    n = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H,
                    json={"add_attachment": {"activity": "write", "tool_type": "pen", "tool_d_mm": 12.0, "tool_shaft_size": None, "tool_shaft_shape": "round"}}).json()["design"]
    names = [a["files"]["preview_stl"].rsplit("/", 1)[1] for a in n["attachments"]]
    assert len(set(names)) == 2 and all("_d" in x for x in names)


def test_refine_old_design_without_attachments(client):
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round")])
    doc = db.get(f"cases/{cid}/designs/{d['design_id']}")
    doc.pop("attachments")                      # この変更の前に作った版
    db.set(f"cases/{cid}/designs/{d['design_id']}", doc)
    n = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H, json={"clip_angle_deg": 60}).json()["design"]
    assert len(n["attachments"]) == 1 and n["clip_angle_deg"] == 60


def test_add_after_review_request_resets_case(client):
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round")])
    _request_review(client, cid, d["design_id"])     # 既存の test_review_and_approval と同じ手順
    n = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H,
                    json={"add_attachment": {"activity": "eat", "tool_type": "spoon", "tool_d_mm": 12, "tool_shaft_size": None, "tool_shaft_shape": "round"}}).json()["design"]
    assert n["approval"]["status"] == "none" and db.get(f"cases/{cid}")["status"] == "previewing"


def test_add_attachment_render_failure_keeps_parent(client, monkeypatch):
    """足したクリップが R6f に落ちたら、版を作らず RENDER_FAILED（details に検査の名前）。要求の道具も増えない"""
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round")])
    good = GEOM.make_design

    def bad_extra(*a, **k):
        res = good(*a, **k)
        for ex in res["extra_clips"].values():
            ex["violations"] = [{"rule": "R6f", "message_ja": "クリップの開きが狭すぎます", "fix_hint": None}]
        return res
    monkeypatch.setattr(GEOM, "make_design", bad_extra)
    before = {i for i, _ in db.list(f"cases/{cid}/designs")}
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H,
                    json={"add_attachment": {"activity": "eat", "tool_type": "spoon", "tool_d_mm": 12, "tool_shaft_size": None, "tool_shaft_shape": "round"}})
    assert r.status_code == 500 and r.json()["error"]["code"] == "RENDER_FAILED"
    assert any(x.get("rule") == "R6f" for x in r.json()["error"]["details"])
    assert {i for i, _ in db.list(f"cases/{cid}/designs")} == before
    case = db.get(f"cases/{cid}")
    assert case["current_design_id"] == d["design_id"] and case["status"] == "previewing" and len(case["requirements"]["tools"]) == 1


def test_add_attachment_unrenderable_keeps_parent(client, monkeypatch):
    """足したクリップが描けない（OpenSCAD の失敗）ときも、版を作らない"""
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round")])
    good = GEOM.make_design

    def fail_extra(*a, **k):
        if k.get("extra_clips"):
            raise GEOM.GeometryError("RENDER_FAILED")
        return good(*a, **k)
    monkeypatch.setattr(GEOM, "make_design", fail_extra)
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H,
                    json={"add_attachment": {"activity": "eat", "tool_type": "spoon", "tool_d_mm": 12, "tool_shaft_size": None, "tool_shaft_shape": "round"}})
    assert r.status_code == 500 and r.json()["error"]["code"] == "RENDER_FAILED"
    assert len(db.list(f"cases/{cid}/designs")) == 1 and db.get(f"cases/{cid}")["current_design_id"] == d["design_id"]


def test_unknown_attachment_id_is_refused(client):
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round")])
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H, json={"clip_angle_deg": 80, "attachment_id": "a9"})
    assert r.status_code == 400 and r.json()["error"]["code"] == "INVALID_ARGUMENT"
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H, json={"tool_d_mm": 2.0})
    assert r.status_code == 400
    assert db.get(f"cases/{cid}")["current_design_id"] == d["design_id"]


def test_user_tool_d_minimum_is_3_5(client):
    """人が入れる柄の太さの下限は、要求（requirements.schema.json）と同じ 3.5mm（直す・足すとも）"""
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round")])
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H, json={"tool_d_mm": 3.2})
    assert r.status_code == 400 and r.json()["error"]["code"] == "INVALID_ARGUMENT"
    assert "3.5" in r.json()["error"]["message"]
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H,
                    json={"add_attachment": {"activity": "write", "tool_type": "pen", "tool_d_mm": 3.2,
                                             "tool_shaft_size": None, "tool_shaft_shape": "round"}})
    assert r.status_code == 400
    assert db.get(f"cases/{cid}")["current_design_id"] == d["design_id"]
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H, json={"tool_d_mm": 3.5})
    assert r.status_code == 200, r.text


def test_old_case_without_tools_keeps_estimated_thickness(client):
    """tools のない古い要求で、太さが区分から推定した値なら、足したあとも最初の道具は推定のまま（知らせも残る）"""
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round")])
    case = db.get(f"cases/{cid}")
    req = {k: v for k, v in case["requirements"].items() if k != "tools"}   # この変更の前に保存した要求
    req.update(tool_d_mm=8.5, tool_d_source="category", tool_shaft_size="medium",
               assumptions=["道具の太さは推定です。刷る前に太さを確かめてください"])
    db.update(f"cases/{cid}", {"requirements": {**req, "__replace__": True}})
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H,
                    json={"add_attachment": {"activity": "eat", "tool_type": "spoon", "tool_d_mm": 12.0,
                                             "tool_shaft_size": None, "tool_shaft_shape": "round"}})
    assert r.status_code == 200, r.text
    new_req = db.get(f"cases/{cid}")["requirements"]
    assert [t["tool_d_source"] for t in new_req["tools"]] == ["category", "user"]
    assert any("推定" in a for a in new_req["tools"][0]["assumptions"])
    assert any(a.startswith("筆：") and "推定" in a for a in new_req["assumptions"])


def test_thickness_change_on_primary_updates_legacy(client):
    """主な取り付け具の太さを直すと、要求の今までの項目と params の c_clip（値と基準値）も直る"""
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round"), ("eat", "spoon", 11.5, "round")])
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H, json={"tool_d_mm": 10.0})
    assert r.status_code == 200, r.text
    n = r.json()["design"]
    tool_d = next(p for p in n["params"] if p["part_id"] == "c_clip" and p["name"] == "tool_d_mm")
    assert tool_d["value"] == 10.0 and tool_d["baseline"] == 10.0 and n["attachments"][0]["tool_d_mm"] == 10.0
    req = db.get(f"cases/{cid}")["requirements"]
    assert req["tool_d_mm"] == 10.0 and req["tools"][0]["tool_d_mm"] == 10.0 and req["tools"][1]["tool_d_mm"] == 11.5


def test_text_refine_on_extra_attachment_changes_only_it(client):
    """言葉の微調整を主でない取り付け具に向けると、その取り付け具の角度だけが変わる"""
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round"), ("eat", "spoon", 11.5, "round")])
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H,
                    json={"instruction": "クリップを立てて", "attachment_id": "a2"})
    assert r.status_code == 200, r.text
    n = r.json()["design"]
    assert [a["angle_deg"] for a in n["attachments"]] == [70, 70] and n["clip_angle_deg"] == 70
    # 数値の変更でカバーの値は全部に効く
    r = client.post(f"/v1/cases/{cid}/designs/{n['design_id']}/refine", headers=H,
                    json={"param_changes": [{"part_id": "cover", "name": "cover_thickness_mm", "value": 3.0}], "attachment_id": "a2"})
    assert r.status_code == 200, r.text
    m = r.json()["design"]
    assert next(p for p in m["params"] if p["name"] == "cover_thickness_mm")["value"] == 3.0
    assert [a["angle_deg"] for a in m["attachments"]] == [70, 70]


def test_attachments_of_old_design_uses_first_round_tool():
    """取り付け具のない古い版は、params と要求の今までの項目から主な取り付け具を作る（ID と位置は最初の丸い柄の道具）"""
    from app import pipeline
    tools = [{"activity": "eat", "tool_type": "spoon", "tool_d_mm": 10, "tool_shaft_size": None, "tool_shaft_shape": "flat"},
             {"activity": "write", "tool_type": "pen", "tool_d_mm": 9, "tool_shaft_size": None, "tool_shaft_shape": "round"}]
    req = {"activity": "write", "tool_type": "pen", "tool_d_mm": 9, "tool_shaft_size": None, "tool_shaft_shape": "round",
           "tools": tools}
    design = {"params": [{"part_id": "c_clip", "name": "tool_d_mm", "value": 9.0, "source": "interview", "baseline": 9.0},
                         {"part_id": "c_clip", "name": "angle_deg", "value": 80, "source": "user", "reason_ja": "画面で角度を選びました"}]}
    atts = pipeline._attachments_of(design, req)
    assert [(a["id"], a["tool_index"], a["primary"]) for a in atts] == [("a2", 1, True)]
    assert atts[0]["tool_d_mm"] == 9.0 and atts[0]["angle_deg"] == 80 and atts[0]["angle_source"] == "user"


def test_primary_thickness_change_survives_regeneration(client):
    """主な取り付け具の太さを直したあとで作り直しても、直した太さのクリップになる（要求の値が正）"""
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round")])
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H, json={"tool_d_mm": 12.0})
    assert r.status_code == 200, r.text
    r = client.post(f"/v1/cases/{cid}/designs", json={}, headers=H)
    assert r.status_code == 200, r.text
    g = r.json()["design"]
    tool_d = next(p for p in g["params"] if p["part_id"] == "c_clip" and p["name"] == "tool_d_mm")
    assert tool_d["value"] == 12.0 and g["attachments"][0]["tool_d_mm"] == 12.0


def test_attachment_id_must_be_string_and_not_with_style(client):
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round")])
    for body in ({"clip_angle_deg": 80, "attachment_id": ["a1"]}, {"clip_angle_deg": 80, "attachment_id": {"x": 1}},
                 {"style": {"color": "#E76F51"}, "attachment_id": "a1"}):
        r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H, json=body)
        assert r.status_code == 400 and r.json()["error"]["code"] == "INVALID_ARGUMENT", (body, r.text)
    assert db.get(f"cases/{cid}")["current_design_id"] == d["design_id"]


def test_prepare_print_has_one_file_per_attachment(client):
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round"), ("eat", "spoon", 12.0, "round")])
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/prepare-print", headers=H)
    assert r.status_code == 200, r.text
    pr = r.json()["files"]["print"]
    assert set(pr) == {"cover", "c_clip", "c_clip_a2"}
    assert pr["c_clip"].endswith("c_clip_brush_70.stl") and pr["c_clip_a2"].endswith("c_clip_spoon_60.stl")
    assert all(files.get(k) for k in pr.values())


def test_single_attachment_print_names_unchanged(client):
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round")])
    pr = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/prepare-print", headers=H).json()["files"]["print"]
    assert set(pr) == {"cover", "c_clip"} and pr["c_clip"].endswith("c_clip_70.stl")


def test_print_violation_on_extra_clip_is_render_failed(client, monkeypatch):
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round"), ("eat", "spoon", 12.0, "round")])
    good = GEOM.make_design

    def bad(*a, **k):
        res = good(*a, **k)
        if k.get("quality") == "print":
            for ex in res["extra_clips"].values():
                ex["violations"] = [{"rule": "R6f", "message_ja": "x", "fix_hint": None}]
        return res
    monkeypatch.setattr(GEOM, "make_design", bad)
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/prepare-print", headers=H)
    assert r.status_code == 500 and r.json()["error"]["code"] == "RENDER_FAILED"
