// 試し刷り1（parts-library.md §6）：クリップの壁の厚さ × しめしろ の9個。
// 形と刷る向きは本番のクリップと同じ（横張り出し・舌の底が下。2026-11-08 の形）。
// デモで使う筆の柄の太さを tool_d_mm に入れる。1つの台にまとめ、番号を刻む。
include <../lib/common.scad>
include <../parts/rail.scad>
include <../parts/c_clip.scad>

hand = "right";            // c_clip.scad の clip_side() が使う（左手なら鏡像）
tool_d_mm = 8.5;
height_mm = 20;            // catalog.json の c_clip.height_mm（固定）と同じ
angle_deg = 70;            // catalog.json の c_clip.angle_deg の既定（60／70／80）
walls = [1.6, 2.0, 2.4];
interferences = [0.2, 0.3, 0.4];
pitch = 42;                // 輪がレールの横へ約20mm張り出すので、前の34mmから広げた
quality = "print";

for (i = [0 : 2]) for (j = [0 : 2]) {
  translate([i * pitch, j * pitch, 0]) {
    // しめしろだけを変えるため、tool_d を (道具の太さ − しめしろ + 既定のしめしろ) にして作る
    td = tool_d_mm - interferences[j] + CLIP_INTERFERENCE_MM;
    c_clip_print(td, walls[i], 0.75, height_mm, angle_deg, true, false, quality);
    // 番号（壁の厚さ・しめしろ）を、舌の手首側の端より手前に刻む（輪とは重ならない）
    translate([-14, -18, 0]) linear_extrude(0.6)
      text(str(walls[i], "/", interferences[j]), size = 3, halign = "left");
  }
}
