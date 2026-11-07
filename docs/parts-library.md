# 部品ライブラリ（OpenSCAD）

> **このドキュメントで決めたこと**
> 1. 部品は「握り本体」「ねじ締めコレット（握りの上端と一体）」「締めナット」の3つを必須にする。握り本体の標準は `fitted`：手のカプセルモデルの指（すき間の分だけ太らせたもの）を握りからくり抜き、くぼみを指に沿わせる。手のモデルが怪しいときは、リング状のくぼみ（`round`／`oval`）に戻す。
> 2. 部品の引数の名前・単位・既定値・範囲は、`scad/catalog.json` を唯一の正とする。生成APIの範囲チェック、Geminiへのプロンプト、この表は、すべてそこから作る。寸法はmm、角度は度。
> 3. ねじのピッチ・すき間・最小の厚さなど、印刷できるかどうかを左右する値は人が固定し、AIには変えさせない。値は11/9の朝の試し刷りで決める。

関連：[measurement.md](measurement.md)（採寸値）、[generation-pipeline.md](generation-pipeline.md)（範囲チェック）、[adr/0005-screw-collet-tool-holder.md](adr/0005-screw-collet-tool-holder.md)（ねじ締め式にした理由）

---

## 1. 全体の形

```
          ┌──┐  ← 道具（筆・ペン・スプーンの柄）
          │  │
        ┌─┴──┴─┐ ← 締めナット（collet_nut）：回すとコレットが締まる
        │ ▒▒▒▒ │
        └┬────┬┘
         │ねじ│   ← コレット（collet）：割りの入った筒＋おねじ。握りの上端と一体
     ╭───┴────┴───╮
     │ ～ くぼみ  │ ← 人差し指（上端からの距離＝finger_pos_mm[0]）
     │ ～ くぼみ  │ ← 中指
     │ ～ くぼみ  │ ← 薬指
     │ ～ くぼみ  │ ← 小指
     ╰─┬────────┬─╯ ← 下端のつば（bottom_flare_mm）：手から抜け落ちにくくする
       └─ 貫通穴 ─┘   ← 長い柄は下まで通せる（bore_through）
```

- 座標：握りの軸をZ軸にする。Z=0が下端（小指側）、Z=`length_mm`が上端（人差し指側）。その上にコレットが付く
- 印刷の向き：握り本体とコレットは立てて刷る（コレットが上）。ナットは平らに置いて刷る。サポートなしで刷れるよう、くり抜いた所とくぼみの張り出しは45度以内にする。ねじ山（台形ねじの面は、立てると約75度張り出す）と角の丸みは、試し刷りで刷れることを確かめた形として扱い、張り出しの自動の検査からは外す（[generation-pipeline.md](generation-pipeline.md) のR6）
- 左右：`fitted` のくり抜きは軸対称ではない。生成APIは、カプセルを実際の手の座標で渡す（右手は正準形から鏡像に戻す。[measurement.md §8.1](measurement.md#81-手の座標系)）ので、右手と左手で、握りの形は互いの鏡像になる。`round`／`oval` はほぼ軸対称。親指置きの向きは `hand` 引数で鏡像にする

## 2. ファイル構成

| パス | 中身 |
|---|---|
| `scad/main.scad` | 入口。全引数の既定値をトップレベル変数で宣言し、`mode` に応じて部品を並べる。生成APIは `-D` でこの変数だけを上書きする |
| `scad/parts/grip_body.scad` | 握り本体 |
| `scad/parts/finger_capsules.scad` | 指のカプセル（くり抜く形）。端点と半径の配列を受け取り、2つの球の `hull()` を並べる |
| `scad/parts/collet.scad` | コレット |
| `scad/parts/collet_nut.scad` | 締めナット |
| `scad/parts/thumb_rest.scad` | 親指置き（拡張） |
| `scad/parts/strap_slot.scad` | ベルト通し（拡張） |
| `scad/lib/common.scad` | 固定値（§3）と、角を丸める共通処理 |
| `scad/view.scad` | 確認用画像の描画専用。STLを読み込み、道具の目安（色付きの棒）と、`fitted` なら手のカプセル（半透明）を添える |
| `scad/test_pieces/*.scad` | 試し刷り用の部品（§6） |
| `scad/vendor/BOSL2/` | ねじ用ライブラリ BOSL2（BSD 2-Clause）。コミットを固定して同梱する。READMEに「BETA CODE」とあるので、更新はしない |
| `scad/catalog.json` | 部品と引数の定義（§4の表の元データ）。生成APIとプロンプトが読む |

`-D` で渡す変数の名前は `<部品ID>_<引数名>` とする（例：`grip_body_length_mm=92`）。配列は `[14,33,51,68]`、真偽値は `true`/`false`、選択肢は `"wings"` のように文字列で渡す。

## 3. 固定値（AIは変えられない）

| 名前 | 値 | 単位 | 理由・決め方 |
|---|---|---|---|
| `NOZZLE_MM` | 0.4 | mm | 一般的なノズルの径。大学のプリンタの実際の値は要確認 |
| `MIN_WALL_MM` | 2.0 | mm | ノズル5本分。これより薄い壁は割れやすい |
| `MIN_WALL_AROUND_BORE_MM` | 3.0 | mm | 握りの中の穴まわり。握ったときの力を受けるため |
| `MIN_EDGE_RADIUS_MM` | 1.5 | mm | 指が当たる所の角の丸みの最小値（安全方針「角を丸める」） |
| `MAX_OVERHANG_DEG` | 45 | 度 | サポートなしで刷れる張り出しの上限 |
| `COLLET_FINGER_WALL_MM` | 2.0 | mm | コレットの割り片の厚さ。薄いほどよく締まるが折れやすい。11/9の試し刷りで見直す |
| `THREAD_PITCH_MM` | 3.0 | mm | 粗いねじの方がFDMでつぶれにくい。BOSL2の台形ねじを使う |
| `THREAD_SLOP_MM` | 0.10（仮） | mm | BOSL2の `$slop`。めねじ側に `4×$slop` のすき間が付く。11/9の朝に0.05／0.10／0.15を刷り比べて決める |
| `THREAD_LENGTH_MM` | 15 | mm | ピッチ5山分。ナットが円すいの長さ（9mm）だけ進んでも、2山以上がかみ合うようにする |
| `COLLET_LENGTH_MM` | 16 | mm | 割り片の長さ。ナットの円すいの位置を割り片の先に合わせるため、AIには変えさせない（前の版はAIが15〜30mmで変えられたが、ナットの高さが固定なので、円すいが割り片の先に届かなかった） |
| `COLLET_TAPER_DEG` | 10 | 度 | コレット先端の外側の傾き。ナット内側の円すいがここを押す |
| `COLLET_TAPER_LENGTH_MM` | 9 | mm | 割り片の先の、傾きを付ける長さ。ナットの円すいも同じ長さにする |
| `CLAMP_RANGE_MM` | 3.0（仮。上限は式で約3.17） | mm | 1つのコレットで挟める太さの幅（`tool_d_max_mm − 3.0` 〜 `tool_d_max_mm`）。幾何の上限は `2 × COLLET_TAPER_LENGTH_MM × tan(COLLET_TAPER_DEG) = 2 × 9 × tan10° ≈ 3.17mm`（ナットが9mm進む場合）。実際に締まる量は試し刷りで確かめる |
| `SLOT_WIDTH_MM` | `π × CLAMP_RANGE_MM / slot_count + 0.4`（4割りで約2.8） | mm | 割りの幅。直径を CLAMP_RANGE だけ縮めると、周の長さは π×CLAMP_RANGE 減るので、割りの合計の幅はそれ以上要る |
| `CAPSULE_CLEARANCE_MM` | 0.5（仮） | mm | くり抜くカプセルを、指の半径より太らせる量（指と握りのすき間）。採寸のずれを吸収する。11/9の朝の `carve_test` で0.3／0.5／1.0を比べて決める |
| `MAX_CARVE_RATIO` | 0.29 | 比 | くり抜きの深さの上限を、カプセルの半径に対する比で表したもの。深さ d、半径 R の円弧の縁の張り出しが45度以下になる条件 `d ≤ R(1 − 1/√2) ≈ 0.29R` から決めた（カプセルが軸に垂直な場合。傾いた場合はR6で確かめる） |
| `BED_MM` | [180, 180, 180] | mm | 造形できる大きさ。大学のプリンタの実際の値は要確認 |
| `FN_PREVIEW` / `FN_PRINT` | 48 / 128 | 個 | 円の分割数。プレビューは軽く、印刷用は滑らかにする |

## 4. 部品と引数

表の「決め方」：**採寸**＝採寸値から計算した値（[§5](#5-採寸値との対応)）、**ルール**＝固定の式、**聞き取り**＝聞き取りの結果、**AI**＝Geminiが要望を見て決める、**ユーザー**＝ユーザーが画面で選ぶ。

「AIが変えてよい幅」は、サーバーが計算した基準値（baseline）から、Geminiが動かしてよい量を表す。これを超えると範囲チェックで止まる（[generation-pipeline.md](generation-pipeline.md)）。

### 4.1 握り本体 `grip_body`（必須）

種類（`variant`）：

- `fitted`（標準）：人差し指側と小指側のすき間の円を結んだ、先細りの筒（`hull()`）から、指のカプセルをくり抜く。軸はすき間の中心どうしを結ぶ線（握りの座標系は [measurement.md §8.4](measurement.md#84-握りの座標系)）
- `round`（断面が円）／`oval`（断面が楕円。手の中で回りにくい）：リング状のくぼみを付ける。手のモデルの警告が多いとき（`FEW_FRAMES`・`LENGTH_UNSTABLE`・`CAVITY_OPEN` など）に使う

`CAVITY_OPEN` がある場合は `fitted` を使わない。有効なすき間の径がない指の基準径は、仮の値32mmと警告を使う（[measurement.md §8.3](measurement.md#83-握りを置く場所指ごとのすき間)）。

`fitted` だけの引数：

| 引数 | 単位 | 既定値 | 範囲 | 決め方 | AIが変えてよい幅 |
|---|---|---|---|---|---|
| `press_depth_mm`（握りをすき間より太くする量。この分だけ指が握りに食い込み、くぼみができる） | mm | `min(1.5, 上限)` | 0.5〜3.0。上限は、握りに当たるカプセル（すき間の円から `press_depth_mm + 半径 + すき間` の距離にあるもの）のうち最も細いものの半径 r_min から `MAX_CARVE_RATIO × (r_min + CAPSULE_CLEARANCE_MM) − CAPSULE_CLEARANCE_MM`。握りに届かない末節は r_min に入れない | AI | 範囲内なら自由 |
| `capsules`（くり抜くカプセルの端点と半径。握りの座標系、mm） | `[[x1,y1,z1,x2,y2,z2,r], …]` | — | 指4本×3区間＝12個まで | 採寸（生成APIが手のモデルから計算） | 変えられない（Geminiの出力にも含めない） |
| `end_margin_mm`（人差し指・小指の外側に足す長さ） | mm | 12 | 8〜20 | AI | 範囲内なら自由 |

`fitted` では、`length_mm` は `|c_index − c_pinky|（軸の長さ）+ 2 × end_margin_mm` で決まる。リング状のくぼみの引数（`finger_pos_mm`・`groove_*`）は使わない。前の版の `axis_offset_mm` は、定義から必ず0になるので廃止した。握りの座標系への変換（[measurement.md §8.4](measurement.md#84-握りの座標系)）は生成APIが版に記録し、カプセルはすでに握りの座標系で渡す。

`round`／`oval` の引数：

| 引数 | 単位 | 既定値 | 範囲 | 決め方 | AIが変えてよい幅 |
|---|---|---|---|---|---|
| `length_mm` | mm | 90 | 60〜150 | 採寸（§5の式） | ±10 |
| `d_top_mm`（人差し指側の太さ） | mm | 32 | 18〜55 | 採寸：人差し指のすき間（§5） | ±3 |
| `d_bottom_mm`（小指側の太さ） | mm | `d_top_mm` と同じ | 18〜55 | 採寸：MVPでは `d_top_mm` と同じ | ±5 |
| `ovality`（短径÷長径） | 比 | 1.0 | 0.70〜1.00（`round` のときは1.0に固定） | AI | 範囲内なら自由 |
| `finger_pos_mm`（各くぼみの中心の、上端からの距離） | mm[4] | — | 各値は `[groove_width_mm/2 + 4, length_mm − groove_width_mm/2 − 4]` の範囲。並びは増加順、間隔は12以上 | 採寸（§5の式） | 各±3 |
| `groove_enabled`（くぼみの有無） | 真偽[4] | [true, true, true, true] | — | AI（届かない指のくぼみを消すなど） | 自由 |
| `groove_width_mm` | mm | 16 | 10〜24 | AI | 範囲内なら自由 |
| `groove_depth_mm` | mm | 2.0 | 0〜4、かつ `groove_width_mm × 0.2` 以下 | AI | 範囲内なら自由 |
| `bottom_flare_mm`（下端のつばの張り出し） | mm | 3 | 0〜6 | AI | 範囲内なら自由 |
| `edge_radius_mm` | mm | 2.5 | 1.5〜5 | AI | 範囲内なら自由（1.5未満は不可） |
| `bore_through`（柄を下まで通す穴） | 真偽 | true | — | AI（短い道具ならfalse） | 自由 |
| `pattern`（模様） | 選択 | `none` | `none` / `rings` / `dots` | ユーザー（拡張） | 変えられない |

組み合わせのルール（範囲チェックで確かめる）：

- `d_top_mm`・`d_bottom_mm` は断面の長径。穴のまわりの厚さは短径で判定する：`(min(d_top_mm, d_bottom_mm) × ovality − 2×groove_depth_mm − bore_d) / 2 ≥ MIN_WALL_AROUND_BORE_MM`。`round` は `ovality=1.0`、`bore_d` は `collet.tool_d_max_mm + 0.5`
- 例：長径18mm、`ovality=0.7`、溝深さ2mm、穴径7.1mmでは、短径側の肉厚は `(18×0.7 − 4 − 7.1)/2 = 0.75mm`。3mm未満なのでR4で不合格にする。楕円率を無視した3.45mmという判定は使わない
- 太さの差：`|d_top_mm − d_bottom_mm| ≤ 15`
- `fitted` のくり抜きは、式ではなく**実際の幾何でカプセルごとに**確かめる（中指・薬指も含む）。カプセルの中心線の上の点を1mmおきに取り、各点で：
  - 握りの軸からその点までの距離を ρ、その高さの握りの半径を R_grip（`d_bottom_mm`〜`d_top_mm` を軸に沿って補間した値の半分）とする
  - くり抜きの深さ：`depth = R_grip − (ρ − r − CAPSULE_CLEARANCE_MM)`（正のときだけ、くぼみができる）
  - 張り出し：`depth ≤ MAX_CARVE_RATIO × (r + CAPSULE_CLEARANCE_MM)`
  - 残りの壁：`(ρ − r − CAPSULE_CLEARANCE_MM) − bore_d/2 ≥ MIN_WALL_AROUND_BORE_MM`
- `press_depth_mm` は、d = D + 2p のとき、すき間の円を決めた指（人差し指・小指）の深さの目安にすぎない。言葉での微調整（「かなり太く」）やスライダーで `d_top_mm`・`d_bottom_mm` を変えると、深さが上限を超えることがある（例：D_index=31.4、すき間0.5でdを39.6にすると深さ4.6mm、上限は約2.2mm）。そのため、**太さを変えたら毎回、上の検査をやり直す**
- 軸が傾くと深さが変わるので、張り出しは描いたあとにメッシュの面の向きでも確かめる（[generation-pipeline.md](generation-pipeline.md) のR6）
- 造形サイズの高さ：`length_mm + THREAD_LENGTH_MM + COLLET_LENGTH_MM + 5 ≤ BED_MM[2]`（立てて刷るため。最大の値の組み合わせでは超えてしまうので、このルールで止める）
- くぼみの深さを幅の0.2倍以下にする理由：くぼみを円弧とみなすと、深さ／幅が0.2のとき縁の張り出しは約41度で、45度以内に収まるため
- 模様は下端のつばの帯にだけ、深さ0.4mmで付ける（指が当たる所には付けない）

### 4.2 コレット `collet`（必須、握りの上端と一体）

種類：`standard` のみ

| 引数 | 単位 | 既定値 | 範囲 | 決め方 | AIが変えてよい幅 |
|---|---|---|---|---|---|
| `tool_d_max_mm`（挟める一番太い柄の径＝穴の径） | mm | 10.6 | 3.5〜19（選択式Q3の区分の上限7／10／13mm＋0.6。スライダーやチャットで直す場合も3〜18mmの柄まで） | 聞き取り：`柄の太さ + 0.6` | ±1 |
| `slot_count`（割りの数） | 個 | 4 | 4〜6 | AI（平たい柄なら4を推奨） | 範囲内なら自由 |

割り片の長さは固定値 `COLLET_LENGTH_MM`（16mm）にした（§3）。

次の値は式で決まり、引数にはしない：

- ねじの外径：`thread_d_mm = max(16, 2 × ceil((tool_d_max_mm + 9) / 2))`。例：柄10mm → 穴10.6mm → 外径20mm
- 挟める太さ：`tool_d_max_mm − CLAMP_RANGE_MM` 〜 `tool_d_max_mm`。例：穴10.6mm なら、およそ7.6〜10.6mmの柄を挟める（式からの値で、要検証）
- 選択式Q3の区分と、挟める太さ（境目を共有して、すき間がないようにした）：
  - 細い（7mmまで）→ 穴7.6mm → 約4.6〜7.6mm
  - ふつう（7〜10mm）→ 穴10.6mm → 約7.6〜10.6mm
  - 太い（10〜13mm）→ 穴13.6mm → 約10.6〜13.6mm
  - 4.6mm未満の細い柄と、13mmを超える柄は、区分では挟めない。チャットかスライダーで柄の太さを直接入れる（穴＝太さ＋0.6mm）
- 警告（止めはしない）：`thread_d_mm > d_top_mm` のとき「ナットが握りより太くなります」と表示する

### 4.3 締めナット `collet_nut`（必須）

種類：`wings`（羽根付き。つまむ力が弱くても、手のひらで回せる）／`knurl`（ぎざぎざの付いた丸形。小さくて目立たない）

| 引数 | 単位 | 既定値 | 範囲 | 決め方 | AIが変えてよい幅 |
|---|---|---|---|---|---|
| `wing_span_mm`（羽根の端から端まで） | mm | 50 | 40〜64（`wings` のとき） | AI | 範囲内なら自由 |
| `edge_radius_mm` | mm | 2.0 | 1.5〜4 | AI | 範囲内なら自由 |

式で決まる値：外径は `thread_d_mm + 8`、高さは `THREAD_LENGTH_MM + COLLET_LENGTH_MM + 2 = 33`。内側の上端に、長さ `COLLET_TAPER_LENGTH_MM`（9mm）・傾き `COLLET_TAPER_DEG` の円すいを付け、割り片の先の傾きと重なる位置にする。

組み合わせのルール：`wings` のとき、`wing_span_mm ≥ 外径 + 10`（羽根が短すぎて手のひらで押せない形にしない）。

### 4.4 親指置き `thumb_rest`（任意・拡張機能）

| 引数 | 単位 | 既定値 | 範囲 | 決め方 |
|---|---|---|---|---|
| `pos_from_top_mm` | mm | 12 | 5〜40 | 採寸（参考値 `thumb_tip_offset_mm`）＋AI |
| `angle_deg`（軸まわりの向き。手のひら側を0度とする） | 度 | 0 | −90〜90（左手は鏡像） | AI |
| `width_mm` | mm | 18 | 14〜24 | AI |
| `depth_mm` | mm | 1.5 | 0.5〜3、かつ `width_mm × 0.2` 以下 | AI |

### 4.5 ベルト通し `strap_slot`（任意・拡張機能）

握る力がほとんどない人のために、面ファスナーのベルトで握りを手に留める。

| 引数 | 単位 | 既定値 | 範囲 | 決め方 |
|---|---|---|---|---|
| `slot_width_mm` | mm | 26 | 20〜30（幅25mmのベルト用） | AI |
| `slot_thickness_mm` | mm | 3.5 | 2.5〜5 | AI |
| `pos_from_top_mm` | mm | `length_mm / 2` | `slot_width_mm/2 + 5` 〜 `length_mm − slot_width_mm/2 − 5` | AI |

穴は軸に沿った縦長の向きにして、立てて刷っても橋渡し（ブリッジ）が短くなるようにする。

### 4.6 全体の引数（`main.scad`）

| 引数 | 選択肢 | 既定値 | 意味 |
|---|---|---|---|
| `hand` | `right` / `left` | `right` | 選択式Q2の答えから入れる |
| `mode` | `assembled` / `print` | `assembled` | `assembled`＝ナットを締めた状態（プレビューと確認用画像）、`print`＝印刷の向きで部品を並べる（ダウンロード用） |
| `quality` | `preview` / `print` | `preview` | 円の分割数（§3） |

## 5. 採寸値との対応

生成APIは、Geminiに聞く前に、採寸値から基準値（baseline）を計算する。Geminiはこの基準値を、§4の「AIが変えてよい幅」の中で調整し、理由を付けて返す。

採寸値は2.0版（[measurement.md §12](measurement.md#12-出力するjsonmeasurement20)）。手のモデル（カプセルとすき間）は、生成APIの `handmodel` が `measurement` から計算する。

| 部品の引数 | 計算式 | 使う採寸値・聞き取りの値 | 理由 |
|---|---|---|---|
| `grip_body.variant` | 警告が少なければ `fitted`、多ければ `round`／`oval`（AIが選び、理由を書く） | `quality.warnings`、`capture.mode` | 手のモデルが怪しいまま指に沿わせると、かえって合わない |
| `grip_body.press_depth_mm`（`fitted`） | `min(1.5, 上限)`（§4.1の式。握りに当たるカプセルだけで r_min を出す） | `fingers.*.radii_mm` | 細い指でも、くり抜きの上限を守る |
| `grip_body.d_top_mm`（`fitted`） | `clamp(D_index + 2 × press_depth_mm, 18, 55)` | 人差し指のすき間 `D_index` | すき間より少し太くして、指を握りに沿わせる |
| `grip_body.d_bottom_mm`（`fitted`） | `clamp(D_pinky + 2 × press_depth_mm, 18, 55)` | 小指のすき間 `D_pinky` | 指ごとの曲がり方の違いを、先細りで表す |
| `grip_body.capsules`（`fitted`） | 手のモデルのカプセル（基節・中節・末節）を握りの座標系に直したもの。半径はそのまま渡し、`CAPSULE_CLEARANCE_MM` はOpenSCADの中で足す | `fingers.*` | — |
| 以下は `round`／`oval` のとき | | | |
| `grip_body.d_top_mm` | `clamp(D_index, 18, 55)` | `D_index` | — |
| `grip_body.d_bottom_mm` | `clamp(D_pinky, 18, 55)`（写真モードで小指が取れなければ `d_top_mm` と同じ） | `D_pinky` | — |
| `grip_body.finger_pos_mm[i]` | `first + offset_f`。`offset_f` は、各指の付け根の位置（`palm.mcp_positions_mm`）のx座標の、人差し指からの差。`first = max(14, groove_width_mm/2 + 4)` | `palm.mcp_positions_mm` | 14＝上端の余白5mm＋人差し指の幅の半分（約9mm）。どちらも仮の値 |
| `grip_body.length_mm` | `max(offset_pinky + 28, finger_pos_mm[3] + groove_width_mm/2 + 6)` | 同上 | 両端に14mmずつ余白を取る |
| `grip_body.groove_depth_mm` | 2.0（既定） | （`flexion_deg` はAIの判断材料にする） | 深いくぼみは指の位置がずれると痛くなるため、浅めから始める |
| `collet.tool_d_max_mm` | `柄の太さ + 0.6` | 選択式Q3の区分の上限（7／10／13mm） | 一番太い所が入る径にし、細い分はナットで締めて吸収する |
| `collet_nut` の種類 | `self_weak` なら `wings`。`self`・`helper` は、AIが雰囲気のメモも見て選ぶ（既定は `wings`） | 選択式Q5の `nut_operator` | 指先でつまめなくても、羽根を手のひらで押して回せる |
| `hand` | そのまま | 選択式Q2の `hand_side` | — |
| `collet.slot_count` | 平たい柄なら4 | 選択式Q4の `tool_shaft_shape` | 平たい面を2組の割り片で押さえる |
| `grip_body.press_depth_mm` | `grip_strength=weak` なら、`fitted` のまま `press_depth_mm` を基準値＋0.5mm（ただし§4.1の上限まで。上限を超えるなら上限で止め、その旨を理由に書く）。`firm` なら既定のまま。`oval` は勧めない（`fitted` の指に沿った形のほうが、回りにくく抜けにくいため） | 選択式Q6の `grip_strength` | 力が弱いほど、指の形に深く沿わせる。値はAIが理由を付けて決める |

`palm.hand_width_mcp_mm` は `length_mm` の確認に使う。`length_mm < hand_width_mcp_mm + 10` なら警告を出す（握りの端が手からはみ出さず、指がつばに乗ってしまうおそれ）。

## 6. 試し刷り用の部品

プリンタは11/9・11/10だけ使える。この表の1〜3は、11/9の朝いちばんに1つの台にまとめて刷る（約2時間）。続けてアプリで作った握りの1回目を刷り、11/10の朝はデモ用の最終版を刷る（[tasks.md §3](tasks.md#3-日程)）。直せる回数が1回しかないので、11/7・11/8にスライサーのプレビューで、張り出し・ブリッジ・薄い壁を確かめておく。

| ファイル | 目的 | 内容 | 刷る順 |
|---|---|---|---|
| `test_pieces/thread_test.scad` | ねじのすき間と、コレットがどれだけ締まるかを確かめる | 本番と同じ寸法のコレット（ねじ15mm＋割り片16mm、穴10.6mm）1本と、`$slop` が0.05／0.10／0.15のナット3個。数字を刻む。筆・ペン・スプーンの柄と、太さの分かる棒（7.6・9・10.6mm）を挟んで引き、実際に締まる幅を測る | 1（一番の不安要素なので最初に刷る） |
| `test_pieces/carve_test.scad` | カプセルのくり抜きが刷れるか、すき間がどのくらいがよいかを確かめる | 長さ40mmの短い握りを3本。それぞれ、Bさんの人差し指と中指を定規・分度器で測った値でカプセルを作り、`CAPSULE_CLEARANCE_MM` を0.3／0.5／1.0にしてくり抜く。数字を刻む | 2 |
| `test_pieces/size_gauge.scad` | すき間の直径の検証（[measurement.md §10](measurement.md#10-精度の確かめ方)） | 直径45／40／35／30／25／20mmの円柱を、下から順に12mmずつ積んだ段付き円柱。各段に数字を刻む | 3 |
| `main.scad`（アプリで作った値） | 握り全体の1回目（`fitted`） | 11/8の通しのテストで、アプリが作ったSTL。試し刷りで決めた固定値を入れてから描き直す | 4（試し刷りのあと） |

## 7. 推奨の印刷設定（PLA）

| 項目 | 値 | 理由 |
|---|---|---|
| 積層の厚さ | 0.2 mm | 速さと、ねじの精度の釣り合い |
| 外壁の数 | 4（1.6 mm） | 握ったときの割れを防ぐ |
| 充填 | 25%、ジャイロイド | 軽さと強さの釣り合い |
| サポート | なし | 張り出しを45度以内にしている |
| ブリム | 5 mm（握り本体） | 背が高い部品が倒れないようにする |
| 材料 | PLA | TPUは使えるか要確認。使えるなら、手に当たる部分の覆い（拡張機能）に回す。コレットとナットは硬くないと締まらないのでPLAにする |

## 8. 安全のための作り込み

- 指が当たる外側の角は、すべて `edge_radius_mm`（1.5mm以上）で丸める。コレットの割りの端も0.5mm面取りする
- 口に入れる部品は作らない。スプーンを挟む場合でも、刷った部品が口に入らないよう、ナットの先から柄が60mm以上出るように画面で案内する（要検証）
- 手指の装具（関節を固定・矯正するもの）に当たる形（指に巻き付ける、指を伸ばすなど）は、部品として用意しない
- 刷ったあと、ナットを締めて道具を強く引き、抜けないことを確かめるよう印刷ガイドに書く
