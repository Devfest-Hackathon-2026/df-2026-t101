# Hand-Some-Fit（HSF）設計仕様書

> プロダクト名は **Hand-Some-Fit**（略称 HSF）。2026-11-08 に決定（それまでの仮称は「自助具ジェネレーター」）。

> **このドキュメントで決めたこと**
> 1. 設計仕様書の目次と、各ドキュメントの役割を決める。迷ったら、まずこのページの「主な決定」を見る。
> 2. 仕様の正は、このdocsと、`scad/catalog.json`（部品の引数）と、`schemas/`（データの形）の3つ。食い違ったら、`catalog.json` と `schemas/` を正として、docsを直す。
> 3. 「要確認」は各ドキュメントの中に書き、まとめを下の「残っている論点」に置く。確かめたら、その場で書き換える。

- 大会：DevFest GDGoC Japan Hackathon 2026（カテゴリ：医療・福祉）
- 提出の締め切り：2026-11-10（火）17:00（コードフリーズ）
- 書いた日：2026-11-07

## プロダクトの一行説明

指が握った形で固まっている人（少し曲がっている人も）のために、スマホ（またはPCのカメラ）で撮ったこぶしの動画と1円玉から、**手の3Dメッシュを1円玉で実寸（mm）にして**作り（誤差は11/9の検証の値で示す）、その手の面に沿って**こぶしの外側にかぶせるカバー**を作り、道具（筆など）は太さぴったりの**C字クリップ**で付ける。人が作った部品を**Geminiが選んで寸法と角度を決め**、範囲チェックと**作業療法士（OT）の確認**を通してから、3Dプリントできる自助具を作るWebアプリ。

## ドキュメントの一覧

| ドキュメント | 役割 | 主に読む人 |
|---|---|---|
| [architecture.md](architecture.md) | システム構成図、コンポーネントの責務、通信の流れ、デプロイ先、環境変数、権限 | 全員 |
| [screens.md](screens.md) | 画面ごとの役割・入力・表示・状態（読み込み中・エラー・空）・遷移 | D、A |
| [measurement.md](measurement.md) | 採寸の仕様（2.1）。動画の撮り方、フレームの選び方、1円玉の自動検出とmmへの換算、集計、手の3Dメッシュ（合成と実寸化）、フォールバック、出力するJSON、精度の確かめ方、確認と修正 | A、B |
| [parts-library.md](parts-library.md) | OpenSCADの部品。引数・単位・既定値・範囲、固定値、採寸値との対応、試し刷り、印刷設定 | B、C |
| [generation-pipeline.md](generation-pipeline.md) | Geminiへの各リクエストの方針と出力のスキーマ、範囲チェック、確認と直しのループ、OpenSCADの実行 | C |
| [api.md](api.md) | 生成APIのエンドポイント、リクエストとレスポンスの例、エラーの形式 | C、D |
| [data-model.md](data-model.md) | Firestoreのコレクション、Cloud Storageのパス、セキュリティルールの方針 | C、D |
| [non-functional.md](non-functional.md) | 処理時間の目標、コストの見積もりと20ドルの配分、予算アラート、セキュリティ、プライバシー、対応ブラウザ | 全員 |
| [prior-art.md](prior-art.md) | 先行例と差別化、課題の根拠（確かめた範囲つき） | 全員、ピッチの準備 |
| [tasks.md](tasks.md) | ディレクトリ構成、分担、11/10までの日程（`impl` ブランチでの作り直し）、MVPと拡張の線引き、完了条件 | 全員 |
| [adr/](adr/) | 設計判断の記録（1判断1ファイル） | 全員、ピッチの準備 |
| [notes/](notes/) | チームの検討メモの原文（[2026-11-07 形状のメモ](notes/2026-11-07-cover-shape.md)）。反映した結果は ADR と各章を正とする | 全員 |

### ADR（設計判断の記録）

| 番号 | 判断 |
|---|---|
| [0001](adr/0001-gemini-output-json-params.md) | Geminiには部品と寸法のJSONを出力させる（案A）。OpenSCADのコードは書かせない |
| [0002](adr/0002-frontend-flutter-web.md) | 画面はFlutter Web、採寸の処理はJSモジュール（`@mediapipe/tasks-vision` を直接呼ぶ）。11/7中に実機で確かめ、だめなら切り替える |
| [0003](adr/0003-why-google-technologies.md) | Googleの技術（Gemini、MediaPipe、Cloud Run、Firebase、Flutter）を選んだ理由。ピッチの材料 |
| [0004](adr/0004-card-scale-detection.md) | （置き換え済み）カードの4隅を手で合わせる。→ ADR-0006 |
| [0005](adr/0005-screw-collet-tool-holder.md) | （置き換え済み）道具を挟む部分はねじ締め式（コレット＋ナット）。→ ADR-0012 |
| [0006](adr/0006-coin-scale-reference.md) | 大きさの基準は1円玉。プロトタイプのあと、OpenCV.jsで自動で見つけてユーザーが確かめる形に変えた（違うときだけタップ）。動画では追いかける |
| [0007](adr/0007-video-capture.md) | 撮影は動画（スマホを半周）。プロトタイプのあと、アプリの中のカメラ（スマホは背面、PCはWebカメラ）で撮る形をMVPにした。動画ファイルの選択と写真2枚はフォールバック |
| [0008](adr/0008-hand-model-capsules.md) | 手はカプセルのモデルで表し、握りからくり抜く（**決めたこと1は ADR-0010 で置き換え**）。角度はメッシュ復元（SAM 3D Body）で出す。同意を得て全員の切り抜いたフレームを送り、MediaPipeでは代わりにしない（2・3は引き続き有効） |
| [0009](adr/0009-gpu-placement.md) | メッシュ復元は同じプロジェクトのCloud Run GPU（シンガポール、L4、最小0台）。クレジットは1つの請求先にまとめる |
| [0010](adr/0010-hand-mesh-fusion.md) | 手は3Dメッシュで表す（SAM 3D Bodyの復元を複数フレームで合成し、1円玉で実寸にする）。手の3Dメッシュは同意を得て保存する（**決めたこと2「握りからくり抜く」は ADR-0011 で置き換え**） |
| [0011](adr/0011-dorsal-cover.md) | 形は、こぶしの外側にかぶせるカバー（方式B）。殻は手の3Dメッシュの面から距離 c〜c＋t の層。手のひら側を開け、手首を覆わない（装具にしない） |
| [0012](adr/0012-c-clip-dovetail.md) | 道具は、太さぴったりのC字クリップで挟み、カバーのアリ溝のレールに差し込む。ねじは使わない（ADR-0005 を置き換え） |
| [0013](adr/0013-clip-angle-variants.md) | 角度は、角度違いのクリップ（0／20／40度）の差し替え。Geminiが選び、プレビューで選び直せる。回す仕組みは作らない |

## 主な決定

| 項目 | 決めたこと | 詳しくは |
|---|---|---|
| 映像 | 動画は保存しない。生成APIとGeminiには数値だけを送る。手を切り抜いたフレーム（最大8枚）は、全員から同意を得て手の3Dメッシュを作るために送り、保存しない。作った手の3Dメッシュ（写真ではない）は保存し、持ち主と担当のOTだけが読める | [measurement.md](measurement.md)、[non-functional.md §4](non-functional.md#4-プライバシー)、[ADR-0010](adr/0010-hand-mesh-fusion.md) |
| 採寸 | 握った形のこぶしを、アプリの中のカメラで撮る動画（15〜20秒、半周）と1円玉（OpenCV.jsで自動検出し、ユーザーが確かめる）。手の3Dメッシュは SAM 3D Body で複数フレームを合成し、手の甲で見える点（手首と指の付け根）の長さで実寸にする（握りこぶしでは指の点が隠れてずれやすいため）。確認の画面で、代表の2〜3枚の手首と指の付け根の点を直せる。写真2枚はフォールバック | [measurement.md](measurement.md)、[ADR-0006](adr/0006-coin-scale-reference.md)〜[0010](adr/0010-hand-mesh-fusion.md) |
| 聞き取り | 寸法に効く基本の情報（やりたいこと、手、道具の種類と太さ（mm）など）は選択式で聞く。道具の太さでC字クリップの内径が決まる。それ以外はGeminiとの任意のチャットで受ける | [screens.md S2](screens.md#s2-やりたいこと選択式の質問任意のチャット) |
| デザイン | 形ができてからS7で、3Dを見ながら選ぶ。模様はOTに頼む前まで、色は最後まで変えられる。色は大学にあるフィラメントから | [screens.md S7](screens.md#s7-プレビューと微調整) |
| AIの役割 | Gemini 4 Argon（`global`）が、任意のチャット・部品選び・寸法の調整と理由・画像での確認（最大3回）を行う。形は作らない | [generation-pipeline.md](generation-pipeline.md)、[ADR-0001](adr/0001-gemini-output-json-params.md) |
| 安全 | 範囲チェック、角の丸み1.5mm以上、装具と口に入れる部品は作らない。カバーは手のひら側を開け、手首を覆わず、握った指を無理に開かせない（描いたあとに自動で確かめる）。内側にフェルトを貼り、痛みや赤みが出たらやめるよう案内する。通常の手順ではOTの確認が済むまで印刷用STLを渡さない（デモのケースを除く） | [generation-pipeline.md §4](generation-pipeline.md#4-範囲チェック)、[data-model.md §4](data-model.md#4-セキュリティルールの方針) |
| 部品 | こぶしにかぶせるカバー（手の3Dメッシュから作る殻。空気穴、ベルトのスリット、アリ溝のレール）＋市販の面ファスナーのベルト＋道具ごとのC字クリップ（角度0／20／40度）＋任意でTPUの筒。今回は筆のクリップを作り、ペン・スプーンは時間があれば | [parts-library.md](parts-library.md)、[ADR-0011](adr/0011-dorsal-cover.md)〜[0013](adr/0013-clip-angle-variants.md) |
| 画面 | Flutter Web＋採寸エンジン（JS。MediaPipe、OpenCV.jsはWeb Worker）＋three.js（埋め込み。カバー・クリップ・道具と手の3Dメッシュ。S7でクリップの角度を選べる） | [ADR-0002](adr/0002-frontend-flutter-web.md) |
| 実行基盤 | Cloud Run（東京）にPython＋OpenSCAD（開発版）、Firebase（東京）。メッシュ復元はCloud Run GPU（シンガポール。[ADR-0009](adr/0009-gpu-placement.md)） | [architecture.md](architecture.md) |
| コスト | ハッカソンのクーポンを個人の請求先アカウントで引き換え、2つのクレジットをまとめる。開発はモックと安いモデル、Argonは調整とデモだけ。定価で見積もり、アプリでも1日の上限で止める | [non-functional.md §2](non-functional.md#2-コストの見積もり) |
| 日程 | プリンタは11/9・11/10だけ。11/8に dev から切った `impl` ブランチで中心の流れを作り直し、20:00に本番のURLで通す。11/9の朝いちばんにC字クリップとアリ溝の小さな試作を刷り（しめしろ・すき間・壁の厚さを決める）、続けてアプリで作ったカバーの1回目、11/9 21:00に機能の追加を止め、11/10の朝にデモ用の最終版を刷る | [tasks.md §3](tasks.md#3-日程) |
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
| MediaPipe Image Segmenter・Interactive Segmenter（プロトタイプで試し、使わないことにした） | https://developers.google.com/edge/mediapipe/solutions/vision/image_segmenter 、https://developers.google.com/edge/mediapipe/solutions/vision/interactive_segmenter/web_js |
| OpenCV.js（1円玉の自動検出。@techstark/opencv-js 4.12.0、Apache-2.0） | https://www.npmjs.com/package/@techstark/opencv-js 、https://github.com/TechStark/opencv-js |
| requestVideoFrameCallback | https://developer.mozilla.org/en-US/docs/Web/API/HTMLVideoElement/requestVideoFrameCallback |
| カードの寸法（ISO/IEC 7810 ID-1。1.0版で使用） | https://www.icao.int/sites/default/files/publications/DocSeries/9303_p5_cons_en.pdf |
| OTの3Dプリンタの全国調査（杏林大学ほか） | https://digitalpr.jp/r/118605 、https://doi.org/10.1080/17483107.2025.2538669 |
| 先行研究（ASSETS 2025） | https://doi.org/10.1145/3663547.3746343 |
| 太柄の径の研究 | https://knowledge.lancashire.ac.uk/id/eprint/58230/ 、https://stacks.cdc.gov/view/cdc/197408 |
| PLAと食品 | https://help.prusa3d.com/article/food-safe-prints_112313 |
| 大会の公式ページ | https://df-hack26.gdgs.jp/ |

## 残っている論点

2026-11-07に、論点（あとから増えた分を含む）をどう片付けるか決めた。11/7夜に、チームの形状のメモ（[notes/](notes/2026-11-07-cover-shape.md)）の未決事項を #28〜#32 に足した。担当と期限の一覧は [tasks.md §6](tasks.md#6-確かめること要確認) にある。11/7夜に、プロトタイプとSAM 3D Bodyのスパイクで確かめた分を書き換えた。

### 決まったもの

| # | 論点 | 決めたこと |
|---|---|---|
| 1 | メッシュ復元を製品で使うか | 使う。全員から同意を得て、手を切り抜いたフレーム（最大8枚）を `hand-mesh` に送り、保存しない。失敗してもMediaPipeの角度で代わりにはしない（[ADR-0008](adr/0008-hand-model-capsules.md)） |
| 3 | ハッカソンのクレジットの扱い | クーポンコードなので、個人の請求先アカウントで引き換えてまとめる（[non-functional.md §2.5](non-functional.md#25-どのクレジットで何を動かすか)）。規約の確認だけ残る |
| 4 | Argonの導入価格 | 料金表の脚注は「使った額の50%をクレジットで戻す」。定価で請求されてあとで戻ると読めるので、見積もりは定価のまま。思考のトークンは出力として課金される |
| 13 | 送ったデータが学習に使われないか | 公式に「許可なく学習に使わない」と明記されている。既定の24時間のキャッシュは止める設定にする |
| 14 | ASSETS 2025の限界の書き方 | 本文で、寸法・印刷・信頼・画一的な出力をすべて確かめた（[prior-art.md §3](prior-art.md#3-assets-2025の課題への答えピッチ用)） |
| 15 | 協力してくれるOT・当事者がいない | ピッチで正直に伝える。メンバーの手での検証結果と、今後OTと評価する計画を示す |
| 6 | 1円玉を切り出せるか | プロトタイプで確かめた。Interactive Segmenterは CPU で1回約5秒かかり画面が止まるので使わず、OpenCV.jsで自動検出し、ユーザーが確かめる形にした（違うときだけタップ）。本物の1円玉の写真を貼った試験画像12枚で全部見つかった。実際のカメラでの精度は11/9の検証で確かめる |
| 16 | `hand-mesh` が締め切りまでに動くか（SAM 3D Bodyの重みの承認を含む） | 重みは承認され、手元のGPUで動いた（11/7）。残りは Cloud Run GPU への配置（11/8 18:00） |
| 23 | SAM 3D Bodyの出力から、どの関節の位置を角度に使うか | キーポイント70点のうち右手の21〜41（手首は41）。角度は、合成した手のメッシュの関節から出す（[ADR-0010](adr/0010-hand-mesh-fusion.md)） |
| 27 | 道具の形（11/7夜、チームのメモで増えた論点） | こぶしの外側にかぶせるカバー（方式B）。道具はC字クリップ＋アリ溝、角度は差し替え（[ADR-0011](adr/0011-dorsal-cover.md)〜[0013](adr/0013-clip-angle-variants.md)）。トンネルに差し込む部品（方式A）とカムレバーは将来の話 |
| 24 | 手を3Dにする方法（11/7夜に増えた論点） | SAM 3D Body の復元を複数フレームで合成し、1円玉で実寸にした手の3Dメッシュで表し、握りはその面から作る（[ADR-0010](adr/0010-hand-mesh-fusion.md)）。表面の直接の再構成は使わない |

### 片付け方が決まっているもの

| # | 論点 | どう片付けるか | 担当・期限 | だめだったとき |
|---|---|---|---|---|
| 2 | プリンタの機種、造形サイズ、ノズル径、TPU、各日の使える時間 | 大学の窓口かプリンタの貼り紙で確かめ、`BED_MM`・`NOZZLE_MM` に入れる | B・11/7 09:30 | 仮の値（180mm角、0.4mm）のまま進め、刷る前にスライサーで収まるか確かめる |
| 5 | iPhoneの動画（HEVC）からフレームを取り出せるか | 採寸エンジンの試作を実機で動かす | A・11/7 18:00 | 「互換性優先」で撮るよう案内する。それでもだめなら写真モードを主にする（[ADR-0007](adr/0007-video-capture.md)） |
| 7 | 日本語入力、three.jsの埋め込み | iPhone Safariで試す | D・11/7 18:00 | [ADR-0002](adr/0002-frontend-flutter-web.md) の切り替え先 |
| 8 | Cloud Runで画面なしで画像を描けるか | 開発版のイメージをデプロイして試す | C・11/7 18:00 | xvfbを入れて動かす |
| 11 | （ADR-0012 で解消）コレットで挟める太さの幅 | ねじ締めをやめ、道具ごとに太さぴったりのC字クリップを刷る。平たい柄（スプーン）は時間があれば | — | — |
| 9 | 仮に置いた値（補正係数、手のひらの厚さ、手の面のすき間 `HAND_CLEARANCE_MM`） | すき間は11/9の朝の `carve_test`、それ以外は11/9の検証で決め直す | B・A・11/9 | 仮の値のまま出し、OT画面で「仮の値」と示す |
| 10 | 1円玉と関節の距離の差による系統的なずれ | 11/9の検証で、ノギスの値との比から補正係数 `k_len` を求める | A・11/9 | 誤差を数字のままピッチで示す |
| 12 | 提出に必要なもの、著作物利用シート | 参加者向けの資料を確かめる。分かるまでは「リポジトリ＋デモ動画＋スライド、デプロイURLは任意」の前提で進める | D・11/7 | — |
| 17 | メッシュ復元が、曲がったまま固まった指で正しく角度・太さを出すか（手の形の型に寄るおそれ） | 11/9の検証で分度器・ノギスと比べる。OT画面にMediaPipeの角度を並べて出す。S5で本人と家族が3Dの手を見て確かめる | E1の担当・11/9 | 差が大きい関節は、OTが差し戻しのコメントで伝え、持ち主が「詳しく見る」で直す。ピッチで誤差を正直に示す |
| 18 | 手の映像・手の3Dメッシュが要配慮個人情報に当たるか | 個人情報保護委員会のガイドラインを確かめ、同意の画面の書き方を決める | D・11/8 | 当たるものとして扱い、同意の文（`mesh-consent-2`）と、映像を保存しない仕組み、メッシュの読める人と消し方を示す |
| 19 | 刷って直せる回数が1回しかない（11/7に刷れなくなった。新しく増えた論点） | 11/7・11/8にスライサーで刷れるかを確かめ、11/9の朝いちばんの枠を予約する。ほかに使えるプリンタも当たる | B・11/7 | クリップがだめなら、TPUの筒の組み合わせに切り替える（[ADR-0012](adr/0012-c-clip-dovetail.md)） |
| 20 | `hand-mesh` に代わりの手段がない（MediaPipeで代わりにしないとチームで決めた。全体レビューで指摘） | 11/8 18:00までに Cloud Run GPU に出し、20:00の通しで確かめる | E1の担当・11/8 | 止まったら撮影からやり直す。Cloud Run GPU に出せなければ全員で決め直す |
| 21 | 1回あたりのGPUの費用（$0.40の見積もり）と、止まるまでの待機の時間 | 11/8に、Cloud Runの請求の画面で実際のインスタンスの時間を見る | E1の担当・11/8 | `MESH_COST_PER_CALL_USD` と `DAILY_COST_LIMIT_USD` を直す |
| 22 | （ADR-0012 で解消）コレットが実際に締まる幅 | ねじ締めをやめた | — | — |
| 28 | 大学の3DプリンタでPETG・TPUが使えるか（チームのメモの未決事項） | 大学の窓口で確かめる | B・11/8 | PLAで、形でしなりを作る対策だけにする（[ADR-0012](adr/0012-c-clip-dovetail.md)） |
| 29 | カバーとこぶしのすき間 c、フェルトの厚み | 11/9の朝に、指の背の一部だけの小さな殻を刷って決める | B・11/9 午前 | 仮の値（すき間1.5mm、フェルト1.0mm）のまま出し、OT画面で「仮の値」と示す |
| 30 | ベルトを1本にするか2本にするか | 11/9に刷ったカバーを着けて、手の上で回らないかを見る | B・11/9 | 2本にする（`strap_count`） |
| 31 | 角度違いのクリップを何種類用意するか | まず選んだ角度の1種類。時間があれば0／20／40度の3種類 | B・C・11/9 | 1種類のまま、ピッチで差し替えの考え方を話す |
| 32 | C字クリップのしめしろ・アリ溝のすき間・壁の厚さ | 11/9の朝いちばんに小さな試作を刷り、数十回の着け外しで比べる（介護する人が片手で扱えるかも見る） | B・11/9 午前 | TPUの筒を使う組み合わせに切り替える |
| 25 | 殻（カバー）の距離場の計算の時間（くり抜きのスパイクで手元約12秒）が Cloud Run で収まるか | 11/8にCloud Runで測る | C・B・11/8 | 格子を粗く（0.7mm）するか、計算の範囲を狭める |
| 26 | 倍率が手全体で1つなので、指ごとの長さの比が型と違う手でずれる | `MESH_SCALE_INCONSISTENT` で知らせる。11/9の検証で、どれだけずれるかを見る | B・11/9 | 指ごとの倍率（拡張機能） |
