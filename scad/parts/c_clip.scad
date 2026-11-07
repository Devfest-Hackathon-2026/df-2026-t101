// C字クリップ（parts-library.md §4.5、ADR-0012・0013）。
// まずレールの座標（rail.scad と同じ：X＝横、Y＝レールの長さ（指先の向き）、Z＝外向き、原点＝レールの上面の中心）で作る。
//   アリ溝の凸（舌）はレールの溝に入り、その上の板に輪が乗る。
//   輪の軸（＝道具の向き）は、Y を Z の負の側（手の側＝指先の側）へ angle 度傾けた向き。開きは軸に垂直で外向き。
// 刷るときは、輪の軸が縦（輪が机と平行）になるよう回して、机の面（z=0）より下は切る。
// common.scad と rail.scad は入口のファイルが先に include する

CLIP_PLATE_MM = 2.0;       // 舌の上の板の厚み（レールの上面に乗る）
CLIP_BRIDGE_W = 6.0;       // 輪と板をつなぐ壁の幅
CLIP_OVERLAP = 0.8;        // 輪と板の重なり

function clip_inner_d(tool_d, tpu) = tpu ? (tool_d - 0.2) + 2 * TPU_SLEEVE_WALL_MM : tool_d - CLIP_INTERFERENCE_MM;
function clip_tongue_len() = RAIL_LENGTH_MM - RAIL_END_WALL_MM - 1;
function clip_tongue_y0() = -RAIL_LENGTH_MM / 2 + 0.5;               // 手首側の端
function clip_axis(angle) = [0, cos(angle), -sin(angle)];
function clip_open_dir(angle) = [0, sin(angle), cos(angle)];
function clip_r_out(tool_d, wall, tpu) = clip_inner_d(tool_d, tpu) / 2 + wall;
// 輪の中心（いちばん低い所が板の上面に CLIP_OVERLAP だけ重なる高さ）
function clip_center(tool_d, wall, height, angle, tpu) =
  let(ro = clip_r_out(tool_d, wall, tpu),
      plate_top = DOVETAIL_CLEARANCE_MM + CLIP_PLATE_MM,
      yc = clip_tongue_y0() + height / 2)
  [0, yc, plate_top + ro * cos(angle) + (height / 2) * sin(angle) - CLIP_OVERLAP];

// 輪の局所座標（Z＝軸、X＝開きの向き）からレールの座標へ
function clip_ring_matrix(c, angle) =
  let(a = clip_axis(angle), o = clip_open_dir(angle), y = cross(a, o))
  [[o[0], y[0], a[0], c[0]], [o[1], y[1], a[1], c[1]], [o[2], y[2], a[2], c[2]], [0, 0, 0, 1]];

// 舌（アリ溝の凸）と板
module clip_tongue(quality) {
  clr = DOVETAIL_CLEARANCE_MM;
  len = clip_tongue_len();
  y0 = clip_tongue_y0();
  wt = RAIL_WIDTH_MM - 2 * clr;
  wb = rail_bottom_w(clr);
  zb = -RAIL_DEPTH_MM + clr;
  // 舌：底が広く口が狭い台形。口から上は板まで同じ幅
  translate([0, y0 + len, 0]) rotate([90, 0, 0]) linear_extrude(height = len)
    polygon([[-wb / 2, zb], [wb / 2, zb], [wt / 2, 0], [wt / 2, clr + 0.01], [-wt / 2, clr + 0.01], [-wt / 2, 0]]);
  // 板（レールの上面に乗る。角を丸める）
  ow = rail_outer_w() - 1;
  translate([0, y0 + len / 2, clr + CLIP_PLATE_MM / 2])
    linear_extrude(height = CLIP_PLATE_MM, center = true) rounded_rect([ow, len], 1.2, $fn = 16);
  // 止めの出っ張り（舌の底、差し込む先から RAIL_DETENT_FROM_END_MM）
  translate([0, y0 + len + 0.5 - RAIL_DETENT_FROM_END_MM, zb - RAIL_DETENT_MM + 1.2])
    intersection() {
      sphere(r = 1.2, $fn = 24);
      // 球の下の部分（舌の底から RAIL_DETENT_MM 出る所と、舌に埋まる所）だけ残す
      translate([-1.5, -1.5, -1.2]) cube([3, 3, 1.2 + 0.3], center = false);
    }
}

// 輪（C の形）。局所座標：Z＝軸、+X＝開き
module clip_ring_2d(tool_d, wall, opening_ratio, tpu) {
  ri = clip_inner_d(tool_d, tpu) / 2;
  ro = ri + wall;
  w = opening_ratio * tool_d;
  ch = tan(CLIP_ENTRY_CHAMFER_DEG);
  offset(r = 0.5) offset(delta = -0.5)   // 腕の先を丸める
  difference() {
    circle(r = ro);
    circle(r = ri);
    // 開き：内側で幅 w、外へ向かって面取りの角度で広がる
    polygon([[0, -w / 2], [ri + 0.2, -w / 2], [ro + 1, -w / 2 - (wall + 0.8) * ch],
             [ro + 1, w / 2 + (wall + 0.8) * ch], [ri + 0.2, w / 2], [0, w / 2]]);
    // 根元の切り欠き（腕の付け根の外側。開きの反対側から ±70度）
    for (s = [-1, 1]) rotate(180 + s * 70) translate([ro, 0])
      rotate(45) square(CLIP_ROOT_NOTCH_MM * 1.414, center = true);
  }
}

module c_clip_rail(tool_d, wall, opening_ratio, height, angle, grip_ribs, tpu, quality = "preview") {
  $fn = fn_for(quality);
  ri = clip_inner_d(tool_d, tpu) / 2;
  ro = ri + wall;
  c = clip_center(tool_d, wall, height, angle, tpu);
  M = clip_ring_matrix(c, angle);
  plate_top = DOVETAIL_CLEARANCE_MM + CLIP_PLATE_MM;
  difference() {
    union() {
      clip_tongue(quality);
      // 輪の外形（穴はあとで抜く）
      multmatrix(M) linear_extrude(height = height, center = true) clip_ring_2d(tool_d, wall, opening_ratio, tpu);
      // 輪と板をつなぐ壁（輪のいちばん低い所の近くと、板の上面を結ぶ）
      hull() {
        translate([0, c[1], plate_top - 0.01]) cube([CLIP_BRIDGE_W, max(4, height * cos(angle) * 0.8), 0.02], center = true);
        multmatrix(M) translate([-ro + 0.6, 0, 0]) cube([1.2, CLIP_BRIDGE_W, height * 0.8], center = true);
      }
    }
    // 道具の通る穴（輪の高さの分だけ。壁を貫かない）
    multmatrix(M) cylinder(r = ri, h = height + 2, center = true);
    // 開きの切り欠き（壁の分だけ）
    multmatrix(M) linear_extrude(height = height + 2, center = true)
      polygon([[0, -opening_ratio * tool_d / 2], [ro + 2, -opening_ratio * tool_d / 2 - (wall + 2) * tan(CLIP_ENTRY_CHAMFER_DEG)],
               [ro + 2, opening_ratio * tool_d / 2 + (wall + 2) * tan(CLIP_ENTRY_CHAMFER_DEG)], [0, opening_ratio * tool_d / 2]]);
    // 内側の細い溝（道具が軸の向きに滑らないよう、輪をぐるりと回る溝）
    if (grip_ribs && !tpu) {
      n = floor((height - 3) / CLIP_GROOVE_PITCH);
      for (i = [0 : max(0, n - 1)]) {
        z = -((n - 1) * CLIP_GROOVE_PITCH) / 2 + i * CLIP_GROOVE_PITCH;
        multmatrix(M) translate([0, 0, z])
          cylinder(r = ri + CLIP_GROOVE_D, h = CLIP_GROOVE_W, center = true);
      }
    }
  }
}

// 刷る向き：輪の軸を縦にし（rotate x を angle+90 度）、輪の底を z=0 に置き、z<0 を切る
module c_clip_print(tool_d, wall, opening_ratio, height, angle, grip_ribs, tpu, quality = "print") {
  c = clip_center(tool_d, wall, height, angle, tpu);
  b = angle + 90;
  cz = c[1] * sin(b) + c[2] * cos(b);
  intersection() {
    translate([0, 0, -(cz - height / 2)]) rotate([b, 0, 0])
      c_clip_rail(tool_d, wall, opening_ratio, height, angle, grip_ribs, tpu, quality);
    translate([-200, -200, 0]) cube([400, 400, 400]);
  }
}

// TPUの筒（局所：軸が Z）
module tpu_sleeve_local(tool_d, height, quality = "preview") {
  $fn = fn_for(quality);
  ri = (tool_d - 0.2) / 2;
  ro = ri + TPU_SLEEVE_WALL_MM;
  difference() {
    cylinder(r = ro, h = height, center = true);
    cylinder(r = ri, h = height + 2, center = true);
  }
}

module tpu_sleeve_rail(tool_d, wall, height, angle, quality = "preview") {
  c = clip_center(tool_d, wall, height, angle, true);
  multmatrix(clip_ring_matrix(c, angle)) tpu_sleeve_local(tool_d, height, quality);
}
