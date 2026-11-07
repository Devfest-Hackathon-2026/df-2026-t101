# hand-mesh（Cloud Run GPU、L4。ADR-0009）
# 重みはイメージに入れない。Cloud Run で重みのバケットをフォルダとしてつなぎ、HAND_MESH_CHECKPOINT_DIR で指す。
# ドライバは Cloud Run が入れる（L4 は 580 系＝CUDA 13.0、2026-11-07 に公式ドキュメントで確認）。
# torch の wheel は CUDA のライブラリを自前で持つので、CUDA 入りのベースイメージは使わない（小さいほど起動が速い）。
# torch は CUDA 13.0 版（cu130）。cu132 はこのドライバより新しく動かない。2.14.1 に cu128 版はない。
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
RUN apt-get update && apt-get install -y --no-install-recommends python3 python3-venv python3-pip libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*
RUN python3 -m venv /venv
ENV PATH=/venv/bin:$PATH

WORKDIR /srv
RUN pip install torch==2.14.1 torchvision==0.29.1 --index-url https://download.pytorch.org/whl/cu130
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .

ENV AUTH_MODE=firebase STORE_BACKEND=gcp HAND_MESH_BACKEND=sam3d PORT=8080
# MESH_RESULT_HMAC_KEY は Secret Manager から環境変数で渡す（ここには書かない）
CMD exec uvicorn app:app --host 0.0.0.0 --port ${PORT}
