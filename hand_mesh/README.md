# hand-mesh（手の3Dメッシュを作るサービス）

[api.md §4](../docs/api.md#4-手のメッシュ復元サービス-hand-mesh) の `POST /v1/hand`。ブラウザから直接呼ぶ。SAM 3D Body（Meta）で、切り抜いた手のフレーム（最大8枚）ごとに手を復元し、**形・体の比率・手の姿勢のパラメータの中央値で1つの手にまとめ**、手首で切り出して閉じた面にし、手の座標系に置いた**未補正の手のメッシュ**を Storage に保存する（[ADR-0010](../docs/adr/0010-hand-mesh-fusion.md)）。角度（MCP・PIP・DIP）と、生成APIが確かめる結果トークンも返す。

## 処理の流れ

| 段階 | ファイル | 中身 |
|---|---|---|
| フレームごとの推定 | `backends.py` | 手のデコーダで `shape`（45）・`scale`（28）・`hand`（108）とキーポイント（MHR70）。左手は画像を左右反転して右手として推定。キーポイントが切り抜きの外に出たフレームは無効 |
| まとめる | `fusion.py` | 有効なフレームのパラメータの中央値を `mhr_forward` に渡す。関節の角度が中央値から30度を超えて外れたフレームは外して取り直す（`MESH_OUTLIER_FRAMES`） |
| 切り出し | `fusion.py` | 手首→中指の付け根の向きの面（手首から5mm指側）より指側、手首から「手の長さ×1.4」以内を残す。切り口の輪を重心への扇でふさぎ、ループ細分割を1回（約9,100頂点） |
| 手の座標系 | `fusion.py` | 原点＝手首、x＝人差し指の付け根→小指の付け根、y＝手首→中指の付け根から x 成分を除いたもの、z＝x×y（[measurement.md §8.1](../docs/measurement.md#81-手の座標系)）。左手は鏡像に戻す（実際の手）。単位は mm、**大きさは未補正**（実寸にするのは生成API） |
| 角度 | `angles.py`・`fusion.py` | まとめた手の関節から、measurement.md §6 と同じ定義。ばらつき（IQR）はフレームごとの角度から |
| 保存 | `glbio.py`・`store.py` | `cases/{case_id}/hand/raw/{mesh_id}.glb`。関節（21点）は GLB の最上位の `extras.joints_mm` |
| トークン | `result_token.py` | `v1.{case_id}.{UTC秒まで、末尾Z}.{角度のsha256}.{GLBのsha256}.{HMAC}`。生成API（`api/app/tokens.py`）と同じ作り方 |

画像はメモリの中だけで扱い、ディスク・Storage・ログには書かない。ログは枚数・処理時間・エラーコードだけ。

返す警告は `MESH_FRAMES_DROPPED`（手の姿勢が出なかったフレームがある）と `MESH_OUTLIER_FRAMES`（角度が大きく外れたフレームを外した）。ブラウザが採寸の警告に足す。ほかの要求の推論中に届いた要求は、待たせずにすぐ `503 MESH_UNAVAILABLE`（やり直してよい）で返す。アプリは合わせて3回まで試す（[measurement.md §11](../docs/measurement.md#11-手のメッシュ復元)）。

## セットアップ（Windows、NVIDIA GPU）

```
cd hand_mesh
py -3.12 -m venv .venv
.venv\Scripts\python -m pip install torch==2.14.1 torchvision==0.29.1 --index-url https://download.pytorch.org/whl/cu132
.venv\Scripts\python -m pip install -r requirements.txt
```

重み（承認制）：Hugging Face の [facebook/sam-3d-body-vith](https://huggingface.co/facebook/sam-3d-body-vith) で利用を申請し、承認されたら `.venv\Scripts\hf auth login`。初回の起動で約2.4GBを `~/.cache/huggingface` に取ってくる。

## 動かし方

```
.venv\Scripts\python -m uvicorn app:app --port 8081
curl http://localhost:8081/healthz
.venv\Scripts\python -m pytest -q tests      # モックで動く
```

開発では、生成APIと同じ `.localstore/`（リポジトリ直下）を使う。ケース `cases/{case_id}` に持ち主 `owner_uid` と同意の記録（`mesh_consent_at`、`consent_text_version = "mesh-consent-2"`）がないと `422 CONSENT_REQUIRED`（生成APIの `POST /consent` が書く）。

## 環境変数

| 名前 | 既定 | 中身 |
|---|---|---|
| `AUTH_MODE` | `dev` | `dev`：`X-User` ヘッダーをユーザーIDとして使う（開発専用）。`firebase`：`Authorization: Bearer <IDトークン>` を確かめる |
| `STORE_BACKEND` | `local` | `local`：`LOCAL_STORE_DIR`（既定はリポジトリ直下の `.localstore/`）。`gcp`：Cloud Storage（`STORAGE_BUCKET`）と Firestore |
| `MESH_RESULT_HMAC_KEY` | なし | 結果トークンの鍵。**`AUTH_MODE=dev` のときだけ、なくても `dev-only-key` で動く**。それ以外で未設定なら起動しない（Secret Manager から渡す） |
| `HAND_MESH_BACKEND` | （なし＝auto） | `sam3d`：本物だけ（読み込み中・失敗の間は `503 MESH_UNAVAILABLE`）。`mock`：モックだけ（カプセルから作ったそれらしい手）。未指定：本物を試し、だめならモック。**モックは `AUTH_MODE=dev` のときだけ**（それ以外で `mock` を指定すると起動せず、未指定でもモックに切り替えない。生成APIも本番ではモックの手を `MEASUREMENT_INVALID` で断る） |
| `HAND_MESH_HF_REPO` | `facebook/sam-3d-body-vith` | 重みのリポジトリ |
| `HAND_MESH_CHECKPOINT_DIR` | なし | `model_config.yaml`・`model.ckpt`・`assets/mhr_model.pt` を置いたフォルダ。指定すると Hugging Face を見ない |
| `MESH_MAX_EXECUTION_SECONDS` | `60` | 1回の処理の打ち切り |
| `MESH_MAX_FRAME_BYTES` | `200000` | 1枚の上限 |
| `MESH_PER_USER_DAILY`・`MESH_GLOBAL_DAILY` | `20`・`100` | 1人・全体の1日の回数の上限（日本時間で区切る） |
| `DAILY_COST_LIMIT_USD`・`MESH_COST_PER_CALL_USD` | `15`・`0.40` | その日の概算費用の上限と、1回の見積もり額 |
| `HAND_MESH_CORS_ORIGINS` | なし | localhost のほかに許すオリジン（カンマ区切り。Hosting のURL） |
| `GOOGLE_CLOUD_PROJECT` | なし | gcp・firebase のとき |

停止設定 `settings/runtime.generation_enabled`：gcp では `true` のときだけ動く（設定なし・取得失敗では `503 GENERATION_DISABLED`）。local では、`false` と書いたときだけ止める。

## Cloud Run GPU（`Dockerfile`）

- 重みはイメージに入れない（SAM License・大きさ）。非公開のバケット `gs://jijogu-hackathon-2026-weights/sam-3d-body-vith/`（asia-southeast1、2.2GiB）に置き、Cloud Run でこのバケットを `/weights` に読み取り専用でつなぐ。`HAND_MESH_CHECKPOINT_DIR=/weights/sam-3d-body-vith` なので Hugging Face は見ない（HF トークンは要らない）
- ドライバは Cloud Run が入れる（L4 は 580 系＝CUDA 13.0）。torch は cu130 版。ベースは素の Ubuntu 24.04
- 起動の確認（startup probe）は `GET /ready`。モデルを読み終わるまで 503 なので、0台から起きたときの最初のリクエストはエラーにならず、読み込みが終わるまで待つ。読み込みに失敗したときは 200 にして、エラーは `/v1/hand` の `503 MESH_UNAVAILABLE` で返す
- Cloud Run では `/healthz` が予約されていて届かないので、動作確認は `GET /health`
- 設定は [ADR-0009](../docs/adr/0009-gpu-placement.md)（asia-southeast1、L4、ゾーン冗長なし、最小0台・最大1台）。同時に受けるのは4件（推論は GPU のロックで1件ずつ）。1件だと、起動待ちの間に事前確認（OPTIONS）で枠が埋まり、やり直しが Cloud Run の 429 で断られた
- アプリは、撮影の画面で同意が済んだ時点で `GET /health` を送って GPU を起こしておく（`MeasureEngine.warmHandMesh`。5分に1回まで、画像は送らない）。撮っている間に起動が終わる

```
# リポジトリの直下から。イメージを作る（約20分）
gcloud builds submit hand_mesh --config deploy/cloudbuild.hand_mesh.yaml --project jijogu-hackathon-2026

# デプロイ（設定は deploy/hand-mesh.flags.yaml にまとめてある。GPU・重みのバケット・起動の確認・環境変数）
gcloud run deploy hand-mesh --flags-file deploy/hand-mesh.flags.yaml
```

URL は https://hand-mesh-312211346578.asia-southeast1.run.app 。Web 版は `env/prod.json` の `HAND_MESH_BASE` でここを指す。

11/7 の実測：重みの読み込み約84秒（GCS をつないだフォルダから）、0台から起きて最初の応答まで約70〜90秒。

最初の1回だけ、持ち主が権限を付ける（重みのバケットを読む権限と、ブラウザから直接呼べるようにする設定）：

```
gcloud storage buckets add-iam-policy-binding gs://jijogu-hackathon-2026-weights --member=serviceAccount:hand-mesh@jijogu-hackathon-2026.iam.gserviceaccount.com --role=roles/storage.objectViewer
gcloud run services update hand-mesh --project jijogu-hackathon-2026 --region asia-southeast1 --no-invoker-iam-check
```

デモ・審査の前だけ温める（終わったらすぐ 0 に戻す。1 のままだと1日約 $30）：

```
gcloud run services update hand-mesh --project jijogu-hackathon-2026 --region asia-southeast1 --min-instances 1
gcloud run services update hand-mesh --project jijogu-hackathon-2026 --region asia-southeast1 --min-instances 0
```

## 11/7 に手元で確かめたこと（RTX 4070 Ti SUPER）

- 本物の重みで `POST /v1/hand` が通る：3枚中2枚が有効、合成・切り出し・細分割・保存を含めて1.8秒、頂点9,138・閉じた面
- 試験用の生メッシュ：`api/tests/fixtures/hand_raw_right.glb`（MediaPipe の見本の写真から）。`hand_raw_fist.glb` は**写真からではなく**、手の姿勢のパラメータを2.5倍にした合成（PIP は85〜92度に曲がるが、MCP は曲がらず少し反る。本当の握りこぶしではない）

## 分かっている制限

- 握りこぶしは、11/9 に本番でメンバーの握りこぶしの動画を通し、手の3Dができることを確かめた（また 11/9 に、前の版の3Dの手から作ったカバーを試し刷りし、メンバーのこぶしに合った。今の版はまだ刷っていない）。寸法の精度をノギスと比べる検証はしていない（[measurement.md §10](../docs/measurement.md#10-精度の確かめ方)）。拘縮や変形のある手での精度は未評価
- `NO_HAND_DETECTED` は、手のキーポイントが切り抜きの外に出たフレームを捨てる判定だけ。手が写っていない画像でも何かしらの姿勢を返すことがある
- 何枚の有効なフレームがあれば合成が安定するかは要確認（api.md §4）
- 画像1枚ずつ順に推論する。GPU が要る

## ライセンス

`vendor/sam-3d-body/` は [facebookresearch/sam-3d-body](https://github.com/facebookresearch/sam-3d-body)（コミット `b5c765a`、2026-02-19）のコピーで、**SAM License**（`vendor/sam-3d-body/LICENSE`）。重みもSAM Licenseで、リポジトリやイメージには入れない。発表物・著作物利用シートに「SAM 3D Body（Meta、SAM License）」と MHR（Meta、Apache-2.0）の利用を書く。
