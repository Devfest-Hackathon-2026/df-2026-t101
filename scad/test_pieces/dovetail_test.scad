// 試し刷り2（parts-library.md §6）：アリ溝のすき間 0.2／0.25／0.3。レールの短い台と、合うクリップの凸だけの部品。
include <../lib/common.scad>
include <../parts/rail.scad>
include <../parts/c_clip.scad>

clrs = [0.2, 0.25, 0.3];
quality = "print";

for (i = [0 : 2]) {
  // レールの台（底を平らにして刷る）
  translate([i * 30, 0, rail_height()]) intersection() {
    rail_block(quality);
    translate([-20, -20, -rail_height()]) cube([40, 40, rail_height() + 1]);
  }
  // 凸だけの部品（舌と板）。すき間 clrs[i] で作る
  translate([i * 30, 40, 0]) rotate([180, 0, 0]) translate([0, 0, -(clrs[i] + 2.0)])
    clip_tongue_clr(clrs[i], quality);
  translate([i * 30 - 6, -22, 0]) linear_extrude(0.6) text(str(clrs[i]), size = 4);
}

// すき間を引数で変えられる舌（c_clip.scad の clip_tongue と同じ形）
module clip_tongue_clr(clr, quality) {
  len = clip_tongue_len();
  wt = RAIL_WIDTH_MM - 2 * clr;
  wb = rail_bottom_w(clr);
  zb = -RAIL_DEPTH_MM + clr;
  translate([0, len / 2, 0]) rotate([90, 0, 0]) linear_extrude(height = len)
    polygon([[-wb / 2, zb], [wb / 2, zb], [wt / 2, 0], [wt / 2, clr + 0.01], [-wt / 2, clr + 0.01], [-wt / 2, 0]]);
  translate([0, 0, clr + 1]) linear_extrude(height = 2, center = true) rounded_rect([rail_outer_w() - 1, len], 1.2, $fn = 16);
}
