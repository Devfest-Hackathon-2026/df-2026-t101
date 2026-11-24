# 設計：アプリの中で発注まで終わらせる（2026-11-21）

決勝に向けた直し（[finals-plan.md](../../notes/2026-11-21-finals-plan.md) の §2.1・§3.2）の設計。画面のモックは Figma「Hand-Some-Fit 発注モック」（https://www.figma.com/design/MLFRY2DtZSloBEQ8cJkb2y）。

## 1. ねらい

予選の審査員から「3Dデータができても、刷るまでに知識が要る」「プリンタを持っていない人は、委託先を自分で探さないといけない」と言われた。プリンタを持っていない本人や家族が、OTの確認が済んだ部品を、アプリの中で受託者に頼めるようにする。

- 頼む人が入れるのは、刷る部品・個数・フェルトの有無・届け先だけ。機種・材料・印刷設定はアプリが決める（審査員の「機種を決めて、それを持つ会社に頼む」）
- 受託する側も、アプリの画面で注文を受け、部品のファイルを取り出し、状態を進める
- 決勝のデモで、頼む → 受託者が受ける → 届く、を1台の端末で見せられる

## 2. 目標・目標にしないこと・してはいけないこと

**目標**

- S10（印刷と使い方）から、受託者を選んで発注できる
- 部品ごとの重さ・印刷時間の目安と、受託者ごとの金額の目安を出す（finals-plan §3.2）
- 受託する側の画面で、注文の一覧・詳細・ファイルのダウンロード・状態の変更ができる
- 頼んだ人の画面に、注文の状態（受付 → 造形中 → 発送済み → 受け取った）が出る
- 合わない部品だけを頼み直せる形にしておく（finals-plan §3.1 の「使ったあとの報告」の土台。報告の画面そのものはこの設計に入れない）

**目標にしないこと**

- 支払い、実際の発送、追跡番号
- 受託者への通知（メールなど）
- 受託者が注文を断る機能
- 注文の中身をあとから変える機能（取り消して頼み直す）
- 受託者ごとに機種・材料・印刷設定を変えること（全員が同じ機種を持つ前提）
- 自分で刷る人向けの3MF（finals-plan §2.1 の「あるとよいもの」。別の作業）
- 使ったあとの報告の画面（finals-plan §3.1。別の設計）

**してはいけないこと（動いても失敗とみなす）**

- 架空の受託者を、実在の会社と提携しているように見せる。受託者の一覧・注文の画面には必ず「デモ用の架空の受託者です」を出す
- OTの確認を通らずに発注できる（デモのケースを除く。デモのケースは今のダウンロードと同じ扱いで、デモの帯を出す）
- 受託者に、手の3D・採寸・聞き取りの中身・ケースのほかの情報を見せる。受託者が見られるのは、注文に入れた印刷用STLと、注文の中身（部品・個数・刷る色・フェルト・届け先・印刷設定・OTの確認の有無と日時）だけ
- ブラウザから Firestore に書けるようにする。今の「書き込みはすべて生成APIだけ」を崩さない
- 届け先を、持ち主と担当の受託者以外が読める

## 3. 制約

- 期限：11/23 の夜に機能を止める。11/24 23:59 に提出
- ブランチは `impl`。コミットと push はメンバーが手で行う（Claude はコマンドを渡す）
- 今の作りに合わせる：アプリはデータを生成API（`Api.instance`）だけで読み書きし、Firestore を直接読まない。ファイル（STL・手の3D）だけは Storage から直接読む（[download.dart](../../../app/lib/features/print/download.dart)、[files.dart](../../../app/lib/core/storage/files.dart)）
- Storage のルールから参照できる Firestore の文書は1回2件まで（[data-model.md §4.2](../../data-model.md#42-cloud-storage)）。今のOT確認の判定でもう2件使っているので、受託者の判定を足せない
- `/v1/files/{path}` は手元（`STORE_BACKEND=local`）だけで動く。本番では使えない（[misc.py](../../../api/app/routes/misc.py)）
- Flutter のモックの裏側（[mock_backend.dart](../../../app/lib/core/api/mock_backend.dart)、`--dart-define=MOCK_API=true`）でも動くようにする。Playwright で通すときに使っている

## 4. 作り方の案（チームが A を選んだ）

| 案 | 中身 | よいところ | 気になるところ |
|---|---|---|---|
| **A. 全部APIを通す（採用）** | 注文・受託者の情報・受託者のアカウントを、生成APIが Firestore に書いて読む。状態の変化は、注文がある画面だけ数秒ごとに読み直す。受託者へのSTLは、APIが受託者かを確かめてから中身を返す | 今の作りと同じ。ブラウザから書けない・OTの確認を通す、という安全の決まりが崩れない | 状態の反映が数秒遅れる（デモでは困らない） |
| B. 注文の状態だけ、アプリが Firestore を直接見る | cloud_firestore を入れ、ルールに注文の読み取りを足し、状態をその場で反映する | デモの見栄えが少しよい | 新しい部品とルールが増え、「全部APIを通す」に例外ができる。残り3日で増やす不安が大きい |
| （作らない）受託者が Storage から直接STLを読む | Storage のルールに受託者の判定を足す | — | ルールが参照できるのは2件までで、今のOT確認の判定と絡んで壊しやすい |

## 5. 決まったこと（チームと確認済み）

### 5.1 受託者

- 利用者が一覧から受託者を選ぶ。受託者は架空でよい（3〜4件）。名前は実在の会社と重ならないもの
- 一覧の上に「デモ用の架空の受託者です。実在の会社ではありません」。各カードにも「架空」の札
- 受託者が持つ情報：名前、地域、持っている機種、使える材料、基本料、1gあたりの値段、発送までの日数、フェルトを貼って送れるか（とその料金）
- 機種はアプリが対応する1つ（仮：Bambu Lab A1。チームが使っている機種に置き換える）。どの受託者もその機種を持っている前提で、印刷設定はアプリが1つ持つ
- 金額はアプリが自動で出す：重さの目安 × 1gあたりの値段 ＋ 基本料（＋フェルト）。見積もりを待たない
- 一覧は金額の安い順。地域での絞り込みや「近い順」は作らない
- どの受託者への注文も、チームの受託者アカウントが受ける。受託者アカウントはOTと同じ許可リスト方式で、受け持つ受託者を持つ。チームのアカウントには全員分を持たせる
- 同じアカウントで、頼む側と受託する側の両方をできる（デモを1台で見せるため）

### 5.2 頼む側の流れ

S10（印刷と使い方）→「刷ってもらう」→ 受託者を選ぶ → 注文の内容を入れる → 「この内容で頼む」→ S10に注文の状態が出る

- 発注できるのはケースの持ち主だけ
- 発注できるのは、OTの確認済みの版（`approval.status == "approved"`）だけ。デモのケース（`demo == true` かつ `print_prepared_at` がある版）は確認を省略し、デモの帯を出す
- 注文の画面で入れるもの：刷る部品（チェック。最初は全部に印）、個数（1〜3）、「フェルトを貼って送ってもらう」（その受託者ができる場合だけ）、届け先（名前・郵便番号・住所・電話）
- 材料と機種と印刷設定は表示するだけ。変えられない
- 金額は、部品・個数・フェルトに合わせてその場で計算し直し、「目安」と書く。支払いの画面はない
- 状態：受付 → 造形中 → 発送済み → 受け取った。「受け取った」は頼んだ人が押す（ここが finals-plan §3.1 の報告の入口になる）
- 取り消せるのは「受付」の間だけ
- ホームのケースのカードに、注文の状態の札を出す
- 届け先を読めるのは、持ち主と担当の受託者だけ

### 5.3 受託する側の画面

- 許可リストにあるアカウントだけ、ホームに「受けた注文」の入口が出る
- 注文の一覧：上で受託者を切り替え、状態ごと（受付／造形中／発送済み／受け取った／取り消し）に並べる
- 注文の詳細：部品ごとのダウンロード、機種・材料・印刷設定（積層の厚さ・充填率・サポート・刷る向き）、フェルトを貼るかと貼り方、個数、届け先、OTが確認した日時（デモのケースは「デモ：確認を省略」）
- 受託者ができる操作は「造形を始める」（受付 → 造形中）と「発送した」（造形中 → 発送済み）の2つだけ

### 5.4 作り方

案A（§4）。

## 6. 設計

### 6.1 データ

#### 受託者と印刷の決まり：`api/app/data/fabrication.json`（Claude の判断）

> §5.1 では「Firestore の `fabricators/{id}` にサーバーが書く」と提案していた。架空の受託者は固定の見本なので、リポジトリの JSON に置くことにした。本番の Firestore に手で入れる作業がなくなり、テストでも同じ値を使える。

```json
{
  "version": 1,
  "printer": {
    "model": "Bambu Lab A1",
    "layer_mm": 0.2,
    "infill_pct": 15,
    "supports_ja": "カバーの内側、クリップの輪の下",
    "orientation_ja": "ファイルの向きのまま"
  },
  "materials": {
    "cover": {"name": "PLA", "density_g_cm3": 1.24},
    "c_clip": {"name": "PETG", "density_g_cm3": 1.27},
    "tpu_sleeve": {"name": "TPU", "density_g_cm3": 1.21}
  },
  "estimate": {"mass_factor": 0.9, "minutes_per_gram": 5.0, "setup_minutes": 5},
  "felt": {"thickness_mm": 1.0},
  "delivery_days_after_ship": 2,
  "fabricators": [
    {"id": "umikaze", "name": "うみかぜ3D工房", "region": "大阪府 大阪市", "fictional": true,
     "base_fee_yen": 800, "yen_per_gram": 20, "lead_days": 3, "felt_service": true, "felt_fee_yen": 200},
    {"id": "hoshizora", "name": "ほしぞら出力舎", "region": "北海道 札幌市", "fictional": true,
     "base_fee_yen": 600, "yen_per_gram": 30, "lead_days": 5, "felt_service": false, "felt_fee_yen": 0},
    {"id": "komorebi", "name": "こもれび造形ラボ", "region": "東京都 品川区", "fictional": true,
     "base_fee_yen": 1000, "yen_per_gram": 25, "lead_days": 2, "felt_service": true, "felt_fee_yen": 200}
  ]
}
```

- 印刷の決まりの数字（`mass_factor`・`minutes_per_gram`・`setup_minutes`）と機種は仮。1回実際に刷った結果で合わせる
- 部品の材料は、印刷用のキー（`print_key`）の頭で決める：`cover` → cover、`c_clip…` → c_clip、`tpu_sleeve` → tpu_sleeve。アプリの `_partMaterial`（[print_screen.dart](../../../app/lib/features/print/print_screen.dart)）と同じ対応

#### 受託者のアカウント：`fabricator_staff/{email}`（Firestore）

| フィールド | 型 | 内容 |
|---|---|---|
| `fabricator_ids` | array<string> | 受け持つ受託者のID。`["*"]` なら全員 |
| `name` | string | 表示名 |
| `added_at` | timestamp | 追加した日時 |

- ドキュメントIDはメールアドレス（小文字）。`therapists` と同じく、管理者が Firebase コンソールから手で追加する
- 判定は `therapists` と同じく「メールが確認済みで、ドキュメントがある」（[auth.py](../../../api/app/auth.py) の `is_therapist` にならう）

#### 注文：`orders/{orderId}`（Firestore）

ケースの下ではなく、上の階層に置く。受託者ごとの一覧を、ケースをまたいで引くため。

| フィールド | 型 | 内容 |
|---|---|---|
| `owner_uid` | string | 頼んだ人（ケースの持ち主） |
| `case_id`、`design_id` | string | どの版の部品か |
| `display_id` | string | 画面に出す短い番号（例：`A12F`）。注文IDから作る |
| `fabricator_id` | string | 受託者 |
| `fabricator_snapshot` | map | 頼んだときの受託者の名前・地域・料金・日数（あとで JSON を変えても注文は変わらない） |
| `status` | string | `received`（受付）→ `printing`（造形中）→ `shipped`（発送済み）→ `delivered`（受け取った）。`received` からだけ `cancelled`（取り消し） |
| `items` | array<map> | 部品ごと：`print_key`、`name_ja`、`material`、`path`（`cases/{c}/designs/{d}/print/…stl`）、`sha256`、`grams`、`minutes` |
| `quantity` | number | 個数（1〜3。全部の部品に同じ数） |
| `color` | map | 刷る色 `{hex, name_ja}`。注文を作るときに、版の `style.color` を写す（色は版を作り直さずに変えられるので、頼んだときの色を残す）。Claude の判断 |
| `felt` | boolean | フェルトを貼って送るか（カバーを含み、受託者が `felt_service` のときだけ `true` にできる） |
| `price` | map | `parts_yen`、`felt_yen`、`total_yen`（すべて目安。サーバーが計算した値） |
| `lead_days` | number | 発送までの日数 |
| `printer` | map | 頼んだときの印刷の決まり（`fabrication.json` の `printer`） |
| `approval` | map | `kind`（`ot` か `demo`）、OTなら `reviewer_email` と `decided_at` |
| `shipping` | map | `name`、`postal_code`、`address`、`phone` |
| `demo` | boolean | デモのケースからの注文か |
| `created_at`・`printing_at`・`shipped_at`・`delivered_at`・`cancelled_at`・`updated_at` | timestamp | 状態が変わった日時 |

- Firestore のルールは変えない。今の `match /{document=**} { allow read, write: if false; }` で、ブラウザからは `orders` も `fabricator_staff` も読み書きできない。読み書きは生成APIがサーバーの権限で行う
- ケースを消すとき（`DELETE /v1/cases/{case_id}`）は、そのケースの注文も消す（届け先を残さないため）

#### 版に足すもの：`cases/{c}/designs/{d}.print_estimates`

`{print_key: {"volume_mm3", "grams", "minutes"}}`。印刷用STLを読める場所に置くとき（`publish_print`）に計算して入れる。この変更より前に作られた版にはないので、ないときは、注文の入口（§6.2 の `GET …/fabricators`）でSTLを読んで計算し、版に書き足す。

### 6.2 計算

- 部品ごと：体積（trimesh で STL を読んだ `volume`、mm³）→ `grams = volume_mm3 / 1000 × density × mass_factor`、`minutes = grams × minutes_per_gram + setup_minutes`。表示は g を整数、時間は「約2時間」「約40分」のように丸める
- 注文：`parts_yen = base_fee_yen + yen_per_gram × Σ(選んだ部品の grams) × quantity`、`felt_yen = felt ? felt_fee_yen × quantity : 0`、`total_yen = parts_yen + felt_yen`。それぞれ10円単位に丸める
- 受託者の一覧の金額は「全部の部品・個数1・フェルトなし」で計算した値。並び順もこの値
- 注文の画面では、アプリが同じ式でその場で計算して出す。注文を作るときはサーバーが計算し直し、その値を保存して返す（保存する値が正しい値）

### 6.3 生成APIの入口（[api.md](../../api.md) に §3.14 以降として足す）

頼む側（ケースの持ち主）：

| 入口 | 中身 |
|---|---|
| `GET /v1/cases/{c}/designs/{d}/fabricators` | 受託者の一覧（金額の安い順）と、その版の部品ごとの目安（`print_estimates`）、印刷の決まり（`printer`・材料）。発注できる版でなければ `FORBIDDEN` |
| `POST /v1/cases/{c}/designs/{d}/orders` | 注文を作る。本文：`fabricator_id`、`print_keys`、`quantity`、`felt`、`shipping`。下の検査を通れば `orders/{id}` を作り、注文を返す |
| `GET /v1/cases/{c}/orders` | そのケースの注文（新しい順） |
| `POST /v1/orders/{o}/cancel` | 取り消す。`received` のときだけ |
| `POST /v1/orders/{o}/delivered` | 受け取った。`shipped` のときだけ |

注文を作るときの検査：

- 持ち主である（`owned_case`）。違えば `FORBIDDEN`
- 版が今の版で、`approval.status == "approved"`、またはケースが `demo` で版に `print_prepared_at` がある。違えば `FORBIDDEN`
- `print_keys` が1つ以上あり、どれも版の `files.print` にある。違えば `INVALID_ARGUMENT`
- `fabricator_id` が `fabrication.json` にある。`quantity` が1〜3
- `felt == true` なら、受託者が `felt_service` で、`print_keys` に `cover` がある
- `shipping` の4つが空でなく、長さが上限以内（名前・電話は40字、郵便番号は10字、住所は200字）。郵便番号と電話は数字とハイフンだけ
- 各部品の `sha256` は、版の `print_sha256` を写す（受託者がダウンロードするときに照らし合わせる）

受託する側（`fabricator_staff` にあるアカウント）：

| 入口 | 中身 |
|---|---|
| `GET /v1/fabricator/me` | 受け持つ受託者の一覧。許可リストになければ `FORBIDDEN`（アプリはこれでホームの入口を出すか決める） |
| `GET /v1/fabricator/orders?fabricator_id=…` | その受託者への注文の一覧。受け持っていない受託者なら `FORBIDDEN` |
| `GET /v1/fabricator/orders/{o}` | 注文の詳細（§5.3 の中身だけ。ケースの情報は返さない） |
| `GET /v1/fabricator/orders/{o}/files/{print_key}` | 印刷用STLの中身（`model/stl`）。受け持つ受託者の注文で、取り消されていないこと。Storage から読み、注文の `sha256` と合わなければ `STALE_DESIGN` |
| `POST /v1/fabricator/orders/{o}/status` | 本文 `{"status": "printing"}`（`received` から）か `{"status": "shipped"}`（`printing` から）。ほかは `CONFLICT` |

- 1つのケース・1つの版に、注文はいくつでも作れる。進行中の注文があっても断らない（Claude の判断。合わない部品だけを、新しい版や同じ版から頼み直すため。同時に1つだけに絞ると、トランザクションの中で一覧を引く必要があり、今の `db.transaction` ではできない）
- 状態を変える処理は、Firestore のトランザクション（`db.transaction`）の中で、今の状態を読んでから書く（取り消しと「造形を始める」が同時に来ても、片方だけが通る）
- 状態が合わないときのエラーは `CONFLICT`（文は「注文の状態が変わりました。読み込み直してください」）
- ケースの一覧（`GET /v1/cases`）の各ケースに、いちばん新しい取り消し以外の注文の `{order_id, status}` を `latest_order` として足す（ホームの札に使う）

### 6.4 画面

Figma のモックの番号で示す。見た目と部品は今のアプリ（[theme.dart](../../../app/lib/core/ui/theme.dart)、[widgets.dart](../../../app/lib/core/ui/widgets.dart)）に合わせる。

| 画面 | パス | 中身 |
|---|---|---|
| 1a. S10（発注前） | `/cases/:c/designs/:d/print`（今のまま） | ダウンロードできる状態のとき、OTの確認済み → 刷る部品（重さ・時間の目安）→「刷ってもらう」「自分で刷る」の2つの大きなボタン。「自分で刷る」を押すと、今の部品ごとのダウンロードと「まとめてダウンロード」を出す。その下の「用意するもの・組み立て方・着け方・注意」は今のまま |
| 1b. S10（発注後） | 同じ | **その版（`design_id`）の**取り消し以外の注文があれば、いちばん新しい注文の状態を上に出す（4つの段階と日時、受託者、刷る色、金額の目安。発送済みなら「届く目安」＝発送日＋`delivery_days_after_ship`日）。`received` なら「取り消す」、`shipped` なら「受け取った」。頼んだ部品の一覧。それより前の注文は、下に1行ずつ（番号・状態・日付）。その下に、1a と同じ「刷ってもらう」（もう一度頼む）と「自分で刷る」（ダウンロード）を、見出し「もう一度頼む・自分で刷る」の下に小さく残す（頼んだ人も、STLをダウンロードできる）。受け取ったあとも 1b のまま（4つの段階がすべて済みになる）。`received`・`printing`・`shipped` の間は、画面が出ている間だけ5秒ごとに `GET /v1/cases/{c}/orders` を読み直す。Claude の判断 |
| 2. 受託者を選ぶ | `/cases/:c/designs/:d/order` | 架空の表示、機種と並び順の説明、受託者のカード（名前・地域・金額の目安・発送までの日数・機種・フェルトの可否・「ここに頼む」） |
| 3. 注文の内容 | `/cases/:c/designs/:d/order/:fabricatorId` | 部品のチェック、個数（−／＋）、フェルト（受託者ができるときだけ）、材料と機種（変えられない）、届け先の4つの欄、合計の目安と内訳、「この内容で頼む」。頼んだら S10 に戻る |
| 4. 受けた注文 | `/fabricator` | 架空の表示、受託者の切り替え、状態ごとの注文の一覧 |
| 5. 注文の詳細 | `/fabricator/orders/:o` | 状態の札、OTの確認、部品ごとのダウンロードと「まとめてダウンロード」、印刷設定、フェルト、個数・届け先、「受託者には手の3D・採寸・聞き取りの内容を見せません」。下に「造形を始める」か「発送した」 |

- S10 の下の「取り付け具を足す（形の画面へ）」と「ホームへ戻る」は、1a・1b のどちらでも今のまま残す
- 注文の画面（3）と受託する側の詳細（5）に、刷る色（色の丸と名前）を出す
- ホーム：`GET /v1/fabricator/me` が通るアカウントだけ「受けた注文」の入口を出す。ケースのカードに `latest_order.status` の札（受付・造形中・発送済み・受け取った）。`latest_order` は、ケースのすべての版の注文のうち、いちばん新しい取り消し以外の注文
- デモのケースでは、S10・受託者の一覧・注文の画面に今のデモの帯を出す
- 受託者のダウンロードは、生成APIの入口から認証ヘッダー付きで読み、Blob にして保存する（[download.dart](../../../app/lib/features/print/download.dart) の手元の場合と同じやり方）
- 文言は `text_ja.dart` にまとめる（今の画面と同じ）

### 6.5 モックの裏側

[mock_backend.dart](../../../app/lib/core/api/mock_backend.dart) に、§6.3 の入口をすべて足す。受託者の値は `fabrication.json` と同じものを持つ。モックのユーザーは受託者アカウントとしても扱う（ホームに入口が出る）。

## 7. 試験

- 生成API（`api/tests/`、今の `test_api_flow.py` と同じ形。`X-User`・`X-User-Email` で人を切り替える）：
  - 確認前の版では発注できない（`FORBIDDEN`）。デモのケースでは `print_prepared_at` のあとなら発注できる
  - 持ち主以外は発注できない
  - 金額の計算（部品・個数・フェルト・丸め）と、フェルトの条件（受託者ができない・カバーを選んでいない）
  - 状態の流れ：受付 → 造形中 → 発送済み → 受け取った。順番を飛ばすと `CONFLICT`。取り消しは受付のときだけ
  - 許可リストにないアカウント・受け持っていない受託者は、受託する側の入口をすべて `FORBIDDEN`
  - 受託者の注文の詳細に、ケースの情報（測った値・手のメッシュのパス・聞き取り）が入っていない
  - ファイルの入口：中身が返る。`sha256` が違えば `STALE_DESIGN`。取り消した注文は `FORBIDDEN`
  - ケースを消すと、その注文も消える
  - `print_estimates` が公開のときに入る。ない版でも一覧の入口で計算されて入る
- アプリ：金額の計算（`app/test/` に単体の試験）。モックの裏側のビルド（`flutter build web --dart-define=MOCK_API=true`）で、1a → 2 → 3 → 1b → 4 → 5 → 1b（受け取った）を Playwright（WebKit の iPhone 15）で通す

## 8. ほかの作業との重なりと、遅れたときに削る順（Claude の判断）

- 同じ日に `impl` で、ボタンと文字を大きくする直し（finals-plan §2.3・§2.4、`theme.dart` が中心）と、使ったあとの報告（§3.1、S10 の「受け取った」のあと）も進む。ぶつかりを減らすため、この作業は：
  - `theme.dart` を触らない（ボタンの大きさは今のテーマに任せる）
  - 新しい画面と部品は `app/lib/features/order/`・`app/lib/features/fabricator/` に置き、`print_screen.dart` と `home_screen.dart` には、新しい部品を呼ぶ分岐だけを足す
- 11/23 の夜に間に合わなければ、次の順に削る：
  1. モックの裏側で全部の画面を Playwright で通すこと（手で通して確かめる）
  2. この変更より前の版の目安を、あとから計算すること（新しく作った版だけ発注できる。デモは新しいケースで行う）
  3. 5秒ごとの読み直し（S10 に「読み込み直す」ボタンを置く）
  4. 「自分で刷る」側の重さ・時間の目安
- 削らないもの：OTの確認を通す検査、受託者の許可リストの検査、受託者に見せる中身の制限、「デモ用の架空の受託者です」の表示

## 9. 作る人に任せること

- `display_id` の作り方、注文IDの形（例：`o_` ＋ 8桁）
- 時間の丸め方と表示の細部
- 画面の部品の分け方（新しいファイルの置き場所は `app/lib/features/order/` と `app/lib/features/fabricator/` を想定）
- 5秒ごとの読み直しの止め方（画面を離れたら止める）
- api.md・data-model.md・screens.md への書き足しの細部
- 受け取ったあとの「使ってみてどうでしたか」は、この設計では入口（状態が `delivered` になる）までにして、画面は finals-plan §3.1 の設計で作る
