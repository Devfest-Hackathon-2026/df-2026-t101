# app（Hand-Some-Fit の画面）

Flutter Web の画面と、ブラウザの中で動く採寸エンジン（TypeScript）です。設計は [docs/screens.md](../docs/screens.md)（画面）と [docs/measurement.md](../docs/measurement.md)（採寸）にあります。

## フォルダ

| 場所 | 中身 |
|---|---|
| `lib/screens/` | 画面（S0 ログイン〜S10 ダウンロード。S9 は OT の確認） |
| `lib/data/` | 生成APIの呼び出し（`api.dart`）、ログイン（`session.dart`）、Storage のファイル（`files.dart`）、モック（`mock_backend.dart`） |
| `lib/bridge/` | 採寸エンジン（`window.jijoguMeasure`）と three.js（`window.jijoguViewer`）を `dart:js_interop` で呼ぶ所 |
| `web_engine/src/` | 採寸エンジン：アプリの中のカメラ、MediaPipe、1円玉の自動検出（OpenCV.js、Web Worker）、集計、hand-mesh の呼び出し |
| `web/js/` | `measure_engine.js`・`coin_worker.js`（web_engine をまとめたもの）、`viewer.js`（three.js） |
| `web/demo/` | モックで使う3Dの見本。形を変えたら `scripts/make_demo_assets.py` で作り直す |

## 初回の準備

MediaPipe の本体と手のモデル、OpenCV.js はリポジトリに入れていないので、取ってきて採寸エンジンをビルドします（Node.js が要ります）。

```sh
bash scripts/fetch_mediapipe.sh   # リポジトリの直下から
```

採寸エンジンだけを直したときは、`cd app/web_engine && npm run build`（型の確認は `npm run typecheck`）。

## 動かし方

### 画面だけを試す（APIなし）

```sh
cd app
flutter run -d chrome --dart-define=MOCK_API=true
```

生成APIと hand-mesh の代わりに、`lib/data/mock_backend.dart` が [docs/api.md](../docs/api.md) の例の形で答えます。ログインは名前を入れるだけ（`AUTH_MODE=dev`）。

### 手元の API につなぐ

1. 生成API を `http://localhost:8080`、hand-mesh を `http://localhost:8081` で動かす（手順は [docs/notes/prototype-lessons.md](../docs/notes/prototype-lessons.md) と [hand_mesh/README.md](../hand_mesh/README.md)）
2. `cd app && flutter run -d chrome`

接続先は `--dart-define=API_BASE=...`・`HAND_MESH_BASE=...` で変えられます（[lib/config.dart](lib/config.dart)）。

### 本番（Firebase Hosting）

```sh
cd app
flutter build web --release --dart-define-from-file=../env/<名前>.json --output build/web_prod
cd .. && firebase deploy --only hosting
```

`env/<名前>.json` は [env/example.json](../env/example.json) を写して値を入れたもの（コミットしない）。スマホの実機でカメラを使うには HTTPS が要るので、Hosting のプレビューチャンネル（`firebase hosting:channel:deploy <名前>`）に出して試します。

## テスト

```sh
cd app && flutter test
```

`test/data_test.dart` で、聞き取りの答えの JSON、API のエラーの読み取り、続きから再開する画面の選び方を確かめています。
