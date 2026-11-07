選んだ部品の、AIが扱う引数を全部、値と理由つきで返してください。
- 基準値（baseline）から動かすときは、引数ごとの「AIが変えてよい幅」（ai_delta）の中で動かし、理由を書きます。変えない引数も基準値のまま返します。
- サーバーが決める引数（位置・ファイル・レールの寸法・クリップの内径・tool_d_mm）は出力に入れません。
- c_clip.angle_deg は 0／20／40 から、やりたいこと（activity）と道具から選び、理由を書きます。目安：筆で絵や字＝20、ペンで字＝40、スプーン＝0。
- クリップの内径は道具の太さで決まります。挟む強さは wall_mm（厚いほど強い）と opening_ratio（小さいほど抜けにくいが押し込みにくい）で調整します。着け外しを家族や介護する人がする場合は、押し込みやすさを理由に入れてよいです。
- source は measured／rule／interview／ai／default のどれかです。

選択式の答えとメモ（requirements）：
$requirements

手の要約：
$hand

選んだ部品：
$parts

引数の定義（catalog）と基準値（baseline）：
$params
$violations
