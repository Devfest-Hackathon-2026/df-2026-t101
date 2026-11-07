# 先行例と差別化

> **このドキュメントで決めたこと**
> 1. 調べた範囲では、「手の動画から寸法を測り、AIが人の作った部品を組み立てて寸法を決め、OTが確認してから刷る」という組み合わせは見つからなかった。新しさは「動画と1円玉からの採寸」と「AIによる組み立てと、その確認の仕組み」にあると説明する。
> 2. 「パラメトリックな握り」自体は新しくない（Georgia TechのAflatoony研究室が一番近い）。そこを本作の新しさとしては言わない。
> 3. ASSETS 2025の限界（寸法・印刷・信頼・画一的な出力）は、本文で確かめた（2026-11-07）。ピッチでは、下の原文の範囲で言う。

- 書いた日：2026-11-07（出典は2026-11-07に確認）
- 関連：[ADR-0003](adr/0003-why-google-technologies.md)

## 1. 採寸に使えるオープンソース

「スマホのカメラで指の寸法を測って数値で出す」もので、そのまま使えるものは見つからなかった（チャットでの検討メモより）。

| 名前 | 内容 | 使えない理由 |
|---|---|---|
| billhsu/ringsize | 指輪のサイズを測るWebツール。カードを枠に合わせ、指を線に合わせて測る | 指の幅を1か所、手作業で測るだけ。ライセンスの記載なし |
| mclear/html5-measurer | Webカメラとクレジットカードで指を測る（2013年） | 古い。ライセンス未定 |
| HandAnthro（Zhou ら、arXiv:2609.37855、2026-09-29） | US Letterの紙の上に置いた手のひらの写真1枚から、手の寸法44か所を推定する。平均の誤差は1寸法あたり3.80mm、親指以外の指は2.48mm | コードの公開は確認できなかった。手を平らに置く前提で、曲がった指は想定していない。https://arxiv.org/abs/2609.37855 |
| FlipByBlink/HandsWidth | 両手の人差し指の先の距離を測る | Apple Vision Pro専用 |

→ MediaPipe Hand Landmarkerと1円玉で作る。

## 2. 自助具の設計の先行例

| 先行例 | 内容 | 本作との違い | 確かめた範囲 |
|---|---|---|---|
| Aflatoony ら「Exploring AI-Fabrication in Shaping the Future of DIY-AT Design: Insights from Makers」ASSETS 2025（Georgia Tech）、DOI 10.1145/3663547.3746343 | 画像生成AIと画像→3D変換を組み合わせた画面を作り、臨床職・デザイナーを含むメイカー18人で評価した | 本作は形をゼロから作らせず、人が作った部品をAIが組み合わせ、寸法は採寸値から決める | 本文で確認（§5.4、§6、§7）。下の§3に原文 |
| Li M, Aflatoony L「Parametric design and three-dimensional printing: enabling Occupational therapists to develop custom hand grips」Disability and Rehabilitation: Assistive Technology 20(6):1829–1837、2025、DOI 10.1080/17483107.2025.2483953 | OTが食具の握りのモデルをパラメータで調整できるツール。OT 12人が試し、使いやすさ・カスタマイズ性・その場での設計・費用対効果を評価した。印刷の条件も検討 | AIなし。手の評価の結果をもとに、人がパラメータを調整する。本作は採寸とAIによる組み立てを足す | 要旨で確認 |
| Mixuan Li「A Parametric Design Tool to Support Customized Adaptations of Assistive Technologies for People with Hand Impairments」Georgia Tech 修士論文（工業デザイン、指導教員 Leila Aflatoony）、**2023年12月** | 上の論文誌版のもとになった研究。会議版はASSETS 2023（DOI 10.1145/3597638.3614492） | 同上 | 検討メモでは「2024年」としていたが、リポジトリの記載は2023年12月。本文は取得できなかった |
| FabCareJapan（林園子、慶應義塾大学大学院 政策・メディア研究科 修士論文、2020年度） | 作業療法士など14人と、3Dプリンタで作る自助具を214個作り、Thingiverseの「FabCareJapan」グループで公開した。7人の利用者へのインタビューで評価 | 公開されたデータから選ぶ形で、寸法を本人に合わせて自動で直す仕組みはない | 要旨で確認 https://fab.sfc.keio.ac.jp/paper/files/2020_SonokoHayashi.pdf |
| Resch S「Designing Customized Wearable Devices: A Novel AI-Based Framework for Product Development」ISMSIT 2025（IEEE）、DOI 10.1109/ISMSIT67332.2025.11268164 | ChatGPT・DALL-Eでデザイン画像を作り、Backflip.aiで3D化し、Blenderで手作業で直し、iPhoneの3Dスキャンで本人に合わせ、足の装具を刷った事例 | 足の装具。仕上げは手作業 | 本文のPDFで確認 |
| Faruqi ら「Style2Fab」UIST 2023（MIT）、DOI 10.1145/3586183.3606723 | 3Dモデルを機能の部分と飾りの部分に分け、飾りの部分だけを生成AIで変える | 見た目だけを変え、寸法は合わせない。本作の「色・模様を選べる」は近い考え方 | 確認 |

## 3. ASSETS 2025の課題への答え（ピッチ用）

本文（https://dl.acm.org/doi/full/10.1145/3663547.3746343 ）で確かめた原文と、本作の答え。

| 先行研究の課題（原文） | 本作の設計 | ピッチでの言い方 |
|---|---|---|
| 寸法：「A central limitation across both groups was the inability to specify exact measurements or manipulate structural components.」（§5.4）。§7でも「dimensional accuracy」を課題に挙げている | 動画と1円玉で採寸し、mm単位の値から寸法を決め、範囲チェックを通す | 「先行研究では正確な寸法を指定できないことが中心的な限界でした。本作は手を測ったmmの値から寸法を決めます。誤差は○mmでした（11/9の検証の値）」 |
| 印刷：「C2 discussed printability challenges, particularly related to orientation and strength」（§5.4） | 形は人が作って試し刷りした部品。立てて刷る向きを決め、張り出しの角度も機械的に確かめる | 「試し刷りで確かめた部品を組み合わせ、刷る向きの張り出しも自動で確かめます」（試し刷りしたのは一部の組み合わせなので、「どんな値でも刷れる」とは言わない） |
| 信頼：「Clinical makers were particularly cautious, expressing concerns about device safety, fit, and real-world performance.」（§6） | 決めた寸法と理由を一覧で見せ、OTが確認してから刷る | 「AIは決めた理由を説明し、最後はOTが確かめます」 |
| 画一的な出力：「these models often generate 'one-size-fits-all' designs that overlook the functional, anatomical, and aesthetic considerations critical to AT design.」（§6.1.1） | 指のカプセルを握りからくり抜いて、本人の指に沿わせる。色も選べる | 「一人ひとりの指の曲がり方に合わせて、くぼみを付けます」（曲がったまま固まった指での検証はまだなので、メンバーの手での検証結果と合わせて言う） |

注意：この論文は自らを「proof-of-concept」とし、「we do not claim that the tool is ready for market adoption」と書いている（§7）。批判ではなく「この課題に答える」という言い方にする。

## 4. 課題の根拠

| 内容 | 出典 | 言い方の注意 |
|---|---|---|
| 3Dプリンタを使った経験があるOTは、回答者3,469人のうち153人（4.4%） | Harada Y ら、Disabil Rehabil Assist Technol 2025;20(8):3162–3176、DOI 10.1080/17483107.2025.2538669。杏林大学のプレスリリース（2025-09-24）https://digitalpr.jp/r/118605 | 壁は、原文では「**職場に**設備がない」「使い方がわからない」 |
| リウマチの人35人では、38.1mmの太柄のスプーンを選んだ人が29人 | Jordon M ら、Front Rehabil Sci 2026、DOI 10.3389/fresc.2026.1770139 | 握りの太さの目安として使う |
| 健常者では、握りの直径30〜40mmが一番快適 | Kong & Lowe、Int J Ind Ergon 2005;35(6):495–507 | 同上 |
