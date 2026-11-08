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
os.environ.update({"AUTH_MODE": "dev", "STORE_BACKEND": "local", "LOCAL_STORE_DIR": TMP, "GEMINI_MODE": "mock"})
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
                    {"part_id": "strap_slits", "name": "strap_width_mm", "value": 25, "source": "default"},
                    {"part_id": "strap_slits", "name": "strap_count", "value": 1, "source": "default"},
                    {"part_id": "strap_slits", "name": "strap_thickness_mm", "value": 2.0, "source": "default"},
                    {"part_id": "c_clip", "name": "tool_d_mm", "value": 8.5, "source": "interview"},
                    {"part_id": "c_clip", "name": "wall_mm", "value": 2.0, "source": "default"},
                    {"part_id": "c_clip", "name": "opening_ratio", "value": 0.75, "source": "default"},
                    {"part_id": "c_clip", "name": "height_mm", "value": 12.0, "source": "default"},
                    {"part_id": "c_clip", "name": "angle_deg", "value": 70, "source": "rule"},
                    {"part_id": "c_clip", "name": "grip_ribs", "value": True, "source": "default"},
                    {"part_id": "c_clip", "name": "count", "value": 1, "source": "default"},
                    {"part_id": "c_clip", "name": "tpu_sleeve", "value": False, "source": "default"},
                ],
                "warnings": []}

    calls = []

    def make_design(scaled_glb, joints_mm, hand_side, params, workdir, cache, quality="preview", parts=("cover", "c_clip")):
        calls.append({"params": params, "quality": quality, "parts": parts})
        out = {}
        for p in parts:
            path = Path(workdir) / f"{p}_{quality}.stl"
            trimesh.creation.box((10, 10, 10)).export(path)
            out[p] = str(path)
        views = []
        for name in ("front", "side", "top", "iso"):
            path = Path(workdir) / f"{name}.png"
            Image.new("RGB", (32, 24), (200, 200, 200)).save(path)
            views.append(str(path))
        return {"files": out, "views": views, "cover_shell_sha256": "ab" * 32, "checks": [], "violations": [],
                "timings_ms": {"openscad": 5}}

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


def _setup_case(client) -> tuple[str, bytes, str]:
    r = client.post("/v1/cases", json={"title": "筆のカバー"}, headers=H)
    assert r.status_code == 201, r.text
    cid = r.json()["case_id"]
    r = client.put(f"/v1/cases/{cid}/requirements", headers=H, json={
        "activity": "draw", "tool_type": "brush", "hand_side": "right", "tool_d_mm": 9.5, "tool_shaft_size": None,
        "tool_shaft_shape": "round", "finger_state": "fist", "donning_by": "helper", "capture_by": "helper"})
    assert r.status_code == 200, r.text
    assert r.json()["case_status"] == "measuring"
    raw = (FIX / "hand_raw_right.glb").read_bytes()
    mesh_id = "hm_0123456789ab"
    files.put(f"cases/{cid}/hand/raw/{mesh_id}.glb", raw)
    return cid, raw, mesh_id


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
