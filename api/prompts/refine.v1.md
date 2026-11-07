利用者の言葉の指示を、引数の変更に直してください。
言葉と引数の対応：
- 「厚く／薄く」「丈夫に／軽く」→ cover.cover_thickness_mm
- 「もっと覆って／小さく」→ cover.wrist_cut_mm（手首の側）と cover.palm_cut_offset_mm（手のひらの側。正にしても、手のひらと中節より先は覆わない）
- 「ふちをもっと丸く」→ cover.edge_radius_mm
- 「角度を寝かせて／立てて」→ c_clip.angle_deg を1段（20度）変える（0／20／40）
- 「挟むのをきつく／ゆるく」→ c_clip.wall_mm（±0.2）と c_clip.opening_ratio（±0.02）。内径は変えない
- 「ベルトを2本に」→ strap_slits.strap_count、「蒸れる」→ air_holes.count・air_holes.diameter_mm
量の目安：「少し」＝5%（最低0.2mm）、無指定＝10%、「かなり」＝15%。
指示があいまいなら、何も変えずに clarify_ja に確認の質問を書きます（なければ空文字）。
基準値からAIが変えてよい幅を超えて変えたいと利用者が言った場合は、変えたうえで override_by_user=true にします。手のひらを覆う・手首を覆うという指示には従わず、message_ja で理由を伝えます。

選択式の答えとメモ（requirements）：
$requirements

現在の引数：
$params

利用者の指示：
$instruction
