"""生成API（docs/api.md）。Cloud Run（asia-northeast1）で動かす。開発では AUTH_MODE=dev・STORE_BACKEND=local。"""
from __future__ import annotations

import logging
import re
import uuid
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from . import ops
from .config import settings
from .errors import ApiError
from .routes import cases, designs, measurement, misc

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("api")

@asynccontextmanager
async def lifespan(_app):
    if settings.auth_mode != "dev" and not settings.hmac_key:
        raise RuntimeError("MESH_RESULT_HMAC_KEY が設定されていません（本番では Secret Manager から渡す）")
    ops.ensure_dev_runtime()
    log.info("api ready auth=%s store=%s gemini=%s", settings.auth_mode, settings.store_backend, settings.gemini_mode)
    yield


app = FastAPI(title="jijogu api", version="impl", lifespan=lifespan)

# CORS（api.md §1）：Hosting の URL、プレビューチャンネル、開発用の localhost だけ
origins = [o.strip() for o in settings.hosting_origins.split(",") if o.strip()]
origin_regex = r"^http://(localhost|127\.0\.0\.1)(:\d+)?$"
if settings.project:
    p = re.escape(settings.project)
    origin_regex = rf"^(http://(localhost|127\.0\.0\.1)(:\d+)?|https://{p}(--[a-z0-9-]+)?\.web\.app|https://{p}\.firebaseapp\.com)$"
app.add_middleware(CORSMiddleware, allow_origins=origins, allow_origin_regex=origin_regex, allow_credentials=False,
                   allow_methods=["GET", "POST", "PUT", "OPTIONS"],
                   allow_headers=["Authorization", "Content-Type", "X-User", "X-User-Email", "X-Firebase-AppCheck"],
                   expose_headers=["X-Request-Id"])


@app.middleware("http")
async def request_id(request: Request, call_next):
    rid = request.headers.get("X-Request-Id") or uuid.uuid4().hex[:16]
    request.state.request_id = rid
    resp = await call_next(request)
    resp.headers["X-Request-Id"] = rid
    return resp


@app.exception_handler(ApiError)
async def api_error(request: Request, e: ApiError):
    rid = getattr(request.state, "request_id", "-")
    if e.status >= 500:
        log.warning("error %s %s rid=%s", e.code, request.url.path, rid)
    return JSONResponse(e.body(rid), status_code=e.status)


@app.exception_handler(RequestValidationError)
async def bad_request(request: Request, e: RequestValidationError):
    rid = getattr(request.state, "request_id", "-")
    err = ApiError("INVALID_ARGUMENT", details=[{"field": ".".join(map(str, x.get("loc", []))), "message": x.get("msg")}
                                                 for x in e.errors()][:10])
    return JSONResponse(err.body(rid), status_code=400)


@app.exception_handler(Exception)
async def internal(request: Request, e: Exception):
    rid = getattr(request.state, "request_id", "-")
    log.exception("internal error rid=%s", rid)
    return JSONResponse(ApiError("INTERNAL").body(rid), status_code=500)


for r in (misc.router, cases.router, measurement.router, designs.router):
    app.include_router(r)
