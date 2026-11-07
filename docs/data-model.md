# データモデル

> **このドキュメントで決めたこと**
> 1. Firestoreは「ケース（1つの道具づくり）」を中心に、`cases/{caseId}` の下に会話（messages）と版（designs）を持たせる。ブラウザは読むだけ。ケース・会話・版は生成APIだけが書き、`hand-mesh` は利用回数と費用だけを書く。
> 2. Cloud Storageには、生成APIが作ったSTLと確認用画像だけを置く。ブラウザからのアップロード経路は作らない。手の映像はどこにも保存しない（メッシュ復元に送るフレームも、`hand-mesh` のメモリの中だけで処理する）。
> 3. 印刷用STLは、OTが「確認済み」にした版だけ読めるようにする。StorageのルールからFirestoreを参照して判定する。

関連：[api.md](api.md)、[architecture.md](architecture.md)、[non-functional.md](non-functional.md)

---

## 1. 場所と料金のプラン

| 項目 | 決めたこと | 理由 |
|---|---|---|
| Firestore | `(default)` データベース、asia-northeast1（東京） | 無料枠が付くのは1プロジェクト1データベースだけ。利用者の近くに置く |
| Cloud Storage | 既定のバケット `<project>.firebasestorage.app`、asia-northeast1 | 健康に関わるデータを国内に置く。東京のバケットには無料枠がないが、保存するのは数十MB程度なので、料金は月$0.01未満の見込み（$0.023/GiB月） |
| プラン | Blaze（従量課金）。配布クレジットを紐づける | 2026-02-03から、Cloud Storage for Firebaseを使うにはBlazeが必須 |

## 2. Firestoreのコレクション

```
users/{uid}
therapists/{email}
cases/{caseId}
cases/{caseId}/messages/{messageId}
cases/{caseId}/designs/{designId}
usage/{yyyymmdd}
usage/{yyyymmdd}/users/{uid}
settings/runtime
```

### 2.1 `users/{uid}`

| フィールド | 型 | 内容 |
|---|---|---|
| `display_name` | string | Googleアカウントの表示名 |
| `email` | string | Googleアカウントのメール |
| `created_at` | timestamp | 初めてAPIを呼んだ日時 |

生成APIが、そのユーザーが初めて呼んだときに作る。

### 2.2 `therapists/{email}`（OTの許可リスト）

| フィールド | 型 | 内容 |
|---|---|---|
| `name` | string | 表示名 |
| `note` | string | 所属など（任意） |
| `added_at` | timestamp | 追加した日時 |

- ドキュメントIDはメールアドレス（小文字）。OTがまだログインしていなくても、管理者が先に登録できるようにするため
- 管理者がFirebaseコンソールから手で追加する。今回は協力してくれるOTがいないため、デモ用にメンバーのアカウントを1つ登録して、OT役を演じる

### 2.3 `cases/{caseId}`

| フィールド | 型 | 内容 |
|---|---|---|
| `owner_uid` | string | 作った人 |
| `title` | string | 例：「筆の握り」 |
| `status` | string | `interviewing` → `measuring` → `designing` → `previewing` → `in_review` → `approved` ／ `changes_requested`。版を作り直すと `previewing` に戻る |
| `requirements` | map | 聞き取りの結果（[generation-pipeline.md §3.1](generation-pipeline.md#31-聞き取り-interview)） |
| `turn_count` | number | 聞き取りの往復の数 |
| `measurement` | map | 採寸結果（[measurement.md §12](measurement.md#12-出力するjsonmeasurement20)、2.0）。動画・フレーム・フレームごとの点は含まない |
| `hand_model` | map | 生成APIが組み立てた手のカプセルモデルと、指ごとのすき間（[api.md §3.3](api.md#33-put-v1casescase_idmeasurement)） |
| `measured_at` | timestamp | 採寸を保存した日時 |
| `current_design_id` | string | 最新の版 |
| `active_operation` | map / null | `{ operation_id, kind, started_at, expires_at }`。生成・微調整・依頼・承認の処理中の印。`expires_at` は開始から300秒。[api.md §1.1](api.md#11-生成の重複防止と異常終了からの復旧mvp) |
| `reviewer_email` | string | 確認を頼んだOT（小文字） |
| `created_at` / `updated_at` | timestamp | — |

### 2.4 `cases/{caseId}/messages/{messageId}`

| フィールド | 型 | 内容 |
|---|---|---|
| `role` | string | `user` ／ `assistant` |
| `text` | string | 画面に出す文 |
| `choices` | array<string> | 選択肢（assistantのとき） |
| `created_at` | timestamp | — |

### 2.5 `cases/{caseId}/designs/{designId}`

| フィールド | 型 | 内容 |
|---|---|---|
| `revision` | number | 1から始まる版の番号 |
| `parent_design_id` | string | 直す元にした版（最初の版は空） |
| `origin` | string | `initial` ／ `refine_text` ／ `refine_params` ／ `refine_style` |
| `status` | string | `queued` → `selecting` → `dimensioning` → `rendering` → `reviewing` → `ready` ／ `needs_attention` ／ `failed` |
| `progress` | map | `{ step, round, max_rounds, message_ja }`。画面の進み具合の表示に使う |
| `parts` | array<map> | 部品選びの結果 `{ part_id, variant, reason_ja }` |
| `params` | array<map> | 引数の一覧 `{ part_id, name, value, unit, range, baseline, source, reason_ja, clamped, override_by_user }` |
| `review` | map | `{ rounds: [ { round, verdict, checks, issues, changes } ], final_verdict, unresolved_issues }` |
| `warnings` | array<string> | 範囲チェックと採寸の警告 |
| `style` | map | `{ color, pattern }` |
| `files` | map | Storageのパス（§3） |
| `approval` | map | `{ status: none ／ requested ／ approved ／ rejected, reviewer_email, requested_at, decided_at, comment_ja, checklist, geometry_hash, print_sha256 }`。確認対象のハッシュと印刷ファイルのハッシュを承認に結び付ける |
| `geometry_hash` | string | OTに頼んだときに記録する。部品・引数・カプセルを正規化したJSONのSHA-256（表示色は除く）。承認のときに、OT画面が見ていた版と同じかを確かめる |
| `input_snapshot` | map | その版の採寸・要件・手のモデル。ケースの現在値が変わっても書き換えない |
| `model` | map | `{ id, location }` |
| `prompt_versions` | map | 例：`{ select: "v3", dimension: "v5", review: "v2" }` |
| `usage` | map | `{ input_tokens, output_tokens, gemini_calls, openscad_ms }` |
| `error` | map | 失敗したときのエラー（[api.md §5](api.md#5-エラー)と同じ形） |
| `created_at` | timestamp | — |

確認済みにしたあとで形を直すと、新しい版ができる。前の版の `approval` はそのまま残るが、`current_design_id` は新しい版に移る。ダウンロード画面は `current_design_id` の版を見るので、直した版はもう一度OTの確認を受けるまで印刷用STLが出ない。

`review-request` を受けた版の形・スナップショット・描画環境は不変とする。承認処理ではR6が不合格でも形を変更しない。形の変更は新しい版に記録し、`approval.status=none` から確認をやり直す。

### 2.6 `usage/{yyyymmdd}` と `usage/{yyyymmdd}/users/{uid}`

| フィールド | 型 | 内容 |
|---|---|---|
| `designs` / `refines` / `interviews` | number | その日の回数 |
| `mesh_requests` / `gpu_execution_seconds` | number | GPU推論の開始回数と実行秒数。失敗・自動再試行も数える |
| `input_tokens` / `output_tokens` | number | その日の合計 |
| `gemini_cost_usd` / `gpu_cost_usd` | number | GeminiとGPU推論それぞれの概算費用。Geminiはトークン数×定価、GPUは回数×`MESH_COST_PER_CALL_USD` |
| `estimated_cost_usd` | number | `gemini_cost_usd + gpu_cost_usd` |

生成APIと `hand-mesh` が、開始前の上限の確認と回数・費用の加算を、1つのトランザクションで行う。日付は日本時間で区切る。

### 2.7 `settings/runtime`（共通の停止設定）

`generation_enabled`（boolean）を管理者がコンソールから設定する。生成APIと `hand-mesh` が各有料処理の開始前に読み、`false`・設定なし・取得失敗では開始しない。ブラウザからは読み書きできない。


## 3. Cloud Storageのパス

```
cases/{caseId}/designs/{designId}/preview.stl      … プレビュー用（mode=assembled、円の分割48）
cases/{caseId}/designs/{designId}/views/front.png  … 確認用画像（768×768）
cases/{caseId}/designs/{designId}/views/side.png
cases/{caseId}/designs/{designId}/views/top.png
cases/{caseId}/designs/{designId}/views/iso.png
cases/{caseId}/designs/{designId}/print.stl        … 印刷用（mode=print、円の分割128）。OTの確認後にだけ作る
```

- 書き込むのは生成APIだけ（Admin SDKを使うのでルールは関係しない）
- Flutter Webから `getData()` などで直接読む場合は、バケットにCORSの設定が要る（要確認：使う読み方を決めたら、Dが設定する）

## 4. セキュリティルールの方針

ルールはコードで書き、`firebase/firestore.rules` と `firebase/storage.rules` に置く。ここでは方針だけを決める。

### 4.1 Firestore

| パス | 読み取り | 書き込み |
|---|---|---|
| `users/{uid}` | 本人だけ | 不可（APIだけ） |
| `therapists/{email}` | 本人だけ（`request.auth.token.email` がドキュメントIDと同じで、メールが確認済み） | 不可（管理者がコンソールから） |
| `cases/{caseId}` | 持ち主（`owner_uid == request.auth.uid`）、または依頼されたOT（`reviewer_email` がログイン中のメールと同じで、メールが確認済みで、`therapists` にドキュメントがある） | 不可（APIだけ） |
| `cases/{caseId}/messages/*` | 親のケースを読める人 | 不可 |
| `cases/{caseId}/designs/*` | 親のケースを読める人 | 不可 |
| `usage/**` | 不可 | 不可 |
| `settings/**` | 不可 | 不可 |

- 「親のケースを読める人」かどうかは、`get()` で親のケースを読んで判定する（1回の評価で読み取り1回分の料金がかかる）
- クライアントからの書き込みをすべて禁止することで、ステータスや確認済みの印を、ブラウザから書き換えられないようにする

### 4.2 Cloud Storage

| パス | 読み取り | 書き込み |
|---|---|---|
| `cases/{caseId}/designs/{designId}/preview.stl`、`views/*` | 持ち主、または依頼されたOT（`firestore.get()` でケースを1件読んで判定） | 不可 |
| `cases/{caseId}/designs/{designId}/print.stl` | 上と同じ条件に加えて、その版の `approval.status == "approved"`（`firestore.get()` で版を読み、合計2件） | 不可 |
| それ以外 | 不可 | 不可 |

- StorageのルールからFirestoreを読めるのは、1回の評価で2件まで。そのため、OTの許可リスト（`therapists`）はStorageのルールでは見ない。そのかわり、`reviewer_email` を書き込むAPI（[api.md §3.6](api.md#36-post-v1casescase_idreview-request)）で、許可リストにあるかを確かめておく
- StorageのルールからFirestoreを参照するには、初回にコンソールで権限の付与を求められる（要確認：デプロイのときに確かめる）
- OTに頼むときに作った印刷用STLは `internal/cases/{caseId}/designs/{designId}/print.stl` に置き、上の「それ以外」でだれも読めないようにする。承認のときに `print_sha256` を確かめてから、読める場所（`print.stl`）にコピーする
- 制限の目的は「普通の手順なら必ずOTの確認を通る」ことを保証すること。プレビュー用STLも同じ形なので、技術的に抜き出すことはできる。この点はピッチの質疑で正直に説明する

### 4.3 ルールのテスト

Firebase Local Emulator Suiteで、次のケースを確かめる（11/9まで）。

1. 他人のケースは読めない
2. 依頼されていないOTは読めない
3. ブラウザからはどこにも書き込めない
4. 確認前の `print.stl` は持ち主にも読めず、確認後は読める

## 5. 保存期間と削除

- ハッカソンの審査が終わったら（2026年12月まで）、デモ用のデータはすべて消す
- ケースを消す機能（`DELETE /v1/cases/{case_id}`）は拡張機能とする。MVPでは管理者がコンソールから消す
- 写真はもともと保存しないので、消す必要がない
