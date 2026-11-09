// アリ溝のレール（カバー側。parts-library.md §4.4）。寸法は固定。
// レールの座標：原点＝レールの上面（溝の口）の中心。X＝横、Y＝長さ（指先の向き。+Y の端が閉じていて止まり）、Z＝外向き。
// クリップは −Y の端（手首側）から差し込み、+Y の端まで滑らせると「カチッ」と止まる。
// common.scad は入口のファイル（main.scad など）が先に include する

RAIL_END_WALL_MM = 2.5;   // 閉じた端の壁

module rail_block(quality = "preview", foot = RAIL_FOOT_MM) {
  $fn = fn_for(quality) / 4;
  ow = rail_outer_w();
  h = rail_height() + foot;
  r = MIN_EDGE_RADIUS_MM;
  L = RAIL_LENGTH_MM;
  difference() {
    // 外形（角を丸めた箱）。下は殻の中へ foot（ふつうは RAIL_FOOT_MM）入り込む
    minkowski() {
      translate([-(ow / 2 - r), -(L / 2 - r), -h + r]) cube([ow - 2 * r, L - 2 * r, h - 2 * r]);
      sphere(r = r);
    }
    // 溝（−Y の端は開き、+Y の端は閉じる）
    // rotate([90,0,0]) で 2D の y が Z に、押し出しが −Y の向きになる
    glen = L + 1 - RAIL_END_WALL_MM;
    translate([0, -L / 2 - 1 + glen, 0]) rotate([90, 0, 0])
      linear_extrude(height = glen) dovetail_profile_xy();
    // 止めのくぼみ（溝の底。閉じた端から RAIL_DETENT_FROM_END_MM）
    translate([0, L / 2 - RAIL_END_WALL_MM - RAIL_DETENT_FROM_END_MM, -RAIL_DEPTH_MM])
      sphere(r = 1.4, $fn = 24);
    // 口の縁の面取り（差し込みやすく）
    translate([0, -L / 2, 0]) rotate([45, 0, 0]) cube([RAIL_WIDTH_MM + 2, 1.2, 1.2], center = true);
  }
}

// dovetail_profile を XY 平面（Y を元の Z に）へ置いたもの（linear_extrude 用）
module dovetail_profile_xy(clr = 0) {
  wt = RAIL_WIDTH_MM - 2 * clr;
  wb = rail_bottom_w(clr);
  zb = -RAIL_DEPTH_MM + clr;
  polygon([[-wb / 2, zb], [wb / 2, zb], [wt / 2, 0], [wt / 2, 2], [-wt / 2, 2], [-wt / 2, 0]]);
}

// カバーに付ける：origin（レールの上面の中心）と frame（行：X・Y・Z の向き）で置く。
// foot：土台の深さ。スリットを避けて台をずらしたときは、面から傾いて浮く側が殻に届くよう生成APIが深くする（2026-11-10）
module rail_on_cover(origin, frame, quality = "preview", foot = RAIL_FOOT_MM) {
  multmatrix(frame_matrix(origin, frame)) rail_block(quality, foot);
}
