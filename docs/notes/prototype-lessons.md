# プロトタイプで分かったこと（proto ブランチの PROTOTYPE.md の写し、2026-11-07）

設計仕様書（[docs/](../README.md)）をもとに、画像認識から3Dプリント用のデータまで、全部の部品を入れたプロトタイプ。

## 何が本物で、何がまだか

| 段階 | 中身 | 状態 |
|---|---|---|
| 選択式の質問（7問）・任意のチャット・まとめ | S2a〜S2c | 本物 |
| 同意 | APIに記録する。同意しないと撮影に進めない | 本物 |
| **カメラで撮る** | アプリの中でカメラを開いて、その場で撮る（`app/web_engine/src/camera.ts`、`lib/features/measure/live_capture_screen.dart`）。スマホは背面カメラ、PCはWebカメラ（内蔵カメラ）。映像に手の骨組みを重ね、「手が見えているか」と残り時間を出す。最大10秒（5秒以上）、1秒に6枚の候補をメモリに取る。カメラが2台以上あれば切り替えられる。動画ファイルを選ぶ方法も予備として残す | 本物（偽のカメラ映像で通した） |
| **画像認識（採寸エンジン）** | `app/web_engine/`（TypeScript）→ `app/web/js/measure_engine.js`。動画から1秒に6枚取り出し、ぼけの少ない3枚/秒を残す → MediaPipe Hand Landmarker で21点 → 1円玉は **OpenCV.js で自動検出**（`src/coin_cv.ts`。Canny の輪郭に楕円を当てる方法と、丸い斑点から色で領域を広げる方法の両方で候補を出し、手の上の丸を外し、手の大きさから1円玉の大きさの見当をつけて選ぶ）。ユーザーは「黄色い輪が1円玉か」を確かめるだけで、違うときだけタップする。楕円の長径から縮尺 → 長さ（上位20%の中央値）・角度・太さ・付け根の位置を集計。写真2枚のモードもある。動画・写真はブラウザの外に出さない | 本物（試験用の写真で通した。実際の手の動画での精度は未確認） |
| **手のメッシュ復元（角度）** | `hand_mesh/`（ポート8081）。切り抜いたフレーム最大8枚を受け取り、SAM 3D Body（手のデコーダ）で関節の角度を出す。画像は保存しない | コードは本物。重みが届くまではモック（下の「準備」） |
| 手のカプセルモデル・すき間・くり抜きの検査 | `api/app/handmodel.py` | 本物 |
| **Gemini**（部品選び・寸法決め・画像での確認・言葉での微調整・チャット） | `api/app/gemini_live.py`（Agent Platform、構造化出力、思考レベル、画像4枚）。確認と直しのループは最大3回 | コードは本物。`GEMINI_MODE=live` で切り替え（下の「準備」）。既定はモック |
| 形づくり | `scad/`（握り本体 fitted／round／oval、BOSL2の台形ねじのコレット、ナット）。STL・確認用画像4枚・印刷用STL | 本物 |
| プレビュー・微調整・ダウンロード | three.js。色の変更は版を作らない。デモ用のケースはOTの確認を省いてダウンロード | 本物 |
| Firebase（ログイン・Firestore・Storage・ルール） | 代わりに `X-User` ヘッダーと `api/.data/` | 未実装 |
| OTの確認の画面、回数とコストの上限、結果トークンの検証 | APIの一部だけ | 未実装 |

## 準備（あなたの手元でしかできないこと）

**本物のGemini**
```
gcloud auth application-default login
gcloud auth application-default set-quota-project <プロジェクトID>
gcloud services enable aiplatform.googleapis.com --project <プロジェクトID>
```

**本物のSAM 3D Body**
1. https://huggingface.co/facebook/sam-3d-body-vith で利用を申請し、承認を待つ
2. `hand_mesh\.venv\Scripts\hf auth login`
3. `hand_mesh` を起動し直す（初回は約2.4GBを取得）。http://localhost:8081/healthz の `backend` が `sam3d` になれば本物

## 動かし方（Windows、ターミナル3つ）

前提：Python 3.12、Node.js、Flutter 3.47、OpenSCAD 開発版（`C:\Program Files\OpenSCAD (Nightly)`。別の場所なら `OPENSCAD_BIN`）、NVIDIA GPU（メッシュ復元を本物で動かす場合）。

```
# 0. 初回だけ：MediaPipe の本体と手のモデル、OpenCV.js を取得し、採寸エンジンをビルド
bash scripts/fetch_mediapipe.sh

# 1. 生成API（http://localhost:8080）
cd api
python -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt
.venv\Scripts\python -m uvicorn app.main:app --host 127.0.0.1 --port 8080
#   本物のGeminiを使うとき（PowerShell）：
#   $env:GEMINI_MODE="live"; $env:GOOGLE_CLOUD_PROJECT="<プロジェクトID>"; .venv\Scripts\python -m uvicorn app.main:app --port 8080

# 2. 手のメッシュ復元（http://localhost:8081）：セットアップは hand_mesh/README.md
cd hand_mesh
.venv\Scripts\python -m uvicorn app:app --host 127.0.0.1 --port 8081

# 3. 画面（http://localhost:5173）
cd app
flutter build web --release
cd build\web
python -m http.server 5173 --bind 127.0.0.1
```

スマホで試すときは、カメラ（getUserMedia）とMediaPipeにHTTPSが要るので、Firebase Hostingのプレビューチャンネルなどに出す（`localhost` 以外のHTTPでは動かない）。

テスト：`cd api && .venv\Scripts\python -m pytest -q`（9件）、`cd hand_mesh && .venv\Scripts\python -m pytest -q tests`（13件）。

## 作ってみて分かったこと（設計書に戻す候補）

1. **すき間の探し方**：「閉じる線を越えない最大の円」では、指先と手のひらの間が開いた手ですき間が小さく出すぎた。中心だけを指の内側に限り、円は閉じる線を越えてよいことにした（越えたら `CAVITY_PARTIAL`）。曲がりの合計が180度を超えると角度が一周する問題も直した。→ measurement.md §8.3
2. **握りの軸の傾き**：指が強く曲がった手では、くり抜きの検査に通らないことが多い。今は `oval` に切り替える。軸を手の x 軸に合わせ、断面の中心を指ごとにずらす形にすれば改善する見込み
3. **ユーザーの指示と自動の直し**：「もう少し太く」のあとに自動の直しをかけると、太さが元に戻ってしまう。ユーザーの指示のあとは自動で直さず、検査に通らなければ `needs_attention` で知らせる
4. **読み上げを有効にすると、写真のタップ位置が取れない**：Flutter Web で `ensureSemantics()` を呼ぶと、タップできる部品は読み上げ用の部品に置き換わり、タップした位置ではなく部品の中心が届く。1円玉をタップする写真は、読み上げ用の部品から外した（`excludeFromSemantics`）。→ screens.md S4
5. **写真2枚のモードでは1円玉を写真ごとに指定する**：別の向きから撮った写真では、1枚目の位置から追いかけられない
6. **ActionChip は読み上げで「チェックボックス」になる**：提案のボタンは普通のボタンにした
7. **カメラで撮る方式を、拡張機能からMVPに上げた**：OSのカメラで録るより、撮りながら手が見えているかを示せる方が、撮り直しが減る。PCのWebカメラでも同じ画面で撮れる。前面カメラ（PCのWebカメラを含む）は鏡のように見せ、取っておくフレームは反転しない。→ measurement.md §2.3、ADR-0007
8. **MediaPipe Interactive Segmenter の点は0〜1の座標**（型定義には書かれていない。試して確かめた）。1円玉を切り出すモデルは約30MBで、初回の読み込みが重い
9. **PCでは1円玉のタップが外れやすい**：Webカメラは画角が広く、1円玉が小さく写る（長径20〜30px）。マウスで少し外すと背景を切り出してしまい、「見つかりませんでした」になっていた。押した点のまわり（長い辺の±10%）で「上下左右のどの向きとも明るさが違う丸い斑点」を積分画像の箱フィルタで探し（縁や角は落ちる）、斑点の中心から色で領域を広げて（内側の色と外側の色のどちらに近いか）、穴を埋めて楕円を当てる。これで数十ミリ秒。押した所を赤い十字で示す。（今は12番の自動検出が先で、タップは予備）小さく写りすぎ（長径14px未満）のときは、近づくかズームして撮り直すよう伝える。撮影の案内に「1円玉を大きめに写す」を足した → measurement.md §3、screens.md S4
10. **Interactive Segmenter は遅く、画面が止まる**：CPU では切り出し1回に約4.5〜5秒かかる（RTX 4070 Ti SUPER のPCで測定）。画像を小さく切っても変わらない（モデルの入力の大きさが決まっているため）。GPU の設定では約0.55秒だが、空のマスク（全部0）が返り使えない（tasks-vision 1.2.2）。しかも呼んでいる間は画面が止まる。PCで「クリックできない」ように見えたのはこれが原因。→ Interactive Segmenter（モデル30MB）はやめ、12番の OpenCV.js に置き換えた。重い処理の前に画面を描かせる（「探しています」と回る印を出す）。→ measurement.md §4.3 の「MVP」の方法を書き換える候補
11. **1円玉の長径が4〜7%短く出ていた**：設計書（measurement.md §4.3）は「投影の幅（最大−最小）」だが、実装では外れ値に強くしようと両端を0.5%ずつ削っていた。円の端は細いので、削ると幅が大きく減る（半径23pxの円で−4.3%、15pxで−6.7%）。縮尺がその分大きく出て、**長さと太さがすべて4〜7%長く出ていた**。設計書どおり最大−最小に戻し、§4.3 の「共分散からの長径（4√λ1）と5%以上違うフレームは使わない」も入れた。陰・刻印・光の反射・ぼけ・JPEGを入れた試験画像（暗い机、白い机、木目、灰色）で、長径の誤差は±2.5%以内になった
12. **1円玉は自動検出にした（OpenCV.js）**：タップより自動の方が、PCでもスマホでも楽で、押し間違いがない。設計書（measurement.md §4.3）では OpenCV.js を「重い（約16MB）」として拡張機能に回していたが、実際は約11MB（圧縮して約3.5MB）で、やめた Interactive Segmenter のモデル（30MB）より軽い。カメラを開くのを待たせないよう、裏で読み込む。方法：①Canny（しきい値3段）の輪郭に楕円を当て、当てはめの誤差6%以下・ぐるりの75%以上を覆うものを候補にする ②丸い斑点から色で領域を広げる方法（9番）も候補にする（光の反射で輪郭が切れる1円玉のため） ③手の21点の凸包の上にある丸（爪・関節）は外す ④1円玉（20mm）は人差し指と小指の付け根の間（大人で約55〜65mm）の約1/3なので、その比が0.12〜0.8の外は外し、1/3に近いほど点数をよくする ⑤動画では前のフレームの1円玉に近く、大きさが25%以上変わらないもの。**試験**：本物の1円玉の写真（Wikimedia Commons、CC BY-SA 3.0）を、暗い机・白い机・木目・灰色の背景に、真上（長径44px・30px）と斜め（短径÷長径0.55）で貼った12枚で、全部1位で見つかり、長径の誤差は−0.7〜+3.7%（小さい30pxで大きめ）。1フレーム約0.1〜0.2秒。手が写っていない写真（はかりの上の1円玉）では、はかりのボタン（丸）を選んでしまった → 手の大きさの見当が効いている。実際のカメラで撮った手と1円玉では未確認
13. **OpenCV.js のモジュールを Promise の resolve に渡すとページが止まる**：OpenCV.js（Emscripten）のモジュールは `then` を持つので、`resolve(cv)` や `async` 関数の `return cv` をすると、`then` が呼ばれ続けて、ページが完全に止まる（試して確かめた）。必ず `{ cv }` のように包む。あわせて、検出（1フレーム約0.1〜0.2秒）の間も画面が止まらないよう、OpenCV は Web Worker で動かす（`src/coin_worker.ts` → `app/web/js/coin_worker.js`）。OpenCV が使えないときは、タップと色で探す方法だけで動く
