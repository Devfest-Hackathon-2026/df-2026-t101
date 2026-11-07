# hand-mesh（Cloud Run GPU、L4。ADR-0009）
# 重みはイメージに入れない。起動時に Hugging Face（HF_TOKEN）か、GCS からコピーしたフォルダ（HAND_MESH_CHECKPOINT_DIR）から読む。
# CUDA のバージョンと torch の組み合わせは、Cloud Run の L4 のドライバに合わせて要確認。
FROM nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
RUN apt-get update && apt-get install -y --no-install-recommends python3 python3-venv python3-pip libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*
RUN python3 -m venv /venv
ENV PATH=/venv/bin:$PATH

WORKDIR /srv
# torch は CUDA に合うものを先に入れる（要確認：L4 のドライバで動く版）
RUN pip install torch==2.14.1 torchvision==0.29.1 --index-url https://download.pytorch.org/whl/cu128
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .

ENV AUTH_MODE=firebase STORE_BACKEND=gcp HAND_MESH_BACKEND=sam3d PORT=8080
# MESH_RESULT_HMAC_KEY・HF_TOKEN は Secret Manager から環境変数で渡す（ここには書かない）
CMD exec uvicorn app:app --host 0.0.0.0 --port ${PORT}
