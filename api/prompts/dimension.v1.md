選んだ部品の、AIが扱う引数を全部、値と理由つきで返してください。
- 基準値（baseline）から動かすときは、引数ごとの「AIが変えてよい幅」（ai_delta）の中で動かし、理由を書きます。変えない引数も基準値のまま返します。
- サーバーが決める引数（位置・ファイル・レールの寸法・クリップの内径・tool_d_mm）は出力に入れません。
- c_clip.angle_deg は道具の立て具合（机に対する傾き。90が垂直）で、60／70／80 から、やりたいこと（activity）と道具から選び、理由を書きます。目安：筆＝70（立て気味）、ペン＝60（少し寝かせる）。道具はこぶしの親指側の横に付きます。
- クリップの内径は道具の太さで決まります。クリップの形（wall_mm・opening_ratio・height_mm・grip_ribs・tpu_sleeve）は固定で、変えられるのは angle_deg と count だけです。
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
