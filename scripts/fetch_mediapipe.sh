#!/usr/bin/env bash
# MediaPipe の本体（wasm）と手のモデルを app/web/mediapipe に、OpenCV.js を app/web/opencv に置く
# （大きいのでリポジトリには入れない）
set -euo pipefail
cd "$(dirname "$0")/../app"
(cd web_engine && npm ci)
mkdir -p web/mediapipe/models
cp -r web_engine/node_modules/@mediapipe/tasks-vision/wasm web/mediapipe/
curl -sL -o web/mediapipe/models/hand_landmarker.task https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/latest/hand_landmarker.task
# 1円玉の自動検出に使う OpenCV.js（@techstark/opencv-js、Apache-2.0、約11MB）
mkdir -p web/opencv
curl -sfL -o web/opencv/opencv.js https://cdn.jsdelivr.net/npm/@techstark/opencv-js@4.12.0-release.1/dist/opencv.js
(cd web_engine && npm run build)
echo "ok: app/web/mediapipe、app/web/opencv、app/web/js/measure_engine.js を用意しました"
