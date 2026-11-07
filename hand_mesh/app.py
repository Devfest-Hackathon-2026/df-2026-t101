"""hand-mesh：切り抜いたフレームから、1つの手の3Dメッシュを作る（docs/api.md §4、ADR-0010）。

動かし方：.venv\\Scripts\\python -m uvicorn app:app --port 8081
画像はメモリの中だけで扱い、ディスク・Storage・ログには書かない。
残すのは、未補正の手のメッシュ（cases/{case_id}/hand/raw/{mesh_id}.glb）と、回数・費用だけ。
"""

from __future__ import annotations

import asyncio
import io
import json
import logging
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone

import numpy as np
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from PIL import Image, ImageOps
from starlette.concurrency import run_in_threadpool
from starlette.datastructures import UploadFile

import auth
import config
import fusion
import glbio
import result_token
import store
from backends import BackendManager, BackendUnavailable

logging.basicConfig(level="INFO", format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("hand_mesh")


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str, retryable: bool = False):
        self.status, self.code, self.message, self.retryable = status, code, message, retryable


def _err(status: int, code: str, message: str, retryable: bool) -> JSONResponse:
    body = {"error": {"code": code, "message": message, "retryable": retryable,
                      "request_id": "req_" + uuid.uuid4().hex[:6]}}
    return JSONResponse(status_code=status, content=body)


@asynccontextmanager
async def lifespan(app: FastAPI):
    config.hmac_key()  # 鍵がなければ（dev 以外で）起動しない
    mgr = BackendManager()
    app.state.backends = mgr
    mgr.start(background=True)
    yield


app = FastAPI(title="hand-mesh", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=config.CORS_REGEX,
    allow_origins=config.EXTRA_ORIGINS,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)


@app.exception_handler(ApiError)
async def _api_error(_: Request, e: ApiError):
    return _err(e.status, e.code, e.message, e.retryable)


@app.exception_handler(RequestValidationError)
async def _validation_error(_: Request, e: RequestValidationError):
    return _err(400, "INVALID_ARGUMENT", "リクエストの形が正しくありません。", False)


@app.get("/health")
@app.get("/healthz")  # 手元用。Cloud Run では /healthz が予約されていて届かない
async def healthz(request: Request):
    return request.app.state.backends.health()


@app.get("/ready")
async def ready(request: Request):
    # Cloud Run の起動の確認（startup probe）。モデルを読み終わるまで 503 を返すので、
    # 0台から起きたときの最初のリクエストは、503 で返されずに読み込みが終わるまで待つ
    if request.app.state.backends.settled():
        return {"ready": True}
    return JSONResponse(status_code=503, content={"ready": False})


@app.post("/v1/angles")
async def angles_gone():
    # 前の版の窓口。角度だけでなくメッシュも返す /v1/hand に置き換えた
    raise ApiError(410, "GONE", "この窓口は使えません。/v1/hand を使ってください。", False)


def _decode_jpeg(data: bytes) -> np.ndarray:
    with Image.open(io.BytesIO(data)) as im:
        im = ImageOps.exif_transpose(im)
        return np.asarray(im.convert("RGB"), dtype=np.uint8).copy()


async def _read_form(request: Request):
    ctype = request.headers.get("content-type", "")
    if not ctype.startswith("multipart/form-data"):
        raise ApiError(400, "INVALID_ARGUMENT", "multipart/form-data で送ってください。")
    form = await request.form(max_files=config.MAX_FRAMES + 2)
    try:
        raw_meta = form.get("meta")
        if isinstance(raw_meta, UploadFile):
            raw_meta = (await raw_meta.read()).decode("utf-8")
        try:
            meta = json.loads(raw_meta or "")
            if not isinstance(meta, dict):
                raise ValueError
        except (ValueError, UnicodeDecodeError):
            raise ApiError(400, "INVALID_ARGUMENT", "meta（JSON）がありません、または読めません。")
        names = [f"frame_{i}" for i in range(config.MAX_FRAMES)]
        if [k for k in form.keys() if k.startswith("frame_") and k not in names]:
            raise ApiError(400, "INVALID_ARGUMENT", f"フレームは最大{config.MAX_FRAMES}枚（frame_0〜frame_7）です。")
        images = []
        for name in names:
            part = form.get(name)
            if part is None:
                continue
            data = await part.read() if isinstance(part, UploadFile) else None
            if not data:
                raise ApiError(400, "INVALID_ARGUMENT", f"{name} は画像ファイルで送ってください。")
            if len(data) > config.MAX_FRAME_BYTES:
                raise ApiError(400, "INVALID_ARGUMENT", f"{name} が大きすぎます（1枚{config.MAX_FRAME_BYTES // 1000}KBまで）。")
            try:
                images.append(_decode_jpeg(data))
            except Exception:
                raise ApiError(400, "INVALID_ARGUMENT", f"{name} を画像として読めません。")
            del data
    finally:
        await form.close()
    return meta, images


def _check_case(case_id: str, uid: str) -> None:
    """持ち主であることと、今の版の同意の記録があることを確かめる。"""
    case = store.get_store().get_doc(f"cases/{case_id}")
    if case is None:
        raise ApiError(404, "NOT_FOUND", "ケースが見つかりません。")
    if case.get("owner_uid") != uid:
        raise ApiError(403, "PERMISSION_DENIED", "このケースを使う権限がありません。")
    if not case.get("mesh_consent_at") or case.get("consent_text_version") != config.CONSENT_VERSION:
        raise ApiError(422, "CONSENT_REQUIRED", "映像を送ること・手の形の3Dデータを保存することへの同意が記録されていません。同意の画面からやり直してください。")


def _compute(backend, images, hand_side):
    """推定 → 合成 → 切り出し（GPU を使う重い所。スレッドで動かす）。"""
    frames = backend.infer_params(images, hand_side)
    fused = fusion.fuse(frames, backend.forward)
    hand = fusion.build_hand_mesh(fused, hand_side)
    return fused, hand, len(frames)


@app.post("/v1/hand")
async def hand(request: Request):
    t0 = time.time()
    uid = auth.user_id(request.headers)
    if not uid:
        raise ApiError(401, "UNAUTHENTICATED", "ログインが必要です。")
    meta, images = await _read_form(request)
    try:
        case_id = meta.get("case_id")
        if not isinstance(case_id, str) or not case_id or "." in case_id or "|" in case_id:
            raise ApiError(400, "INVALID_ARGUMENT", "meta.case_id が必要です。")
        hand_side = meta.get("hand_side")
        if hand_side not in ("right", "left"):
            raise ApiError(400, "INVALID_ARGUMENT", "meta.hand_side は 'right' か 'left' にしてください。")
        if not images:
            raise ApiError(400, "INVALID_ARGUMENT", "フレーム（frame_0〜）が1枚もありません。")
        _check_case(case_id, uid)

        mgr: BackendManager = request.app.state.backends
        try:
            backend = mgr.current()
        except BackendUnavailable as e:
            log.info("hand: frames=%d error=MESH_UNAVAILABLE (%s)", len(images), e)
            raise ApiError(503, "MESH_UNAVAILABLE", "手の3Dを計算する準備をしています。しばらくして自動でやり直します。", True)

        st = store.get_store()
        try:
            await run_in_threadpool(st.reserve_call, uid)  # 上限の確認と回数・見積もり額の加算
        except store.LimitError as e:
            status = 429 if e.code == "RATE_LIMITED" else 503
            raise ApiError(status, e.code, e.message, False)

        t_gpu = time.time()
        try:
            fused, hm, n_frames = await asyncio.wait_for(run_in_threadpool(_compute, backend, images, hand_side),
                                                         timeout=config.MAX_EXEC_SECONDS)
        except asyncio.TimeoutError:
            raise ApiError(503, "MESH_UNAVAILABLE", "手の3Dの計算が時間内に終わりませんでした。", True)
        except fusion.FusionError as e:
            if str(e) == "NO_HAND_DETECTED":
                raise ApiError(422, "NO_HAND_DETECTED", "どのフレームでも手の姿勢が分かりませんでした。撮り直してください。")
            log.error("hand: fusion failed (%s)", e)
            raise ApiError(503, "MESH_UNAVAILABLE", "手の3Dを作れませんでした。撮り直してください。", True)
        except BackendUnavailable:
            raise ApiError(503, "MESH_UNAVAILABLE", "手の3Dを計算する準備をしています。", True)
        except Exception as e:  # noqa: BLE001 - 画像の中身はログに出さない
            log.error("hand: frames=%d error=%s", len(images), type(e).__name__)
            raise ApiError(503, "MESH_UNAVAILABLE", "手の3Dの計算に失敗しました。", True)
        finally:
            gpu_s = time.time() - t_gpu
            try:
                await run_in_threadpool(st.add_gpu_seconds, uid, gpu_s)
            except Exception:  # noqa: BLE001
                pass
    finally:
        images.clear()  # 画像はここで捨てる

    fingers = fusion.fingers_from(fused)
    mesh_id = "hm_" + uuid.uuid4().hex[:12]
    created = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    glb = glbio.write_glb(hm["vertices"], hm["faces"], {
        "joints_mm": hm["joints_mm"],
        "hand_side": hand_side,
        "model": backend.model,
        "units": "mm",
        "scale": "uncorrected",
        "frame": "hand",
        "created_at": created,
        "mesh_id": mesh_id,
    })
    mesh_sha = result_token.bytes_sha256(glb)
    path = f"cases/{case_id}/hand/raw/{mesh_id}.glb"
    try:
        await run_in_threadpool(st.put_object, path, glb, "model/gltf-binary")
    except store.StoreError as e:
        log.error("hand: store failed (%s)", e)
        raise ApiError(503, "MESH_STORE_FAILED", "手の3Dデータを保存できませんでした。もう一度お試しください。", True)

    warnings = list(fused.warnings)
    body = {
        "method": "mesh_recovery",
        "model": backend.model,
        "fusion": "median_params",
        "frames_used": fused.frames_used,
        "mesh_id": mesh_id,
        "mesh_sha256": mesh_sha,
        "mesh_stats": hm["stats"],
        "joints_mm": hm["joints_mm"],
        "fingers": fingers,
        "warnings": warnings,
        "result_token": result_token.make_token(config.hmac_key(), case_id, fingers, mesh_sha),
    }
    log.info("hand: backend=%s frames=%d used=%d dropped=%d verts=%d %.2fs", backend.name, n_frames,
             fused.frames_used, fused.frames_dropped, hm["stats"]["vertices"], time.time() - t0)
    return body
