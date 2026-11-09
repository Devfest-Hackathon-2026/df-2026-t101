# 取り付け具を複数持たせる 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 1つの版（カバー1つ）に道具ごとのC字クリップを複数持たせ、聞き取りで道具を複数選べ、できあがった版にもあとから足せる・直せるようにする。

**Architecture:** 版に `attachments`（取り付け具の一覧）を足し、「主な取り付け具」の値は今までの項目（`params` の `c_clip`・`clip_angle_deg`・`tool`・`files.parts.c_clip`）にも入れて互換を保つ。カバーと殻は1回だけ作り、ほかの取り付け具のクリップは `make_design` の `extra_clips` で同じレールに描く。取り付け具のための純粋な関数は `api/app/attachments.py` と `app/lib/data/attachments.dart` に集める。

**Tech Stack:** Python 3.14・FastAPI・trimesh・OpenSCAD（生成API）、Flutter Web 3.47（画面）、Gemini（構造化出力。開発は `GEMINI_MODE=mock`）

**Spec:** [docs/adr/0014-multiple-attachments.md](../adr/0014-multiple-attachments.md)（計画はこの決定に従う。迷ったら ADR を正とする）

## Global Constraints

- **コミットと push はしない**（チームの決まり：人が手で行う）。各タスクの最後は「変えたファイルの一覧」を残すだけにし、全部終わったら人にコミット用のコマンドを渡す
- 取り付け具の数は1つの版に最大4つ（`MAX_ATTACHMENTS = 4`）
- 角度の選択肢は catalog の `c_clip.angle_deg.choices`（今は 60／70／80）。道具ごとの目安は 筆70・ペン60・スプーン60
- 柄の太さの範囲は catalog の `c_clip.tool_d_mm`（3.0〜20.0mm）。区分で答えたときの目安は 細い6.0・ふつう8.5・太い11.5、区分も分からないときは 筆8.5・ペン8.5・スプーン11.5
- 平たい柄の道具は取り付け具を作らず、`「◯◯：平たい柄はクリップで挟めません。太柄スポンジなどで丸くしてください」` を知らせる
- 取り付け具が1つの版は、カバーとクリップの形・画面の見た目・ファイル名（`c_clip_{角度}.preview.stl`、`c_clip_{角度}.stl`）が今と同じ。`geometry_hash` の値は変わってよい
- 取り付け具を足す・直すと新しい版になる。カバーの `cover_shell_sha256` とカバーのプレビュー用STLの中身は前の版と同じ。確認済み（`approval`）は引き継がない
- Firestore の地図のキーに `.` `:` を使わない（取り付け具の印刷用のキーは `c_clip_a2` のようにする）
- 画面の文は日本語。今のコードと同じく、コメントも日本語で短く
- テストのコマンド（`<SP>` は作業用フォルダ）：
  - 生成API：`cd api && LOCAL_STORE_DIR=<SP>/ls .venv/bin/python -m pytest -q -p no:cacheprovider <テスト>`
  - OpenSCAD を使うテスト：先頭に `OPENSCAD_BIN=/Applications/OpenSCAD.app/Contents/MacOS/OpenSCAD`
  - 画面：`cd app && flutter test`。静的チェックは、フォルダ名の日本語で落ちるので `app/` を英数字だけの場所へ写して `flutter analyze`

## Review Focus

1. **この変更の前に作ったケース・版**（`attachments` も `requirements.tools` もない）を S7・S9・S10 で開く、角度を変える、取り付け具を足す → 取り付け具が1つの版として今どおり動く（Task 6・Task 9 にテストを足す）
2. **同じ道具を太さ違いで2つ**（例：ペン8.5mmとペン12mm）→ ファイル名もボタンの名前も区別できる（Task 2・Task 6 にテストを足す）
3. **5つ目を足そうとする** → `INVALID_ARGUMENT`、版は作らず、`requirements.tools` も変えない（Task 6 にテストを足す）
4. **OTに頼んだ版・確認済みの版に足す** → 新しい版の `approval.status` は `none`、ケースは `previewing` に戻る（Task 6 にテストを足す）
5. **聞き取りを開き直す**（道具が複数の要求）→ 選んだ順と道具ごとの太さ・形が戻る。チャットの提案は主な道具に当たる（Task 9 にテストを足す）

---

## ファイルの地図

| ファイル | 役割 | タスク |
|---|---|---|
| `api/app/attachments.py`（新規） | 道具の一覧の正規化、取り付け具の組み立て、ID・ファイル名・キー、取り付け具ごとの引数 | 1・2 |
| `schemas/requirements.schema.json` | `tools` を足す | 1 |
| `api/app/routes/cases.py` | `put_requirements` が `tools` を受け、今までの項目を主な道具でうめる | 1 |
| `api/app/geometry/design.py` | `make_design(..., extra_clips=...)` | 3 |
| `api/app/gemini/{__init__,schemas,mock}.py`、`api/prompts/dimension.v2.md`・`attachment.v1.md`（新規） | 取り付け具ごとの角度 | 4 |
| `api/app/pipeline.py` | 作る・足す・直す・印刷用 | 5・6・7 |
| `api/app/routes/designs.py` | 微調整の指示の種類、`design_view` | 6 |
| `api/tests/test_attachments.py`（新規）、`test_api_flow.py`、`test_geometry_scad.py` | テスト | 各タスク |
| `app/lib/data/requirements.dart`、`app/lib/data/attachments.dart`（新規） | 画面のデータ | 8・9 |
| `app/lib/screens/interview.dart` | 道具を複数選ぶ・道具ごとの質問・まとめ | 9 |
| `app/lib/screens/design.dart` | 取り付け具の切り替え・角度・足す・太さを直す | 10 |
| `app/lib/screens/print.dart`・`review.dart` | 取り付け具ごとの一覧 | 11 |
| `app/lib/data/mock_backend.dart` | モックの取り付け具 | 10・11 |
| `docs/api.md`・`data-model.md`・`screens.md`・`generation-pipeline.md` | 作ったものに合わせる | 各タスク |

---

### Task 1: 要求に道具の一覧（`tools`）を持たせる

**Files:**
- Create: `api/app/attachments.py`
- Modify: `schemas/requirements.schema.json`、`api/app/routes/cases.py`（`SHAFT_D`・`DEFAULT_D` と `put_requirements` の太さの決め方）
- Test: `api/tests/test_attachments.py`、`api/tests/test_api_flow.py`
- Docs: `docs/api.md` §3.2、`docs/data-model.md`（`requirements`）

**Interfaces:**
- Produces（`api/app/attachments.py`）：
  - `TOOL_JA: dict[str, str] = {"brush": "筆", "pen": "ペン", "spoon": "スプーン"}`
  - `ANGLE_BY_TOOL: dict[str, int] = {"brush": 70, "pen": 60, "spoon": 60}`
  - `SHAFT_D`・`DEFAULT_D`（`routes/cases.py` から移す）、`MAX_ATTACHMENTS = 4`
  - `normalize_tool(t: dict) -> dict`：`{activity, tool_type, tool_d_mm, tool_d_source("user"|"category"), tool_shaft_size, tool_shaft_shape, assumptions: list[str]}` を返す（今の `put_requirements` の太さの決め方と同じ）
  - `normalize_tools(body: dict) -> list[dict]`：`body["tools"]` があればそれを、なければ今までの項目から1つの道具を作って正規化する
  - `primary_index(tools: list[dict]) -> int | None`：最初の丸い柄（`tool_shaft_shape != "flat"`）の位置。なければ None
- 要求（`requirements`）の形：`tools` に正規化した一覧（1〜4個）。今までの `activity`・`tool_type`・`tool_d_mm`・`tool_d_source`・`tool_shaft_size`・`tool_shaft_shape` は主な道具（`primary_index`、なければ `tools[0]`）の値。`assumptions` は全部の道具のものを道具の名前つきでまとめる

- [ ] **Step 1: テストを書く**（`api/tests/test_attachments.py`）

```python
from app.attachments import normalize_tools, primary_index

def test_normalize_tools_from_legacy_fields():
    t = normalize_tools({"activity": "draw", "tool_type": "brush", "tool_d_mm": 9.5, "tool_shaft_size": None,
                         "tool_shaft_shape": "round"})
    assert len(t) == 1 and t[0]["tool_d_mm"] == 9.5 and t[0]["tool_d_source"] == "user"

def test_normalize_tools_category_and_order():
    t = normalize_tools({"tools": [
        {"activity": "write", "tool_type": "pen", "tool_d_mm": None, "tool_shaft_size": "thin", "tool_shaft_shape": "round"},
        {"activity": "eat", "tool_type": "spoon", "tool_d_mm": None, "tool_shaft_size": "unknown", "tool_shaft_shape": "round"}]})
    assert [x["tool_type"] for x in t] == ["pen", "spoon"]
    assert t[0]["tool_d_mm"] == 6.0 and t[1]["tool_d_mm"] == 11.5 and t[1]["tool_d_source"] == "category"

def test_primary_is_first_round_tool():
    t = normalize_tools({"tools": [
        {"activity": "eat", "tool_type": "spoon", "tool_d_mm": 10, "tool_shaft_size": None, "tool_shaft_shape": "flat"},
        {"activity": "write", "tool_type": "pen", "tool_d_mm": 9, "tool_shaft_size": None, "tool_shaft_shape": "round"}]})
    assert primary_index(t) == 1
    assert primary_index([t[0]]) is None
```

`api/tests/test_api_flow.py` に足す：

```python
def test_requirements_with_tools_fills_legacy_from_primary(client):
    cid = client.post("/v1/cases", json={}, headers=H).json()["case_id"]
    r = client.put(f"/v1/cases/{cid}/requirements", headers=H, json={
        "activity": "eat", "tool_type": "spoon", "hand_side": "right", "tool_d_mm": 10, "tool_shaft_size": None,
        "tool_shaft_shape": "flat", "finger_state": "fist", "donning_by": "helper", "capture_by": "helper",
        "tools": [{"activity": "eat", "tool_type": "spoon", "tool_d_mm": 10, "tool_shaft_size": None, "tool_shaft_shape": "flat"},
                  {"activity": "write", "tool_type": "pen", "tool_d_mm": 9, "tool_shaft_size": None, "tool_shaft_shape": "round"}]})
    req = r.json()["requirements"]
    assert r.status_code == 200 and len(req["tools"]) == 2
    assert req["tool_type"] == "pen" and req["tool_d_mm"] == 9 and req["tool_shaft_shape"] == "round"
    # 5つは多すぎる
    body = {**r.json()["requirements"], "tools": [req["tools"][1]] * 5}
    assert client.put(f"/v1/cases/{cid}/requirements", headers=H, json=_req_body(body)).status_code == 400
```

（`_req_body` はスキーマにある項目だけを残すテスト用の小さな関数。サーバーが足す `notes` などを落とす）

- [ ] **Step 2: テストが落ちることを確かめる**

Run: `pytest tests/test_attachments.py tests/test_api_flow.py -k "tools or primary" -q`
Expected: FAIL（`app.attachments` がない／`tools` がスキーマで弾かれる）

- [ ] **Step 3: `api/app/attachments.py` を作り、スキーマに `tools`（配列、1〜4個、要素は `activity`・`tool_type`・`tool_d_mm`・`tool_shaft_size`・`tool_shaft_shape`）を足し、`put_requirements` を `normalize_tools` と `primary_index` で書き直す**

`tools` の要素の `tool_shaft_shape` は必須、`tool_d_mm` は null か 3.5〜20。`put_requirements` の「平たい柄」の `assumptions` は、平たい柄の道具ごとに Global Constraints の文を入れる。

- [ ] **Step 4: テストが通ることを確かめる**

Run: `pytest tests/test_attachments.py tests/test_api_flow.py -q`
Expected: PASS（今までのテストも全部）

- [ ] **Step 5: docs を直し、変えたファイルを書き出す**

---

### Task 2: 取り付け具を組み立てる純粋な関数

**Files:**
- Modify: `api/app/attachments.py`、`api/app/gemini/mock.py`（`ANGLE_BY_TOOL` を `app.attachments` から読む）
- Test: `api/tests/test_attachments.py`、`api/tests/test_geometry.py`（`geometry.baseline.ANGLE_BY_TOOL` と同じであることだけ）

**Interfaces:**
- Consumes：Task 1 の `normalize_tools`・`primary_index`・`TOOL_JA`・`ANGLE_BY_TOOL`
- Produces：
  - 取り付け具（dict）の形：`{"id": "a1", "tool_index": 0, "tool_type", "activity", "tool_d_mm", "tool_d_source", "angle_deg": int, "angle_source": "rule"|"ai"|"user", "reason_ja": str, "primary": bool}`。版に保存するときは、Task 5 で `"files": {"preview_stl": key}`・`"print_key": str`・`"tool": {...}`・`"clip": {...}`・`"checks": [...]` が加わる
  - `build_attachments(requirements: dict) -> tuple[list[dict], list[dict]]`：丸い柄の道具を取り付け具に、平たい柄を `skipped`（`{"tool_index", "tool_type", "reason_ja"}`）に。`id` は `f"a{tool_index+1}"`、`primary` は `primary_index` の道具、`angle_deg` は `ANGLE_BY_TOOL`
  - `next_attachment_id(attachments: list[dict]) -> str`：`a` のあとの数字の最大＋1
  - `clip_params(base_c_clip: dict, att: dict) -> dict`：`{**base_c_clip, "tool_d_mm": att["tool_d_mm"], "angle_deg": att["angle_deg"]}`
  - `attachment_params(params: list[Param], att: dict) -> list[Param]`：写しを作り、`c_clip.tool_d_mm` を値と基準値の両方で、`c_clip.angle_deg` を値で置き換える
  - `clip_stem(att: dict, attachments: list[dict]) -> str`：取り付け具が1つなら `c_clip_{角度}`。2つ以上なら `c_clip_{tool_type}_{角度}`、同じ道具がほかにもあれば `_d{太さ×100の4桁}` を足す
  - `print_key(att: dict) -> str`：主なら `"c_clip"`、ほかは `f"c_clip_{att['id']}"`
  - `attachment_label(att: dict, attachments: list[dict]) -> str`：`"ペン"`。同じ道具がほかにもあれば `"ペン 8.5mm"`

- [ ] **Step 1: テストを書く**

```python
from app.attachments import build_attachments, clip_stem, next_attachment_id, print_key, attachment_label

REQ2 = {"tools": [
    {"activity": "draw", "tool_type": "brush", "tool_d_mm": 9.5, "tool_d_source": "user", "tool_shaft_size": None, "tool_shaft_shape": "round"},
    {"activity": "eat", "tool_type": "spoon", "tool_d_mm": 11.5, "tool_d_source": "category", "tool_shaft_size": "thick", "tool_shaft_shape": "round"}]}

def test_build_attachments_two_round_tools():
    atts, skipped = build_attachments(REQ2)
    assert [a["id"] for a in atts] == ["a1", "a2"] and skipped == []
    assert atts[0]["primary"] and not atts[1]["primary"]
    assert (atts[0]["angle_deg"], atts[1]["angle_deg"]) == (70, 60)

def test_flat_tool_is_skipped_and_primary_moves():
    req = {"tools": [{**REQ2["tools"][1], "tool_shaft_shape": "flat"}, REQ2["tools"][0]]}
    atts, skipped = build_attachments(req)
    assert [a["id"] for a in atts] == ["a2"] and atts[0]["primary"]
    assert skipped[0]["tool_type"] == "spoon" and "太柄スポンジ" in skipped[0]["reason_ja"]

def test_names_single_and_duplicate():
    a1 = {"id": "a1", "tool_type": "pen", "tool_d_mm": 8.5, "angle_deg": 60, "primary": True}
    a2 = {"id": "a2", "tool_type": "pen", "tool_d_mm": 12.0, "angle_deg": 60, "primary": False}
    assert clip_stem(a1, [a1]) == "c_clip_60"
    assert clip_stem(a2, [a1, a2]) == "c_clip_pen_60_d1200"
    assert print_key(a1) == "c_clip" and print_key(a2) == "c_clip_a2"
    assert attachment_label(a2, [a1, a2]) == "ペン 12mm" and attachment_label(a1, [a1]) == "ペン"
    assert next_attachment_id([a1, a2]) == "a3"
```

`test_geometry.py` に：`assert geometry.baseline.ANGLE_BY_TOOL == app.attachments.ANGLE_BY_TOOL`

- [ ] **Step 2: 落ちることを確かめる** — Run: `pytest tests/test_attachments.py -q` / Expected: FAIL（関数がない）
- [ ] **Step 3: Interfaces の関数を実装する**（`attachment_label` の太さは `:g` で表す）
- [ ] **Step 4: 通ることを確かめる** — Run: `pytest tests/test_attachments.py tests/test_geometry.py -q` / Expected: PASS
- [ ] **Step 5: 変えたファイルを書き出す**

---

### Task 3: 形の計算で、同じレールにほかのクリップも描く

**Files:**
- Modify: `api/app/geometry/design.py`（`make_design`）、`api/app/geometry/__init__.py` の説明
- Modify: `api/tests/test_api_flow.py` の `_fake_geometry().make_design`（同じ引数を受け、`extra_clips` ごとに箱のSTLを作り、`checks: []`・`violations: []`・`tool`・`clip` を返す）
- Test: `api/tests/test_geometry_scad.py`

**Interfaces:**
- Produces：`make_design(scaled_glb, joints_mm, hand_side, params, workdir, cache, quality="preview", parts=("cover","c_clip"), color="#2A9D8F", extra_clips: dict[str, dict] | None = None) -> dict`
  - 返り値に `"extra_clips": {取り付け具のID: {"file": str, "tool": {...今の "tool" と同じ形}, "clip": {...今の "clip" と同じ形}, "checks": [R6f, R6h], "violations": [...severity が error のもの]}}` を足す
  - `extra_clips` の値は1つのクリップの引数（`clip_params` の返り値）。描き方は主なクリップと同じ（`cliplib.lookup` にあれば持ってくる、なければ OpenSCAD。`quality="print"` なら刷る向き）
  - ほかのクリップの違反は、返り値の最上位の `violations` に**入れない**（外すかどうかは生成の流れが決める）
  - 確認用画像（`views`）は今どおり主なクリップだけ

- [ ] **Step 1: テストを書く**（`test_geometry_scad.py`）

```python
def test_make_design_extra_clip_shares_cover(tmp_path):
    raw = fixture_glb("hand_raw_fist")
    J = parse_joints(read_glb(raw)[2]["joints_mm"])
    pm = prepare_measurement(raw, make_measurement(J, 1.15), "right", {"tool_d_mm": 9.5, "tool_type": "brush"})
    params = {}
    for b in pm["baseline"]:
        params.setdefault(b["part_id"], {})[b["name"]] = b["value"]
    cache = DirCache(tmp_path / "cache")
    base = make_design(pm["scaled_glb"], pm["joints_mm"], "right", params, str(tmp_path / "a"), cache)
    extra = {**params["c_clip"], "tool_d_mm": 12.0, "angle_deg": 60}
    r = make_design(pm["scaled_glb"], pm["joints_mm"], "right", params, str(tmp_path / "b"), cache, extra_clips={"a2": extra})
    e = r["extra_clips"]["a2"]
    assert r["cover_shell_sha256"] == base["cover_shell_sha256"]
    assert Path(e["file"]).exists() and e["clip"]["tool_d_mm"] == 12.0 and e["clip"]["angle_deg"] == 60
    assert {c["rule"] for c in e["checks"]} >= {"R6f", "R6h"}
    assert r["violations"] == base["violations"]
    rp = make_design(pm["scaled_glb"], pm["joints_mm"], "right", params, str(tmp_path / "c"), cache, quality="print", extra_clips={"a2": extra})
    m = trimesh.load(rp["extra_clips"]["a2"]["file"], force="mesh")
    assert m.is_watertight and abs(m.bounds[0][2]) < 0.05      # 刷る向き：机の面に乗る
```

- [ ] **Step 2: 落ちることを確かめる** — Run: `OPENSCAD_BIN=... pytest tests/test_geometry_scad.py -k extra -q` / Expected: FAIL（`extra_clips` がない）
- [ ] **Step 3: `make_design` に `extra_clips` を足す**。主なクリップの「ライブラリから持ってくる／OpenSCAD で描く・R6f・R6h・道具の軸」の部分を、1つのクリップの引数を受ける内部の関数にまとめ、主なクリップとほかのクリップの両方で使う（主なクリップの結果は今と同じ形・同じファイル名のまま）
- [ ] **Step 4: 通ることを確かめる** — Run: `OPENSCAD_BIN=... pytest tests/test_geometry_scad.py tests/test_cliplib.py tests/test_geometry.py -q`、`pytest tests/test_api_flow.py -q` / Expected: PASS
- [ ] **Step 5: 変えたファイルを書き出す**

---

### Task 4: Gemini が取り付け具ごとに角度を選ぶ

**Files:**
- Create: `api/prompts/dimension.v2.md`（v1 に「ほかの取り付け具（`$attachments`）の角度を `attachments` に、取り付け具ごとに60／70／80から理由つきで返す」を足す）、`api/prompts/attachment.v1.md`（1つの取り付け具の角度だけを選ぶ）
- Modify: `api/app/gemini/__init__.py`、`schemas.py`、`mock.py`
- Test: `api/tests/test_attachments.py`
- Docs: `docs/generation-pipeline.md`（寸法決めの出力と、足すときの呼び出し）

**Interfaces:**
- Consumes：取り付け具（Task 2 の形）
- Produces：
  - `schemas.DIMENSION` に任意の `attachments`：`[{"attachment_id": str, "angle_deg": number, "reason_ja": str}]`
  - `schemas.ATTACHMENT = {"angle_deg": number, "reason_ja": str}`（両方必須）
  - `gemini.dimension(requirements, hand, parts, param_defs, violations, usage, attachments: list[dict] | None = None) -> dict`（`attachments` は主でない取り付け具の `{attachment_id, tool_type, activity, tool_d_mm}`）
  - `gemini.attachment_angle(requirements: dict, hand: dict, attachment: dict, usage: Usage) -> dict`（`{"angle_deg", "reason_ja"}`）
  - `PROMPT_VERSIONS["dimension"] = "v2"`、`PROMPT_VERSIONS["attachment"] = "v1"`、`THINKING["attachment"] = "LOW"`
  - モック：`mock.dimension(requirements, param_defs, attachments=None)` は渡された取り付け具ごとに `ANGLE_BY_TOOL` の角度と理由を返す。`mock.attachment_angle(attachment)` も同じ

- [ ] **Step 1: テストを書く**（モックで形を確かめる）

```python
from app import gemini

def test_mock_dimension_returns_angle_per_attachment():
    u = gemini.Usage()
    out = gemini.dimension({"tool_type": "brush", "activity": "draw"}, {}, [], [], None, u,
                           attachments=[{"attachment_id": "a2", "tool_type": "spoon", "activity": "eat", "tool_d_mm": 11.5}])
    assert out["attachments"] == [{"attachment_id": "a2", "angle_deg": 60, "reason_ja": out["attachments"][0]["reason_ja"]}]

def test_mock_attachment_angle():
    a = gemini.attachment_angle({}, {}, {"tool_type": "brush", "activity": "draw"}, gemini.Usage())
    assert a["angle_deg"] == 70 and a["reason_ja"]
```

- [ ] **Step 2: 落ちることを確かめる** — Run: `pytest tests/test_attachments.py -k mock -q` / Expected: FAIL
- [ ] **Step 3: Interfaces のとおりに実装する**（本物の呼び出しは今の `_run` を使う）
- [ ] **Step 4: 通ることを確かめる** — Run: `pytest tests -q`（OpenSCAD なし）/ Expected: PASS
- [ ] **Step 5: docs を直し、変えたファイルを書き出す**

---

### Task 5: 作るときに取り付け具を複数作る

**Files:**
- Modify: `api/app/pipeline.py`（`run` の最初の生成、`_make`、`_render_safe`、`_upload_preview`、`design_view` の返す項目）
- Test: `api/tests/test_api_flow.py`
- Docs: `docs/api.md` §3.4、`docs/data-model.md`（版の `attachments`）

**Interfaces:**
- Consumes：Task 2 の関数、Task 3 の `extra_clips`、Task 4 の `gemini.dimension(..., attachments=)`
- Produces（版に保存する項目）：
  - `attachments`：取り付け具の一覧（Task 2 の形＋`files.preview_stl`・`print_key`・`tool`・`clip`・`checks`）。主な取り付け具の `files.preview_stl` は `files.parts.c_clip.preview_stl` と同じ
  - 今までの項目は主な取り付け具の値（`params` の `c_clip`、`clip_angle_deg`、`clip`、`tool`、`files.parts.c_clip`）
  - `design_view` が `attachments` も返す
- 決まり：
  - `build_attachments` が空なら `DESIGN_INFEASIBLE`（今と同じ文の流れ）。`skipped` は `unresolved_issues`（severity `medium`）に Global Constraints の文で書き、版は `needs_attention`
  - 主でない取り付け具は、角度を `dimension` の `attachments` から（選択肢になければ `ANGLE_BY_TOOL` にし、`clamped` に残す）、範囲チェックを `validator.check(attachment_params(params, att), ..., requirements={**req, "tool_shaft_shape": "round", "tool_d_mm": att["tool_d_mm"]})` で。致命的な違反・`extra_clips` の `violations`（R6f など）・描けない、のどれかなら、その取り付け具を外して `「◯◯のクリップは作れませんでした（理由）」` を書く。主が外れたら次の取り付け具を主に繰り上げて、今までの項目をうめ直す
  - R6h に落ちた取り付け具は `needs_attention` にし、文に道具の名前（`attachment_label`）を入れる
  - プレビュー用STLの名前は `clip_stem(att, attachments) + ".preview.stl"`

- [ ] **Step 1: テストを書く**

```python
def test_design_with_two_tools_makes_two_clips(client):
    cid, raw, mesh_id = _setup_case(client, tools=[("draw", "brush", 9.5, "round"), ("eat", "spoon", 11.5, "round")])
    _put_measurement(client, cid, raw, mesh_id)
    d = client.post(f"/v1/cases/{cid}/designs", json={}, headers=H).json()["design"]
    atts = d["attachments"]
    assert [a["tool_type"] for a in atts] == ["brush", "spoon"] and atts[0]["primary"]
    assert atts[0]["files"]["preview_stl"] == d["files"]["parts"]["c_clip"]["preview_stl"]
    assert atts[0]["files"]["preview_stl"].endswith("c_clip_brush_70.preview.stl")
    assert atts[1]["files"]["preview_stl"].endswith("c_clip_spoon_60.preview.stl")
    assert all(files.get(a["files"]["preview_stl"]) for a in atts)
    assert d["clip_angle_deg"] == 70

def test_single_tool_design_keeps_old_names(client):
    cid, raw, mesh_id = _setup_case(client)          # 今までどおり道具1つ
    _put_measurement(client, cid, raw, mesh_id)
    d = client.post(f"/v1/cases/{cid}/designs", json={}, headers=H).json()["design"]
    assert len(d["attachments"]) == 1 and d["files"]["parts"]["c_clip"]["preview_stl"].endswith("c_clip_70.preview.stl")

def test_flat_tool_is_left_out_with_notice(client):
    cid, raw, mesh_id = _setup_case(client, tools=[("eat", "spoon", 10, "flat"), ("write", "pen", 9, "round")])
    _put_measurement(client, cid, raw, mesh_id)
    d = client.post(f"/v1/cases/{cid}/designs", json={}, headers=H).json()["design"]
    assert [a["tool_type"] for a in d["attachments"]] == ["pen"] and d["status"] == "needs_attention"
    assert any("太柄スポンジ" in i["description_ja"] for i in d["review"]["unresolved_issues"])
```

（`_setup_case` に `tools` を受ける引数を足し、採寸の保存を `_put_measurement` にまとめる。モックの寸法決めで筆は70度になる）

- [ ] **Step 2: 落ちることを確かめる** — Run: `pytest tests/test_api_flow.py -k "tools or single_tool or flat" -q` / Expected: FAIL
- [ ] **Step 3: 決まりのとおりに `run` の最初の生成を書き換える**
- [ ] **Step 4: 通ることを確かめる** — Run: `pytest tests -q` と OpenSCAD のテスト / Expected: PASS
- [ ] **Step 5: docs を直し、変えたファイルを書き出す**

---

### Task 6: 足す・取り付け具ごとに直す

**Files:**
- Modify: `api/app/routes/designs.py`（`refine`）、`api/app/pipeline.py`（`run` の微調整）
- Test: `api/tests/test_api_flow.py`
- Docs: `docs/api.md` §3.5

**Interfaces:**
- Consumes：Task 2・4・5
- Produces（`POST /v1/cases/{case_id}/designs/{design_id}/refine` の本文）：次のどれか1つ（今の4つに2つ足す）。`attachment_id` は `instruction`・`param_changes`・`clip_angle_deg`・`tool_d_mm` に添えてよい（なければ主な取り付け具）。版にない ID は `INVALID_ARGUMENT`
  - `add_attachment`：`{activity, tool_type, tool_d_mm|null, tool_shaft_size, tool_shaft_shape}`
  - `tool_d_mm`：数（3.0〜20.0）
- `pipeline.run(case_id, *, origin, parent=None, style=None, instruction=None, param_changes=None, clip_angle=None, attachment_id: str | None = None, add_attachment: dict | None = None, tool_d: float | None = None)`。`origin` は今のものに `"refine_add_attachment"`・`"refine_tool_d"` を足す
- 古い版（`attachments` がない）は、`params` と今までの項目から主な取り付け具1つを組み立ててから進める（`pipeline._attachments_of(design: dict, requirements: dict) -> list[dict]`）
- 決まり：
  - **足す**：`MAX_ATTACHMENTS` に達していたら、平たい柄なら、太さが範囲外なら、版を作る前に `INVALID_ARGUMENT`。角度は `gemini.attachment_angle`（選択肢になければ `ANGLE_BY_TOOL`）。描いて、足した取り付け具が R6f・描けないで落ちたら、作りかけの版を消して前の版に戻し `RENDER_FAILED`（`details` に検査の名前）。成功したら `requirements.tools` の最後に足す（`tool_index` はその位置）。画像での確認はしない
  - **角度・太さ**：その取り付け具だけ値を変え、全部描き直す（カバーは殻を使い回す）。太さは `requirements.tools[tool_index]` も直し、主なら `requirements.tool_d_mm` と `params` の `c_clip.tool_d_mm`（値と基準値）も直す。画像での確認はしない
  - **言葉・数値**：`cover` などの値は今どおり全部に効かせ、`c_clip` の値は `attachment_id` の取り付け具に（主でなければ、`attachment_params` で作った一覧で Gemini の `refine` と範囲チェックをかけ、角度だけを取り付け具に書き戻す）
  - 新しい版の `approval` は `{"status": "none"}`、ケースは `previewing`

- [ ] **Step 1: テストを書く**

```python
def test_add_attachment_keeps_cover_and_resets_approval(client):
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round")])
    cover_before = files.get(d["files"]["parts"]["cover"]["preview_stl"])
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H,
                    json={"add_attachment": {"activity": "eat", "tool_type": "spoon", "tool_d_mm": 12.0,
                                             "tool_shaft_size": None, "tool_shaft_shape": "round"}})
    n = r.json()["design"]
    assert n["design_id"] != d["design_id"] and [a["id"] for a in n["attachments"]] == ["a1", "a2"]
    assert db.get(f"cases/{cid}/designs/{n['design_id']}")["cover_shell_sha256"] == db.get(f"cases/{cid}/designs/{d['design_id']}")["cover_shell_sha256"]
    assert files.get(n["files"]["parts"]["cover"]["preview_stl"]) == cover_before
    assert n["approval"]["status"] == "none"
    assert [t["tool_type"] for t in db.get(f"cases/{cid}")["requirements"]["tools"]] == ["brush", "spoon"]

def test_add_attachment_refused_without_new_version(client):
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round")] * 1)
    for bad in ({"tool_d_mm": 25.0, "tool_shaft_shape": "round"}, {"tool_d_mm": 9.0, "tool_shaft_shape": "flat"}):
        r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H,
                        json={"add_attachment": {"activity": "write", "tool_type": "pen", "tool_shaft_size": None, **bad}})
        assert r.status_code == 400
    assert db.get(f"cases/{cid}")["current_design_id"] == d["design_id"]
    assert len(db.get(f"cases/{cid}")["requirements"]["tools"]) == 1

def test_fifth_attachment_is_refused(client):
    cid, d = _design_with_tools(client, [("draw", "brush", 8, "round"), ("write", "pen", 9, "round"),
                                         ("eat", "spoon", 11, "round"), ("other", "brush", 10, "round")])
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H,
                    json={"add_attachment": {"activity": "write", "tool_type": "pen", "tool_d_mm": 12, "tool_shaft_size": None, "tool_shaft_shape": "round"}})
    assert r.status_code == 400 and db.get(f"cases/{cid}")["current_design_id"] == d["design_id"]

def test_angle_and_thickness_change_one_attachment(client):
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round"), ("write", "pen", 8.5, "round")])
    n = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H,
                    json={"clip_angle_deg": 80, "attachment_id": "a2"}).json()["design"]
    assert [a["angle_deg"] for a in n["attachments"]] == [70, 80] and n["clip_angle_deg"] == 70
    m = client.post(f"/v1/cases/{cid}/designs/{n['design_id']}/refine", headers=H,
                    json={"tool_d_mm": 9.0, "attachment_id": "a2"}).json()["design"]
    assert m["attachments"][1]["tool_d_mm"] == 9.0
    assert db.get(f"cases/{cid}")["requirements"]["tools"][1]["tool_d_mm"] == 9.0

def test_duplicate_tool_names_are_distinct(client):
    cid, d = _design_with_tools(client, [("write", "pen", 8.5, "round")])
    n = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H,
                    json={"add_attachment": {"activity": "write", "tool_type": "pen", "tool_d_mm": 12.0, "tool_shaft_size": None, "tool_shaft_shape": "round"}}).json()["design"]
    names = [a["files"]["preview_stl"].rsplit("/", 1)[1] for a in n["attachments"]]
    assert len(set(names)) == 2 and all("_d" in x for x in names)

def test_refine_old_design_without_attachments(client):
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round")])
    doc = db.get(f"cases/{cid}/designs/{d['design_id']}")
    doc.pop("attachments")                      # この変更の前に作った版
    db.set(f"cases/{cid}/designs/{d['design_id']}", doc)
    n = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H, json={"clip_angle_deg": 60}).json()["design"]
    assert len(n["attachments"]) == 1 and n["clip_angle_deg"] == 60

def test_add_after_review_request_resets_case(client):
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round")])
    _request_review(client, cid, d["design_id"])     # 既存の test_review_and_approval と同じ手順
    n = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/refine", headers=H,
                    json={"add_attachment": {"activity": "eat", "tool_type": "spoon", "tool_d_mm": 12, "tool_shaft_size": None, "tool_shaft_shape": "round"}}).json()["design"]
    assert n["approval"]["status"] == "none" and db.get(f"cases/{cid}")["status"] == "previewing"
```

（`_design_with_tools`：`_setup_case(tools=...)` → 採寸 → 生成までを1つにまとめた関数。`_request_review`：今の承認のテストの依頼の手順をまとめた関数）

- [ ] **Step 2: 落ちることを確かめる** — Run: `pytest tests/test_api_flow.py -k "attachment or thickness or old_design or review_request" -q` / Expected: FAIL
- [ ] **Step 3: `refine` の指示の判定と、`run` の微調整を決まりのとおりに実装する**（今の微調整は、OTに頼んだ版でも版の `status` が `ready`／`needs_attention` なら直せる。足すときもこの条件のままにする）
- [ ] **Step 4: 通ることを確かめる** — Run: `pytest tests -q` と OpenSCAD のテスト / Expected: PASS
- [ ] **Step 5: docs を直し、変えたファイルを書き出す**

---

### Task 7: 印刷用STLを取り付け具ごとに作る

**Files:**
- Modify: `api/app/pipeline.py`（`prepare_print`・`publish_print`・`geometry_hash`）
- Test: `api/tests/test_api_flow.py`
- Docs: `docs/api.md` §3.6・§3.7・§3.11、`docs/data-model.md`（`files.print`）

**Interfaces:**
- Consumes：Task 2 の `print_key`・`clip_stem`、Task 3 の `extra_clips`（`quality="print"`）
- Produces：
  - `geometry_hash(parts, params, shell_sha, attachments: list[dict] | None = None) -> str`（取り付け具の `(id, tool_d_mm, angle_deg)` を並べて入れる）
  - `files.print`：`{"cover": key, "c_clip": key, "c_clip_a2": key, ...}`（キーは `print_key`、ファイル名は `clip_stem(att, attachments) + ".stl"`）。`print_sha256` も同じキー
  - 取り付け具ごとの `print_key` を `attachments[i]["print_key"]` に保存する

- [ ] **Step 1: テストを書く**

```python
def test_prepare_print_has_one_file_per_attachment(client):
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round"), ("eat", "spoon", 12.0, "round")])
    r = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/prepare-print", headers=H)
    pr = r.json()["files"]["print"]
    assert set(pr) == {"cover", "c_clip", "c_clip_a2"}
    assert pr["c_clip"].endswith("c_clip_brush_70.stl") and pr["c_clip_a2"].endswith("c_clip_spoon_60.stl")
    assert all(files.get(k) for k in pr.values())

def test_single_attachment_print_names_unchanged(client):
    cid, d = _design_with_tools(client, [("draw", "brush", 9.5, "round")])
    pr = client.post(f"/v1/cases/{cid}/designs/{d['design_id']}/prepare-print", headers=H).json()["files"]["print"]
    assert set(pr) == {"cover", "c_clip"} and pr["c_clip"].endswith("c_clip_70.stl")
```

承認の流れ（今の `test_review_and_approval`）にも、取り付け具2つで `print/` に3つのファイルが出ることを足す。

- [ ] **Step 2: 落ちることを確かめる** — Run: `pytest tests/test_api_flow.py -k print -q` / Expected: FAIL
- [ ] **Step 3: 実装する**
- [ ] **Step 4: 通ることを確かめる** — Run: `pytest tests -q` と OpenSCAD のテスト / Expected: PASS
- [ ] **Step 5: docs を直し、変えたファイルを書き出す**

---

### Task 8: 画面のデータ：道具の一覧と取り付け具

**Files:**
- Modify: `app/lib/data/requirements.dart`
- Create: `app/lib/data/attachments.dart`
- Test: `app/test/data_test.dart`

**Interfaces:**
- Produces：
  - `class ToolAnswer { String? activity; String? toolType; double? toolDmm; String? shaftSize; String? shaftShape; bool get isComplete; Map<String, dynamic> toJson(); static ToolAnswer fromJson(Map<String, dynamic>); }`（`toJson` の太さの決まりは今の `Answers.toJson` と同じ。区分の道具は `tool_d_mm: null`）
  - `Answers`：`List<ToolAnswer> tools`（選んだ順）。`ToolAnswer get primary`（最初の丸い柄、なければ最初）。今の `activity`・`toolType`・`toolDmm`・`shaftSize`・`shaftShape` はゲッター・セッターとして残し、`tools` が空なら1つ作ってから `tools[0]` を読み書きする（今のテストと、チャットの提案の当て先＝主な道具のため）。`toJson()` は今までの項目（主な道具の値）と `tools` の両方を出す。`loadFrom` は `tools` があればそれから、なければ今までの項目から1つを戻す。`isAnswered(0)` は `tools` が1つ以上、`isAnswered(2)`・`isAnswered(3)` は全部の道具に答えがある
  - `attachments.dart`：`const toolJa = {'brush': '筆', 'pen': 'ペン', 'spoon': 'スプーン'};`、`List<Map<String, dynamic>> attachmentsOf(Map<String, dynamic> design)`（`attachments` がなければ、`params` の `c_clip`・`files.parts.c_clip`・`tool`・`clip_angle_deg` から主な取り付け具1つ `{'id': 'a1', 'primary': true, ...}` を組み立てる）、`String attachmentLabel(Map<String, dynamic> att, List<Map<String, dynamic>> all)`（生成APIの `attachment_label` と同じ決まり）

- [ ] **Step 1: テストを書く**

```dart
test('道具を2つ選ぶと tools と主な道具の項目を送る', () {
  final a = Answers()
    ..tools = [ToolAnswer()..activity = 'eat'..toolType = 'spoon'..toolDmm = 10..shaftShape = 'flat',
               ToolAnswer()..activity = 'write'..toolType = 'pen'..shaftSize = 'thin'..shaftShape = 'round'];
  final j = a.toJson();
  expect((j['tools'] as List).length, 2);
  expect(j['tool_type'], 'pen');
  expect(j['tool_shaft_size'], 'thin');
  expect(j['tool_d_mm'], isNull);
});
test('保存済みの tools を順番どおりに戻す', () {
  final a = Answers()..loadFrom({'tools': [
    {'activity': 'draw', 'tool_type': 'brush', 'tool_d_mm': 9.5, 'tool_d_source': 'user', 'tool_shaft_shape': 'round'},
    {'activity': 'eat', 'tool_type': 'spoon', 'tool_d_mm': 11.5, 'tool_d_source': 'category', 'tool_shaft_size': 'thick', 'tool_shaft_shape': 'round'}]});
  expect(a.tools.map((t) => t.toolType), ['brush', 'spoon']);
  expect(a.tools[1].toolDmm, isNull);
  expect(a.tools[1].shaftSize, 'thick');
});
test('古い版は取り付け具1つとして読む', () {
  final atts = attachmentsOf({'params': [{'part_id': 'c_clip', 'name': 'angle_deg', 'value': 70},
                                         {'part_id': 'c_clip', 'name': 'tool_d_mm', 'value': 9.5}],
                              'files': {'parts': {'c_clip': {'preview_stl': 'x/c_clip_70.preview.stl'}}}, 'clip_angle_deg': 70});
  expect(atts.length, 1);
  expect(atts[0]['angle_deg'], 70);
  expect(atts[0]['files']['preview_stl'], 'x/c_clip_70.preview.stl');
});
```

（今の4つの `Answers` のテストも、そのまま通ること）

- [ ] **Step 2: 落ちることを確かめる** — Run: `cd app && flutter test` / Expected: FAIL（`ToolAnswer` がない）
- [ ] **Step 3: 実装する**
- [ ] **Step 4: 通ることを確かめる** — Run: `flutter test`、ASCII の場所で `flutter analyze` / Expected: All tests passed、No issues found
- [ ] **Step 5: 変えたファイルを書き出す**

---

### Task 9: 聞き取り（S2）で道具を複数選ぶ

**Files:**
- Modify: `app/lib/screens/interview.dart`、`app/lib/data/mock_backend.dart`（`PUT requirements` が `tools` を保存して返す）
- Test: `app/test/data_test.dart`（チャットの提案が主な道具に当たること）
- Docs: `docs/screens.md` S2

**Interfaces:**
- Consumes：Task 8 の `Answers`・`ToolAnswer`・`toolJa`
- 決まり：
  - 質問1（何をしたいですか）は、押すたびに選ぶ／外す（選んだ順を保つ）。自動では次へ進まず、1つ以上選ぶと「次へ」が押せる。選んだ4つの活動と道具の組は今と同じ（描く→筆、書く→ペン、食べる→スプーン、その他→筆）
  - 質問3（太さ）・質問4（形）は道具ごとに出す。見出しの前に道具の名前（例「ペン：道具の柄の太さ」）。道具が1つなら今と同じ見た目
  - まとめは、道具ごとに「道具・太さ・形」の行を出し、鉛筆のボタンでその道具の質問3に戻る
  - チャットの `suggested_changes` は主な道具に当てる（今の `_applySuggestion` のまま、セッターが主な道具を読み書きする）

- [ ] **Step 1: テストを書く**

```dart
test('チャットの提案は主な道具に当たる', () {
  final a = Answers()
    ..tools = [ToolAnswer()..toolType = 'spoon'..shaftShape = 'flat', ToolAnswer()..toolType = 'pen'..shaftShape = 'round'];
  a.toolDmm = 9.0;                 // _applySuggestion が使うセッター
  expect(a.primary.toolType, 'pen');
  expect(a.primary.toolDmm, 9.0);
});
```

（画面の流れは、モック（`--dart-define=MOCK_API=true`）で、道具1つ・道具2つ・開き直しの3通りを手で確かめる）

- [ ] **Step 2: 落ちることを確かめる** — Run: `flutter test` / Expected: FAIL（セッターが `tools[0]` に当たっている）
- [ ] **Step 3: セッターの当て先を `primary` にし、決まりのとおりに画面を直す**
- [ ] **Step 4: 通ることを確かめる** — Run: `flutter test`、`flutter analyze`、モックで3通り / Expected: PASS
- [ ] **Step 5: docs を直し、変えたファイルを書き出す**

---

### Task 10: プレビュー（S7）で取り付け具を切り替え・足す・直す

**Files:**
- Modify: `app/lib/screens/design.dart`（`_previewPage`・角度のボタン・`_refine` の呼び出し・言葉で直す・数値で直す）、`app/lib/data/mock_backend.dart`（`attachments` を返す、`add_attachment`・`attachment_id`・`tool_d_mm` の微調整）
- Docs: `docs/screens.md` S7

**Interfaces:**
- Consumes：Task 8 の `attachmentsOf`・`attachmentLabel`、Task 6 の `refine` の本文
- 決まり：
  - 選んでいる取り付け具の ID を状態に持つ（最初は主な取り付け具）。取り付け具が2つ以上なら、3D表示の上に道具の名前のボタン（`attachmentLabel`）を並べる
  - 3D表示の `parts` は、カバーと、選んでいる取り付け具のクリップ（`PartFile('c_clip', att['files']['preview_stl'])`）。`tool` は選んでいる取り付け具の `tool`
  - 角度のボタン・AIの角度の理由・主な寸法の表示は、選んでいる取り付け具のもの。角度を押すと `{'clip_angle_deg': a, 'attachment_id': id}`
  - 「言葉で直す」「数値で直す」の本文に `attachment_id` を添える
  - 「取り付け具を足す」：下から出る画面で、道具（筆・ペン・スプーン）、太さ（mm か区分）、形（丸い／平たい）を選ぶ。平たいを選ぶと Global Constraints の文を出して「足す」を押せない。取り付け具が4つなら、ボタンを押せず「取り付け具は4つまでです」。送る本文は `{'add_attachment': ToolAnswer.toJson()}`
  - 「太さを直す」：選んでいる取り付け具の太さを同じ下から出る画面で直し、`{'tool_d_mm': v, 'attachment_id': id}`
  - 新しい版になったときの説明に「カバーは前の版と同じです。刷ってあるカバーをそのまま使えます」を出す（取り付け具を足した・直したとき）
  - モックは、`requirements.tools` から取り付け具を作り、見本のSTLは角度ごとの `demo/c_clip_{角度}.stl` を使う

- [ ] **Step 1: 画面の流れの確かめ方を決める**：モックで、道具2つのケースを作り、切り替え・角度・足す・太さ・5つ目が押せないことを手で確かめる（画面のテストはこのリポジトリにないので、手での確かめを完了の条件にする）
- [ ] **Step 2: モックに取り付け具を足し、`flutter test` が通ることを確かめる**
- [ ] **Step 3: 決まりのとおりに `design.dart` を直す**
- [ ] **Step 4: `flutter analyze`・`flutter test`、モックで Step 1 の手順を通す** / Expected: No issues found、All tests passed、手順が全部できる
- [ ] **Step 5: docs を直し、変えたファイルを書き出す**

---

### Task 11: ダウンロード（S10）と OT確認（S9）の一覧

**Files:**
- Modify: `app/lib/screens/print.dart`、`app/lib/screens/review.dart`、`app/lib/data/mock_backend.dart`（`prepare-print`・承認が取り付け具ごとのファイルを返す）
- Docs: `docs/screens.md` S9・S10

**Interfaces:**
- Consumes：Task 8 の `attachmentsOf`・`attachmentLabel`、Task 7 の `files.print` のキー
- 決まり：
  - S10：カバーの行と、取り付け具ごとの行（`「${attachmentLabel} クリップ（${太さ}mm・${角度}度）」`、ダウンロードは `files.print[att['print_key'] ?? 'c_clip']`）。取り付け具が1つなら、今の見た目（「C字クリップ（70度）」）のまま。「まとめて」は全部。印刷ガイドに「クリップは差し替えて使います。使う道具のクリップをレールに差し込みます」（取り付け具が2つ以上のときだけ）
  - S9：取り付け具ごとに、道具・太さ・角度と、R6f・R6h の結果（合格／注意）を一覧で出す

- [ ] **Step 1: 確かめ方を決める**：モックで、取り付け具2つの版をデモで「印刷用データを作る」→ S10 に3行、OT役で S9 に2つの取り付け具が出ることを手で確かめる
- [ ] **Step 2: モックを直し、`flutter test` が通ることを確かめる**
- [ ] **Step 3: 画面を直す**
- [ ] **Step 4: `flutter analyze`・`flutter test`、モックで Step 1 を通す** / Expected: No issues found、All tests passed、手順が全部できる
- [ ] **Step 5: docs を直し、変えたファイルを書き出す**

---

### Task 12: 全体の確かめと引き渡し

**Files:** なし（確かめだけ）

- [ ] **Step 1: 生成APIの全部のテスト** — Run: `pytest tests -q`（`OPENSCAD_BIN` あり）と hand-mesh の `pytest tests -q` / Expected: 全部 PASS
- [ ] **Step 2: 画面** — Run: `flutter test`、ASCII の場所で `flutter analyze`、`flutter build web --release --dart-define=MOCK_API=true` / Expected: PASS、No issues found、Built
- [ ] **Step 3: 手元の本物の流れ**：生成API（`AUTH_MODE=dev`、`STORE_BACKEND=local`、`GEMINI_MODE=mock`、`OPENSCAD_BIN` あり）で、道具2つのケースの「生成 → 足す → 角度を変える → デモの印刷用データ」を `test_api_flow` と同じ手順で通し、カバーの `cover_shell_sha256` が版をまたいで同じことを確かめる
- [ ] **Step 4: ADR-0014 の「失敗とみなすこと」を1つずつ、どのテストで確かめたかを書き出す**
- [ ] **Step 5: 人にコミット用のコマンド（タスクのまとまりごと）と、本番に出す手順（画面＝Hosting、生成API＝Cloud Run。hand-mesh は変えていない）を渡す**
