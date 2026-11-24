// 試し刷り（2026-11-23、feat/attachment-variants）：C字クリップ・コレット式・万力式を、同じレールに差して比べる。
// part で刷る物を選ぶ。どれも刷る向きで出る。
//   "rail_stub"   … レールの短い台（底を平らにしたもの。dovetail_test.scad と同じ。カバーを刷らずに差して試す）
//   "c_clip"      … 比べる元の C字クリップ（本番と同じ形）
//   "collet"      … コレットの受け具（舌・腕と一体。道具の軸を立てて刷る。舌の下にサポートが要る）
//   "collet_nut"  … コレットのナット
//   "vise"        … 万力の受け具（同上。tool_d_mm と angle_deg で形が変わる。左手は hand="left"）
//   "vise_screw"  … 万力のねじ（つまみを下にして刷る）
//   "assembled"   … 刷らない。レールの台に差して道具（灰色の棒）を入れた姿を、3つ並べて見る
// 例：openscad -o collet.stl -D 'part="collet"' -D tool_d_mm=8.5 scad/test_pieces/holder_test.scad
include <../vendor/BOSL2/std.scad>
include <../vendor/BOSL2/threading.scad>
include <../lib/common.scad>
include <../parts/rail.scad>
include <../parts/c_clip.scad>
include <../parts/holder_base.scad>
include <../parts/collet_holder.scad>
include <../parts/vise_holder.scad>

part = "assembled";
hand = "right";
quality = "print";
tool_d_mm = 8.5;          // 道具（筆など）の太さ。C字とコレットはこの太さに合わせて作る
angle_deg = 70;           // 道具の立て具合（60／70／80。C字と同じ）
collet_slots = 4;
nut_variant = "wings";    // wings／knurl
// 万力は tool_d_mm ± 2.5mm を挟める形になる（8.5 のとき 6〜12mm。parts/vise_holder.scad）

module rail_stub(q) {
  translate([0, 0, rail_height()]) intersection() {
    rail_block(q);
    translate([-20, -20, -rail_height()]) cube([40, 40, rail_height() + 1]);
  }
}

module tool_rod(c, d, len = 90) {
  color("gray", 0.6) multmatrix(holder_matrix(c, angle_deg)) cylinder(d = d, h = len, center = true, $fn = 24);
}

if (part == "rail_stub") {
  rail_stub(quality);
} else if (part == "c_clip") {
  c_clip_print(tool_d_mm, 2.0, 0.75, 20, angle_deg, true, false, quality);
} else if (part == "collet") {
  collet_holder_print(tool_d_mm, angle_deg, collet_slots, quality);
} else if (part == "collet_nut") {
  collet_nut(tool_d_mm, nut_variant, 40, quality);
} else if (part == "vise") {
  vise_holder_print(tool_d_mm, angle_deg, quality);
} else if (part == "vise_screw") {
  vise_screw(tool_d_mm, quality);
} else if (part == "assembled") {
  q = "preview";
  // レールの台は rail_block の座標のまま（上面＝z0）
  // C字
  translate([0, 0, 0]) {
    color("tan") rail_block(q);
    color("steelblue") c_clip_rail(tool_d_mm, 2.0, 0.75, 20, angle_deg, true, false, q);
    tool_rod(clip_center(tool_d_mm, 2.0, 20, angle_deg, false), tool_d_mm);
  }
  // コレット：ナットは締めた位置（ねじの下端まで下ろした所）に置く
  translate([80, 0, 0]) {
    c = collet_center();
    color("tan") rail_block(q);
    color("seagreen") collet_holder_rail(tool_d_mm, angle_deg, collet_slots, q);
    color("orange") multmatrix(holder_matrix(c, angle_deg)) translate([0, 0, COLLET_HUB_H_MM / 2 + 0.2])
      collet_nut(tool_d_mm, nut_variant, 40, q);
    tool_rod(c, tool_d_mm);
  }
  // 万力：道具は V 字に収まった位置、ねじは道具に当たる位置
  translate([170, 0, 0]) {
    c = vise_center(tool_d_mm);
    M = holder_matrix(c, angle_deg);
    color("tan") rail_block(q);
    color("indianred") vise_holder_rail(tool_d_mm, angle_deg, q);
    color("orange") multmatrix(M) vise_screw_at(tool_d_mm, tool_d_mm, q);
    color("gray", 0.6) multmatrix(M) translate([vise_tool_x(tool_d_mm, vise_dmax(tool_d_mm)), 0, 0])
      cylinder(d = tool_d_mm, h = 90, center = true, $fn = 24);
  }
}
