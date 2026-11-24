// 試作：C字クリップ以外の取り付け具（コレット式・万力式）で共通に使う土台（2026-11-23、feat/attachment-variants）。
// レールに入る舌と板は c_clip.scad の clip_tongue() をそのまま使うので、レールのすき間・止めの出っ張りは C字クリップと同じ。
// 道具を持つ部分（ハブ）は「ハブの局所座標」で作り、holder_matrix() でレールの座標へ置く。
//   ハブの局所座標：原点＝道具の軸の上の点、+Z＝道具の軸の「上」向き（道具の先＝机の反対側）、
//                   +X＝こぶしの外向き（C字の開きと同じ lat）、−X＝レール（手）の側
//   道具の軸の向きは C字クリップと同じ（clip_axis(tilt)。tilt は 60／70／80度）
// 刷る向き：道具の軸を立てて刷る（ねじ山は立てないと崩れるため。ADR-0005）。そのぶん舌と板が斜めになり、サポートが要る。
// 入口のファイルが、BOSL2（std・threading）→ common.scad → rail.scad → c_clip.scad → このファイルの順に include する。

HOLDER_ARM_W_MM = 8.0;     // 腕の、ハブの側の幅（C字は 6.0。ハブが重いので太くする）

// ハブの中心（レールの座標）。lat：親指側へ、down：手のひら側へ、fwd：指先側へ
function holder_center(lat, down, fwd) = clip_lat() * lat - clip_up() * down + clip_fwd() * fwd;
function holder_z(tilt) = -clip_axis(tilt);                 // ハブの局所 +Z（道具の先と反対向き）
function holder_x() = clip_lat();                           // ハブの局所 +X（軸に垂直）

// ハブの局所座標 → レールの座標
function holder_matrix(c, tilt) =
  let(z = holder_z(tilt), x = holder_x(), y = cross(z, x))
  [[x[0], y[0], z[0], c[0]], [x[1], y[1], z[1], c[1]], [x[2], y[2], z[2], c[2]], [0, 0, 0, 1]];

// レールの座標 → ハブの局所座標（回転は直交なので転置でよい）
function holder_matrix_inv(c, tilt) =
  let(z = holder_z(tilt), x = holder_x(), y = cross(z, x))
  [[x[0], x[1], x[2], -(x * c)], [y[0], y[1], y[2], -(y * c)], [z[0], z[1], z[2], -(z * c)], [0, 0, 0, 1]];

// 舌・板・腕の根元の台の外形の点（レールの座標）。刷る向きでの、いちばん低い所を求めるのに使う。
// 包む箱の角で見積もると、実際の形より低い所が出て、刷る向きで机から浮いた（コレットで 0.8mm）ので、外形の点をそのまま並べる
function holder_tongue_corners() =
  let(clr = DOVETAIL_CLEARANCE_MM, ow = rail_outer_w() - 1, len = clip_tongue_len(),
      y0 = clip_tongue_y0(), y1 = y0 + len, yc = y0 + len / 2,
      wt = RAIL_WIDTH_MM - 2 * clr, wb = rail_bottom_w(clr), zb = -RAIL_DEPTH_MM + clr,
      plate_top = clr + CLIP_PLATE_MM, r = 1.2,
      rx = -clip_side() * (ow / 2 - CLIP_ROOT_X / 2), ry = yc + 2.5)
  concat(
    // 舌（台形の 4 つの頂点 × 両端）
    [for (y = [y0, y1]) for (p = [[-wb / 2, zb], [wb / 2, zb], [-wt / 2, 0], [wt / 2, 0]]) [p[0], y, p[1]]],
    // 止めの出っ張りの先
    [[0, y1 + 0.5 - RAIL_DETENT_FROM_END_MM, zb - RAIL_DETENT_MM]],
    // 板（角の丸みを 8 点ずつ）
    [for (sx = [-1, 1]) for (sy = [-1, 1]) for (k = [0 : 8]) for (z = [clr, plate_top])
      let(a = atan2(sy, sx) - 45 + k * 90 / 8)
      [sx * (ow / 2 - r) + r * cos(a), yc + sy * (len / 2 - r) + r * sin(a), z]],
    // 腕の根元の台
    [for (dx = [-1, 1]) for (dy = [-1, 1]) for (z = [plate_top, plate_top + CLIP_ROOT_H])
      [rx + dx * CLIP_ROOT_X / 2, ry + dy * CLIP_ROOT_Y / 2, z]]);

// 刷る向き（ハブの局所座標）で、全体を机まで持ち上げる量。hub_zmin はハブのいちばん低い所（局所 z）
function holder_print_lift(c, tilt, hub_zmin) =
  let(z = holder_z(tilt), zs = [for (p = holder_tongue_corners()) (p - c) * z])
  -min(min(zs), hub_zmin);

// 舌（clip_tongue）と、腕（板の上の根元の台 → ハブの −X の側面を hull でつなぐ）。レールの座標で描く。
// attach_x：腕を付けるハブの側面の局所 x（負）。z_lo／z_hi：腕を付ける高さの範囲（局所 z）
module holder_tongue_and_arm(c, tilt, attach_x, z_lo, z_hi, quality = "preview") {
  M = holder_matrix(c, tilt);
  ow = rail_outer_w() - 1;
  plate_top = DOVETAIL_CLEARANCE_MM + CLIP_PLATE_MM;
  clip_tongue(quality);
  hull() {
    translate([-clip_side() * (ow / 2 - CLIP_ROOT_X / 2), clip_tongue_y0() + clip_tongue_len() / 2 + 2.5,
               plate_top + CLIP_ROOT_H / 2 - 0.01])
      cube([CLIP_ROOT_X, CLIP_ROOT_Y, CLIP_ROOT_H], center = true);
    // 側面をわずかに傾ける（c_clip.scad と同じ理由：ハブの多角形の辺と重なって閉じない立体になるのを避ける）
    multmatrix(M) translate([attach_x + 0.6, 0, 0]) hull() {
      translate([0, 0, z_lo]) cube([1.2, HOLDER_ARM_W_MM - 0.4, 0.01], center = true);
      translate([0, 0, z_hi]) cube([1.2, HOLDER_ARM_W_MM + 0.4, 0.01], center = true);
    }
  }
}

// 刷る向きへ：ハブの局所座標に戻し、机まで持ち上げ、z<0 を切る
module holder_print(c, tilt, hub_zmin) {
  intersection() {
    translate([0, 0, holder_print_lift(c, tilt, hub_zmin)]) multmatrix(holder_matrix_inv(c, tilt)) children();
    translate([-200, -200, 0]) cube([400, 400, 400]);
  }
}
