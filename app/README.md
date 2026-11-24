# app（Hand-Some-Fit の画面）

Flutter Web の画面と、ブラウザの中で動く採寸エンジン（TypeScript）です。設計は [docs/screens.md](../docs/screens.md)（画面）と [docs/measurement.md](../docs/measurement.md)（採寸）にあります。

## フォルダ

`lib/` は機能ごとに分けています。画面とその画面だけで使う物は `features/<機能>/`、いくつもの機能で使う物は `core/` に置きます。

| 場所 | 中身 |
|---|---|
| `lib/main.dart` | 起動 |
| `lib/app/` | 画面の行き先（`router.dart`）と URL（`paths.dart`） |
| `lib/core/config.dart`・`session.dart` | 接続先などの設定、ログイン |
| `lib/core/text_ja.dart` | AI が書いた文（`*_ja`）から、混ざった項目名（`tool_type=spoon` など）を表示の前に取り除く |
| `lib/core/api/` | 生成APIの呼び出し（`api.dart`）、エラーの読み取り（`api_error.dart`）、モック（`mock_backend.dart`） |
| `lib/core/models/` | 聞き取りの答え（`requirements.dart`）、取り付け具（`attachments.dart`） |
| `lib/core/storage/` | Storage のファイル（`files.dart`） |
| `lib/core/ui/` | 色・文字（`theme.dart`）、共通の部品（`widgets.dart`）、道具の太さの入力（`tool_fields.dart`）。`ui.dart` で両方を読み込む |
| `lib/core/viewer/` | three.js の3D表示（`window.jijoguViewer` を `dart:js_interop` で呼ぶ） |
| `lib/features/login/` | S0 ログイン |
| `lib/features/home/` | S1 ホーム（ケースの一覧） |
| `lib/features/interview/` | S2 聞き取り |
| `lib/features/measure/` | S3〜S5 採寸：撮影の前（`capture_screen`）、カメラ（`live_capture_screen`）、1円玉の確認（`coin_screen`）、解析（`analyze_screen`）、結果の確認と点の修正（`measure_confirm_screen`・`point_editor`）、採寸エンジンの呼び出し（`measure_engine`、`window.jijoguMeasure`）、撮影のあとの戻る操作で「撮り直しますか？」と確かめる（`keep_recording`） |
| `lib/features/design/` | S6〜S8 形を作る・直す、OT に確認を頼む |
| `lib/features/review/` | S9 OT の確認 |
| `lib/features/print/` | S10 ダウンロード（`print_screen`）、Storage のファイルを保存する（`download`） |
| `lib/features/order/` | S10 の「刷ってもらう／自分で刷る」（`print_choice`）と注文の状態（`order_status_card`）、S12 受託者を選ぶ（`fabricator_list_screen`）、S13 注文の内容（`order_form_screen`）、金額・重さ・時間の目安の計算（`order_logic`） |
| `lib/features/fabricator/` | 受託する側の S14 受けた注文（`fabricator_orders_screen`）・S15 注文の詳細（`fabricator_order_screen`）、生成APIから STL を受け取って保存する（`api_download`） |
| `assets/images/` | アプリ名のロゴ（`logo.png`。S0・S1）、Google の G（`google_g.svg`）、S10 の部品の絵が描けるまでの代わり（`part_cover.svg`・`part_c_clip.svg`） |
| `web_engine/src/` | 採寸エンジン：アプリの中のカメラ、MediaPipe、1円玉の自動検出（OpenCV.js、Web Worker）、集計、hand-mesh の呼び出し |
| `web/js/` | `measure_engine.js`・`coin_worker.js`（web_engine をまとめたもの）、`viewer.js`（three.js） |
| `web/demo/` | モックで使う3Dの見本。形を変えたら `scripts/make_demo_assets.py` で作り直す |
| `web/mediapipe/`・`web/opencv/` | MediaPipe の本体と手のモデル、OpenCV.js（リポジトリに入れない。下の「初回の準備」で取ってくる） |

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

生成APIと hand-mesh の代わりに、`lib/core/api/mock_backend.dart` が [docs/api.md](../docs/api.md) の例の形で答えます。ログインは名前を入れるだけ（`AUTH_MODE=dev`）。

### 手元の API につなぐ

1. 生成API を `http://localhost:8080`、hand-mesh を `http://localhost:8081` で動かす（手順は [docs/notes/prototype-lessons.md](../docs/notes/prototype-lessons.md) と [hand_mesh/README.md](../hand_mesh/README.md)）
2. `cd app && flutter run -d chrome`

接続先は `--dart-define=API_BASE=...`・`HAND_MESH_BASE=...` で変えられます（[lib/core/config.dart](lib/core/config.dart)）。

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

- `test/data_test.dart`：聞き取りの答えの JSON、API のエラーの読み取り、続きから再開する画面の選び方
- `test/attachments_preview_test.dart`：S7 の取り付け具の切り替え・足す・太さを直す（ADR-0014）
- `test/attachments_print_test.dart`：S10 のダウンロードの行と、S9 の取り付け具の一覧
- `test/text_ja_test.dart`：AI の文から項目名を取り除く（`text_ja.dart`）
- `test/order_logic_test.dart`：発注の金額・重さ・時間の目安、注文の状態の名前、届く目安
- `test/reviews_mock_test.dart`：OT のホームの「確認を頼まれているケース」（モック）
- `test/refine_choice_test.dart`・`test/param_step_test.dart`：S7 の直し方の選択と、数値の −／＋ボタン
- `test/stop_recording_dialog_test.dart`：S3 の録画中に閉じるときの確かめる画面
- `test/data_url_bytes_test.dart`：同じ画像をデコードし直さないこと
