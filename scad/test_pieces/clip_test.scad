// 試し刷り1（parts-library.md §6）：クリップの壁の厚さ × しめしろ の9個。輪が机と平行の向き。
// デモで使う筆の柄の太さを tool_d_mm に入れる。1つの台にまとめ、番号を刻む。
include <../lib/common.scad>
include <../parts/rail.scad>
include <../parts/c_clip.scad>

tool_d_mm = 8.5;
walls = [1.6, 2.0, 2.4];
interferences = [0.2, 0.3, 0.4];
quality = "print";

for (i = [0 : 2]) for (j = [0 : 2]) {
  translate([i * 34, j * 34, 0]) {
    // しめしろだけを変えるため、tool_d を (道具の太さ − しめしろ + 既定のしめしろ) にして作る
    td = tool_d_mm - interferences[j] + CLIP_INTERFERENCE_MM;
    c_clip_print(td, walls[i], 0.75, 12, 0, true, false, quality);
    // 番号（壁の厚さ・しめしろ）を板の横に刻む
    translate([-14, -6, 0]) linear_extrude(0.6)
      text(str(walls[i], "/", interferences[j]), size = 3, halign = "left");
  }
}
