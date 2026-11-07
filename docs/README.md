# 自助具ジェネレーター（仮称）設計仕様書

> **このドキュメントで決めたこと**
> 1. 設計仕様書の目次と、各ドキュメントの役割を決める。迷ったら、まずこのページの「主な決定」を見る。
> 2. 仕様の正は、このdocsと、`scad/catalog.json`（部品の引数）と、`schemas/`（データの形）の3つ。食い違ったら、`catalog.json` と `schemas/` を正として、docsを直す。
> 3. 「要確認」は各ドキュメントの中に書き、まとめを下の「残っている論点」に置く。確かめたら、その場で書き換える。

- 大会：DevFest GDGoC Japan Hackathon 2026（カテゴリ：医療・福祉）
- 提出の締め切り：2026-11-10（火）17:00（コードフリーズ）
- 書いた日：2026-11-07

## プロダクトの一行説明

指が曲がったまま伸びない人のために、スマホで撮った手の動画と1円玉から**mmの数値で採寸**して（誤差は11/9の検証の値で示す）指をカプセルで表した手のモデルを作り、人が作った部品を**Geminiが選んで寸法を決め**、指の形をくり抜いて握りを指に沿わせ、範囲チェックと**作業療法士（OT）の確認**を通してから、3Dプリントできる握り（自助具）を作るWebアプリ。

## ドキュメントの一覧

| ドキュメント | 役割 | 主に読む人 |
|---|---|---|
| [architecture.md](architecture.md) | システム構成図、コンポーネントの責務、通信の流れ、デプロイ先、環境変数、権限 | 全員 |
| [screens.md](screens.md) | 画面ごとの役割・入力・表示・状態（読み込み中・エラー・空）・遷移 | D、A |
| [measurement.md](measurement.md) | 採寸の仕様（2.0）。動画の撮り方、フレームの選び方、1円玉からmmへの換算、集計、手のカプセルモデル、フォールバック、出力するJSON、精度の確かめ方、確認と修正 | A、B |
| [parts-library.md](parts-library.md) | OpenSCADの部品。引数・単位・既定値・範囲、固定値、採寸値との対応、試し刷り、印刷設定 | B、C |
| [generation-pipeline.md](generation-pipeline.md) | Geminiへの各リクエストの方針と出力のスキーマ、範囲チェック、確認と直しのループ、OpenSCADの実行 | C |
| [api.md](api.md) | 生成APIのエンドポイント、リクエストとレスポンスの例、エラーの形式 | C、D |
| [data-model.md](data-model.md) | Firestoreのコレクション、Cloud Storageのパス、セキュリティルールの方針 | C、D |
| [non-functional.md](non-functional.md) | 処理時間の目標、コストの見積もりと20ドルの配分、予算アラート、セキュリティ、プライバシー、対応ブラウザ | 全員 |
| [prior-art.md](prior-art.md) | 先行例と差別化、課題の根拠（確かめた範囲つき） | 全員、ピッチの準備 |
| [tasks.md](tasks.md) | ディレクトリ構成、4人の分担、11/10までの日程、MVPと拡張の線引き、完了条件 | 全員 |
| [adr/](adr/) | 設計判断の記録（1判断1ファイル） | 全員、ピッチの準備 |

### ADR（設計判断の記録）

| 番号 | 判断 |
|---|---|
| [0001](adr/0001-gemini-output-json-params.md) | Geminiには部品と寸法のJSONを出力させる（案A）。OpenSCADのコードは書かせない |
| [0002](adr/0002-frontend-flutter-web.md) | 画面はFlutter Web、採寸の処理はJSモジュール（`@mediapipe/tasks-vision` を直接呼ぶ）。11/7中に実機で確かめ、だめなら切り替える |
| [0003](adr/0003-why-google-technologies.md) | Googleの技術（Gemini、MediaPipe、Cloud Run、Firebase、Flutter）を選んだ理由。ピッチの材料 |
| [0004](adr/0004-card-scale-detection.md) | （置き換え済み）カードの4隅を手で合わせる。→ ADR-0006 |
| [0005](adr/0005-screw-collet-tool-holder.md) | 道具を挟む部分はねじ締め式（コレット＋ナット）。デモは筆の握り |
| [0006](adr/0006-coin-scale-reference.md) | 大きさの基準は1円玉。1回タップして追いかける |
| [0007](adr/0007-video-capture.md) | 撮影は動画（スマホを半周）。写真2枚はフォールバック |
| [0008](adr/0008-hand-model-capsules.md) | 手はカプセルのモデルで表し、握りからくり抜く。角度はメッシュ復元（SAM 3D Body）で出す。同意を得て全員の切り抜いたフレームを送り、MediaPipeでは代わりにしない |
| [0009](adr/0009-gpu-placement.md) | メッシュ復元は同じプロジェクトのCloud Run GPU（シンガポール、L4、最小0台）。クレジットは1つの請求先にまとめる |

## 主な決定

| 項目 | 決めたこと | 詳しくは |
|---|---|---|
| 映像 | 動画は保存しない。生成APIとGeminiには数値だけを送る。手を切り抜いたフレーム（最大8枚）は、全員から同意を得て角度の推定に送り、保存しない | [measurement.md](measurement.md)、[non-functional.md §4](non-functional.md#4-プライバシー) |
| 採寸 | 動画（5〜10秒、半周）と1円玉。長さは上位20%のフレームの中央値、角度・太さは中央値。指をカプセルで表した手のモデルを作る。写真2枚はフォールバック | [measurement.md](measurement.md)、[ADR-0006](adr/0006-coin-scale-reference.md)〜[0008](adr/0008-hand-model-capsules.md) |
| 聞き取り | 寸法に効く基本の情報（やりたいこと、持つ手、柄の太さと形、ナットを回す人、握る力、撮影する人）は選択式の7問で聞く。それ以外はGeminiとの任意のチャットで受ける | [screens.md S2](screens.md#s2-やりたいこと選択式の質問任意のチャット) |
| デザイン | 形ができてからS7で、3Dを見ながら選ぶ。模様はOTに頼む前まで、色は最後まで変えられる。色は大学にあるフィラメントから | [screens.md S7](screens.md#s7-プレビューと微調整) |
| AIの役割 | Gemini 4 Argon（`global`）が、任意のチャット・部品選び・寸法の調整と理由・画像での確認（最大3回）を行う。形は作らない | [generation-pipeline.md](generation-pipeline.md)、[ADR-0001](adr/0001-gemini-output-json-params.md) |
| 安全 | 範囲チェック、角の丸み1.5mm以上、装具と口に入れる部品は作らない、通常の手順ではOTの確認が済むまで印刷用STLを渡さない（デモのケースを除く） | [generation-pipeline.md §4](generation-pipeline.md#4-範囲チェック)、[data-model.md §4](data-model.md#4-セキュリティルールの方針) |
| 部品 | 握り本体（標準は指のカプセルでくり抜く `fitted`）＋ねじ締めコレット＋ナット。筆・ペン・スプーンを付け替えられる | [parts-library.md](parts-library.md)、[ADR-0005](adr/0005-screw-collet-tool-holder.md) |
| 画面 | Flutter Web＋採寸エンジン（JS。MediaPipe）＋three.js（埋め込み） | [ADR-0002](adr/0002-frontend-flutter-web.md) |
| 実行基盤 | Cloud Run（東京）にPython＋OpenSCAD（開発版）、Firebase（東京）。メッシュ復元はCloud Run GPU（シンガポール。[ADR-0009](adr/0009-gpu-placement.md)） | [architecture.md](architecture.md) |
| コスト | ハッカソンのクーポンを個人の請求先アカウントで引き換え、2つのクレジットをまとめる。開発はモックと安いモデル、Argonは調整とデモだけ。定価で見積もり、アプリでも1日の上限で止める | [non-functional.md §2](non-functional.md#2-コストの見積もり) |
| 日程 | プリンタは11/9・11/10だけ。11/8 20:00に通し、11/9の朝に試し刷り → アプリで作った握りの1回目、11/9 21:00に機能の追加を止め、11/10の朝にデモ用の最終版を刷る | [tasks.md §3](tasks.md#3-日程) |
| デモ | `settings/runtime.demo_mode` が `true` のあいだに作ったケースは、OTの確認なしで印刷用STLを作ってダウンロードできる（審査とデモ動画で最後まで見せるため）。画面に「デモ用：OTの確認を省略しています」と必ず出す | [api.md §3.11](api.md#311-post-v1casescase_iddesignsdesign_idprepare-printデモのケースだけ) |

## 書き方のルール

- 各ドキュメントの冒頭に、決めたことを3行以内で書く
- 決めたことには理由を添える。確かめていないことは「要確認」と書き、推測で埋めない
- 寸法はmm、角度は度。JSONのキーの末尾に `_mm`、`_deg` を付ける
- コードは書かない（スキーマとOpenSCADの引数の例は書いてよい）

## 調べた情報の出典（2026-11-07時点）

| 内容 | 出典 |
|---|---|
| Gemini 4 Argon（モデルID、GA、ロケーション、機能、思考レベル） | https://docs.cloud.google.com/vertex-ai/generative-ai/docs/models/gemini/4-argon 、https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/guides/gemini-4-argon 、https://docs.cloud.google.com/gemini-enterprise-agent-platform/release-notes |
| Geminiの料金 | https://cloud.google.com/vertex-ai/generative-ai/pricing |
| Gemini Enterprise Agent Platform（旧 Vertex AI）の名称変更 | https://docs.cloud.google.com/gemini-enterprise-agent-platform/vertex-ai-name-changes |
| ロケーション | https://docs.cloud.google.com/gemini-enterprise-agent-platform/resources/locations |
| 構造化出力 | https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/capabilities/control-generated-output 、https://github.com/googleapis/python-genai |
| 画像の入力とトークン数 | https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/capabilities/image-understanding |
| 429と再試行 | https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/deploy/error-code-429 |
| 予算とアラート | https://docs.cloud.google.com/billing/docs/how-to/budgets 、https://docs.cloud.google.com/billing/docs/how-to/disable-billing-with-notifications |
| Cloud Runの料金・上限・認証 | https://cloud.google.com/run/pricing 、https://cloud.google.com/run/quotas 、https://cloud.google.com/run/docs/configuring/request-timeout 、https://cloud.google.com/run/docs/authenticating/end-users |
| Firebase HostingからCloud Runへの転送（60秒の制限） | https://firebase.google.com/docs/hosting/cloud-run |
| Cloud Storage for FirebaseとBlazeプラン | https://firebase.google.com/docs/storage/faqs-storage-changes-announced-sept-2024 |
| StorageのルールからFirestoreを参照 | https://firebase.google.com/docs/storage/security/rules-conditions |
| Firestoreの無料枠 | https://firebase.google.com/docs/firestore/quotas |
| OpenSCAD（版、CLI、Docker、画面なしでの描画） | https://github.com/openscad/openscad/releases 、https://hub.docker.com/r/openscad/openscad 、https://github.com/openscad/openscad/pull/5833 |
| BOSL2（ねじ） | https://github.com/BelfrySCAD/BOSL2 |
| MediaPipe Hand Landmarker（Web、ランドマーク、モデル） | https://developers.google.com/edge/mediapipe/solutions/vision/hand_landmarker 、https://developers.google.com/edge/mediapipe/solutions/vision/hand_landmarker/web_js |
| MediaPipeのモデルカード（精度・公平性） | https://storage.googleapis.com/mediapipe-assets/Model%20Card%20Hand%20Tracking%20(Lite_Full)%20with%20Fairness%20Oct%202021.pdf |
| MediaPipeのFlutterパッケージ | https://pub.dev/packages/mediapipe_vision |
| Flutter Web（Wasm、レンダラー、HTML要素の埋め込み、アクセシビリティ） | https://docs.flutter.dev/platform-integration/web/wasm 、https://api.flutter.dev/flutter/widgets/HtmlElementView-class.html 、https://docs.flutter.dev/ui/accessibility/web-accessibility |
| iOS Safariの日本語入力の不具合 | https://github.com/flutter/flutter/issues/195443 |
| three.js（STLLoader） | https://threejs.org/docs/pages/STLLoader.html |
| 1円玉の直径（財務省「通常貨幣一覧」） | https://www.mof.go.jp/policy/currency/coin/general_coin/list.htm |
| Cloud Run GPU（種類・リージョン・最低構成・料金） | https://docs.cloud.google.com/run/docs/configuring/services/gpu 、https://cloud.google.com/run/pricing |
| 手のメッシュ復元のライセンス | https://mano.is.tue.mpg.de/license.html 、https://github.com/geopavlakos/hamer 、https://github.com/rolpotamias/WiLoR 、https://github.com/facebookresearch/sam-3d-body 、https://github.com/facebookresearch/MHR |
| MediaPipe Image Segmenter・Interactive Segmenter | https://developers.google.com/edge/mediapipe/solutions/vision/image_segmenter 、https://developers.google.com/edge/mediapipe/solutions/vision/interactive_segmenter/web_js |
| requestVideoFrameCallback | https://developer.mozilla.org/en-US/docs/Web/API/HTMLVideoElement/requestVideoFrameCallback |
| カードの寸法（ISO/IEC 7810 ID-1。1.0版で使用） | https://www.icao.int/sites/default/files/publications/DocSeries/9303_p5_cons_en.pdf |
| OTの3Dプリンタの全国調査（杏林大学ほか） | https://digitalpr.jp/r/118605 、https://doi.org/10.1080/17483107.2025.2538669 |
| 先行研究（ASSETS 2025） | https://doi.org/10.1145/3663547.3746343 |
| 太柄の径の研究 | https://knowledge.lancashire.ac.uk/id/eprint/58230/ 、https://stacks.cdc.gov/view/cdc/197408 |
| PLAと食品 | https://help.prusa3d.com/article/food-safe-prints_112313 |
| 大会の公式ページ | https://df-hack26.gdgs.jp/ |

## 残っている論点

2026-11-07に、論点（全23件。あとから増えた分を含む）をどう片付けるか決めた。担当と期限の一覧は [tasks.md §6](tasks.md#6-今日117確かめる要確認) にある。

### 決まったもの

| # | 論点 | 決めたこと |
|---|---|---|
| 1 | メッシュ復元を製品で使うか | 使う。全員から同意を得て、手を切り抜いたフレーム（最大8枚）を `hand-mesh` に送り、保存しない。失敗してもMediaPipeの角度で代わりにはしない（[ADR-0008](adr/0008-hand-model-capsules.md)） |
| 3 | ハッカソンのクレジットの扱い | クーポンコードなので、個人の請求先アカウントで引き換えてまとめる（[non-functional.md §2.5](non-functional.md#25-どのクレジットで何を動かすか)）。規約の確認だけ残る |
| 4 | Argonの導入価格 | 料金表の脚注は「使った額の50%をクレジットで戻す」。定価で請求されてあとで戻ると読めるので、見積もりは定価のまま。思考のトークンは出力として課金される |
| 13 | 送ったデータが学習に使われないか | 公式に「許可なく学習に使わない」と明記されている。既定の24時間のキャッシュは止める設定にする |
| 14 | ASSETS 2025の限界の書き方 | 本文で、寸法・印刷・信頼・画一的な出力をすべて確かめた（[prior-art.md §3](prior-art.md#3-assets-2025の課題への答えピッチ用)） |
| 15 | 協力してくれるOT・当事者がいない | ピッチで正直に伝える。メンバーの手での検証結果と、今後OTと評価する計画を示す |

### 片付け方が決まっているもの

| # | 論点 | どう片付けるか | 担当・期限 | だめだったとき |
|---|---|---|---|---|
| 2 | プリンタの機種、造形サイズ、ノズル径、TPU、各日の使える時間 | 大学の窓口かプリンタの貼り紙で確かめ、`BED_MM`・`NOZZLE_MM` に入れる | B・11/7 09:30 | 仮の値（180mm角、0.4mm）のまま進め、刷る前にスライサーで収まるか確かめる |
| 5 | iPhoneの動画（HEVC）からフレームを取り出せるか | 採寸エンジンの試作を実機で動かす | A・11/7 18:00 | 「互換性優先」で撮るよう案内する。それでもだめなら写真モードを主にする（[ADR-0007](adr/0007-video-capture.md)） |
| 6 | 1円玉を1回のタップで切り出せるか | 暗い布・白い机の2通りで試す | A・11/7 18:00 | 代表フレーム3枚で長径を手で合わせる（[ADR-0006](adr/0006-coin-scale-reference.md)） |
| 7 | 日本語入力、three.jsの埋め込み | iPhone Safariで試す | D・11/7 18:00 | [ADR-0002](adr/0002-frontend-flutter-web.md) の切り替え先 |
| 8 | Cloud Runで画面なしで画像を描けるか | 開発版のイメージをデプロイして試す | C・11/7 18:00 | xvfbを入れて動かす |
| 11 | コレットで挟める太さの幅、平たい柄 | `thread_test` で筆・ペン・スプーンを挟んで引く | B・11/9 午前 | 道具ごとに穴の径を変える（[ADR-0005](adr/0005-screw-collet-tool-holder.md)） |
| 9 | 仮に置いた値（補正係数、手のひらの厚さ、指の太さの比、くり抜きのすき間） | すき間は11/9の朝の `carve_test`、それ以外は11/9の検証で決め直す | B・A・11/9 | 仮の値のまま出し、OT画面で「仮の値」と示す |
| 10 | 1円玉と関節の距離の差による系統的なずれ | 11/9の検証で、ノギスの値との比から補正係数 `k_len` を求める | A・11/9 | 誤差を数字のままピッチで示す |
| 12 | 提出に必要なもの、著作物利用シート | 参加者向けの資料を確かめる。分かるまでは「リポジトリ＋デモ動画＋スライド、デプロイURLは任意」の前提で進める | D・11/7 | — |
| 16 | `hand-mesh` が締め切りまでに動くか（SAM 3D Bodyの重みの承認を含む） | 11/7の朝に重みの利用申請を出し、11/8 18:00までに作る。デモと審査の時間帯は最小台数1で温める | E1の担当・11/8 | 11/8 12:00に重みが承認されていなければ、全員で決め直す（MediaPipeの角度で代わりにすることを含む） |
| 17 | メッシュ復元が、曲がったまま固まった指で正しく角度を出すか | 11/9の検証で分度器と比べる。OT画面にMediaPipeの角度を並べて出す | E1の担当・11/9 | 差が大きい関節は、OTが差し戻しのコメントで伝え、持ち主が「詳しく見る」で直す。ピッチで誤差を正直に示す |
| 18 | 手の映像が要配慮個人情報に当たるか（新しく増えた論点） | 個人情報保護委員会のガイドラインを確かめ、同意の画面の書き方を決める | D・11/8 | 当たるものとして扱い、同意の文と、保存しない仕組みを示す |
| 19 | 刷って直せる回数が1回しかない（11/7に刷れなくなった。新しく増えた論点） | 11/7・11/8にスライサーで刷れるかを確かめ、11/9の朝いちばんの枠を予約する。ほかに使えるプリンタも当たる | B・11/7 | ねじがだめなら、11/9の昼に穴をぴったりにする形（ADR-0005の案A）に切り替える |
| 20 | `hand-mesh` に代わりの手段がない（MediaPipeで代わりにしないとチームで決めた。全体レビューで指摘） | 11/8 12:00の中間の通しで、重みの承認と動作を確かめる | E1の担当・11/8 | 止まったら撮影からやり直す。重みが承認されなければ全員で決め直す |
| 21 | 1回あたりのGPUの費用（$0.40の見積もり）と、止まるまでの待機の時間 | 11/8に、Cloud Runの請求の画面で実際のインスタンスの時間を見る | E1の担当・11/8 | `MESH_COST_PER_CALL_USD` と `DAILY_COST_LIMIT_USD` を直す |
| 22 | コレットが実際に締まる幅（式では上限約3.2mm）と、平たい柄 | 11/9の `thread_test` で、太さの分かる棒を挟んで測る | B・11/9 | Q3の区分を直す |
| 23 | SAM 3D Bodyの出力から、どの関節の位置を角度に使うか | 出力の形を見て決める | E1の担当・11/8 | — |
