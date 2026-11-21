# アプリの中で発注まで終わらせる Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** OTの確認が済んだ部品を、アプリの中で架空の受託者に発注でき、受託する側が同じアプリで注文を受けて状態を進められるようにする。

**Architecture:** 案A（全部APIを通す）。生成API（FastAPI）に `orders` の入口を足し、Firestore の `orders/{id}` と `fabricator_staff/{email}` をサーバーの権限で読み書きする。受託者と印刷の決まりはリポジトリの `api/app/data/fabrication.json`。アプリ（Flutter Web）は `Api.instance` だけで読み書きし、受託者のSTLもAPIの入口から受け取る。

**Tech Stack:** Python 3 / FastAPI / trimesh（API）、Flutter Web / Dart（アプリ）、pytest、flutter_test、Playwright（WebKit・iPhone 15）

**Spec:** [docs/superpowers/specs/2026-11-21-in-app-ordering-design.md](../specs/2026-11-21-in-app-ordering-design.md)（以下「設計」。§番号は設計の節）

## Global Constraints

- ブランチは `impl`。始める前に、メンバーが `git checkout impl && git merge main` を行う（今の作業ツリーは `main`）
- コミットと push はメンバーが手で行う。各タスクの「Commit」の段階では、実行役はコマンドを渡すだけで、自分では実行しない
- `app/lib/core/ui/theme.dart` は触らない（設計 §8）。新しい画面と部品は `app/lib/features/order/`・`app/lib/features/fabricator/` に置き、`print_screen.dart`・`home_screen.dart` には新しい部品を呼ぶ分岐だけを足す
- Firestore と Storage のルールは変えない。ブラウザから Firestore に書かない
- 受託者に返す中身は設計 §2 の一覧だけ（部品・個数・刷る色・フェルト・届け先・印刷設定・OTの確認の有無と日時）。`case_id`・`design_id`・Storage のパス・採寸・手のメッシュ・聞き取りは返さない
- 受託者の一覧・注文の画面・受けた注文の画面には「デモ用の架空の受託者です。実在の会社ではありません。」を出す。デモのケースでは今の `DemoBanner` も出す
- 金額はすべて「目安」と書く。支払いの画面は作らない
- 画面の文言は、今の画面と同じく各画面のファイルに直接書く（設計 §6.4 の「`text_ja.dart` にまとめる」は誤り。`text_ja.dart` は AI の文の掃除だけを持つ）
- 目安は「最初に要ったときに計算して版に書き足す」1つの道だけで作る。設計 §6.1 の「公開のときに計算」と「ない版はあとから計算」は、この1つで両方を満たす
- `flutter analyze` は日本語のパスで落ちる。`app/` を ASCII のパス（セッションの scratchpad など）に `rsync -a --delete` で写してから実行する。`flutter test`・`flutter build` はその場で動く
- API の試験は `cd api && .venv/bin/python -m pytest …`

## Review Focus

1. **古い版の画面から頼む**：承認のあとに形を作り直し、古い版の S10 を開いたまま「刷ってもらう」を押す → `FORBIDDEN`（今の版だけ発注できる）。Task 2 の `test_order_on_old_design_is_refused`
2. **全角の数字で届け先を入れる**：日本語入力で「０００－００００」「０９０ー１２３４ー５６７８」と入れる → 半角に直して受け付ける。Task 2 の `test_shipping_accepts_fullwidth_digits`
3. **ケースを消したあとに、受託者が注文を開く**：注文も消えているので `NOT_FOUND`（500 にならない）。Task 4 の `test_fabricator_sees_404_after_case_deleted`
4. **Storage から印刷用STLがなくなっている**：受託者のダウンロードは `NOT_FOUND`（500 にならない）。Task 3 の `test_fabricator_file_missing_is_404`
5. **「この内容で頼む」「造形を始める」を素早く2回押す**：送っている間はボタンを押せず、注文や状態の変更は1回だけ起きる。Task 6 の Step 4、Task 8 の Step 3（サーバー側は、状態の変更がトランザクションの中で今の状態を確かめるので、2回目は 409。Task 3 の `test_fabricator_status_flow`）

---

### Task 1: 受託者と印刷の決まり、目安と金額の計算

**Files:**
- Create: `api/app/data/fabrication.json`（設計 §6.1 の JSON をそのまま。加えて `"colors"` に `design_screen.dart` の `_colors` と同じ6色 `{"#2A9D8F": "ティール", "#E76F51": "コーラル", "#264653": "紺", "#E9C46A": "黄色", "#F4F1EA": "白", "#5A666B": "灰色"}`）
- Create: `api/app/fabrication.py`
- Test: `api/tests/test_fabrication.py`

**Interfaces:**
- Produces（`app.fabrication`）：
  - `config() -> dict`（JSON を1回だけ読んで持つ）
  - `fabricators() -> list[dict]`、`fabricator(fid: str) -> dict | None`
  - `part_of(print_key: str) -> str`（`"cover"`／`"c_clip"`／`"tpu_sleeve"`。`c_clip_a2` なども `"c_clip"`）
  - `material_of(print_key: str) -> str`（`"PLA"` など）
  - `estimate_part(stl: bytes, print_key: str) -> dict`（`{"volume_mm3": float, "grams": float, "minutes": float}`）
  - `round10(yen: float) -> int`（10円単位の四捨五入。`math.floor(x / 10 + 0.5) * 10`）
  - `quote(fab: dict, grams: dict[str, float], print_keys: list[str], quantity: int, felt: bool) -> dict`（`{"parts_yen": int, "felt_yen": int, "total_yen": int}`。式は設計 §6.2）
  - `color_of(hex: str | None) -> dict`（`{"hex": hex, "name_ja": 名前か ""}`）

- [ ] **Step 1: 失敗する試験を書く**

```python
# api/tests/test_fabrication.py
import io, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import trimesh
from app import fabrication as fx

def _stl(x, y, z):
    buf = io.BytesIO(); trimesh.creation.box((x, y, z)).export(buf, file_type="stl"); return buf.getvalue()

def test_three_fictional_fabricators():
    fs = fx.fabricators()
    assert [f["id"] for f in fs] == ["umikaze", "hoshizora", "komorebi"]
    assert all(f["fictional"] is True for f in fs)
    assert fx.fabricator("nope") is None

def test_part_and_material_from_print_key():
    assert fx.part_of("cover") == "cover" and fx.material_of("cover") == "PLA"
    assert fx.part_of("c_clip_a2") == "c_clip" and fx.material_of("c_clip") == "PETG"
    assert fx.material_of("tpu_sleeve") == "TPU"

def test_estimate_part_uses_density_and_factor():
    e = fx.estimate_part(_stl(10, 10, 10), "cover")        # 1000 mm³
    assert abs(e["volume_mm3"] - 1000) < 1e-6
    assert abs(e["grams"] - 1.0 * 1.24 * 0.9) < 1e-6
    assert abs(e["minutes"] - (e["grams"] * 5.0 + 5)) < 1e-6

def test_quote_matches_figma_mock():
    umikaze = fx.fabricator("umikaze")
    g = {"cover": 18.0, "c_clip": 4.0}
    assert fx.quote(umikaze, g, ["cover", "c_clip"], 1, False) == {"parts_yen": 1240, "felt_yen": 0, "total_yen": 1240}
    assert fx.quote(umikaze, g, ["cover", "c_clip"], 1, True)["total_yen"] == 1440
    assert fx.quote(umikaze, g, ["c_clip"], 2, False)["parts_yen"] == 960          # 800 + 20×4×2
    assert fx.quote(umikaze, g, ["cover"], 2, True)["felt_yen"] == 400

def test_round10_half_up():
    assert fx.round10(1234.9) == 1230 and fx.round10(1235) == 1240

def test_color_name():
    assert fx.color_of("#2A9D8F") == {"hex": "#2A9D8F", "name_ja": "ティール"}
    assert fx.color_of("#123456")["name_ja"] == ""
```

- [ ] **Step 2: 試験が落ちることを確かめる**

Run: `cd api && .venv/bin/python -m pytest tests/test_fabrication.py -v`
Expected: FAIL（`ModuleNotFoundError: app.fabrication` か `cannot import name`）

- [ ] **Step 3: `api/app/data/fabrication.json` と `api/app/fabrication.py` を書く**

`estimate_part` は `trimesh.load(io.BytesIO(stl), file_type="stl")` の `abs(volume)` から設計 §6.2 の式。`quote` は `parts_yen = round10(base_fee_yen + yen_per_gram × Σgrams[k] × quantity)`、`felt_yen = round10(felt_fee_yen × quantity) if felt else 0`、`total_yen = parts_yen + felt_yen`。

- [ ] **Step 4: 試験が通ることを確かめる**

Run: `cd api && .venv/bin/python -m pytest tests/test_fabrication.py -v`
Expected: 6 passed

- [ ] **Step 5: Commit（メンバーに渡す）**

```bash
git add api/app/data/fabrication.json api/app/fabrication.py api/tests/test_fabrication.py
git commit -m "api: 架空の受託者と印刷の決まり、重さ・時間・金額の目安の計算を足す"
```

---

### Task 2: 頼む側の入口（受託者の一覧・発注・注文の一覧・取り消し・受け取った）

**Files:**
- Create: `api/app/routes/orders.py`
- Modify: `api/app/main.py`（`from .routes import cases, designs, measurement, misc, orders` と `include_router` の並びに `orders.router`）
- Test: `api/tests/test_orders.py`

**Interfaces:**
- Consumes: Task 1 の `app.fabrication` すべて。`routes.common.owned_case`、`store.db`・`files`・`now`、`errors.ApiError`
- Produces（`app.routes.orders`）：
  - `ensure_estimates(case_id: str, design_id: str, d: dict) -> dict[str, dict]`（`d["files"]["print"]` の全キーについて `print_estimates` を返す。足りなければ `files.get(path)` から計算して `db.update` で書き足す。STL が見つからないキーは飛ばす）
  - `orderable_design(case_id: str, design_id: str, user) -> tuple[dict, dict]`（`(case, design)`。設計 §6.3 の「注文を作るときの検査」の最初の2つ。満たさなければ `ApiError("FORBIDDEN")`）
  - `owner_view(order_id: str, o: dict) -> dict`（全部のフィールド＋`order_id`）
  - 状態の名前：`received`・`printing`・`shipped`・`delivered`・`cancelled`
  - 入口：`GET /v1/cases/{c}/designs/{d}/fabricators` → `{"fabricators": [{…受託者, "price": quote(全部品・1個・フェルトなし)}], "estimates": {key: {...}}, "printer": {...}, "materials": {key: "PLA"…}, "color": {hex, name_ja}}`（金額の安い順）／`POST /v1/cases/{c}/designs/{d}/orders` → `{"order": owner_view}`（201）／`GET /v1/cases/{c}/orders` → `{"orders": [owner_view…]}`（新しい順）／`POST /v1/orders/{o}/cancel`・`POST /v1/orders/{o}/delivered` → `{"order": owner_view}`
  - 状態が合わないとき：`ApiError("CONFLICT", "注文の状態が変わりました。読み込み直してください")`

- [ ] **Step 1: 失敗する試験を書く**

`test_api_flow.py` の準備を使い回す：

```python
# api/tests/test_orders.py
from test_api_flow import H, client, _setup_case, _put_measurement  # noqa: F401（client は fixture）
from app.store import db, files

SHIP = {"name": "見本 太郎", "postal_code": "000-0000", "address": "見本の住所", "phone": "000-0000-0000"}

def _ready(client):
    """デモのケースで、印刷用データまで作った版"""
    cid, raw, mesh_id = _setup_case(client)
    _put_measurement(client, cid, raw, mesh_id)
    d = client.post(f"/v1/cases/{cid}/designs", headers=H, json={}).json()["design"]
    assert client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/prepare-print", headers=H).status_code == 200
    return cid, d["design_id"]

def _order(client, cid, did, **kw):
    body = {"fabricator_id": "umikaze", "print_keys": ["cover", "c_clip"], "quantity": 1, "felt": False, "shipping": SHIP} | kw
    return client.post(f"/v1/cases/{cid}/designs/{did}/orders", headers=H, json=body)
```

試験（名前と確かめること）：

- `test_fabricators_sorted_with_estimates`：一覧が `["hoshizora", "umikaze", "komorebi"]` の順（仮のSTLは1部品約1.1gと軽いので、基本料の安い順になる：670円・840円・1,060円）。各 `price.total_yen` が `fabrication.quote(…, 全部品, 1, False)` と同じ。`estimates` に `cover` と `c_clip` があり `grams > 0`。版の文書に `print_estimates` が書き足されている
- `test_order_requires_approval_or_demo`：`db.update(f"cases/{cid}", {"demo": False})` のあと `_order` は 403。`fabricators` の入口も 403
- `test_order_on_old_design_is_refused`：`db.update(f"cases/{cid}", {"current_design_id": "d_other"})` のあと `_order` は 403
- `test_only_owner_can_order`：`headers={"X-User": "someone"}` で 403
- `test_create_order_snapshot`：201。`status == "received"`、`price == {"parts_yen": …, "felt_yen": 0, "total_yen": …}` が `fabrication.quote(umikaze, estimates, ["cover","c_clip"], 1, False)` と同じ、`items` の各 `sha256` が版の `print_sha256` と同じ、`color["hex"]` が版の `style.color`、`approval["kind"] == "demo"`、`fabricator_snapshot["name"] == "うみかぜ3D工房"`、`printer["model"] == "Bambu Lab A1"`
- `test_felt_rules`：`hoshizora` で `felt=True` は 400、`print_keys=["c_clip"]` で `felt=True` は 400、`umikaze`・カバーありの `felt=True` は 201 で `felt_yen == 200`
- `test_invalid_order_inputs_are_400`：`quantity` 0 と 4、`print_keys` 空・版にないキー、`fabricator_id` 不明、`shipping` の欄が空・住所 201字・郵便番号に英字、のそれぞれ 400
- `test_shipping_accepts_fullwidth_digits`：`postal_code="０００－００００"`・`phone="０９０ー１２３４ー５６７８"` で 201、保存された値は `"000-0000"`・`"090-1234-5678"`
- `test_multiple_orders_allowed`：2回頼んで2つとも 201。`GET /v1/cases/{cid}/orders` が新しい順に2件
- `test_cancel_only_when_received`：受付で取り消し 200（`status == "cancelled"`）。`db` で別の注文を `printing` にしてから取り消すと 409
- `test_delivered_only_when_shipped`：受付で `delivered` は 409。`shipped` にしてからは 200（`status == "delivered"`、`delivered_at` がある）
- `test_other_user_cannot_touch_order`：別の `X-User` で `cancel`・`delivered`・`GET /v1/cases/{cid}/orders` が 403

- [ ] **Step 2: 試験が落ちることを確かめる**

Run: `cd api && .venv/bin/python -m pytest tests/test_orders.py -v`
Expected: FAIL（404。入口がまだない）

- [ ] **Step 3: `api/app/routes/orders.py` を書き、`main.py` に登録する**

- 注文ID は `"o_" + uuid4().hex[:8]`、`display_id = order_id[2:6].upper()`
- 届け先は、検査の前に全角の数字・ハイフン類（`－` `ー` `‐` `−`）を半角に直す（`unicodedata.normalize("NFKC", s)` のあと、残ったハイフン類を `-` に）。郵便番号は `^[0-9-]{1,10}$`、電話は `^[0-9-]{1,40}$`、名前は1〜40字、住所は1〜200字
- `items` は `print_keys` の順に `{print_key, name_ja, material, path, sha256, grams, minutes}`。`name_ja` は `cover` → 「カバー」、`c_clip…` → 「C字クリップ」＋版の取り付け具から道具と角度（あれば。`(筆・70度)` の形）、`tpu_sleeve` → 「TPUの筒」
- `approval` は版が `approved` なら `{"kind": "ot", "reviewer_email", "decided_at"}`、そうでなければ `{"kind": "demo"}`
- 取り消し・受け取ったは `db.transaction` の中で今の `status` を読んでから書き、`*_at` と `updated_at` を入れる

- [ ] **Step 4: 試験が通ることを確かめる**

Run: `cd api && .venv/bin/python -m pytest tests/test_orders.py tests/test_api_flow.py -v`
Expected: 全部 passed（`test_api_flow.py` も壊れていない）

- [ ] **Step 5: Commit（メンバーに渡す）**

```bash
git add api/app/routes/orders.py api/app/main.py api/tests/test_orders.py
git commit -m "api: 受託者の一覧と、発注・注文の一覧・取り消し・受け取ったの入口を足す"
```

---

### Task 3: 受託する側の入口

**Files:**
- Modify: `api/app/auth.py`（`fabricator_ids_for` を足す）
- Modify: `api/app/routes/orders.py`（受託する側の入口と `fabricator_view`）
- Test: `api/tests/test_orders.py`（続き）

**Interfaces:**
- Consumes: Task 2 の `orders` コレクションの形と `owner_view`
- Produces：
  - `auth.fabricator_ids_for(user) -> list[str] | None`（メール確認済みで `fabricator_staff/{email}` があれば受け持つID。`["*"]` は全部のID に広げる。なければ `None`）
  - `orders.fabricator_view(order_id: str, o: dict) -> dict`（`order_id, display_id, fabricator_id, fabricator_snapshot, status, items（各要素から path を除く）, quantity, color, felt, price, lead_days, printer, approval, shipping, demo, created_at, printing_at, shipped_at, delivered_at, cancelled_at, updated_at` だけ）
  - 入口：`GET /v1/fabricator/me` → `{"fabricators": [{id, name}…]}`／`GET /v1/fabricator/orders?fabricator_id=…` → `{"orders": [fabricator_view…]}`（新しい順）／`GET /v1/fabricator/orders/{o}` → `{"order": fabricator_view}`／`GET /v1/fabricator/orders/{o}/files/{print_key}` → `model/stl` の中身（`Content-Disposition: attachment; filename="<path の最後>"`）／`POST /v1/fabricator/orders/{o}/status` 本文 `{"status": "printing"|"shipped"}` → `{"order": fabricator_view}`

- [ ] **Step 1: 失敗する試験を書く**

```python
FAB = {"X-User": "fab1", "X-User-Email": "fab@example.com"}

def _staff(ids=("*",)):
    db.set("fabricator_staff/fab@example.com", {"fabricator_ids": list(ids), "name": "受託者役"})
```

- `test_non_staff_gets_403_everywhere`：許可リストなしで5つの入口すべて 403
- `test_staff_scope_by_fabricator`：`_staff(["hoshizora"])` で `GET /v1/fabricator/orders?fabricator_id=umikaze` は 403、`me` は `hoshizora` だけ
- `test_fabricator_view_hides_case_data`：注文の詳細のキーに `case_id`・`design_id`・`owner_uid` がなく、`items[*]` に `path` がない。`shipping`・`color`・`printer`・`approval` はある
- `test_fabricator_status_flow`：`printing` → 200、もう一度 `printing` → 409、`shipped` → 200（`shipped_at` がある）。受付から直接 `shipped` は 409。`{"status": "delivered"}` は 400
- `test_cancel_vs_printing_race_is_single_winner`：`printing` にしたあとの頼む側の取り消しは 409
- `test_fabricator_file_download`：200、`content-type` が `model/stl`、中身が Storage の `print/cover.stl` と同じ
- `test_fabricator_file_sha_mismatch`：`files.put(<そのパス>, b"changed")` のあと 409 で `error.code == "STALE_DESIGN"`
- `test_fabricator_file_missing_is_404`：そのパスのファイルを消した（`files.delete_prefix(<パス>)`）あと 404
- `test_cancelled_order_file_is_403`：取り消した注文のファイルは 403

- [ ] **Step 2: 試験が落ちることを確かめる**

Run: `cd api && .venv/bin/python -m pytest tests/test_orders.py -v -k "fabricator or staff or race"`
Expected: FAIL（404）

- [ ] **Step 3: `fabricator_ids_for` と受託する側の入口を書く**

状態の変更は Task 2 と同じく `db.transaction` の中。受け持っていない受託者の注文は、存在を知らせないよう 404 ではなく 403 にそろえる。

- [ ] **Step 4: 試験が通ることを確かめる**

Run: `cd api && .venv/bin/python -m pytest tests/ -v`
Expected: 全部 passed

- [ ] **Step 5: Commit（メンバーに渡す）**

```bash
git add api/app/auth.py api/app/routes/orders.py api/tests/test_orders.py
git commit -m "api: 受託する側の入口（受けた注文・詳細・STLの受け取り・状態の変更）を足す"
```

---

### Task 4: ケースとのつながり（消すときに注文も消す、ホームの札）と API の文書

**Files:**
- Modify: `api/app/routes/cases.py`（`delete_case`、`list_cases`）
- Modify: `docs/api.md`（§2 の一覧と §3.14〜。設計 §6.3 の入口と検査）、`docs/data-model.md`（§2 の一覧、`orders/{orderId}`・`fabricator_staff/{email}`・版の `print_estimates`、§4.1 の表に「不可（APIだけ）」の2行）
- Test: `api/tests/test_orders.py`（続き）

**Interfaces:**
- Consumes: Task 2・3 の `orders` の形
- Produces：`GET /v1/cases` の各ケースに `latest_order: {"order_id", "status"} | None`（そのケースのすべての版の注文のうち、`created_at` がいちばん新しい取り消し以外の注文）

- [ ] **Step 1: 失敗する試験を書く**

- `test_case_list_has_latest_order`：注文なしで `latest_order is None`。2つ頼んで新しい方を取り消すと、古い方の `order_id` と `"received"`
- `test_delete_case_deletes_orders`：頼んだあとケースを消すと `db.list("orders")` にそのケースの注文がない
- `test_fabricator_sees_404_after_case_deleted`：`_staff()` のあとケースを消すと、受託者の詳細・ファイルは 404

- [ ] **Step 2: 試験が落ちることを確かめる**

Run: `cd api && .venv/bin/python -m pytest tests/test_orders.py -v -k "latest_order or delete"`
Expected: FAIL

- [ ] **Step 3: `cases.py` を直し、`api.md`・`data-model.md` に書き足す**

`delete_case` は、ケースの文書を消す直前に、`db.list("orders")` から `case_id` が同じものを消す（今の「ケースの文書は最後に消す」の順を守る）。

- [ ] **Step 4: 試験が通ることを確かめる**

Run: `cd api && .venv/bin/python -m pytest tests/ -v`
Expected: 全部 passed

- [ ] **Step 5: Commit（メンバーに渡す）**

```bash
git add api/app/routes/cases.py api/tests/test_orders.py docs/api.md docs/data-model.md
git commit -m "api: ケースを消すと注文も消し、ケースの一覧にいちばん新しい注文を足す。発注の入口とデータを文書に書く"
```

---

### Task 5: アプリの計算とモックの裏側

**Files:**
- Create: `app/lib/features/order/order_logic.dart`
- Modify: `app/lib/core/api/mock_backend.dart`
- Test: `app/test/order_logic_test.dart`

**Interfaces:**
- Consumes: Task 2・3 の入口の形（モックはそれをまねる）
- Produces（`order_logic.dart`）：
  - `int round10(num yen)`（サーバーと同じ四捨五入）
  - `Map<String, int> quoteOrder(Map<String, dynamic> fab, Map<String, num> grams, List<String> keys, int quantity, bool felt)`（`parts_yen`・`felt_yen`・`total_yen`）
  - `String yen(int v)`（`約1,440円`）、`String gramsJa(num g)`（`約18g`）、`String minutesJa(num m)`（60分未満は「約40分」、それ以上は30分単位で「約2時間」「約1時間30分」）
  - `const orderSteps = ['received', 'printing', 'shipped', 'delivered']`、`String orderStatusJa(String s)`（受付・造形中・発送済み・受け取った・取り消し）
  - `DateTime? deliveryEstimate(Map<String, dynamic> order, int daysAfterShip)`（`shipped_at` ＋日数。未発送は null）
  - `const fictionalNotice = 'デモ用の架空の受託者です。実在の会社ではありません。'`
- モックの裏側：Task 2・3 のすべての入口を `handle` に足す。受託者の値は `fabrication.json` と同じ3件。モックの利用者は受託者アカウントとしても扱う（`/v1/fabricator/me` が3件を返す）。版の目安は部品ごとに固定値（カバー 18g・クリップ 4g）

- [ ] **Step 1: 失敗する試験を書く**

```dart
// app/test/order_logic_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:jijogu_app/core/api/mock_backend.dart';
import 'package:jijogu_app/features/order/order_logic.dart';

const umikaze = {'id': 'umikaze', 'base_fee_yen': 800, 'yen_per_gram': 20, 'felt_service': true, 'felt_fee_yen': 200};

void main() {
  test('金額は Figma のモックと同じ', () {
    final g = {'cover': 18, 'c_clip': 4};
    expect(quoteOrder(umikaze, g, ['cover', 'c_clip'], 1, false)['total_yen'], 1240);
    expect(quoteOrder(umikaze, g, ['cover', 'c_clip'], 1, true)['total_yen'], 1440);
    expect(yen(1440), '約1,440円');
  });
  test('時間の丸め', () {
    expect(minutesJa(40), '約40分');
    expect(minutesJa(118), '約2時間');
    expect(minutesJa(95), '約1時間30分');
  });
  test('届く目安は発送日＋日数', () {
    final o = {'status': 'shipped', 'shipped_at': '2026-11-23T10:10:00Z'};
    expect(deliveryEstimate(o, 2)!.day, 25);
    expect(deliveryEstimate({'status': 'printing'}, 2), isNull);
  });
  test('mock: 頼む → 造形中 → 発送 → 受け取った', () async {
    // ケースと版を作って prepare-print まで進める手順は、data_test.dart の今のモックの試験と同じ
    // （MockBackend.instance.handle(method, path, body)）。そのあと：
    // 1. GET  /v1/cases/{c}/designs/{d}/fabricators → fabricators の id が [umikaze, hoshizora, komorebi]
    //    （モックの目安はカバー18g・クリップ4g なので 1,240円・1,260円・1,550円の安い順）
    // 2. POST /v1/cases/{c}/designs/{d}/orders（umikaze・全部品・1個・フェルトあり）→ order.status == 'received'、price.total_yen == 1440
    // 3. GET  /v1/cases/{c}/orders → 1件
    // 4. POST /v1/fabricator/orders/{o}/status {status: printing} → 'printing'、続けて shipped → 'shipped'
    // 5. POST /v1/orders/{o}/delivered → 'delivered'
    // 6. POST /v1/orders/{o}/cancel → ApiError（code: 'CONFLICT'）
  });
}
```

- [ ] **Step 2: 試験が落ちることを確かめる**

Run: `cd app && flutter test test/order_logic_test.dart`
Expected: FAIL（`order_logic.dart` がない）

- [ ] **Step 3: `order_logic.dart` を書き、`mock_backend.dart` に入口を足す**

- [ ] **Step 4: 試験が通ることを確かめる**

Run: `cd app && flutter test`
Expected: All tests passed（今の試験も含めて）

- [ ] **Step 5: Commit（メンバーに渡す）**

```bash
git add app/lib/features/order/order_logic.dart app/lib/core/api/mock_backend.dart app/test/order_logic_test.dart
git commit -m "app: 発注の金額・時間・状態の計算と、モックの裏側の発注の入口を足す"
```

---

### Task 6: 受託者を選ぶ画面と、注文の内容の画面（Figma 2・3）

**Files:**
- Create: `app/lib/features/order/fabricator_list_screen.dart`（`FabricatorListScreen({required String caseId, required String designId})`）
- Create: `app/lib/features/order/order_form_screen.dart`（`OrderFormScreen({required String caseId, required String designId, required String fabricatorId})`）
- Modify: `app/lib/app/paths.dart`（`Paths.order(c, d) => '/cases/$c/designs/$d/order'`、`Paths.orderForm(c, d, f) => '/cases/$c/designs/$d/order/$f'`）
- Modify: `app/lib/app/router.dart`（`designs/:d/order` と `designs/:d/order/:f` を `print` の分岐の隣に）
- Test: `app/test/data_test.dart`（パスの試験を足す）

**Interfaces:**
- Consumes: Task 5 の `order_logic.dart`、Task 2 の `GET …/fabricators`・`POST …/orders`
- Produces: `Paths.order`・`Paths.orderForm`。注文の画面は、頼めたら `Navigator.pop` を2回して S10 に戻り、S10 が読み直す（S10 は `pushNamed(...).then((_) => _load())` で受ける。Task 7）

- [ ] **Step 1: パスの試験を書く**

```dart
test('発注のパス', () {
  expect(Paths.order('c1', 'd1'), '/cases/c1/designs/d1/order');
  expect(Paths.orderForm('c1', 'd1', 'umikaze'), '/cases/c1/designs/d1/order/umikaze');
});
```

Run: `cd app && flutter test test/data_test.dart` → Expected: FAIL

- [ ] **Step 2: 2つの画面と、パス・ルートを書く**

- 見た目は Figma 2・3。部品は今の `AppPage`・`InfoCard`（`NoticeTone.warning` で架空の表示）・`ChoiceButton(multi: true)`（部品とフェルトのチェック）・`StatusLabel`（機種・フェルトの札、「架空」）・`FilledButton`／`FilledButton.tonal`
- 受託者のカード（名前・地域・`yen(price.total_yen)`（目安）・「発送まで◯日」・機種・フェルトの札・「ここに頼む」）。デモのケースなら上に `DemoBanner`
- 注文の画面：部品のチェック（最初は全部）、個数の −／＋（1〜3）、フェルト（`felt_service` のときだけ。カバーのチェックを外したら外して押せなくする）、材料と機種と印刷設定（`printer` を表示だけ）、刷る色（色の丸と `color.name_ja`）、届け先の4つの `TextField`（郵便番号と電話は `keyboardType: TextInputType.phone`）、合計（`quoteOrder` でその場で計算。内訳と「目安」「支払いの画面はありません（デモ）」）
- 「この内容で頼む」は、部品が1つ以上・届け先の4つが空でないときだけ押せる

- [ ] **Step 3: 試験と静的解析が通ることを確かめる**

Run: `cd app && flutter test` → Expected: All tests passed
Run: `rsync -a --delete app/ <ASCIIのパス>/app/ && cd <ASCIIのパス>/app && flutter analyze` → Expected: No issues found（または今と同じ件数）

- [ ] **Step 4: 二重押しを防ぐ**

「この内容で頼む」を押したら `_busy = true` にしてボタンを `onPressed: null` にし、応答（成功・失敗）で戻す。モックのビルドで、押した直後にボタンが押せない色になることを目で確かめる（Run: `cd app && flutter build web --dart-define=MOCK_API=true` のあと、`build/web` を手元で配って開く）

- [ ] **Step 5: Commit（メンバーに渡す）**

```bash
git add app/lib/features/order/ app/lib/app/paths.dart app/lib/app/router.dart app/test/data_test.dart
git commit -m "app: 受託者を選ぶ画面と、注文の内容の画面を足す"
```

---

### Task 7: S10 とホームにつなぐ（Figma 1a・1b）

**Files:**
- Create: `app/lib/features/order/print_choice.dart`（`PrintChoice({required VoidCallback onOrder, required VoidCallback onSelfPrint, required Map<String, dynamic>? fabricators})`。1a の「刷ってもらう」「自分で刷る」の大きな2つのボタン。`fabricators` があれば「約1,240円から（目安）」）
- Create: `app/lib/features/order/order_status_card.dart`（`OrderStatusCard({required Map<String, dynamic> order, required int daysAfterShip, VoidCallback? onCancel, VoidCallback? onDelivered})`。4つの段階・受託者・刷る色・金額・届く目安・部品）
- Modify: `app/lib/features/print/print_screen.dart`
- Modify: `app/lib/features/home/home_screen.dart`

**Interfaces:**
- Consumes: Task 2 の `GET …/fabricators`・`GET /v1/cases/{c}/orders`・`cancel`・`delivered`、Task 4 の `latest_order`、Task 3 の `GET /v1/fabricator/me`、Task 5・6 の部品とパス
- Produces: ホームの「受けた注文」の入口は `Navigator.pushNamed(context, '/fabricator')`（画面は Task 8）

- [ ] **Step 1: S10 に分岐を足す**

`ready`（今の変数）のとき：
- `GET /v1/cases/{c}/orders` を読み、`design_id` がこの版の注文だけを使う。取り消し以外の注文がなければ 1a：部品の行に `estimates` の重さ・時間、`PrintChoice`。「自分で刷る」を押したら、今の部品ごとのダウンロードと「まとめてダウンロード」を出す（`_selfPrint = true`）
- 取り消し以外の注文があれば 1b：いちばん新しい注文の `OrderStatusCard`、前の注文を1行ずつ、見出し「もう一度頼む・自分で刷る」の下に `PrintChoice`
- 注文が `received`・`printing`・`shipped` の間は `Timer.periodic(5秒)` で注文だけ読み直し、`dispose` で止める
- 「取り付け具を足す」「ホームへ戻る」と、その下の「用意するもの」以降は今のまま

- [ ] **Step 2: ホームに入口と札を足す**

- `initState` で `GET /v1/fabricator/me` を呼び、通れば上のバーの `actions` に「受けた注文」（`Icons.storefront_rounded`、ラベル付き）。403 なら出さない
- `_CaseCard` に `latest_order.status` があれば `StatusLabel`（受付・造形中は `StatusTone.warning`、発送済み・受け取ったは `StatusTone.success`）

- [ ] **Step 3: モックのビルドで通して確かめる**

Run: `cd app && flutter test` → Expected: All tests passed
Run: `cd app && flutter build web --dart-define=MOCK_API=true` → 開いて、ケースを作り「印刷用データを作る（デモ）」→ 1a → 刷ってもらう → 2 → 3 → 頼む → 1b（受付）→ ホームの札が「受付」になることを目で確かめる

- [ ] **Step 4: 静的解析**

Run: ASCII のパスに写して `flutter analyze` → Expected: 新しい指摘なし

- [ ] **Step 5: Commit（メンバーに渡す）**

```bash
git add app/lib/features/order/print_choice.dart app/lib/features/order/order_status_card.dart app/lib/features/print/print_screen.dart app/lib/features/home/home_screen.dart
git commit -m "app: 印刷の画面に発注の入口と注文の状態を出し、ホームに注文の札と受けた注文の入口を足す"
```

---

### Task 8: 受託する側の画面（Figma 4・5）

**Files:**
- Create: `app/lib/features/fabricator/fabricator_orders_screen.dart`（`FabricatorOrdersScreen()`）
- Create: `app/lib/features/fabricator/fabricator_order_screen.dart`（`FabricatorOrderScreen({required String orderId})`）
- Create: `app/lib/features/fabricator/api_download.dart`（`Future<void> downloadFromApi(String apiPath, String filename)`）
- Modify: `app/lib/app/paths.dart`（`Paths.fabricator() => '/fabricator'`、`Paths.fabricatorOrder(o) => '/fabricator/orders/$o'`）、`app/lib/app/router.dart`
- Test: `app/test/data_test.dart`（パスの試験）

**Interfaces:**
- Consumes: Task 3 の入口すべて、Task 5 の `orderStatusJa`・`fictionalNotice`
- Produces: なし（最後の画面）

- [ ] **Step 1: パスの試験を書いて落ちることを確かめる**

```dart
test('受託する側のパス', () {
  expect(Paths.fabricator(), '/fabricator');
  expect(Paths.fabricatorOrder('o_1'), '/fabricator/orders/o_1');
});
```

Run: `cd app && flutter test test/data_test.dart` → Expected: FAIL

- [ ] **Step 2: `downloadFromApi` を書く**

`Config.mockApi` なら `demo/` の見本を `downloadFile` で開く。それ以外は `'${Config.apiBase}$apiPath'` を `Session.instance.authHeader()` 付きで `http.get` し、`model/stl` の Blob にして `<a download>` で保存する（`download.dart` の手元の場合と同じ手順）。

- [ ] **Step 3: 2つの画面と、パス・ルートを書く**

- 4：架空の表示、受託者の切り替え（`DropdownMenu`。`me` の一覧）、状態ごとの見出し（受付・造形中・発送済み・受け取った・取り消し）と注文の行（番号・部品・個数・日時・フェルト）。行を押すと 5
- 5：状態の札、OTの確認（`approval.kind == 'demo'` なら「デモ：確認を省略」）、部品ごとのダウンロード（`downloadFromApi('/v1/fabricator/orders/$o/files/$key', '<key>.stl')`）と「まとめてダウンロード」、印刷設定、刷る色、フェルト（貼るなら厚さと貼り方）、個数・届け先、「手の3D・採寸・聞き取りの内容は、受託者には見せません。」。下のボタンは `received` なら「造形を始める」、`printing` なら「発送した」、それ以外はなし。押している間は二重押しできない

- [ ] **Step 4: 試験・静的解析・モックで通す**

Run: `cd app && flutter test` → Expected: All tests passed
Run: ASCII のパスで `flutter analyze` → Expected: 新しい指摘なし
Run: モックのビルドで、ホーム → 受けた注文 → 注文 → 造形を始める → 発送した → 頼む側の S10 が「発送済み」と届く目安 → 受け取った、を目で確かめる

- [ ] **Step 5: Commit（メンバーに渡す）**

```bash
git add app/lib/features/fabricator/ app/lib/app/paths.dart app/lib/app/router.dart app/test/data_test.dart
git commit -m "app: 受託する側の画面（受けた注文・注文の詳細・STLのダウンロード・状態の変更）を足す"
```

---

### Task 9: 通しの確かめ、画面の文書、本番に出す

**Files:**
- Modify: `docs/screens.md`（§1 の画面の一覧に S12〜S15 として 2・3・4・5 を足し、S10 の表に 1a・1b の分岐を書く）
- Modify: `docs/notes/2026-11-21-finals-plan.md`（§2.1・§3.2 を「済み」に）

- [ ] **Step 1: Playwright でモックのビルドを通す**

モックのビルド（`flutter build web --dart-define=MOCK_API=true`）を WebKit の iPhone 15 で開き、1a → 2 → 3 → 1b → 4 → 5（造形を始める・発送した）→ 1b（受け取った）を通す。Flutter の画面は `flt-semantics-placeholder` を押して意味の木を出し、`getByRole` で押す。スクロールは `flt-semantics` の `scrollTop` を直接変える。
Expected: 最後に S10 の4つの段階がすべて済みになる

- [ ] **Step 2: API の試験をすべて通す**

Run: `cd api && .venv/bin/python -m pytest tests/ -v`
Expected: 全部 passed

- [ ] **Step 3: 文書を直す**

- [ ] **Step 4: Commit（メンバーに渡す）**

```bash
git add docs/screens.md docs/notes/2026-11-21-finals-plan.md
git commit -m "docs: 発注の画面を画面の仕様に書く"
```

- [ ] **Step 5: 本番に出す（メンバーが行う。実行役は手順を渡す）**

1. Firebase のコンソールで、Firestore に `fabricator_staff/<受託者役のメール（小文字）>` を作り、`fabricator_ids: ["*"]`・`name`・`added_at` を入れる
2. 生成APIを Cloud Run にデプロイし直す（いつもの手順）
3. `app/` で `flutter build web --release --dart-define-from-file=../env/prod.json --output build/web_prod && firebase deploy --only hosting`
4. 本番で、新しいデモのケースを1つ作り、発注 → 受託する側で造形を始める・発送した → 受け取った、まで通す。スマホは、デプロイの直後はタブを閉じて開き直す
