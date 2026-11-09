// 確認用画像の描画専用（generation-pipeline.md §6.4）。作ったSTLを読み込み、手（半透明）と道具の目安の棒を添える。
cover_file = "";
clip_file = "";
sleeve_file = "";
hand_file = "";
cover_color = "#2A9D8F";
rod_a = [];           // 道具の棒の端（実際の手の座標）
rod_b = [];
rod_d = 8;

if (cover_file != "") color(cover_color) import(cover_file, convexity = 10);
if (clip_file != "") color("#9aa0a6") import(clip_file, convexity = 10);
if (sleeve_file != "") color("#e9c46a") import(sleeve_file, convexity = 10);
if (len(rod_a) == 3 && len(rod_b) == 3) {
  d = rod_b - rod_a;
  L = norm(d);
  color("#d62828") translate(rod_a)
    rotate([0, acos(d[2] / L), atan2(d[1], d[0])]) cylinder(d = rod_d, h = L, $fn = 24);
}
if (hand_file != "") %color("#e9b48f", 0.45) import(hand_file, convexity = 10);
