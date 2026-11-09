# 生成APIの仕様

> **このドキュメントで決めたこと**
> 1. 生成APIは、Cloud Run（asia-northeast1）上のHTTP JSON API（`/v1`）とする。認証は、FirebaseのIDトークンを `Authorization: Bearer` で送る方式にする。Firebase Hostingの転送（rewrite）は使わず、ブラウザから直接呼ぶ。Hosting経由だと60秒で打ち切られ、生成が間に合わないため。
> 2. ケース・会話・版への書き込みはこのAPIが行う（`hand-mesh` が書くのは、利用回数と費用、Storageの未補正の手のメッシュだけ）。ブラウザはFirestoreに書かない（ケース・版もこのAPIの `GET` で読む）。手のメッシュを実寸にし、そこからカバーの殻を作るのもこのAPI（[ADR-0011](adr/0011-dorsal-cover.md)）。生成は1回のリクエスト内で行い、途中経過と期限付きの処理中の印をFirestoreに書く。
> 3. エラーは `{"error": {"code", "message", "details", "retryable", "request_id"}}` の形にそろえる。`message` は画面にそのまま出せる日本語にする。

関連：[generation-pipeline.md](generation-pipeline.md)、[data-model.md](data-model.md)、[measurement.md](measurement.md)

---

## 1. 共通

| 項目 | 内容 |
|---|---|
| ベースURL | `https://<サービス名>-<ハッシュ>.asia-northeast1.run.app`（デプロイ後に決まる。フロントエンドにはビルド時に `--dart-define` で渡す） |
| 認証 | `Authorization: Bearer <FirebaseのIDトークン>`。サーバーはFirebase Admin SDKで検証する。Cloud Run自体は誰でも呼べる設定にする（`--no-invoker-iam-check`）。アプリの中でトークンを確かめる |
| App Check（拡張） | `X-Firebase-AppCheck: <トークン>`。入れたら、サーバーはAdmin SDKで検証する |
| CORS | 許可するオリジンは、HostingのURL（`https://<project>.web.app`、`https://<project>.firebaseapp.com`）、Hostingのプレビューチャンネル（`https://<project>--<チャンネル名>-<ハッシュ>.web.app` の形。正規表現で許可する）、開発用の `http://localhost:<port>` だけ。プリフライト（OPTIONS）はアプリで処理する。`hand-mesh` も同じ |
| 形式 | `Content-Type: application/json; charset=utf-8`。キーはスネークケース |
| 単位 | 寸法はmm、角度は度。キーの末尾に `_mm`、`_deg` を付ける |
| リクエストID | すべての応答に `X-Request-Id` を付ける。ログと突き合わせるため |
| タイムアウト | Cloud Runのリクエストのタイムアウトは300秒。生成APIの中では280秒で打ち切る |
| 回数の制限 | 1人1日あたり：生成10回、微調整30回、聞き取り60回。全体で1日あたり生成100回。上限は環境変数で変えられる。超えたら `RATE_LIMITED` |
| 生成の停止スイッチ | Geminiを呼ぶ処理と `hand-mesh` は、毎回共通の `settings/runtime.generation_enabled` を読む。`false`、設定なし、読み取り失敗なら `GENERATION_DISABLED`。両サービスの `GENERATION_ENABLED=false` でも停止する。全体を止める操作はFirestoreの共通設定を `false` にする（片方の環境変数だけでは他方は止まらない） |

### 1.1 生成の重複防止と異常終了からの復旧（MVP）

3日で作り切れる範囲に絞る。全部入りの形（`Idempotency-Key`、リースの更新、費用の予約と精算）は拡張機能とし、§1.2に残す。

- 生成・微調整・OTへの依頼・承認を始めるとき、Firestoreのトランザクションで、ケースに処理中の印 `active_operation = { operation_id, kind, started_at, expires_at }` を書く。`expires_at` は開始から300秒（Cloud Runのタイムアウトと同じ）
- 有効な印（`expires_at` が未来）があるあいだ、同じケースの生成・微調整・依頼・承認と、採寸・聞き取りの保存は `409 CONFLICT`。画面は送信中ボタンを押せなくし、二重の送信を防ぐ
- 処理の中では280秒で打ち切る（Geminiの呼び出しとOpenSCADの子プロセスを止め、`GENERATION_TIMEOUT` を記録する）
- 結果（進み具合、版の状態、ファイルの参照）を書くときは、トランザクションで `active_operation.operation_id` が自分のものかを確かめる。違えば（期限切れで回収されたあとなら）書かずに終える。終わったら印を消す
- 期限切れの回収：新しい処理を始めるとき、または `POST /recover` を呼んだときに、`expires_at` を過ぎた印があれば、印を消し、`kind` ごとに次のように戻す
  - 生成・微調整（`design`／`refine`）：処理中の版を `failed`（`GENERATION_INTERRUPTED`）にし、ケースを `previewing` に戻す
  - OTへの依頼（`review_request`）・デモの印刷用データ（`prepare_print`）：版は変えない。`internal/` の作りかけの印刷用STLを捨て、`approval.status` を `none` に戻す（ケースは `previewing`）
  - 承認（`approval`）：版は変えない。`approval.status=requested` のまま（OTはもう一度押せる）
- 通信が切れたときは、画面はまずFirestoreの版の状態を読む。処理が続いていれば待ち、`failed` になっていれば「もう一度作る」を出す（勝手に再送しない）

### 1.2 拡張機能（時間があれば）

- `Idempotency-Key` による再送の重複防止（同じキーなら同じ結果を返す）
- 処理権のリースを15秒ごとに更新し、プロセスが落ちたことを早く見つける
- GPUとGeminiの費用を、開始前に最大額で予約し、終わったあとで精算する

## 2. エンドポイント一覧

| メソッド | パス | 役割 | 呼べる人 |
|---|---|---|---|
| GET | `/healthz` | 動作確認 | 誰でも（認証なし） |
| GET | `/v1/parts` | 部品カタログ（`scad/catalog.json` の公開部分） | ログインした人 |
| POST | `/v1/cases` | ケース（1つの道具づくり）を作る | ログインした人 |
| PUT | `/v1/cases/{case_id}/requirements` | 選択式の質問の答えを保存する（Geminiは呼ばない） | 持ち主 |
| POST | `/v1/cases/{case_id}/interview` | 任意のチャットを1往復進める | 持ち主 |
| PUT | `/v1/cases/{case_id}/measurement` | 採寸結果を保存する | 持ち主 |
| POST | `/v1/cases/{case_id}/designs` | 形を作る（部品選び → 寸法決め → カバーの殻の計算 → 描画 → 確認）。部品はカバー本体とC字クリップ（とTPUの筒） | 持ち主 |
| POST | `/v1/cases/{case_id}/consent` | メッシュ復元のためにフレームを送ること、手の形の3Dデータを保存することへの同意を記録する（撮影の前） | 持ち主 |
| POST | `/v1/cases/{case_id}/designs/{design_id}/refine` | 言葉や数値、クリップの角度、模様で直す（新しい版を作る）。色だけの変更は版を作らない | 持ち主 |
| GET | `/v1/therapists` | 確認を頼めるOTの一覧（名前とメールアドレス） | ログインした人 |
| POST | `/v1/cases/{case_id}/review-request` | OTに確認を頼む（部品ごとの印刷用STLもここで作る） | 持ち主 |
| POST | `/v1/cases/{case_id}/designs/{design_id}/prepare-print` | デモのケースだけ：OTの確認なしで部品ごとの印刷用STLを作る | 持ち主（デモのケースのみ） |
| POST | `/v1/cases/{case_id}/designs/{design_id}/approval` | OTが「確認済み」にするか、差し戻す | 依頼されたOT |
| POST | `/v1/cases/{case_id}/recover` | 期限切れの処理中の印を回収し、最新状態を返す（AI・GPU処理なし） | 持ち主、依頼されたOT |
| DELETE | `/v1/cases/{case_id}` | ケースを消す（手のメッシュ・版・チャット・STL・画像もまとめて消す） | 持ち主 |

STL・画像・実寸の手のメッシュ（GLB）は、APIを通さずに、FirebaseのStorage SDKでダウンロードする。読めるかどうかはStorageのセキュリティルールで決める（[data-model.md](data-model.md)）。

## 3. 各エンドポイント

### 3.1 `POST /v1/cases`

リクエスト

```json
{ "title": "筆のカバー" }
```

応答 `201 Created`

```json
{
  "case_id": "c_8f3k2m",
  "status": "interviewing"
}
```

作ったあと、画面は選択式の質問（S2a）を出す。

### 3.2 `PUT /v1/cases/{case_id}/requirements`

選択式の質問（[screens.md S2a](screens.md#s2-やりたいこと選択式の質問任意のチャット)）の答えを保存する。Geminiは呼ばない。

- 採寸を保存したあとに `hand_side` を変えると `409 CONFLICT`（「手の左右を変えるには、採寸からやり直してください」）。保存した手のメッシュは左右ごとに座標が違い、逆の手として形を作ると手のひら側を覆う形になるため（2026-11-08）。形を作るときの左右は、採寸の `hand_side` を正とする

リクエスト

```json
{
  "activity": "draw",
  "tool_type": "brush",
  "hand_side": "right",
  "tool_d_mm": 9.5,
  "tool_shaft_size": null,
  "tool_shaft_shape": "round",
  "finger_state": "fist",
  "donning_by": "helper",
  "capture_by": "helper"
}
```

- 値はすべて選択肢か、範囲のある数値。スキーマは `schemas/requirements.schema.json` に置く。列挙値：`activity` は `draw`／`write`／`eat`／`other`、`tool_type` は `brush`／`pen`／`spoon`（「その他」もこの3つのどれかで代用する）、`tool_shaft_size` は `thin`／`medium`／`thick`／`unknown`、`tool_shaft_shape` は `round`／`flat`、`finger_state`（指の状態）は `fist`（握った形で固まっている）／`bent`（少し曲がっている）／`straight`（ほぼ伸ばせる）、`donning_by`（カバーとクリップを着け外しする人）は `self`／`helper`、`capture_by` は `self`／`helper`
- **道具の太さ `tool_d_mm`**（3.5〜20mm、小数第1位まで）：C字クリップの内径をこの値から決める（`内径 = tool_d_mm − CLIP_INTERFERENCE_MM`。[ADR-0012](adr/0012-c-clip-dovetail.md)）。クリップはしめしろ0.2〜0.4mmで挟むので、区分（3mm刻み）では合わない。そのため、画面では太さを**数値で**入れてもらう（1円玉＝直径20mmと並べた図と、定規で測る案内を出す）。測れないときだけ `tool_shaft_size` の区分を送り、サーバーが区分の中央の値（`thin`=6、`medium`=8.5、`thick`=11.5、`unknown`=道具ごとの既定）を `tool_d_mm` に入れて、`assumptions` に「道具の太さは推定」と残す。推定のまま刷るとクリップが合わないおそれが大きいので、S7とOT画面で目立たせる
- **道具の一覧 `tools`**（任意、1〜4個。[ADR-0014](adr/0014-multiple-attachments.md)）：1つの手のカバーに複数の道具のクリップを付けるときに送る。要素は `activity`・`tool_type`・`tool_d_mm`・`tool_shaft_size`・`tool_shaft_shape`（`tool_shaft_shape` は必須、`tool_d_mm` は null か 3.5〜20mm、それ以外の項目は入れられない）。5個以上は `REQUIREMENTS_INVALID`。省略すると、上の項目から1つの道具として扱う。サーバーは各要素に `tool_d_source` と `assumptions` を足して正規化し、`requirements.tools` に保存する。今までの `activity`・`tool_type`・`tool_d_mm`・`tool_d_source`・`tool_shaft_size`・`tool_shaft_shape` は**主な道具**（`tools` の中で最初の丸い柄。丸い柄がなければ先頭）の値で埋める。`assumptions` は全部の道具の分を、道具の名前つきでまとめる（平たい柄は「◯◯：平たい柄はクリップで挟めません。太柄スポンジなどで丸くしてください」）
- `tool_shaft_shape=flat`（平たい柄）は、MVPのC字クリップでは挟めない。保存は受け付け、`assumptions` に残す。生成（§3.4）では、平たい柄の道具の取り付け具だけを作らずに `review.unresolved_issues` で知らせ、ほかの丸い柄の道具の取り付け具は作る。丸い柄の道具が1つもないときだけ `DESIGN_INFEASIBLE`（平たい柄用の取り付け具は作らない。[ADR-0014](adr/0014-multiple-attachments.md)）
- 前の版の `nut_operator`（ナットを回す人）と `grip_strength` はなくした。ねじ締めのコレットとナットをやめ（[ADR-0012](adr/0012-c-clip-dovetail.md)）、道具を手で握らない形にしたため（[ADR-0011](adr/0011-dorsal-cover.md)）。代わりに、ベルトとクリップの扱いやすさを決めるため `donning_by` を聞く
- `activity=other` のときは、チャットで `activity_ja`（やりたいことの説明）と `tool_type` が決まるまで、ケースは `interviewing` のまま（撮影に進めない）。チャットが出した `activity_ja` は、サーバーが `requirements.activity_ja` に保存する
- それ以外は、保存するとケースの `status` が `measuring` になる。チャットのメモはあとから足してもよい

応答 `200 OK`

```json
{
  "requirements": {
    "activity": "draw", "tool_type": "brush", "hand_side": "right",
    "tool_d_mm": 9.5, "tool_d_source": "user", "tool_shaft_size": null, "tool_shaft_shape": "round",
    "finger_state": "fist", "donning_by": "helper", "capture_by": "helper",
    "activity_ja": null, "notes": [], "assumptions": []
  },
  "case_status": "measuring"
}
```

- `tools` を送ったときは、応答の `requirements.tools` に正規化した一覧（各要素に `tool_d_source`・`assumptions` つき）が入る。送らなかったときも、1つの道具の一覧が入る
- `tool_d_source` は `user`（数値で入れた）か `category`（区分から推定）

### 3.2.1 `POST /v1/cases/{case_id}/interview`（任意のチャット）

リクエスト

```json
{ "message": "人差し指の関節の出っ張りが当たると痛いです。長い時間描きたい" }
```

応答 `200 OK`

```json
{
  "turn": {
    "status": "ask",
    "message_ja": "痛い所に当たらないよう、そこのすき間を少し広げます。1回に何分くらい描きますか？",
    "choices": ["15分くらい", "30分くらい", "1時間以上"],
    "notes": ["人差し指の関節の出っ張りが当たると痛い", "長い時間使う"],
    "suggested_changes": [],
    "out_of_scope_reason": "none"
  },
  "requirements": { "notes": ["人差し指の関節の出っ張りが当たると痛い", "長い時間使う"] },
  "case_status": "measuring",
  "turn_count": 1
}
```

- `message` は500文字まで。超えたら `400 INVALID_ARGUMENT`。往復は最大3回
- `notes` はサーバーが `requirements.notes` に足す。`suggested_changes` は画面で確かめてから `PUT requirements` で反映する
- `out_of_scope` のときは `200` で返し、ケースの `status` は変えない

### 3.2.2 `POST /v1/cases/{case_id}/consent`

撮影の前の同意の画面（S3）で「同意して進む」を押したときに呼ぶ。本文は `{ "mesh_consent": true, "consent_text_version": "mesh-consent-2" }`。生成APIが `cases/{case_id}.mesh_consent_at`（日時）と `consent_text_version` を書く。`hand-mesh` と `PUT measurement` は、この記録があり、版が `mesh-consent-2` であることを確かめる。

- `mesh-consent-2` は、前の版（切り抜いたフレームを送ること）に、「手の形の3Dデータ（写真ではありません）を、作った形を確かめるために保存します。ケースを消すと消えます」を足したもの（[ADR-0010](adr/0010-hand-mesh-fusion.md)）。手のメッシュを保存するようになり、同意の中身が変わったので、版を上げる
- 古い版（`2026-11-07`）の同意しかないケースは、撮影の前に同意の画面をもう一度出す（`hand-mesh` は `422 CONSENT_REQUIRED` を返す）
- 同意を取り消す場合は `{ "mesh_consent": false }` を送り、記録を消す（以後、採寸に進めない）。すでに保存した手のメッシュは、ケースを消すまで残る（消したいときはケースを消す。[data-model.md §5](data-model.md#5-保存期間と削除)）

### 3.3 `PUT /v1/cases/{case_id}/measurement`

リクエスト：[measurement.md §12](measurement.md#12-出力するjsonmeasurement22) のJSON（**2.2**）そのもの。手の甲の4区間の長さ（倍率に使う）・指の区間の長さ（確認用）・付け根の位置・比較用の角度、`capture.mesh_id`・`capture.mesh_result_token`、点を直したときは `manual_points` を含む。**手のメッシュそのものは送らない**（`hand-mesh` がStorageに置いた未補正のメッシュを、生成APIが読む）。ブラウザが重いファイルを運ばずに済み、ブラウザが書き換えたメッシュを受け取らずに済むため。

**点を直したとき**（S5。代表のフレーム2〜3枚の、手首と指の付け根の5点）は、ブラウザが直したフレームから手の甲の4区間の長さを出し直し、`manual_points` を付けて**同じAPIでもう一度送る**。生成APIは倍率 k を出し直し、新しい `measurement_id` で実寸のメッシュを保存する。メッシュの形と姿勢は変わらず、大きさだけが変わるので、GPU（`hand-mesh`）は呼ばない。値のスライダーで直す機能はMVPにない（[measurement.md §13](measurement.md#13-確認と点の修正s5)）。

処理の順番

1. スキーマと、[measurement.md §12](measurement.md#12-出力するjsonmeasurement22) の項目間の制約を確かめる。合わなければ `422 MEASUREMENT_INVALID`（どの項目がどの制約に違反したかを `details` に入れる）。手のモデルの計算の前に検証し、負の長さや欠けた付け根の位置を計算に渡さない
2. ケースに同意の記録（`mesh_consent_at`、`consent_text_version = mesh-consent-2`）があることを確かめる
3. `capture.mesh_result_token` の署名（`hand-mesh` と共有の鍵でHMAC-SHA256）・ケースID・角度のハッシュを確かめる。メッシュ復元を通らない角度を受け付けないため
4. 未補正のメッシュ `cases/{case_id}/hand/raw/{mesh_id}.glb` を読み、ファイルのSHA-256が、トークンに入った `mesh_sha256` と一致することを確かめる。関節の位置（21点）は、ブラウザの値ではなく、このファイルに入った値（`extras.joints_mm`）を使う
5. **倍率** `k = median(測った区間の長さ ÷ メッシュの関節どうしの長さ)` を、**手の甲で見える4区間**（手首→人差し指の付け根、手首→中指の付け根、手首→小指の付け根、人差し指の付け根→小指の付け根）の比から出す。握りこぶしでは指の区間が重なって隠れ、MediaPipeの点がずれやすいため（[measurement.md §8.2](measurement.md#82-メッシュの合成と実寸化)）。指の区間の比は、ばらつきの確かめにだけ使い、4区間の k から10%を超えて離れたら警告 `MESH_SCALE_INCONSISTENT` を付ける。k が0.5〜2.0の外なら、点の取り違えか1円玉の誤検出とみなして `422 MEASUREMENT_INVALID`（範囲は入力の安全のための仮の値。要確認）
6. メッシュの頂点に k を掛け、**実寸のメッシュ**（手の座標系、mm）を `cases/{case_id}/hand/{measurement_id}.glb` に保存する
7. 実寸のメッシュから、**カバーの目印**を出す：手のひら側を切る面の基準（PIP関節の中心の平均の高さと、付け根の関節の中心＋8mmの浅い方）、手首側を切る位置の基準（手首→中指の付け根の長さ）、レールを付ける位置と向き（人差し指の基節の、親指側かつ手の甲側の外面）、ベルトのスリットと空気穴を置ける範囲（[generation-pipeline.md](generation-pipeline.md)）
8. 部品の基準値（baseline）を作る

応答 `200 OK`

```json
{
  "accepted": true,
  "measurement_id": "m_02",
  "warnings": ["ANGLE_DISAGREE"],
  "hand_model": {
    "frame": "hand",
    "mesh_path": "cases/c_8f3k2m/hand/m_02.glb",
    "scale_factor": 1.17,
    "scale_source": "manual_points",
    "scale_spread_ratio": 0.04,
    "joints_mm": {
      "wrist": [0.0, 0.0, 0.0],
      "index": [[-21.4, 86.0, 0.0], [-22.0, 104.7, 24.2], [-21.1, 101.0, 44.5], [-19.8, 90.2, 52.0]]
    },
    "cover_landmarks": {
      "palm_cut_base_mm": 38.6,
      "wrist_to_middle_mcp_mm": 92.4,
      "rail_anchor": { "point_mm": [-31.5, 95.0, -6.0], "direction": [0.02, 0.62, 0.78] },
      "slit_zones": { "thumb_side": [-36.0, 52.0], "pinky_side": [44.0, 50.0] }
    }
  },
  "baseline": [
    { "part_id": "cover", "name": "cover_thickness_mm", "value": 2.5, "source": "default" },
    { "part_id": "cover", "name": "wrist_cut_mm", "value": 37.0, "source": "measured" },
    { "part_id": "cover", "name": "palm_cut_offset_mm", "value": 0.0, "source": "default" },
    { "part_id": "c_clip", "name": "tool_d_mm", "value": 9.5, "source": "interview" },
    { "part_id": "c_clip", "name": "angle_deg", "value": 20, "source": "rule" }
  ],
  "case_status": "designing"
}
```

- `hand_model` は手の座標系（[measurement.md §8.1](measurement.md#81-手の座標系)）の、実寸（倍率 k を掛けたあと）の値。S5の3D表示に使う。画面は `mesh_path` をStorage SDKで読んでthree.jsで表示し、カバーの目印（切る面・レールの位置）を重ねる
- 前の版のカプセル（`capsules`）とすき間の円（`cavities`）、握りの軸は返さない。カバー方式では握りの軸がなく、殻は手の面そのものから作るため（[ADR-0011](adr/0011-dorsal-cover.md)）
- `joints_mm` は実寸の関節の位置（手首と、指ごとに付け根・PIP・DIP・指先の4点）。例では人差し指だけを示した（握った形なので、指先が付け根の近くに戻っている）
- `cover_landmarks` は**実際の手の座標**（`frame: "hand_actual"`）で返す。`palm_normal`（手のひらの向き）と `outward` も入る。`palm_cut_base_mm` は、PIP関節の中心の平均の、手のひらの法線の向きの高さ。手のひら側を切る面は、ここに `palm_cut_offset_mm` を足した高さ。`rail_anchor` は正準形で、`direction` は人差し指の基節の向き（指先の向き）
- `scale_source` は `auto`（自動の点）か `manual_points`（直した点を使った）。`scale_spread_ratio` は、指の区間の比の中央値と k の差÷k。OT画面で倍率のばらつきを見せる
- 値の修正（`overrides`）は、MVPでは受け付けない（スキーマで `maxItems: 0`）。直せるのは、倍率に使う5点（`manual_points`）だけ
- 同じケースに何度送ってもよい（最後に保存した値が使われる）。保存のたびに新しい `measurement_id` を作り、実寸のメッシュも別のファイルにする（前の版の形が参照しているため）。ただし、§1.1の処理中の印が有効な間の保存は `409 CONFLICT`
- 採寸をやり直して保存した場合、それまでの形（designs）は残す。ただし、ケースの `current_design_id` は空に戻す
- 時間：メッシュの読み込み・倍率・カバーの目印で1〜2秒（要確認）

### 3.4 `POST /v1/cases/{case_id}/designs`

リクエスト

```json
{ "style": { "color": "#2A9D8F", "pattern": "none" } }
```

- 処理には中央値で約75秒、最大で約170秒かかる（カバーの殻の計算の10〜20秒を含む。[non-functional.md](non-functional.md)）。ブラウザは応答を待ちながら、2秒ごとに `GET /v1/cases/{case_id}`（`current_design_id`）と `GET /v1/cases/{case_id}/designs/{design_id}` を呼び、`progress` を読んで進み具合を出す（`app/lib/screens/design.dart`）
- 部品は、**カバー本体**（`cover`。空気穴 `air_holes`・ベルトのスリット `strap_slits`・アリ溝のレール `rail` を含む）と**C字クリップ**（`c_clip`）を必ず作る。**TPUの筒**（`tpu_sleeve`）と2個目のクリップは、道具と要望からGeminiが選ぶ（[generation-pipeline.md](generation-pipeline.md)、[ADR-0011](adr/0011-dorsal-cover.md)〜[ADR-0013](adr/0013-clip-angle-variants.md)）
- 描く前に、**カバーの殻**を作る：実寸の手のメッシュ（正準形）の符号付き距離から、手の面から距離 `HAND_CLEARANCE_MM`（c）〜 c ＋ `cover_thickness_mm`（t）の層を取り、手のひら側・手首側・親指・人差し指側の外を切る面と、なめらかな共通部分（半径 `edge_radius_mm`）でつなぎ、閉じた面（`cover_shell.stl`）にする。切り口のふちも丸くなる。続けて、手を c だけ広げた立体（**内側を守る立体** `cover_keepout.stl`。レールの土台が内側へ出ないように、最後に引く）を作る。右手なら最後に鏡像に戻す。11/7のスパイク（手元のPC）の同じ仕組みで約12秒。カバーの外接箱の大きさで変わるので、10〜20秒を見込む。Cloud Run（4 vCPU）での時間は要確認
- 殻・内側を守る立体・距離場は、採寸の版ごとのフォルダ `internal/cases/{case_id}/cover/{measurement_id}/` の下（`shell/<24桁>`・`keepout/c{c}`・`sdf`）に置く（誰も読めない場所。[data-model.md §3](data-model.md#3-cloud-storageのパス)）。採寸の版（`hand_measurement_id`）と、殻を決める引数（c・t・`palm_cut_offset_mm`・`wrist_cut_mm`・`edge_radius_mm`）が同じなら、前の版の殻を使い回す。印刷用STLを作るとき（§3.6・§3.11）もこれを使う
- OpenSCADは、殻を `import()` して、ベルトのスリット・空気穴を引き、アリ溝のレールを足し、最後に内側を守る立体を引く。スリット・空気穴・レールの位置と向きは、生成APIが手のメッシュとカバーの目印（§3.3）から計算して `-D` で渡す。クリップとTPUの筒は、それぞれ別に描く（`mode=c_clip` など）
- **取り付け具（道具ごとのクリップ）**（[ADR-0014](adr/0014-multiple-attachments.md)）：`requirements.tools`（古いケースは今までの項目から1つ）の丸い柄の道具ごとに、C字クリップを1つずつ作る（1つの版に最大4つ。カバーは1つ）。最初の丸い柄の道具が**主な取り付け具**で、今までの項目（`params` の `c_clip`、`clip_angle_deg`、`clip`、`tool`、`files.parts.c_clip`）と確認用画像4枚は主な取り付け具の値・形にする。ほかの取り付け具の角度は、寸法決め（`dimension.v2`）が取り付け具ごとに60／70／80から選ぶ（モックは道具ごとの目安 筆70・ペン60・スプーン60。選択肢にない答えは目安に直して `clamped` に `attachment_id` つきで残す）。範囲チェック（R1〜R5）と描いたあとのクリップの検査（R6f・R6h）は取り付け具ごと
  - 平たい柄の道具は取り付け具を作らず、「◯◯：平たい柄はクリップで挟めません。太柄スポンジなどで丸くしてください」を `review.unresolved_issues`（severity `medium`）に書き、版は `needs_attention`
  - ある取り付け具だけが、範囲チェックの致命的な違反・R6f（クリップの開き）・描けない（OpenSCADの失敗）のどれかになったら、その取り付け具を版から外し、「◯◯のクリップは作れませんでした（理由）」を `unresolved_issues`（severity `medium`）に書いて、版は `needs_attention`。主な取り付け具が外れたら、次の取り付け具を主に繰り上げ、今までの項目をうめ直す。取り付け具が1つだけのときは今までどおり（R6f は `needs_attention`、描けなければ `RENDER_FAILED`）
  - どれかの取り付け具が R6h（道具の通り道）に落ちたら `needs_attention`。取り付け具が2つ以上なら、文に道具の名前を入れる（同じ道具が2つなら太さも。例「ペン 9mm」）
  - プレビュー用STLの名前は、取り付け具が1つなら今までどおり `c_clip_{角度}.preview.stl`、2つ以上なら `c_clip_{道具}_{角度}.preview.stl`（同じ道具が2つなら太さを `_d0900` のように足す。それでも同じ名前になるときは取り付け具のIDを足す）
- 版に記録するもの：`hand_measurement_id`、`scale_factor`、`hand_clearance_mm`、`cover_shell_sha256`、`clip_angle_deg`、`clip`（使った固定STL）、`tool`（道具の軸。S7の3D表示が棒を描くのに使う）、部品ごとのファイル（下の応答の `files.parts`）、取り付け具の一覧 `attachments`（下の応答。[data-model.md §2.5](data-model.md#25-casescaseiddesignsdesignid)）。`geometry_hash` は、引数・`cover_shell_sha256`・固定値の版から作る（[data-model.md §2.5](data-model.md#25-casescaseiddesignsdesignid)）
- 描いたあと、実際の形で検査する（R6。[generation-pipeline.md](generation-pipeline.md)）：カバーは閉じた面で1つのかたまり、最小の厚さ ≥ `MIN_WALL_MM`、**手のひら側に材料がない**（切る面より手のひら側に頂点がない）、**手首を覆わない**（手首から25mm以内に頂点がない）、内側の面と手の距離が c 以上。クリップは開きの幅が道具の太さより小さく（抜けない）、サポートなしで刷れること。手のひら側と手首の検査は、装具にしないための安全の決まりなので、AIや画面の操作で外すことはできない
- `design_id` は処理を始めた直後に作るので、Firestoreの `cases/{case_id}.current_design_id` を見れば、応答が返る前から追いかけられる
- 同じケースに有効な処理中の印があれば `409 CONFLICT`。期限切れの回収は§1.1に従う

応答 `200 OK`

```json
{
  "design": {
    "design_id": "d_01",
    "revision": 1,
    "status": "ready",
    "parts": [
      { "part_id": "cover", "variant": "standard", "reason_ja": "握った形のまま、手の甲側からかぶせられる形にしました" },
      { "part_id": "air_holes", "variant": "standard", "reason_ja": "長い時間使うので、手の甲に空気穴を6つ開けました" },
      { "part_id": "strap_slits", "variant": "single", "reason_ja": "ベルト1本で留めます。回ってしまう場合は2本にできます" },
      { "part_id": "rail", "variant": "standard", "reason_ja": "人差し指の横にクリップを差し込みます" },
      { "part_id": "c_clip", "variant": "standard", "reason_ja": "筆の太さ9.5mmに合わせ、押し込むだけで留まるクリップにしました" }
    ],
    "params": [
      {
        "part_id": "c_clip", "name": "angle_deg", "value": 70, "unit": "deg",
        "range": [60, 80], "choices": [60, 70, 80], "baseline": 70, "source": "ai",
        "reason_ja": "絵を描くので、筆を立て気味の70度にしました。少し寝かせたいときは60度も選べます",
        "clamped": false
      },
      {
        "part_id": "cover", "name": "cover_thickness_mm", "value": 2.5, "unit": "mm",
        "range": [2.0, 3.5], "baseline": 2.5, "source": "ai",
        "reason_ja": "クリップの力を受けるレールのまわりが割れにくい厚さにしました",
        "clamped": false
      }
    ],
    "review": {
      "rounds": 2,
      "final_verdict": "ok",
      "unresolved_issues": []
    },
    "warnings": [],
    "hand_overlay": { "mesh_path": "cases/c_8f3k2m/hand/m_02.glb", "frame": "hand" },
    "files": {
      "parts": {
        "cover": { "preview_stl": "cases/c_8f3k2m/designs/d_01/cover.preview.stl" },
        "c_clip": { "preview_stl": "cases/c_8f3k2m/designs/d_01/c_clip_70.preview.stl" }
      },
      "views": {
        "front": "cases/c_8f3k2m/designs/d_01/views/front.png",
        "side": "cases/c_8f3k2m/designs/d_01/views/side.png",
        "top": "cases/c_8f3k2m/designs/d_01/views/top.png",
        "iso": "cases/c_8f3k2m/designs/d_01/views/iso.png"
      }
    },
    "attachments": [
      {
        "id": "a1", "tool_index": 0, "tool_type": "brush", "activity": "draw", "tool_d_mm": 9.5, "tool_d_source": "user",
        "angle_deg": 70, "angle_source": "ai", "reason_ja": "絵を描くので、筆を立て気味の70度にしました。少し寝かせたいときは60度も選べます",
        "primary": true, "print_key": "c_clip",
        "files": { "preview_stl": "cases/c_8f3k2m/designs/d_01/c_clip_70.preview.stl" },
        "tool": { "center": [-31.5, 95.0, 4.0], "axis": [0.0, -0.34, -0.94], "tip_mm": 100.0, "rear_mm": 50.0, "diameter_mm": 9.5 },
        "clip": { "source": "library", "variant": "c_clip_d0950_a70", "tool_d_mm": 9.5, "angle_deg": 70 },
        "checks": [ { "rule": "R6f", "ok": true, "severity": "error" }, { "rule": "R6h", "ok": true, "severity": "warning" } ]
      }
    ],
    "approval": { "status": "none" },
    "summary_ja": "こぶしの外側に沿うカバーに、筆の太さ9.5mmに合わせた70度のクリップを付けました。手のひら側と手首は開けてあります。"
  }
}
```

`status` が `needs_attention` のときは、`review.unresolved_issues` に解決しなかった指摘が入る（作らなかった・作れなかった取り付け具の知らせも入る）。

- `attachments`：取り付け具の一覧（`attachments[0]` が主な取り付け具）。1つの取り付け具は、`id`（`a1`・`a2`…。`requirements.tools` の何番目か＋1）、`tool_index`、`tool_type`、`activity`、`tool_d_mm`・`tool_d_source`、`angle_deg`・`angle_source`（`ai`／`rule`／`user`）・`reason_ja`、`primary`、`print_key`（印刷用のファイルの地図のキー。主は `c_clip`、ほかは `c_clip_a2` のように `.`・`:` を使わない）、`files.preview_stl`（主な取り付け具は `files.parts.c_clip.preview_stl` と同じ）、`tool`（道具の軸）、`clip`（使ったクリップ）、`checks`（R6f・R6h の結果）。上の例は道具が1つのとき。道具が2つ（筆とスプーン）なら、`attachments` は2つになり、プレビュー用STLは `c_clip_brush_70.preview.stl`・`c_clip_spoon_60.preview.stl`

- カバーとクリップのSTLは、**手の座標系**（実際の手の形、mm）で描く。そのため、S7のプレビューでは、手のメッシュ（`hand_overlay.mesh_path`）をそのまま重ねられる（前の版の握りの座標系への変換 `grip_transform` はなくした）。クリップは、レールに差し込んだ位置に置いて描く
- 印刷用STL（§3.6）は、部品ごとに刷る向きに置き直す（カバーは手のひら側を切った面を下、クリップは輪が机と平行）

### 3.5 `POST /v1/cases/{case_id}/designs/{design_id}/refine`

次の6つのうち、どれか1つだけを送る。`instruction`・`param_changes`・`clip_angle_deg`・`tool_d_mm` には、直す取り付け具の `attachment_id`（`a1`・`a2`…）を添えてよい（なければ主な取り付け具。版にない ID は `INVALID_ARGUMENT`。`add_attachment`・`style` には添えない）。取り付け具のない古い版は、`params` と要求の今までの項目から主な取り付け具を1つ作ってから進める（ID は要求の道具の一覧の最初の丸い柄の位置＋1）。`requirements.tools` のない古い要求は、今までの項目から道具を1つ作る（保存した太さが区分から推定した値なら、`tool_d_source: category` と「道具の太さは推定です」の知らせを引き継ぐ）。

```json
{ "instruction": "人差し指の関節のところをもう少しゆったりさせて", "attachment_id": "a2" }
```

```json
{ "param_changes": [ { "part_id": "air_holes", "name": "count", "value": 8 } ] }
```

```json
{ "clip_angle_deg": 80, "attachment_id": "a2" }
```

```json
{ "tool_d_mm": 9.0, "attachment_id": "a2" }
```

```json
{ "add_attachment": { "activity": "eat", "tool_type": "spoon", "tool_d_mm": 12.0, "tool_shaft_size": null, "tool_shaft_shape": "round" } }
```

```json
{ "style": { "color": "#E76F51", "pattern": "none" } }
```

- `instruction`：Geminiの `refine` で引数の変更に直し、範囲チェック → 描画 → 確認1回、の順に進む
- `param_changes`：画面で直接直した場合。Geminiは呼ばず、範囲チェック → 描画、の順に進む。ユーザーの意思による変更なので、「AIが変えてよい幅」（R3）は当てはめず、`override_by_user=true` として記録する（OT画面で目立たせる）。範囲（R2）と組み合わせ（R4）のルール、描いたあとの検査（R6。手のひら側・手首を含む）は当てはめる
- `clip_angle_deg`：**クリップの角度だけを変える**（60／70／80のどれか。カタログの選択肢。S7の角度の選択）。Geminiは呼ばず、新しい版を作るが、**クリップだけを描き直し**、カバーのファイル・確認用画像のうちカバーだけのものは前の版のものを使い回す。確認用画像は、クリップと筆の向きが変わるので描き直す。角度を変える仕組み（回す部品）は作らず、角度違いのクリップを刷って差し替える（[ADR-0013](adr/0013-clip-angle-variants.md)）。`param_changes` で `c_clip.angle_deg` を送っても同じ扱いになる
- 殻は、殻を決める引数（c・t・`palm_cut_offset_mm`・`wrist_cut_mm`・`edge_radius_mm`）が変わったときだけ作り直す（10〜20秒）。空気穴・スリット・レール・クリップだけの変更では、前の版の殻を使い回す（§3.4）
- `style`：**色だけの変更なら、新しい版を作らず**、その版の `style.color` だけを書き換える（描き直さない。`geometry_hash` に色は入らないので、確認済みもそのまま）。OTの確認後でも変えられる
- 色だけの変更以外は、新しい `design_id`（`revision` が1つ増える）を作り、§3.4と同じ形で返す。前の版の「確認済み」は引き継がない（角度だけの変更も、刷る部品が変わるので引き継がない）
- 指示があいまいなときは、新しい版を作らずに `200` で `{ "clarify_ja": "人差し指の付け根の関節ですか？ 2つ目の関節ですか？" }` を返す
- **取り付け具ごとに直す**（[ADR-0014](adr/0014-multiple-attachments.md) §4）：
  - `instruction`・`param_changes`：カバーなど `c_clip` 以外の値は今までどおり版の全部に効かせる。`c_clip` の値は `attachment_id` の取り付け具にだけ効かせる。主でない取り付け具のときは、その取り付け具の太さと角度に置き換えた引数の一覧を Gemini の `refine` に渡し、`c_clip` の変更をその一覧で範囲チェックして、角度だけを取り付け具に書き戻す（太さは聞き取りが決める値なので、言葉や数値では変わらない。下の `tool_d_mm` で直す）
  - `clip_angle_deg`：その取り付け具の角度だけを変える。主な取り付け具なら今までの項目（`params` の `c_clip.angle_deg`・`clip_angle_deg`）も変わる
  - `tool_d_mm`（3.5〜20.0mm。§3.2 の要求と同じ、人が入れる太さの範囲。外れたら `INVALID_ARGUMENT`）：その取り付け具の柄の太さを直す（`tool_d_source` は `user`）。ケースの `requirements.tools` のその道具の太さも直す。主な取り付け具なら、`requirements.tool_d_mm` と `params` の `c_clip.tool_d_mm`（値と基準値）も直す。直した版が作れたときだけ要求を書き換える
  - `clip_angle_deg`・`tool_d_mm` は、角度だけの変更と同じく、Geminiの画像での確認をしない。どれも全部の取り付け具を描き直すが、カバーは前の版の殻を使い回す（殻を決める引数を変えたときを除く）
- **`add_attachment`（取り付け具を足す）**：要素は `requirements.tools` の1つと同じ（`activity`・`tool_type`・`tool_d_mm`（null なら区分 `tool_shaft_size` から推定）・`tool_shaft_size`・`tool_shaft_shape`）
  - 版を作る前に確かめ、次のときは `400 INVALID_ARGUMENT`（新しい版は作らず、回数にも数えない）：版の取り付け具が4つ（`MAX_ATTACHMENTS`）ある、または `requirements.tools` がすでに4つある（平たい柄の道具も数に入る）／平たい柄（`tool_shaft_shape=flat`。文は「◯◯：平たい柄はクリップで挟めません。太柄スポンジなどで丸くしてください」）／太さが §3.2 の要求と同じ範囲（3.5〜20.0mm）の外／項目の形が違う
  - 足す取り付け具の ID は版の中の最大の番号＋1、`tool_index` は `requirements.tools` の最後の位置。角度は Gemini の `attachment` で60／70／80から選ぶ（モックは道具ごとの目安。選択肢にない答えは目安に直して `clamped` に残す）。ほかの取り付け具と主な取り付け具は前の版のまま。カバーは前の版の殻を使い、`cover_shell_sha256` とカバーのプレビュー用STLは前の版と同じ。画像での確認はしない
  - 足す取り付け具が範囲チェックの致命的な違反（`DESIGN_INFEASIBLE`）・R6f（クリップの開き）・描けない（OpenSCADの失敗）のどれかになったら、作りかけの版を消して、ケースを前の版・前の状態に戻し、エラーを返す（R6f と描けないときは `RENDER_FAILED`。`details` に検査の名前 `rule`（`R6f…`・`render`）と `attachment_id`）。`requirements.tools` にも足さない。§3.4 のように、その取り付け具だけ外して版を作ることはしない
  - 作れたら、足した道具を `requirements.tools` の最後に加える（`assumptions` も道具の名前つきで足す）。主な取り付け具と今までの項目は変わらない
- 取り付け具を足す・直すと新しい版になる。確認済み（`approval`）は引き継がず `{"status": "none"}`、ケースは `previewing` に戻る（OTに頼んだ版や承認済みの版でも、版の `status` が `ready`／`needs_attention` なら直せる。もう一度OTに頼む）。`origin` は `refine_add_attachment`・`refine_tool_d` が加わる

### 3.6 `POST /v1/cases/{case_id}/review-request`

リクエスト

```json
{ "reviewer_email": "ot.demo@example.com", "design_id": "d_02", "message_ja": "筆のカバーとクリップを確認してください" }
```

- 画面は `GET /v1/therapists` の一覧からOTを選ばせる（メールアドレスを打たなくてよい）。一覧にないOTは、メールアドレスを入れて頼める
- `reviewer_email` が `therapists` の許可リストにない場合は `422 REVIEWER_NOT_ALLOWED`
- 対象が最新の `ready`／`needs_attention` の版であることを確かめる
- **この時点で部品ごとの印刷用STLを作る**：その版の引数で、カバー（`mode=cover`）・取り付け具ごとのC字クリップ（`mode=c_clip`）・TPUの筒（選んだときだけ）を `quality=print` で描き、それぞれ刷る向きに置き直して、R6を通す。カバーの殻は、版に記録した `cover_shell_sha256` の `internal/cases/{case_id}/cover/` のファイルを使う（作り直さない）。できたファイルは、まだ誰も読めない場所（`internal/`）に置き、部品ごとのSHA-256（`print_sha256` の map）と、`geometry_hash` を版に記録する。クリップのファイルは取り付け具の数だけできる（キーは `attachments[i].print_key`：主は `c_clip`、ほかは `c_clip_a2`…。名前はプレビューと同じ元に `.stl` をつけたもの。1つなら今まで通り `c_clip_{角度}.stl`）。`geometry_hash` には取り付け具の `(id, tool_d_mm, angle_deg)` も入れる。どれか1つでも（どの取り付け具でも）R6が不合格なら `RENDER_FAILED` を返し、依頼しない（持ち主が `refine` で直してから頼み直す）
- こうすると、OTが見る画像と印刷用STLは同じ引数から作られ、承認のときに描き直さずに済む。デプロイで描画のコンテナが新しくなっても、確認待ちの版はそのまま承認できる
- 処理には20〜60秒かかる。画面は「印刷用のデータを準備しています」と出す
- ケースの `reviewer_email` と `status = in_review` を書き込み、その版の `approval.status` を `requested` にする

応答 `200 OK`

```json
{ "case_status": "in_review", "review_url": "https://<project>.web.app/review/c_8f3k2m" }
```

通知メールは送らない（MVPでは、`review_url` を画面に出してユーザーが伝える）。

### 3.7 `POST /v1/cases/{case_id}/designs/{design_id}/approval`

呼べるのは、ログイン中のメールアドレスが、ケースの `reviewer_email` と同じで、メールが確認済みで、かつ `therapists` にある人だけ。

リクエスト

```json
{
  "decision": "approve",
  "geometry_hash": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "comment_ja": "関節の当たりは良さそうです。最初は短時間から試し、赤みが出たら外してください。",
  "checklist": {
    "dimensions_reviewed": true,
    "edges_safe": true,
    "not_an_orthosis": true,
    "palm_open_wrist_free": true,
    "no_mouth_contact": true,
    "user_informed": true
  }
}
```

- `decision` は `approve` か `reject`。`approve` のときは、`checklist` がすべて `true` でないと `422 CHECKLIST_INCOMPLETE`。`palm_open_wrist_free` は「手のひら側が開いていて、手首を覆っていない（握った指を開かせない・固定しない）」ことをOTが目で確かめた印（自動の検査 R6 と二重にする）
- `geometry_hash` は、OT画面が表示した版の値を送る。最新の版でない、`approval.status` が `requested` でない、またはハッシュが一致しなければ `409 STALE_DESIGN`
- `approve` のとき、サーバーは描き直さない。依頼のときに作った `internal/` の部品ごとの印刷用STLの `print_sha256` を確かめてから、読める場所（`print/` の下。取り付け具ごとのクリップも）にコピーし、トランザクションで `approval.status=approved` にする
- 形を変えたい場合は、OTは差し戻し（`reject`）を選ぶ。持ち主が `refine` で新しい版を作り、OTに頼み直す

応答 `200 OK`

```json
{
  "approval": {
    "status": "approved",
    "reviewer_email": "ot.demo@example.com",
    "decided_at": "2026-11-09T05:12:30Z",
    "comment_ja": "関節の当たりは良さそうです。最初は短時間から試し、赤みが出たら外してください。"
  },
  "files": {
    "print": {
      "cover": "cases/c_8f3k2m/designs/d_02/print/cover.stl",
      "c_clip": "cases/c_8f3k2m/designs/d_02/print/c_clip_70.stl"
    }
  },
  "case_status": "approved"
}
```

### 3.8 `GET /v1/parts`

`scad/catalog.json` のうち、部品ID・種類・引数・単位・範囲・説明を返す。画面のスライダーの範囲と、OT画面の表に使う。

### 3.9 `POST /v1/cases/{case_id}/recover`

本文は空。§1.1の規則で、期限切れだけを `kind` ごとに回収し、`200` で `{ case_status, current_design_id, active_operation, recovered }` を返す。有効な処理は中断しない。S6の待機画面は約16秒ごと（2秒ごとの読み取りの8回に1回）、およびケースを開き直したときに呼ぶ。回収後は版の失敗状態と「もう一度試す」を表示する。

### 3.10 `GET /v1/therapists`

`therapists` の許可リストから、表示名とメールアドレスの一覧を返す。S8でOTを選ぶのに使う。

### 3.11 `POST /v1/cases/{case_id}/designs/{design_id}/prepare-print`（デモのケースだけ）

デモの印（`cases/{case_id}.demo = true`）が付いたケースで、OTの確認なしに印刷用STLを作る。審査員やデモ動画で、最後のダウンロードまで見せるため。

- ケースの `demo` は、ケースを作るときに `settings/runtime.demo_mode` が `true` なら生成APIが `true` にする（管理者がコンソールで切り替える。ケースを作ったあとで変わることはない）
- `demo` でないケースで呼ぶと `403 FORBIDDEN`（ふだんの流れでは、必ずOTの確認を通る）
- 中身は `review-request` と同じ（クリップは取り付け具ごとに1つ。`files.print` は `{ cover, c_clip, c_clip_a2, … }`）：その版の引数で部品ごとに `quality=print` で描き、刷る向きに置き直し、R6を通し、`print/` の下に置く。R6が不合格なら `RENDER_FAILED`
- 版に `print_prepared_at` と `print_sha256` を記録する。`approval.status` は `none` のまま（OTの確認は受けていない）
- 画面（S7・S10）には「デモ用：OTの確認を省略しています。実際に使う前には必ずOTの確認が必要です」と必ず出す

### 3.12 `DELETE /v1/cases/{case_id}`

ケースを消す。S1のカードのメニューの「消す」から、確かめてから呼ぶ。消したあとは元に戻せない。

- 呼べるのは持ち主だけ（ほかの人は `403 FORBIDDEN`、ケースがなければ `404 NOT_FOUND`）
- 有効な処理中の印（`active_operation`）があるあいだは `409 CONFLICT`（形を作っている途中に消すと、書き込みと食い違うため）
- 消すもの（[data-model.md §5](data-model.md#5-保存期間と削除)）：Storageの `cases/{case_id}/`（実寸と未補正の手のメッシュ、STL、画像）と `internal/cases/{case_id}/`、Firestoreの `cases/{case_id}/designs` と `cases/{case_id}/messages`、最後に `cases/{case_id}` 本体。途中で失敗しても、ケースの文書が残っていればもう一度消せる
- OTに確認を頼んでいる途中（`in_review`）でも消せる。消すと、OTの確認の画面も開けなくなる（画面の確認の文で伝える）
- 応答は `200` で `{ "deleted": true, "case_id": "...", "files_deleted": 12 }`

## 4. 手のメッシュ復元サービス `hand-mesh`

生成APIとは別のCloud Runサービス（asia-southeast1、L4）。ブラウザの採寸エンジンから直接呼ぶ。認証・CORS・エラーの形は、生成APIと同じ。

ほかの窓口：`GET /health`（動作確認。モデルの読み込みの状態も返す。手元では `/healthz` も同じ）と、`GET /ready`（Cloud Run の起動の確認用。モデルを読み終わるか、読み込みに失敗するまで `503`）。0台から起きたときの最初のリクエストは、`/ready` が通るまで Cloud Run が待たせる（11/7 の実測で約70秒）。

### `POST /v1/hand`

前の版の `POST /v1/angles`（角度だけを返す）を置き換える。フレームごとに手のメッシュを復元し、**1つの手のメッシュに合成**して、角度と一緒に返す（[ADR-0010](adr/0010-hand-mesh-fusion.md)）。

呼べる人と制限（前の版と同じ）

- 呼べるのは、ログインしていて、そのケースに同意の記録（`cases/{case_id}.mesh_consent_at`、`consent_text_version = mesh-consent-2`。`POST /consent` で生成APIが書く）がある持ち主だけ。`hand-mesh` は、推論の前にFirestoreでこれを確かめる。同意の記録がない、または版が古ければ `422 CONSENT_REQUIRED`
- 本文は `multipart/form-data`：`meta`（JSON）と、`frame_0` 〜 `frame_7`（JPEG、長い辺512px、1枚200KBまで）
- `meta.case_id` を必須とし、サーバーが持ち主であることを確かめる。直接HTTPで呼んでも同じ制限をかける
- 推論の前に、Firestoreのトランザクションで次を確かめ、回数を1つ増やす：共通の停止設定、1人1日20回・全体1日100回の上限、その日の概算費用（`usage/{日付}.estimated_cost_usd`）が `DAILY_COST_LIMIT_USD` 未満であること。だめなら推論を始めず `RATE_LIMITED`／`GENERATION_DISABLED`
- 1回の処理は `MESH_MAX_EXECUTION_SECONDS`（既定60秒）で打ち切る
- 画像はFirestoreにもStorageにもログにも書かない。残すのは回数と費用と、下の未補正のメッシュだけ

処理

1. フレームごとに、SAM 3D Bodyの手のデコーダで、形（`shape`）・体の比率（`scale`）・手の姿勢（`hand`）を出す。左手は画像を左右反転して右手として推定する（手のデコーダは右手だけのため）
2. 手のキーポイントが切り抜きの中に収まっているフレームを有効とする
3. 有効なフレームの `shape`・`scale`・`hand` の**中央値**で、1つの手を作り直す。関節の角度が中央値から30度を超えて外れたフレームは外し、もう一度中央値を取る。1枚だけ外れたフレームに引っぱられないため
4. 手首の面で手の部分を切り出し、切り口をふさいで閉じた面にし、ループ細分割を1回かける（カバーの殻を距離から作るには閉じた面が要り、MHRの手は約2,300頂点と粗いため）
5. 手の座標系（[measurement.md §8.1](measurement.md#81-手の座標系)：原点＝手首、x＝人差し指の付け根→小指の付け根、y＝手首→中指の付け根からx成分を除いたもの、z＝x×y）に置く。左手なら鏡像に戻し、**実際の手**の形にする。単位はmmだが、**大きさは未補正**（MHRの手の大きさのまま。実寸にするのは生成API。§3.3）。大きさの基準（1円玉）はブラウザ側の値だから
6. 関節の角度を、合成した手の関節から、[measurement.md §6](measurement.md#6-フレームごとに求める値) と同じ定義（隣り合う区間の符号付きのなす角、手のひら側が正）で出す。ばらつき（四分位範囲）は、フレームごとの角度から出す
7. 未補正のメッシュを、Cloud Storageの `cases/{case_id}/hand/raw/{mesh_id}.glb` に書く（`hand-mesh` のサービスアカウントが書く。ブラウザからは読めない）。関節の位置（21点、手の座標系、未補正のmm）を、GLBの `extras.joints_mm` に入れる

`meta` の例

```json
{ "case_id": "c_8f3k2m", "hand_side": "right", "frames": [ { "name": "frame_0", "view": "thumb_side" }, { "name": "frame_1", "view": "top" } ] }
```

応答 `200 OK`

```json
{
  "method": "mesh_recovery",
  "model": "sam-3d-body",
  "fusion": "median_params",
  "frames_used": 7,
  "mesh_id": "hm_5q2w9e",
  "mesh_sha256": "sha256:9f2c…",
  "mesh_stats": { "vertices": 9134, "faces": 18264, "watertight": true },
  "joints_mm": {
    "wrist": [0.0, 0.0, 0.0],
    "index": [[-18.3, 73.5, 0.0], [-18.8, 101.4, 12.1], [-18.0, 112.8, 26.9], [-16.9, 116.4, 41.0]]
  },
  "fingers": {
    "index": { "flexion_deg": { "mcp": 58.0, "pip": 72.5, "dip": 18.0 }, "iqr_deg": { "mcp": 6.0, "pip": 8.5, "dip": 5.0 } }
  },
  "warnings": [],
  "result_token": "v1.c_8f3k2m.2026-11-08T10:15:00Z.<角度のハッシュ>.<メッシュのハッシュ>.<HMAC>"
}
```

- `joints_mm` は、未補正の関節の位置。ブラウザはS5の表示の準備にだけ使ってよいが、生成APIは使わない（Storageのファイルの値を使う。§3.3）。例では人差し指だけを示した
- `mesh_stats` の頂点・三角形の数は、細分割1回のあとの目安（スパイクの細分割前は約2,300頂点・約4,500三角形）
- 画像は応答を返したらすぐ捨てる。ログには、件数・処理時間・エラーコードだけを書く
- `result_token`：ケースID・日時・角度のハッシュ・`mesh_sha256` に、Secret Managerに置いた共有の鍵（`MESH_RESULT_HMAC_KEY`）でHMAC-SHA256の署名を付けたもの。鍵はリポジトリにも環境変数のファイルにも入れず、Secret Managerから両サービスに渡す。ブラウザは `mesh_id` を採寸JSONの `capture.mesh_id` に、トークンを `capture.mesh_result_token` に入れて送る
- 呼ぶたびに新しい `mesh_id` を作る（撮り直しで前のメッシュを上書きしない）。採寸に使われなかった未補正のメッシュも、ケースを消すときに一緒に消す（[data-model.md §5](data-model.md#5-保存期間と削除)）
- エラー：`CONSENT_REQUIRED`（422、同意がない・版が古い）、`NO_HAND_DETECTED`（422、有効なフレームが1枚もなかった。撮り直し）、`MESH_UNAVAILABLE`（503、起動中・混雑・処理の60秒超過・**ほかの要求のGPU計算中**（同時に1件だけ計算し、2件目はロック待ちで時間を使わずすぐ返す。2026-11-08）。ブラウザは自動で最大3回やり直す。MediaPipeの角度では代わりにしない）、`MESH_STORE_FAILED`（503、未補正のメッシュをStorageに書けなかった。自動で1回やり直す）
- 何枚の有効なフレームがあれば合成が安定するかは要確認（11/8に、1〜8枚で角度とメッシュのずれを比べる）
- 停止設定は `503 GENERATION_DISABLED`、回数・予算超過は `429 RATE_LIMITED`。この2つは自動再試行しない。`MESH_UNAVAILABLE` の自動再試行も待ち時間を含めて合計5分で終え、予算を超えて続けない
- **Cloud Run自体が返す429**（最大1台・同時1件のため、2人目がインスタンスの空き待ちで受ける。本文がこのAPIのエラーの形ではない）と、アプリの `RATE_LIMITED` は、HTTPの番号ではなく本文の `error.code` で区別する。`error.code` がない429は、`MESH_UNAVAILABLE` と同じ扱いで自動再試行する

時間と費用の見積もり

| 項目 | 値 | 出どころ |
|---|---|---|
| モデルの読み込み | 約48秒（起動のたびに1回） | 11/7のスパイク（手元の RTX 4070 Ti SUPER）。Cloud Run の L4 では、コンテナの起動と重みの読み込みを合わせて1〜3分を見込む（要確認） |
| 推論 | 1フレーム約0.2秒（その起動で最初の1枚は約1秒） | 同上。L4での値は要確認 |
| 合成・切り出し・細分割・保存 | 数秒（合成そのものは0.014秒） | 同上 |
| 1回の費用 | `MESH_COST_PER_CALL_USD`（既定 $0.40）を、回数を増やすときに足す | Cloud Run GPUはインスタンスが動いている間ずっと課金されるので、まばらに呼ぶと、起動（1〜3分）＋処理（1分未満）＋止まるまでの待機（最大約15分。要確認）の分がかかり、1回あたり約(2+1+15)分×$1.26/時 ≈ $0.38。続けて呼べば1回あたりは安くなるので、この額は「まばらに呼んだ場合の見積もり」。精算はしない。自動再試行も1回に数える。デモの時間帯に最小台数を1にした分の費用は、ここには入らない（[non-functional.md §2.6](non-functional.md#26-gpuhand-meshの費用)） |

## 5. エラー

形式

```json
{
  "error": {
    "code": "MEASUREMENT_INVALID",
    "message": "採寸データに範囲外の値があります。採寸画面で点の位置を確認してください。",
    "details": [
      { "field": "palm.hand_width_mcp_mm", "rule": "maximum", "limit": 110, "actual": 121.5 }
    ],
    "retryable": false,
    "request_id": "req_7c1d9e"
  }
}
```

| HTTP | `code` | 意味 | `retryable` |
|---|---|---|---|
| 400 | `INVALID_ARGUMENT` | リクエストの形が正しくない | false |
| 401 | `UNAUTHENTICATED` | IDトークンがない、または無効 | false |
| 403 | `FORBIDDEN` | 持ち主でも、依頼されたOTでもない | false |
| 404 | `NOT_FOUND` | ケースや版がない | false |
| 409 | `CONFLICT` | 同じケースで生成中のものがある | true（少し待つ） |
| 409 | `STALE_DESIGN` | 確認しようとした版が最新ではない | false |
| 422 | `MEASUREMENT_INVALID` | 採寸データがスキーマに合わない。結果トークンや手のメッシュのハッシュが合わない。倍率が範囲外 | false |
| 422 | `OUT_OF_SCOPE` | 装具や口に入れる部品など、対象外 | false |
| 422 | `REVIEWER_NOT_ALLOWED` | 許可リストにないOT | false |
| 422 | `CHECKLIST_INCOMPLETE` | 確認項目が埋まっていない | false |
| 422 | `DESIGN_INFEASIBLE` | 自動で直しても、組み合わせのルール（厚さ、造形サイズなど）を満たせない。例：道具が太すぎる・細すぎてクリップが作れない、道具がすべて平たい柄（MVPのC字クリップでは挟めない。丸い柄の道具が1つでもあれば、平たい柄の道具の取り付け具だけを作らずに版を作る） | false |
| 429 | `RATE_LIMITED` | 回数の上限に達した | true（翌日） |
| 500 | `RENDER_FAILED` | OpenSCADの失敗、カバーの殻が作れなかった、または描いたあとの検査（R6：最小の厚さ、1つのかたまり、手のひら側に材料がない、手首を覆わない、手に食い込まない、クリップが抜けない）で不合格。どの検査かを `details` に入れる | false |
| 502 | `AI_OUTPUT_INVALID` | 聞き直してもGeminiの出力がスキーマに合わない | true |
| 503 | `AI_UNAVAILABLE` | Geminiが混雑している、または一時的なエラー（再試行したあと） | true |
| 503 | `GENERATION_DISABLED` | 停止スイッチが入っている | false |
| 504 | `RENDER_TIMEOUT` | OpenSCADが60秒を超えた | true |
| 504 | `GENERATION_TIMEOUT` | 生成・微調整・OTへの依頼（印刷用STLの作成を含む）・デモの印刷用データ・承認の処理が280秒を超えた | true |
| 422 | `CONSENT_REQUIRED` | `hand-mesh`：ケースに同意の記録がない、または同意の文の版が古い | false |
| 422 | `NO_HAND_DETECTED` | `hand-mesh`：どのフレームでも手の姿勢が出なかった（撮り直し） | false |
| 503 | `MESH_UNAVAILABLE` | `hand-mesh`：起動中・混雑・処理の60秒超過 | true（自動で最大3回） |
| 503 | `MESH_STORE_FAILED` | `hand-mesh`：未補正の手のメッシュをStorageに書けなかった | true（自動で1回） |
| 503 | `GENERATION_INTERRUPTED` | 処理中の印が期限切れになり、異常終了した処理を回収した | true |
| 500 | `INTERNAL` | その他 | true |

- `retryable` が `true` のエラーでは、画面に「もう一度試す」ボタンを出す
- 生成の途中で失敗した場合は、その版の `status` を `failed` にし、`error` に同じ形で記録する
- `MESH_SCALE_INCONSISTENT` はエラーではなく警告（`PUT measurement` の `warnings`）。保存は受け付け、OT画面で目立たせる
