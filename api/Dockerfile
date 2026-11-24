# 生成API（Cloud Run、asia-northeast1）。OpenSCAD の開発版（Manifold）と Python を同じイメージに入れる。
# ビルドはリポジトリの直下から：docker build -f api/Dockerfile -t jijogu-api .
# （scad/ と schemas/ を同梱するため、文脈はリポジトリの直下）
# 要確認：openscad/openscad:dev の中身（Debian の版と python3 の版）と、Manifold が既定で使えるか
# dev は毎日変わる版なので、作り直すたびに違う OpenSCAD が入らないよう、本番で動かしてきた版（2026-11-23 のビルド
# 1b7459cc で使われたもの）に固定する（2026-11-24）。上げるときは digest を書き換えて、形のテストを流してから
FROM openscad/openscad:dev@sha256:c7e532e701d3add64de98c317abbbcacbf1ab9efb656014dcb001b90e7538c38

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

# 道具の留め具（万力式。2026-11-24 に C字クリップから置き換えた）は、生成のたびに scad/vise_main.scad で描く
# （1つ 0.5 秒ほど）。C字クリップのときの、先に作っておく固定STLのライブラリはやめた

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
