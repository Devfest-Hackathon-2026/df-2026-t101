// 入口（道具の留め具＝万力式。2026-11-24 に C字クリップから置き換えた）。
// 生成APIは、留め具を描くときだけこのファイルを使う（カバーは main.scad）。ねじに使う BOSL2 を、カバーを描くときに
// 読み込まないよう分けた。-D の名前は main.scad と同じ（部品の ID は今まで通り c_clip）。
//   mode = "clip"（刷る並び：受け具と、その横にねじ。1つのSTL）／"assembled"（レールの座標に組んだ受け具とねじを、
//          rail_origin・rail_frame で手の座標へ置く。part は "c_clip" だけ）
// 左手は hand = "left" で描く（鏡に映すと、めねじが左ねじになりねじが入らない）。
include <vendor/BOSL2/std.scad>
include <vendor/BOSL2/threading.scad>
include <lib/common.scad>
include <parts/rail.scad>
include <parts/c_clip.scad>
include <parts/holder_base.scad>
include <parts/vise_holder.scad>

mode = "clip";
part = "c_clip";
quality = "preview";
hand = "right";

rail_origin = [];
rail_frame = [[1, 0, 0], [0, 1, 0], [0, 0, 1]];

c_clip_tool_d_mm = 8.5;    // 道具の柄の太さ。挟める太さはこの ±2.5mm（parts/vise_holder.scad）
c_clip_angle_deg = 70;     // 道具の立て具合（60／70／80）

VISE_PLATE_GAP_MM = 6;     // 刷る並びの、受け具とねじのつまみの間

module vise_plate() {
  td = c_clip_tool_d_mm;
  vise_holder_print(td, c_clip_angle_deg, quality);
  // ねじは受け具のねじの出っ張りの先（+X）に、つまみを下にして置く
  translate([vise_boss_end(vise_dmax(td)) + VISE_PLATE_GAP_MM + VISE_KNOB_SPAN_MM / 2, 0, 0]) vise_screw(td, quality);
}

module vise_assembled() {
  td = c_clip_tool_d_mm;
  vise_holder_rail(td, c_clip_angle_deg, quality);
  // ねじは、基準の太さの道具に当たるところまで入れた位置
  multmatrix(holder_matrix(vise_center(td), c_clip_angle_deg)) vise_screw_at(td, td, quality);
}

if (mode == "clip" || mode == "c_clip") {
  vise_plate();
} else if (mode == "assembled") {
  if (len(rail_origin) == 3) multmatrix(frame_matrix(rail_origin, rail_frame)) vise_assembled();
  else vise_assembled();
}
