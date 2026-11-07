import io
import json
import os
import sys
from pathlib import Path

import numpy as np
import pytest

os.environ["HAND_MESH_BACKEND"] = "mock"
os.environ["AUTH_MODE"] = "dev"
os.environ["STORE_BACKEND"] = "local"
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from fastapi.testclient import TestClient  # noqa: E402
from PIL import Image  # noqa: E402

import angles  # noqa: E402
import config  # noqa: E402
import fusion  # noqa: E402
import glbio  # noqa: E402
import result_token  # noqa: E402
import store  # noqa: E402
from app import app  # noqa: E402
from backends import MockBackend  # noqa: E402

CASE = "c_test"
UID = "u_test"


@pytest.fixture()
def local(tmp_path):
    """テストごとに空の .localstore を使い、持ち主・同意の記録を置く。"""
    st = store.LocalStore(tmp_path)
    st._put_doc(f"cases/{CASE}", {"owner_uid": UID, "mesh_consent_at": "2026-11-08T00:00:00Z",
                                  "consent_text_version": config.CONSENT_VERSION})
    store.reset_store(st)
    yield st
    store.reset_store(None)


@pytest.fixture(scope="module")
def client():
    with TestClient(app) as c:
        yield c


def _jpeg(color, size=(64, 48)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", size, color).save(buf, format="JPEG", quality=80)
    return buf.getvalue()


def _post(client, meta, n_frames=2, headers=None):
    files = {"meta": (None, json.dumps(meta), "application/json")}
    for i in range(n_frames):
        files[f"frame_{i}"] = (f"frame_{i}.jpg", _jpeg((200, 150 + i * 20, 120)), "image/jpeg")
    return client.post("/v1/hand", files=files, headers=headers if headers is not None else {"X-User": UID})


META = {"case_id": CASE, "hand_side": "right",
        "frames": [{"name": "frame_0", "view": "thumb_side"}, {"name": "frame_1", "view": "top"}]}


def test_healthz(client):
    body = client.get("/healthz").json()
    assert body["ok"] is True and body["backend"] == "mock" and body["model_loaded"] is True


def test_angles_endpoint_gone(client):
    assert client.post("/v1/angles").status_code == 410


def test_requires_user(client, local):
    assert _post(client, META, headers={}).json()["error"]["code"] == "UNAUTHENTICATED"


def test_consent_required(client, local):
    local._put_doc(f"cases/{CASE}", {"owner_uid": UID, "mesh_consent_at": None, "consent_text_version": config.CONSENT_VERSION})
    r = _post(client, META)
    assert r.status_code == 422 and r.json()["error"]["code"] == "CONSENT_REQUIRED"


def test_consent_old_version(client, local):
    local._put_doc(f"cases/{CASE}", {"owner_uid": UID, "mesh_consent_at": "x", "consent_text_version": "mesh-consent-1"})
    assert _post(client, META).json()["error"]["code"] == "CONSENT_REQUIRED"


def test_not_owner(client, local):
    assert _post(client, META, headers={"X-User": "someone"}).status_code == 403


@pytest.mark.parametrize("side", ["right", "left"])
def test_success_and_stored_glb(client, local, side):
    r = _post(client, {**META, "hand_side": side})
    assert r.status_code == 200, r.text
    b = r.json()
    assert b["method"] == "mesh_recovery" and b["fusion"] == "median_params" and b["frames_used"] == 2
    assert b["mesh_id"].startswith("hm_") and b["mesh_stats"]["watertight"] is True
    assert set(b["fingers"]) == {"index", "middle", "ring", "pinky"}
    for f in b["fingers"].values():
        assert set(f["flexion_deg"]) == {"mcp", "pip", "dip"} and all(0 < v < 120 for v in f["flexion_deg"].values())
    # 保存したGLB：ハッシュが応答と合い、extras に関節が入っている
    path = local.root / "storage" / "cases" / CASE / "hand" / "raw" / f"{b['mesh_id']}.glb"
    data = path.read_bytes()
    assert result_token.bytes_sha256(data) == b["mesh_sha256"]
    ex = glbio.read_extras(data)
    assert ex["joints_mm"] == b["joints_mm"] and ex["hand_side"] == side and ex["units"] == "mm"
    mesh, _ = glbio.read_glb(data)
    assert mesh.is_watertight and len(mesh.vertices) == b["mesh_stats"]["vertices"]
    # 手の座標系：原点は手首、人差し指と小指の付け根は y がそろい、x は人差し指→小指で増える
    j = b["joints_mm"]
    assert j["wrist"] == [0.0, 0.0, 0.0]
    assert j["index"][0][0] < j["pinky"][0][0] and abs(j["index"][0][1] - j["pinky"][0][1]) < 1e-6
    # トークン：生成APIと同じ確かめ方で通る
    t = result_token.verify_token(config.hmac_key(), b["result_token"], CASE, b["fingers"], b["mesh_sha256"])
    assert t["case_id"] == CASE and "." not in t["ts"] and t["ts"].endswith("Z")
    # 回数の記録
    day = store._today()
    assert local.get_doc(f"usage/{day}")["mesh_requests"] == 1


def test_left_is_mirror_of_right(client, local):
    """左手は鏡像：指先は手のひら側に曲がる。右手と左手で、手の座標系の z の符号が逆になる（§8.1）。"""
    r = _post(client, {**META, "hand_side": "right"}).json()["joints_mm"]
    l = _post(client, {**META, "hand_side": "left"}).json()["joints_mm"]
    for f in ("index", "middle", "ring", "pinky"):
        assert r[f][3][2] == pytest.approx(-l[f][3][2], abs=1e-3)
        assert r[f][3][0] == pytest.approx(l[f][3][0], abs=1e-3)


def test_rate_limit(client, local, monkeypatch):
    monkeypatch.setattr(config, "PER_USER_DAILY", 1)
    assert _post(client, META).status_code == 200
    r = _post(client, META)
    assert r.status_code == 429 and r.json()["error"]["code"] == "RATE_LIMITED"


def test_generation_disabled(client, local):
    local._put_doc("settings/runtime", {"generation_enabled": False})
    r = _post(client, META)
    assert r.status_code == 503 and r.json()["error"]["code"] == "GENERATION_DISABLED"


def test_cors_localhost(client):
    r = client.options("/v1/hand", headers={"Origin": "http://localhost:5173",
                                            "Access-Control-Request-Method": "POST",
                                            "Access-Control-Request-Headers": "x-user"})
    assert r.headers.get("access-control-allow-origin") == "http://localhost:5173"
    r = client.options("/v1/hand", headers={"Origin": "https://evil.example.com", "Access-Control-Request-Method": "POST"})
    assert "access-control-allow-origin" not in r.headers


def test_bad_requests(client, local):
    assert _post(client, {**META, "hand_side": "both"}).status_code == 400
    assert _post(client, META, n_frames=0).json()["error"]["code"] == "INVALID_ARGUMENT"
    assert _post(client, {**META, "case_id": "c.x"}).status_code == 400
    r = client.post("/v1/hand", files={"meta": (None, json.dumps(META)), "frame_0": ("a.jpg", b"not a jpeg", "image/jpeg")},
                    headers={"X-User": UID})
    assert r.status_code == 400


def test_sam3d_strict_missing_weights(client, local, monkeypatch, tmp_path):
    """HAND_MESH_BACKEND=sam3d で重みがない：モックに代えず 503 MESH_UNAVAILABLE。"""
    from backends import BackendManager

    monkeypatch.setenv("HAND_MESH_CHECKPOINT_DIR", str(tmp_path))
    mgr = BackendManager("sam3d")
    mgr.start(background=False)
    old = client.app.state.backends
    client.app.state.backends = mgr
    try:
        assert client.get("/healthz").json()["ok"] is False
        r = _post(client, META)
        assert r.status_code == 503 and r.json()["error"]["code"] == "MESH_UNAVAILABLE"
    finally:
        client.app.state.backends = old


# --- 合成・トークン・角度の計算 -------------------------------------------------


def test_token_roundtrip_and_tamper():
    fingers = {"index": {"flexion_deg": {"mcp": 1.0, "pip": 2.0, "dip": 3.0}}}
    tok = result_token.make_token("k", "c_1", fingers, "ab" * 32, ts="2026-11-08T10:15:00Z")
    assert tok.count(".") == 5
    result_token.verify_token("k", tok, "c_1", fingers, "ab" * 32)
    with pytest.raises(ValueError):
        result_token.verify_token("other", tok, "c_1")
    with pytest.raises(ValueError):
        result_token.verify_token("k", tok, "c_2")
    with pytest.raises(ValueError):
        result_token.verify_token("k", tok, "c_1", {"index": {"flexion_deg": {"mcp": 9.0, "pip": 2.0, "dip": 3.0}}})
    with pytest.raises(ValueError):
        result_token.verify_token("k", tok, "c_1", mesh_sha256="cd" * 32)


def test_fusion_drops_outlier_frame():
    """1枚だけ大きく外れたフレームは外して、もう一度まとめる。"""
    b = MockBackend()
    frames = b.infer_params([np.zeros((4, 4, 3))] * 5, "right")
    bad = dict(frames[2])
    bad["hand"] = bad["hand"] + 70.0
    bad["kps"] = angles.synthetic_right_keypoints(MockBackend._vec_to_angles(bad["hand"]))
    frames[2] = bad
    fused = fusion.fuse(frames, b.forward)
    assert fused.frames_used == 4 and fused.frames_dropped == 1 and "MESH_OUTLIER_FRAMES" in fused.warnings


def test_fusion_no_hand():
    with pytest.raises(fusion.FusionError):
        fusion.fuse([None, None], MockBackend().forward)


def test_glb_extras_roundtrip():
    v = np.array([[0, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1]], float)
    f = np.array([[0, 2, 1], [0, 1, 3], [0, 3, 2], [1, 2, 3]])
    data = glbio.write_glb(v, f, {"joints_mm": {"wrist": [0, 0, 0]}, "x": 1})
    assert glbio.read_extras(data) == {"joints_mm": {"wrist": [0, 0, 0]}, "x": 1}


def _rand_rot(seed):
    q, _ = np.linalg.qr(np.random.default_rng(seed).normal(size=(3, 3)))
    return q * np.sign(np.linalg.det(q))


@pytest.mark.parametrize("seed", [0, 1, 2])
def test_angle_roundtrip(seed):
    """順運動学 → どの向きのキーポイントでも同じ角度（反りすぎを含む）。"""
    want = {"index": {"mcp": 10.0, "pip": 85.0, "dip": -12.0},
            "middle": {"mcp": 45.0, "pip": 60.0, "dip": 20.0},
            "ring": {"mcp": 70.0, "pip": 30.0, "dip": 5.0},
            "pinky": {"mcp": -15.0, "pip": 100.0, "dip": 40.0}}
    kps = angles.synthetic_right_keypoints(want, _rand_rot(seed))
    got = angles.frame_flexion(angles.to_canonical_left(kps))
    for f in want:
        for j in want[f]:
            assert got[f][j] == pytest.approx(want[f][j], abs=1e-6)
