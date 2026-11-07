# データモデル

> **このドキュメントで決めたこと**
> 1. Firestoreは「ケース（1つの道具づくり）」を中心に、`cases/{caseId}` の下に会話（messages）と版（designs）を持たせる。ブラウザは読むだけ。ケース・会話・版は生成APIだけが書き、`hand-mesh` がFirestoreに書くのは利用回数と費用だけ（Storageには未補正の手のメッシュを書く。§3）。
> 2. Cloud Storageには、生成APIが作った部品ごとのSTL（カバー・C字クリップ・TPUの筒）・確認用画像・実寸の手のメッシュと、`hand-mesh` が作った未補正の手のメッシュを置く。ブラウザからのアップロード経路は作らない。手の映像（動画・フレーム）はどこにも保存しない。手のメッシュは写真ではなく、形を作り直して確かめるのに要るので、同意を得て保存する（[ADR-0010](adr/0010-hand-mesh-fusion.md)）。
> 3. 部品ごとの印刷用STLは、OTが「確認済み」にした版だけ読めるようにする（デモの印が付いたケースだけは、OTの確認なしで作って読める）。StorageのルールからFirestoreを参照して判定する。

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
settings/filaments
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
| `title` | string | 例：「筆のカバー」 |
| `status` | string | `interviewing` → `measuring` → `designing` → `previewing` → `in_review` → `approved` ／ `changes_requested`。版を作り直すと `previewing` に戻る。角度の計算（`hand-mesh`）に失敗したときは採寸が保存されないので、`measuring` のまま（撮影からやり直す。専用の状態は作らない） |
| `demo` | boolean | デモのケースか。ケースを作るときに `settings/runtime.demo_mode` が `true` なら `true`。`true` のケースは、OTの確認なしで印刷用STLを作れる（[api.md §3.11](api.md#311-post-v1casescase_iddesignsdesign_idprepare-printデモのケースだけ)） |
| `mesh_consent_at` | timestamp / null | メッシュ復元のためにフレームを送ること、手の形の3Dデータを保存することに同意した日時（`POST /consent`）。`hand-mesh` と `PUT measurement` が確かめる |
| `consent_text_version` | string | 同意した文の版。今の版は `mesh-consent-2`（手のメッシュを保存することを足した版）。古い版の同意しかなければ、`hand-mesh` と `PUT measurement` は受け付けない |
| `requirements` | map | 選択式の質問の答え（`activity`、`tool_type`、`hand_side`、**道具の太さ `tool_d_mm`** と出どころ `tool_d_source`（`user`＝数値で入れた／`category`＝区分から推定）、`tool_shaft_size`（測れないときの区分）、`tool_shaft_shape`、`finger_state`、`donning_by`、`capture_by`）、「その他」のときのやりたいことの説明（`activity_ja`）、チャットのメモ（`notes`）、仮に置いた値（`assumptions`）。スキーマは `schemas/requirements.schema.json`。列挙値は [api.md §3.2](api.md#32-put-v1casescase_idrequirements) |
| `turn_count` | number | 任意のチャットの往復の数（最大3） |
| `measurement` | map | 採寸結果（[measurement.md §12](measurement.md#12-出力するjsonmeasurement22)、2.2）。`capture.mesh_id` と、点を直したときの `manual_points`（代表のフレームの番号・点の番号・直した位置のpx）を含む。動画・フレームの画像は含まない |
| `measurement_id` | string | 最新の採寸のID（保存のたびに新しく作る。例：`m_02`）。実寸の手のメッシュのファイル名にも使う |
| `hand_model` | map | 生成APIが作った手のモデル：実寸の手のメッシュのパス（`mesh_path`）、倍率（`scale_factor`、`scale_source`、`scale_spread_ratio`）、実寸の関節の位置（`joints_mm`）、カバーの目印（`cover_landmarks`：手のひら側を切る面の基準、手首→中指の付け根の長さ、レールの位置と向き、スリットを置ける範囲。[api.md §3.3](api.md#33-put-v1casescase_idmeasurement)）。メッシュそのものはStorageに置き、ここには入れない（Firestoreの1ドキュメントは1MiBまでのため） |
| `measured_at` | timestamp | 採寸を保存した日時 |
| `current_design_id` | string | 最新の版 |
| `active_operation` | map / null | `{ operation_id, kind, started_at, expires_at }`。`kind` は `design`／`refine`／`review_request`／`prepare_print`／`approval`。生成・微調整・依頼・デモの印刷用データ・承認の処理中の印。`expires_at` は開始から300秒。[api.md §1.1](api.md#11-生成の重複防止と異常終了からの復旧mvp) |
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
| `origin` | string | `initial` ／ `refine_text` ／ `refine_params` ／ `refine_clip_angle` ／ `refine_style` |
| `status` | string | `queued` → `running` → `ready` ／ `needs_attention` ／ `failed` |
| `progress` | map | `{ step, round, max_rounds, message_ja }`。`step` は `selecting`／`dimensioning`／`shelling`（カバーの殻の計算）／`rendering`／`reviewing`。画面の進み具合の表示に使う |
| `parts` | array<map> | 部品選びの結果 `{ part_id, variant, reason_ja }` |
| `params` | array<map> | 引数の一覧 `{ part_id, name, value, unit, range, baseline, source, reason_ja, clamped, override_by_user }` |
| `review` | map | `{ rounds: [ { round, verdict, checks, issues, changes } ], final_verdict, unresolved_issues }` |
| `warnings` | array<string> | 範囲チェックと採寸の警告 |
| `style` | map | `{ color, pattern }`。色だけの変更は、版を作らずにここだけ書き換える（`geometry_hash` に色は入らない） |
| `files` | map | Storageのパス（§3）。`{ parts: { cover: { preview_stl }, c_clip: { preview_stl }, tpu_sleeve: { preview_stl } }, views: { front, side, top, iso }, print: { cover, c_clip, tpu_sleeve } }`。`print` は読める場所にできたときだけ入る。部品ごとに分けるのは、カバーとクリップを別々に刷り（材料・向きが違う）、角度違いのクリップだけを刷り直せるようにするため |
| `approval` | map | `{ status: none ／ requested ／ approved ／ rejected, reviewer_email, requested_at, decided_at, comment_ja, checklist, geometry_hash, print_sha256 }`（`print_sha256` は部品ごとの map）。確認対象のハッシュと印刷ファイルのハッシュを承認に結び付ける |
| `geometry_hash` | string | OTに頼んだとき（デモのケースは印刷用データを作ったとき）に記録する。部品・引数・`cover_shell_sha256`・固定値の版を正規化したJSONのSHA-256（色は除く）。殻は手のメッシュから作るので、殻のファイルのハッシュを入れる。承認のときに、OT画面が見ていた版と同じかを確かめる |
| `hand_measurement_id` | string | この版が使った採寸のID。実寸の手のメッシュ `cases/{caseId}/hand/{hand_measurement_id}.glb` を指す |
| `scale_factor` | number | この版が使った倍率 k（未補正のメッシュ → 実寸） |
| `hand_clearance_mm` | number | この版のカバーとこぶしのすき間（`HAND_CLEARANCE_MM`。フェルトの厚みを含む。11/9に値を変えても、前の版を同じ形で描き直せるよう記録する） |
| `cover_shell_sha256` | string | カバーの殻（`cover_shell.stl`）のSHA-256。ファイルは `internal/cases/{caseId}/cover/{cover_shell_sha256}.stl`（内側を守る立体と距離場は、採寸の版ごとの `{measurementId}.keepout.stl`・`{measurementId}.sdf.npz`）。採寸の版と、殻を決める引数が同じ版では同じ値になる |
| `clip_angle_deg` | number | C字クリップの角度（0／20／40）。角度だけを変えた版は、カバーのファイルを前の版と共有する |
| `print_prepared_at` / `print_sha256` | timestamp / map | 印刷用STLを作った日時と、部品ごとのファイルのSHA-256 |
| `input_snapshot` | map | その版の採寸・要件・手のモデル。ケースの現在値が変わっても書き換えない |
| `model` | map | `{ id, location }` |
| `prompt_versions` | map | 例：`{ select: "v3", dimension: "v5", review: "v2" }` |
| `usage` | map | `{ input_tokens, output_tokens, gemini_calls, openscad_ms }` |
| `error` | map | 失敗したときのエラー（[api.md §5](api.md#5-エラー)と同じ形） |
| `created_at` | timestamp | — |

確認済みにしたあとで形を直すと、新しい版ができる。前の版の `approval` はそのまま残るが、`current_design_id` は新しい版に移る。ダウンロード画面は `current_design_id` の版を見るので、直した版はもう一度OTの確認を受けるまで印刷用STLが出ない。

`review-request` を受けた版の形とスナップショットは不変とする。印刷用STLは依頼のときに作り、承認では描き直さない。形の変更は新しい版に記録し、`approval.status=none` から確認をやり直す。色だけの変更は版を変えない。

### 2.6 `usage/{yyyymmdd}` と `usage/{yyyymmdd}/users/{uid}`

| フィールド | 型 | 内容 |
|---|---|---|
| `designs` / `refines` / `interviews` | number | その日の回数 |
| `mesh_requests` / `gpu_execution_seconds` | number | GPU推論の開始回数と実行秒数。失敗・自動再試行も数える |
| `input_tokens` / `output_tokens` | number | その日の合計 |
| `gemini_cost_usd` / `gpu_cost_usd` | number | GeminiとGPU推論それぞれの概算費用。Geminiはトークン数×定価、GPUは回数×`MESH_COST_PER_CALL_USD`（$0.40） |
| `estimated_cost_usd` | number | `gemini_cost_usd + gpu_cost_usd` |

- `hand-mesh`：開始前に、上限の確認と、回数・固定の見積もり額の加算を1つのトランザクションで行う
- 生成API：開始前は上限の確認だけ。Geminiの費用は呼び終えたあとで、トークン数から加算する（開始前には分からないため）。そのため、1日の上限を少し超えることがある
- 日付は日本時間で区切る

### 2.6.1 `settings/filaments`（選べる色）

`colors`（`[{ name_ja, hex, material }]`）を管理者がコンソールで設定する。大学にあるフィラメントの色だけを入れ、S7・S10の色の選択肢に使う。ブラウザは読むだけ（ログインしていれば読める）。

### 2.7 `settings/runtime`（共通の停止設定）

- `generation_enabled`（boolean）：管理者がコンソールから設定する。生成APIと `hand-mesh` が各有料処理の開始前に読み、`false`・設定なし・取得失敗では開始しない。**初めにデプロイしたら `true` を入れる**（入れ忘れると全部止まる）
- `demo_mode`（boolean）：`true` のあいだに作ったケースに、デモの印（`demo: true`）を付ける。審査の期間とデモ動画の撮影のときだけ `true` にする
- ブラウザからは読み書きできない


## 3. Cloud Storageのパス

```
cases/{caseId}/designs/{designId}/cover.preview.stl          … カバー本体のプレビュー用（手の座標系、円の分割48）
cases/{caseId}/designs/{designId}/c_clip_{angle}.preview.stl … C字クリップのプレビュー用（レールに差し込んだ位置。angle は 0／20／40）
cases/{caseId}/designs/{designId}/tpu_sleeve.preview.stl     … TPUの筒（選んだときだけ）
cases/{caseId}/designs/{designId}/views/front.png  … 確認用画像（768×768。手のメッシュ・カバー・クリップ・道具の棒を重ねたもの）
cases/{caseId}/designs/{designId}/views/side.png
cases/{caseId}/designs/{designId}/views/top.png
cases/{caseId}/designs/{designId}/views/iso.png
cases/{caseId}/designs/{designId}/print/cover.stl           … 印刷用（刷る向きに置き直したもの、円の分割128）。承認のときに internal/ からコピーする。デモのケースは prepare-print で直接ここに作る
cases/{caseId}/designs/{designId}/print/c_clip_{angle}.stl
cases/{caseId}/designs/{designId}/print/tpu_sleeve.stl
cases/{caseId}/hand/{measurementId}.glb            … 実寸の手のメッシュ（手の座標系、mm）。PUT measurement のときに生成APIが書く
cases/{caseId}/hand/raw/{meshId}.glb               … 未補正の手のメッシュ（hand-mesh が書く。関節の位置を extras.joints_mm に入れる）。だれも読めない
internal/cases/{caseId}/designs/{designId}/print/*.stl … OTに頼むときに作る部品ごとの印刷用STL。承認まで、だれも読めない
internal/cases/{caseId}/cover/{coverShellSha256}.stl       … カバーの殻。同じ採寸の版・同じ殻の引数の版で使い回す。だれも読めない
internal/cases/{caseId}/cover/{measurementId}.keepout.stl … 内側を守る立体（手を HAND_CLEARANCE_MM だけ広げたもの。レールの土台が内側へ出ないよう、最後に引く）。採寸の版ごとに1つ。だれも読めない
internal/cases/{caseId}/cover/{measurementId}.sdf.npz     … 手のメッシュの符号付き距離場（圧縮して数MBの見込み。要確認）。殻を組み立て直すときに使い回す。採寸の版ごとに1つ。だれも読めない
```

- 前の版の `internal/cases/{caseId}/cavity/`（握りからくり抜く立体）はなくした。握りをやめ、カバー方式にしたため（[ADR-0011](adr/0011-dorsal-cover.md)）。手を広げた立体を作る仕組みは、内側を守る立体（`.guard.stl`）として残る
- 書き込むのは生成APIと、`hand-mesh`（`cases/{caseId}/hand/raw/` だけ）。どちらもサーバーの権限で書くので、ルールは関係しない
- 手のメッシュの大きさは1ファイル数百KBの見込み（細分割1回で約9,000頂点。要確認）。数十ケースでも、料金は今の見込み（月$0.01未満）からほとんど変わらない
- 未補正のメッシュをブラウザから読めなくするのは、生成APIが倍率を掛けて実寸にする前の値を、画面や他の人が使わないようにするため。生成APIは、結果トークンの `mesh_sha256` とファイルのハッシュが一致することを確かめてから使う（[api.md §3.3](api.md#33-put-v1casescase_idmeasurement)）
- Flutter Webから `getData()` などで直接読む場合は、バケットにCORSの設定が要る（Dが11/7に設定する。[tasks.md](tasks.md) のD1）

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
| `settings/filaments` | ログインした人 | 不可 |
| `settings/**`（それ以外） | 不可 | 不可 |

- 「親のケースを読める人」かどうかは、`get()` で親のケースを読んで判定する（1回の評価で読み取り1回分の料金がかかる）
- クライアントからの書き込みをすべて禁止することで、ステータスや確認済みの印を、ブラウザから書き換えられないようにする

### 4.2 Cloud Storage

| パス | 読み取り | 書き込み |
|---|---|---|
| `cases/{caseId}/designs/{designId}/*.preview.stl`、`views/*` | 持ち主、または依頼されたOT（`firestore.get()` でケースを1件読んで判定） | 不可 |
| `cases/{caseId}/designs/{designId}/print/*` | 上と同じ条件に加えて、その版の `approval.status == "approved"`、**または** ケースの `demo == true` かつ版の `print_prepared_at` がある（`firestore.get()` でケースと版を読み、合計2件） | 不可 |
| `cases/{caseId}/hand/{measurementId}.glb` | 持ち主、または依頼されたOT（`firestore.get()` でケースを1件読んで判定） | 不可 |
| `cases/{caseId}/hand/raw/*` | 不可 | 不可（`hand-mesh` だけがサーバーの権限で書く） |
| それ以外 | 不可 | 不可 |

- StorageのルールからFirestoreを読めるのは、1回の評価で2件まで。そのため、OTの許可リスト（`therapists`）はStorageのルールでは見ない。そのかわり、`reviewer_email` を書き込むAPI（[api.md §3.6](api.md#36-post-v1casescase_idreview-request)）で、許可リストにあるかを確かめておく
- StorageのルールからFirestoreを参照するには、初回にコンソールで権限の付与を求められる（要確認：デプロイのときに確かめる）
- OTに頼むときに作った部品ごとの印刷用STLは `internal/cases/{caseId}/designs/{designId}/print/` に置き、上の「それ以外」でだれも読めないようにする。承認のときに部品ごとの `print_sha256` を確かめてから、読める場所（`print/`）にコピーする
- 制限の目的は「普通の手順なら必ずOTの確認を通る」ことを保証すること。プレビュー用STLも同じ形なので、技術的に抜き出すことはできる。この点はピッチの質疑で正直に説明する
- デモのケースだけは、OTの確認なしで印刷用STLが読める。デモの印はケースを作るときにサーバーが付け、ブラウザからは付けられない。画面には「デモ用：OTの確認を省略しています」と必ず出す

### 4.3 ルールのテスト

Firebase Local Emulator Suiteで、次のケースを確かめる（11/9まで）。

1. 他人のケースは読めない
2. 依頼されていないOTは読めない
3. ブラウザからはどこにも書き込めない
4. 確認前の `print/` の下（カバー・クリップ）は持ち主にも読めず、確認後は読める
5. 実寸の手のメッシュは持ち主と依頼されたOTだけが読め、他人は読めない。未補正のメッシュ（`hand/raw/`）は持ち主にも読めない
6. デモのケースは、印刷用データを作ったあとなら確認なしで読める。デモでないケースは、`prepare-print` が `403` になる

## 5. 保存期間と削除

- ハッカソンの審査が終わったら（2026年12月まで）、デモ用のデータはすべて消す
- ケースを消す機能（`DELETE /v1/cases/{case_id}`）は拡張機能とする。MVPでは管理者がコンソールから消す
- **ケースを消すときは、手のメッシュも必ず消す**：Firestoreの `cases/{caseId}`（下のコレクションを含む）に加えて、Storageの `cases/{caseId}/`（実寸と未補正の手のメッシュ、STL、画像）と `internal/cases/{caseId}/`（印刷用STL、カバーの殻、内側を守る立体）をまとめて消す。同意の画面で「ケースを消すと消えます」と約束しているため。消し方の手順は、管理者向けにREADMEに書く（要確認：コンソールでフォルダごと消せるか、11/9に確かめる）
- 撮り直しで採寸に使われなかった未補正のメッシュも、ケースを消すまで残す（どの撮影で作られたかの記録として）。それより早く消す仕組みは拡張機能
- 同意を取り消しても、保存済みの手のメッシュは自動では消さない（形の版が参照しているため）。消したいときはケースを消す
- 動画・写真はもともと保存しないので、消す必要がない
