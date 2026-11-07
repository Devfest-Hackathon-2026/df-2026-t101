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
| `HAND_MESH_BACKEND` | （なし＝auto） | `sam3d`：本物だけ（読み込み中・失敗の間は `503 MESH_UNAVAILABLE`）。`mock`：モックだけ（カプセルから作ったそれらしい手）。未指定：本物を試し、だめならモック |
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

- 重みはイメージに入れない（SAM License・大きさ）。起動のたびに Hugging Face から取るか（Secret Manager の HF トークンを `HF_TOKEN` に渡す）、GCS に置いた重みを起動時に `HAND_MESH_CHECKPOINT_DIR` へコピーする（どちらにするか要確認。GCS の方が起動が速く、HF の障害に左右されない）
- 起動から使えるまで：コンテナ＋重みの読み込みで1〜3分の見込み（要確認。手元では読み込み10〜48秒）
- 設定は [ADR-0009](../docs/adr/0009-gpu-placement.md)（asia-southeast1、L4、最小0台・最大1台、同時1件）

## 11/7 に手元で確かめたこと（RTX 4070 Ti SUPER）

- 本物の重みで `POST /v1/hand` が通る：3枚中2枚が有効、合成・切り出し・細分割・保存を含めて1.8秒、頂点9,138・閉じた面
- 試験用の生メッシュ：`api/tests/fixtures/hand_raw_right.glb`（MediaPipe の見本の写真から）。`hand_raw_fist.glb` は**写真からではなく**、手の姿勢のパラメータを2.5倍にした合成（PIP は85〜92度に曲がるが、MCP は曲がらず少し反る。本当の握りこぶしではない）

## 分かっている制限

- 握りこぶしの写真での確かめはまだ（要確認）。拘縮や変形のある手での精度は未評価
- `NO_HAND_DETECTED` は、手のキーポイントが切り抜きの外に出たフレームを捨てる判定だけ。手が写っていない画像でも何かしらの姿勢を返すことがある
- 何枚の有効なフレームがあれば合成が安定するかは要確認（api.md §4）
- 画像1枚ずつ順に推論する。GPU が要る

## ライセンス

`vendor/sam-3d-body/` は [facebookresearch/sam-3d-body](https://github.com/facebookresearch/sam-3d-body)（コミット `b5c765a`、2026-02-19）のコピーで、**SAM License**（`vendor/sam-3d-body/LICENSE`）。重みもSAM Licenseで、リポジトリやイメージには入れない。発表物・著作物利用シートに「SAM 3D Body（Meta、SAM License）」と MHR（Meta、Apache-2.0）の利用を書く。
