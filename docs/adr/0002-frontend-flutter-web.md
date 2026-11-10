# ADR-0002：画面はFlutter Web、採寸の処理はJSモジュールにする（期限付きの確認と、切り替えの条件付き）

> **このドキュメントで決めたこと**
> 1. 画面はFlutter Webで作る。動画からのフレームの取り出し・MediaPipe・1円玉の追いかけは、Flutterの外のJSモジュール（採寸エンジン）にまとめ、`dart:js_interop` で呼ぶ。3D表示も、three.jsのJSモジュールを埋め込む。
> 2. 11/7 18:00までに、iPhoneのSafariとAndroidのChromeの実機で「動画の解析 → 3D表示 → 日本語入力」が動くかを確かめる。だめなら、決めておいた代わりの方法に切り替える。
> 3. 技術だけを見ればReact＋Viteの方が危険は小さい。それでもFlutter Webを選ぶのは、チームの希望に加え、将来のネイティブアプリ化と、Googleの技術でそろえた構成が説明しやすいため。採寸エンジンをJSにしておけば、Reactへの切り替えもすぐできる。

- 状態：採用（条件付き。2026-11-07、撮影を動画にしたこと（[ADR-0007](0007-video-capture.md)）を受けて更新）。2026-11-10 の時点では、切り替えずに Flutter Web のまま作り終えた（下の「2026-11-10 の補足」）
- 日付：2026-11-07
- 関連：[architecture.md](../architecture.md)、[screens.md](../screens.md)、[ADR-0003](0003-why-google-technologies.md)

## 背景

- スマホで撮影し、PCでプレビューして印刷する。カメラ、MediaPipe（手の検出）、three.js（3D表示）の3つとの相性が大事になる
- チームはAIを使って開発するので、言語の慣れは判断に入れなくてよい（チームの回答）。チームはGoogleの技術を使いたいと考えている
- 撮影を動画にしたので、フレームの取り出し（`<video>`、`requestVideoFrameCallback`、canvas）とMediaPipeの呼び出しを、何十枚ものフレームでくり返す。この部分はブラウザのJavaScriptの機能そのもので、Dartを通すと、フレームを受け渡すたびに手間と時間がかかる
- 期間は11/10 17:00まで。iPhoneのSafariで動くことが欠かせない

## 調べたこと（2026-11-07時点）

| 項目 | React＋Vite | Flutter Web |
|---|---|---|
| MediaPipe | `@mediapipe/tasks-vision` 1.2.2（11/3公開）をそのまま使える | Google公式の `mediapipe_vision` 0.1.2（11/5公開。Webに対応）があるが、公開されたばかりで、iPhoneのSafariでの動作は確認できなかった。動画のフレームはJSの側にあるので、JSから `@mediapipe/tasks-vision` を直接呼ぶ方が素直 |
| 動画 | `<video>` とcanvasをそのまま使える | 同じことをJSモジュールで行う。Flutterの `camera` のWeb版は、フレームを受け取る機能がない |
| three.js | そのまま使える（r187） | 公式のFlutterパッケージはない。`HtmlElementView` でHTML要素を埋め込み、JSモジュールを呼ぶ。公式ドキュメントには「処理が重くなりうる」「ポインターの操作をHTML側に取られることがある」と書かれている（対策は `pointer_interceptor`） |
| 初回の読み込み | MediaPipe（約3MB）＋モデル（約8MB） | 左に加えて、描画エンジンのCanvasKit（約2.3MB、圧縮後）。iPhoneのSafariは既定でCanvasKitを使う |
| 日本語入力 | ブラウザの標準の入力欄 | iPhoneのSafariで、変換中の文字が重複する不具合が未修正のまま報告されている（flutter/flutter#195443。`enableInteractiveSelection:false` の入力欄で起きる） |
| アクセシビリティ | 標準のHTMLなので、そのまま読み上げられる | Webでは既定で無効。`SemanticsBinding.instance.ensureSemantics()` で有効にする |
| Firebase | 公式のJS SDK | FlutterFire（firebase_auth 7.0.1、cloud_firestore 7.1.0、firebase_storage 14.0.1。いずれもWebに対応） |
| 将来 | Webだけ | 同じコードでAndroid・iOSのアプリにできる。アプリなら、`mediapipe_vision` のネイティブ版でカメラの映像をその場で処理し、撮り方を重ねて案内できる |

## 決定

画面はFlutter Web、採寸エンジンと3D表示はJSモジュールにする。

- 採寸エンジンは `app/web_engine/`（TypeScript）に書き、1つのESモジュール `app/web/js/measure_engine.js` にまとめる。入口は「動画（または写真2枚）と1円玉のタップ位置を受け取り、集計したJSONと代表フレームを返す」関数にする
- 危険の大きい3点は11/7中に実機で確かめ、だめなら次のように切り替える

| 確かめること（11/7 18:00まで） | 担当 | だめだったときの切り替え先 |
|---|---|---|
| 採寸エンジンが、iPhoneのSafariとAndroidのChromeで、10秒の動画から20枚以上のフレームの21点と1円玉の楕円を取れる | A | 動画が読めなければ、写真2枚のモードをMVPの主な方式にする（[ADR-0007](0007-video-capture.md)）。GPUで結果がおかしければCPUにする |
| three.jsで、STLを表示して回せる（PCのChrome、iPhoneのSafari） | D | 埋め込みをやめ、プレビューだけ別のHTMLページ（`/viewer.html?stl=...`）にして、iframeで開く |
| iPhoneのSafariで、聞き取りの入力欄に日本語を打てる | D | 入力欄の設定を見直す。それでもだめなら、選択肢のボタンを主にして、入力欄は補助にする |

2つ以上で切り替え先を使うことになった場合は、11/7 21:00の打ち合わせで、画面をReact＋Viteに切り替えるかを決める。採寸エンジンと3D表示はJSなので、そのまま使える。

## 理由

1. **将来の広がり**：同じ画面のコードのまま、撮影をネイティブアプリにできる。アプリなら、カメラの映像に「手をここに」「1円玉をここに」と重ねて案内でき、採寸の失敗が減る
2. **Googleの技術でそろえる**：Flutter、Firebase（FlutterFire）、MediaPipeがそろうので、「なぜその技術か」を一貫して説明しやすい
3. **役割の分け方**：重い処理はブラウザの機能を直接使うJSに、画面はFlutterに分けると、それぞれ一番素直な書き方ができる。採寸エンジンは画面の技術に依存しないので、単体で試せる
4. **チームの希望**：AIを使って開発するので、言語の慣れは問題にならない

## 引き受けること（トレードオフ）

- 初回の読み込みが、React版より約2MB重くなる
- DartとJSのつなぎ込み（`dart:js_interop`）が、採寸エンジンと3D表示の2か所で要る
- 日本語入力とアクセシビリティは、標準のHTMLより手間がかかる

## 見直す条件

- 上の3つの確認のうち、2つ以上で切り替え先を使うことになった場合（Flutterを選んだ利点が薄れるため）
- 審査のあと、本格的に開発を続ける場合は、Webとアプリのどちらを主にするかを改めて決める

## 2026-11-10 の補足（実装の結果）

- Flutter Web から React への切り替えはしなかった。採寸エンジン（`app/web_engine/` → `app/web/js/measure_engine.js`）と3D表示（`app/web/js/viewer.js`）は、決定のとおりJSにして `dart:js_interop` で呼んでいる
- 写真2枚のモードは 2026-11-09 にやめた。採寸エンジンの入口は動画だけ（アプリの中のカメラか、ライブラリから選んだ動画）で、上の「（または写真2枚）」と、1つめの確認の切り替え先「写真2枚のモードを主にする」は使わない
- 11/7 18:00 の3つの確認の結果は、この記録に書けていない。コミットの記録では、11/9〜11/10 に iPhone の Safari に合わせて撮影の画面を直している（引っぱって再読み込みを止める、映像の左右の黒い帯をなくす）。MediaPipe は GPU で作れなければ CPU で作る（`engine.ts`）
- アクセシビリティ：`ensureSemantics()` で読み上げ用の情報を常に作るのは、2026-11-09 にやめた（スマホが重かったため。[non-functional.md §6](../non-functional.md#6-アクセシビリティ)）。読み上げを使う人は、Flutter Web の「Enable accessibility」のボタンで有効にする
