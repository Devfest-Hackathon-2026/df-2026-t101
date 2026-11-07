# 生成API（Cloud Run、asia-northeast1）。OpenSCAD の開発版（Manifold）と Python を同じイメージに入れる。
# ビルドはリポジトリの直下から：docker build -f api/Dockerfile -t jijogu-api .
# （scad/ と schemas/ を同梱するため、文脈はリポジトリの直下）
# 要確認：openscad/openscad:dev の中身（Debian の版と python3 の版）と、Manifold が既定で使えるか
FROM openscad/openscad:dev

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-venv python3-pip ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /srv
COPY api/requirements.txt api/requirements.txt
RUN python3 -m venv /srv/venv \
 && /srv/venv/bin/pip install --no-cache-dir -r api/requirements.txt

COPY api/app api/app
COPY api/prompts api/prompts
COPY scad scad
COPY schemas schemas

ENV PYTHONUNBUFFERED=1 \
    OPENSCAD_BIN=openscad \
    AUTH_MODE=firebase \
    STORE_BACKEND=gcp \
    GEMINI_MODE=live \
    GEMINI_LOCATION=global \
    GEMINI_MODEL=gemini-4-argon \
    PORT=8080

WORKDIR /srv/api
# MESH_RESULT_HMAC_KEY・STORAGE_BUCKET・GOOGLE_CLOUD_PROJECT はデプロイの時に渡す（鍵は Secret Manager から）
CMD exec /srv/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port ${PORT} --timeout-keep-alive 300
