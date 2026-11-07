# 生成APIの仕様

> **このドキュメントで決めたこと**
> 1. 生成APIは、Cloud Run（asia-northeast1）上のHTTP JSON API（`/v1`）とする。認証は、FirebaseのIDトークンを `Authorization: Bearer` で送る方式にする。Firebase Hostingの転送（rewrite）は使わず、ブラウザから直接呼ぶ。Hosting経由だと60秒で打ち切られ、生成が間に合わないため。
> 2. Firestoreへの書き込みはすべてこのAPIが行う。ブラウザはFirestoreを読む（変更を待ち受ける）だけにする。生成は1回のリクエストの中で終わらせ、途中経過はFirestoreに書く。
> 3. エラーは `{"error": {"code", "message", "details", "retryable", "request_id"}}` の形にそろえる。`message` は画面にそのまま出せる日本語にする。

関連：[generation-pipeline.md](generation-pipeline.md)、[data-model.md](data-model.md)、[measurement.md](measurement.md)

---

## 1. 共通

| 項目 | 内容 |
|---|---|
| ベースURL | `https://<サービス名>-<ハッシュ>.asia-northeast1.run.app`（デプロイ後に決まる。フロントエンドにはビルド時に `--dart-define` で渡す） |
| 認証 | `Authorization: Bearer <FirebaseのIDトークン>`。サーバーはFirebase Admin SDKで検証する。Cloud Run自体は誰でも呼べる設定にする（`--no-invoker-iam-check`）。アプリの中でトークンを確かめる |
| App Check（拡張） | `X-Firebase-AppCheck: <トークン>`。入れたら、サーバーはAdmin SDKで検証する |
| CORS | 許可するオリジンは、HostingのURL（`https://<project>.web.app`、`https://<project>.firebaseapp.com`）と、開発用の `http://localhost:<port>` だけ。プリフライト（OPTIONS）はアプリで処理する |
| 形式 | `Content-Type: application/json; charset=utf-8`。キーはスネークケース |
| 単位 | 寸法はmm、角度は度。キーの末尾に `_mm`、`_deg` を付ける |
| リクエストID | すべての応答に `X-Request-Id` を付ける。ログと突き合わせるため |
| タイムアウト | Cloud Runのリクエストのタイムアウトは300秒。生成APIの中では280秒で打ち切る |
| 回数の制限 | 1人1日あたり：生成10回、微調整30回、聞き取り60回。全体で1日あたり生成100回。上限は環境変数で変えられる。超えたら `RATE_LIMITED` |
| 生成の停止スイッチ | 環境変数 `GENERATION_ENABLED=false` にすると、Geminiを呼ぶAPIはすべて `GENERATION_DISABLED` を返す（予算を使い切りそうなときに使う） |

## 2. エンドポイント一覧

| メソッド | パス | 役割 | 呼べる人 |
|---|---|---|---|
| GET | `/healthz` | 動作確認 | 誰でも（認証なし） |
| GET | `/v1/parts` | 部品カタログ（`scad/catalog.json` の公開部分） | ログインした人 |
| POST | `/v1/cases` | ケース（1つの道具づくり）を作る | ログインした人 |
| POST | `/v1/cases/{case_id}/interview` | 聞き取りを1往復進める | 持ち主 |
| PUT | `/v1/cases/{case_id}/measurement` | 採寸結果を保存する | 持ち主 |
| POST | `/v1/cases/{case_id}/designs` | 形を作る（部品選び → 寸法決め → 描画 → 確認） | 持ち主 |
| POST | `/v1/cases/{case_id}/designs/{design_id}/refine` | 言葉や数値、色・模様で直す（新しい版を作る） | 持ち主 |
| POST | `/v1/cases/{case_id}/review-request` | OTに確認を頼む | 持ち主 |
| POST | `/v1/cases/{case_id}/designs/{design_id}/approval` | OTが「確認済み」にするか、差し戻す | 依頼されたOT |

STLと画像は、APIを通さずに、FirebaseのStorage SDKでダウンロードする。読めるかどうかはStorageのセキュリティルールで決める（[data-model.md](data-model.md)）。

## 3. 各エンドポイント

### 3.1 `POST /v1/cases`

リクエスト

```json
{ "title": "筆の握り" }
```

応答 `201 Created`

```json
{
  "case_id": "c_8f3k2m",
  "status": "interviewing",
  "first_turn": {
    "status": "ask",
    "message_ja": "どんなことをしたいですか？",
    "choices": ["筆で絵を描きたい", "ペンで字を書きたい", "スプーンで食べたい"],
    "requirements": {}
  }
}
```

最初の質問は固定の文にし、Geminiは呼ばない（待ち時間とコストを省くため）。

### 3.2 `POST /v1/cases/{case_id}/interview`

リクエスト

```json
{ "message": "筆で絵を描きたい。右手で持ちたい" }
```

応答 `200 OK`

```json
{
  "turn": {
    "status": "ask",
    "message_ja": "筆の柄の太さは分かりますか？",
    "choices": ["6mmくらい", "8mmくらい", "10mmくらい", "分からない"],
    "requirements": {
      "activity_ja": "筆で絵を描く",
      "tool_type": "brush",
      "tool_shaft_diameter_mm": null,
      "tool_shaft_shape": "round",
      "hand_side": "right",
      "pinch_strength": "unknown",
      "assumptions": []
    },
    "out_of_scope_reason": "none"
  },
  "case_status": "interviewing",
  "turn_count": 2
}
```

- `message` は500文字まで。超えたら `400 INVALID_ARGUMENT`
- `turn.status` が `ready` になると、ケースの `status` は `measuring` になる
- `out_of_scope` のときは `200` で返し、ケースの `status` は `interviewing` のままにする。言い直してもらうため

### 3.3 `PUT /v1/cases/{case_id}/measurement`

リクエスト：[measurement.md §12](measurement.md#12-出力するjsonmeasurement20) のJSON（2.0）そのもの。クエリ `?dry_run=true` を付けると、保存せずに手のモデルだけを返す（S5でスライダーを動かしたときの3Dの更新に使う）

応答 `200 OK`

```json
{
  "accepted": true,
  "warnings": ["ANGLE_DISAGREE"],
  "hand_model": {
    "frame": "hand",
    "capsules": [
      { "finger": "index", "segment": "proximal", "p1_mm": [0.0, 82.1, 0.0], "p2_mm": [1.2, 101.5, 33.0], "radius_mm": 9.0 }
    ],
    "cavities": {
      "index": { "diameter_mm": 31.4, "center_mm": [2.0, 88.3, 30.1] },
      "pinky": { "diameter_mm": 27.9, "center_mm": [58.6, 74.0, 25.4] }
    }
  },
  "baseline": [
    { "part_id": "grip_body", "name": "variant", "value": "fitted", "source": "rule" },
    { "part_id": "grip_body", "name": "d_top_mm", "value": 34.4, "source": "measured" },
    { "part_id": "grip_body", "name": "d_bottom_mm", "value": 30.9, "source": "measured" },
    { "part_id": "grip_body", "name": "press_depth_mm", "value": 1.5, "source": "default" },
    { "part_id": "collet", "name": "tool_d_max_mm", "value": 8.6, "source": "interview" }
  ],
  "case_status": "designing"
}
```

- `hand_model` は手の座標系（[measurement.md §8.1](measurement.md#81-手の座標系)）の値。S5の3D表示に使う。握りの座標系に直したカプセル（`grip_body.capsules`）は、`POST designs` の中で計算し、版に記録する
- 同じケースに何度送ってもよい（最後に保存した値が使われる）

- スキーマに合わなければ `422 MEASUREMENT_INVALID`。どの項目がどの制約に違反したかを `details` に入れる
- 採寸をやり直して保存した場合、それまでの形（designs）は残す。ただし、ケースの `current_design_id` は空に戻す

### 3.4 `POST /v1/cases/{case_id}/designs`

リクエスト

```json
{ "style": { "color": "#3A7CA5", "pattern": "none" } }
```

- 処理には最大で約150秒かかる（[non-functional.md](non-functional.md)）。ブラウザは応答を待ちながら、`cases/{case_id}/designs/{design_id}` の `progress` を読んで進み具合を出す
- `design_id` は処理を始めた直後に作るので、Firestoreの `cases/{case_id}.current_design_id` を見れば、応答が返る前から追いかけられる
- 同じケースで生成中のものがあれば `409 CONFLICT`

応答 `200 OK`

```json
{
  "design": {
    "design_id": "d_01",
    "revision": 1,
    "status": "ready",
    "parts": [
      { "part_id": "grip_body", "variant": "oval", "reason_ja": "手の中で回りにくいよう楕円にしました" },
      { "part_id": "collet", "variant": "standard", "reason_ja": "筆の太さが変わっても締めて固定できます" },
      { "part_id": "collet_nut", "variant": "wings", "reason_ja": "つまむ力が弱くても回せる羽根付きにしました" }
    ],
    "params": [
      {
        "part_id": "grip_body", "name": "d_top_mm", "value": 34.0, "unit": "mm",
        "range": [18, 55], "baseline": 34.2, "source": "ai",
        "reason_ja": "人差し指のすき間 31.4mm に、沿わせる分（1.5mm×2）を足した34.4mmを、扱いやすい34.0に丸めました",
        "clamped": false
      }
    ],
    "review": {
      "rounds": 2,
      "final_verdict": "ok",
      "unresolved_issues": []
    },
    "warnings": [],
    "files": {
      "preview_stl": "cases/c_8f3k2m/designs/d_01/preview.stl",
      "views": {
        "front": "cases/c_8f3k2m/designs/d_01/views/front.png",
        "side": "cases/c_8f3k2m/designs/d_01/views/side.png",
        "top": "cases/c_8f3k2m/designs/d_01/views/top.png",
        "iso": "cases/c_8f3k2m/designs/d_01/views/iso.png"
      }
    },
    "approval": { "status": "none" },
    "summary_ja": "人差し指側を34mm、くぼみ4つの楕円の握りにしました。"
  }
}
```

`status` が `needs_attention` のときは、`review.unresolved_issues` に解決しなかった指摘が入る。

### 3.5 `POST /v1/cases/{case_id}/designs/{design_id}/refine`

次の3つのうち、どれか1つだけを送る。

```json
{ "instruction": "もう少し太くして" }
```

```json
{ "param_changes": [ { "part_id": "grip_body", "name": "groove_depth_mm", "value": 2.5 } ] }
```

```json
{ "style": { "color": "#E8A0BF", "pattern": "rings" } }
```

- `instruction`：Geminiの `refine` で引数の変更に直し、範囲チェック → 描画 → 確認1回、の順に進む
- `param_changes`：画面のスライダーなどで直接直した場合。Geminiは呼ばず、範囲チェック → 描画、の順に進む。ユーザーの意思による変更なので、「AIが変えてよい幅」（R3）は当てはめず、`override_by_user=true` として記録する（OT画面で目立たせる）。範囲（R2）と組み合わせ（R4）のルールは当てはめる
- `style`：色だけの変更なら描き直さない（プレビューの色だけ変える）。模様を変えた場合は描き直す
- どの場合も、新しい `design_id`（`revision` が1つ増える）を作り、§3.4と同じ形で返す。前の版の「確認済み」は引き継がない
- 指示があいまいなときは、新しい版を作らずに `200` で `{ "clarify_ja": "握り全体を太くしますか？人差し指側だけですか？" }` を返す

### 3.6 `POST /v1/cases/{case_id}/review-request`

リクエスト

```json
{ "reviewer_email": "ot.demo@example.com", "design_id": "d_02", "message_ja": "筆の握りを確認してください" }
```

- `reviewer_email` が `therapists` の許可リストにない場合は `422 REVIEWER_NOT_ALLOWED`
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
  "comment_ja": "くぼみの位置は良いです。最初は短時間から試してください。",
  "checklist": {
    "dimensions_reviewed": true,
    "edges_safe": true,
    "not_an_orthosis": true,
    "no_mouth_contact": true,
    "user_informed": true
  }
}
```

- `decision` は `approve` か `reject`。`approve` のときは、`checklist` がすべて `true` でないと `422 CHECKLIST_INCOMPLETE`
- 確認を頼まれた版より新しい版が作られていたら `409 STALE_DESIGN`（古い版を確認済みにしないため）
- `approve` のとき、サーバーは `mode=print` で印刷用STLを作り、範囲チェックR6を通してから、`approval.status = approved` にする

応答 `200 OK`

```json
{
  "approval": {
    "status": "approved",
    "reviewer_email": "ot.demo@example.com",
    "decided_at": "2026-11-09T05:12:30Z",
    "comment_ja": "くぼみの位置は良いです。最初は短時間から試してください。"
  },
  "files": { "print_stl": "cases/c_8f3k2m/designs/d_02/print.stl" },
  "case_status": "approved"
}
```

### 3.8 `GET /v1/parts`

`scad/catalog.json` のうち、部品ID・種類・引数・単位・範囲・説明を返す。画面のスライダーの範囲と、OT画面の表に使う。

## 4. 手のメッシュ復元サービス `hand-mesh`

生成APIとは別のCloud Runサービス（asia-southeast1、L4）。ブラウザの採寸エンジンから直接呼ぶ。認証・CORS・エラーの形は、生成APIと同じ。

### `POST /v1/angles`

- 呼べるのは、ログインしていて、撮影の前に同意した人だけ。採寸を使う人は全員が同意している（同意したかは、リクエストの `consent: true` と、ブラウザの画面で確かめる。サーバーは画像を保存しないので、同意の記録はケースの `measurement.capture.mesh_consent` に残る）
- 本文は `multipart/form-data`：`meta`（JSON）と、`frame_0` 〜 `frame_7`（JPEG、長い辺512px、1枚200KBまで）

`meta` の例

```json
{ "consent": true, "hand_side": "right", "frames": [ { "name": "frame_0", "view": "thumb_side" }, { "name": "frame_1", "view": "top" } ] }
```

応答 `200 OK`

```json
{
  "method": "mesh_recovery",
  "model": "sam-3d-body",
  "fingers": {
    "index": { "flexion_deg": { "mcp": 58.0, "pip": 72.5, "dip": 18.0 }, "iqr_deg": { "mcp": 6.0, "pip": 8.5, "dip": 5.0 }, "frames_used": 7 }
  },
  "warnings": []
}
```

- 画像は応答を返したらすぐ捨てる。ログには、件数・処理時間・エラーコードだけを書く
- エラー：`CONSENT_REQUIRED`（422、同意がない）、`NO_HAND_DETECTED`（422、どのフレームでも手の姿勢が出なかった）、`MESH_UNAVAILABLE`（503、起動中・混雑。ブラウザは自動で最大3回やり直す。MediaPipeの角度では代わりにしない）

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
| 422 | `MEASUREMENT_INVALID` | 採寸データがスキーマに合わない | false |
| 422 | `OUT_OF_SCOPE` | 装具や口に入れる部品など、対象外 | false |
| 422 | `REVIEWER_NOT_ALLOWED` | 許可リストにないOT | false |
| 422 | `CHECKLIST_INCOMPLETE` | 確認項目が埋まっていない | false |
| 422 | `DESIGN_INFEASIBLE` | 自動で直しても、組み合わせのルール（穴のまわりの厚さ、造形サイズなど）を満たせない。例：細い握りに太い道具を挟もうとした | false |
| 429 | `RATE_LIMITED` | 回数の上限に達した | true（翌日） |
| 500 | `RENDER_FAILED` | OpenSCADの失敗、またはメッシュの確認（R6）で不合格 | false |
| 502 | `AI_OUTPUT_INVALID` | 聞き直してもGeminiの出力がスキーマに合わない | true |
| 503 | `AI_UNAVAILABLE` | Geminiが混雑している、または一時的なエラー（再試行したあと） | true |
| 503 | `GENERATION_DISABLED` | 停止スイッチが入っている | false |
| 504 | `RENDER_TIMEOUT` | OpenSCADが60秒を超えた | true |
| 500 | `INTERNAL` | その他 | true |

- `retryable` が `true` のエラーでは、画面に「もう一度試す」ボタンを出す
- 生成の途中で失敗した場合は、その版の `status` を `failed` にし、`error` に同じ形で記録する
