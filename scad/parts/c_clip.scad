// C字クリップ（parts-library.md §4.5、ADR-0012・0013）。2026-11-08 に「横張り出し」の形に変えた。
// レールの座標（rail.scad と同じ：X＝横、Y＝レールの長さ＝手首→指先、Z＝外向き、原点＝レールの上面の中心）で作る。
//   レールの外向き Z は、手の甲の法線と親指側の横向きのちょうど間（45度）にあるので、レールの座標では
//     手の甲向き up ＝ [ s·side, 0, s ]、親指側 lat ＝ [ −s·side, 0, s ]、指先向き fwd ＝ [0, 1, 0]
//     （s ＝ 1/√2。side：右手 +1、左手 −1。左右で X の符号だけが入れ替わる＝鏡像）
//   輪の中心 ＝ 原点 + lat·CLIP_LAT_MM − up·CLIP_DOWN_MM + fwd·CLIP_FWD_MM（こぶしの親指側の横）
//   道具の軸 ＝ fwd·cos(tilt) − up·sin(tilt)。tilt は机（手の甲を上にして置いた姿勢）に対する傾き（60／70／80度）。
//     手の甲の上から下へ向けるとこぶしの指の背に当たり、机にも届かないので、輪をこぶしの横へ出して立てる（11/8 の計算）
//   開きは lat の向き（外側から押し込む）。板と輪は腕（hull）でつなぐ。
// 刷るときは、舌（アリ溝の凸）の底を机に置く向き（アリ溝の面がきれいに出る）。
// common.scad と rail.scad は入口のファイルが先に include する。hand（"right"／"left"）も入口のファイルが決める。

CLIP_PLATE_MM = 2.5;       // 舌の上の板の厚み（レールの上面に乗る）。2.0 から厚くした（腕の根元を受けるため。2026-11-08）
CLIP_ARM_W = 6.0;          // 輪と板をつなぐ腕の、輪の側の幅
CLIP_ROOT_X = 8.0;         // 腕の根元の台（板の上）：横（レールの X）
CLIP_ROOT_Y = 12.0;        // 同：長さ（レールの Y）
CLIP_ROOT_H = 5.0;         // 同：高さ。ペンを押す力は腕の根元に集まるので、根元を太く・先を細くする
CLIP_LAT_MM = 20.0;        // 輪の中心を、レールの上面の中心から親指側へ出す量
CLIP_DOWN_MM = 6.0;        // 同じく、手のひら側へ下げる量
CLIP_FWD_MM = 5.0;         // 同じく、指先側へ進める量
CLIP_S2 = 0.70710678;

function clip_side() = (hand == "left") ? -1 : 1;
function clip_up() = [CLIP_S2 * clip_side(), 0, CLIP_S2];
function clip_lat() = [-CLIP_S2 * clip_side(), 0, CLIP_S2];
function clip_fwd() = [0, 1, 0];
function clip_inner_d(tool_d, tpu) = tpu ? (tool_d - 0.2) + 2 * TPU_SLEEVE_WALL_MM : tool_d - CLIP_INTERFERENCE_MM;
function clip_tongue_len() = RAIL_LENGTH_MM - RAIL_END_WALL_MM - 1;
function clip_tongue_y0() = -RAIL_LENGTH_MM / 2 + 0.5;               // 手首側の端
function clip_axis(tilt) = clip_fwd() * cos(tilt) - clip_up() * sin(tilt);
function clip_open_dir(tilt) = clip_lat();                            // lat は fwd・up に垂直なので軸にも垂直
function clip_r_out(tool_d, wall, tpu) = clip_inner_d(tool_d, tpu) / 2 + wall;
// 輪の中心（レールの座標）。道具の太さによらず同じ所
function clip_center(tool_d, wall, height, tilt, tpu) =
  clip_lat() * CLIP_LAT_MM - clip_up() * CLIP_DOWN_MM + clip_fwd() * CLIP_FWD_MM;

// 輪の局所座標（Z＝軸、X＝開きの向き）からレールの座標へ
function clip_ring_matrix(c, tilt) =
  let(a = clip_axis(tilt), o = clip_open_dir(tilt), y = cross(a, o))
  [[o[0], y[0], a[0], c[0]], [o[1], y[1], a[1], c[1]], [o[2], y[2], a[2], c[2]], [0, 0, 0, 1]];

// 刷る向きで、いちばん低い所（舌の底か、輪の下端）の z。これを 0 に持ち上げる
function clip_print_zmin(tool_d, wall, height, tilt, tpu) =
  let(c = clip_center(tool_d, wall, height, tilt, tpu), a = clip_axis(tilt), ro = clip_r_out(tool_d, wall, tpu),
      ring_lo = c[2] - (ro * sqrt(max(0, 1 - a[2] * a[2])) + (height / 2) * abs(a[2])),
      tongue_lo = -RAIL_DEPTH_MM + DOVETAIL_CLEARANCE_MM - RAIL_DETENT_MM)
  min(ring_lo, tongue_lo);

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
    // 穴は 0.3 小さく描き、内径そのものは c_clip_rail の 3D の円柱（r = ri）で決める。同じ半径を2回描くと
    // 面がほぼ重なって、溝と口の近くで閉じない立体になる太さがあった（5.25・6.5・12mm。2026-11-08）
    circle(r = ri - 0.3);
    // 開き：内側で幅 w、外へ向かって面取りの角度で広がる
    polygon([[0, -w / 2], [ri + 0.2, -w / 2], [ro + 1, -w / 2 - (wall + 0.8) * ch],
             [ro + 1, w / 2 + (wall + 0.8) * ch], [ri + 0.2, w / 2], [0, w / 2]]);
    // 根元の切り欠き（CLIP_ROOT_NOTCH_MM）は 2026-11-08 にやめた：差し込むときの応力が切り欠きに集まり
    // （見積もりで 27→37MPa）、PLA の積層の境目から割れやすくなるため
  }
}

module c_clip_rail(tool_d, wall, opening_ratio, height, tilt, grip_ribs, tpu, quality = "preview") {
  $fn = fn_for(quality);
  ri = clip_inner_d(tool_d, tpu) / 2;
  ro = ri + wall;
  c = clip_center(tool_d, wall, height, tilt, tpu);
  M = clip_ring_matrix(c, tilt);
  plate_top = DOVETAIL_CLEARANCE_MM + CLIP_PLATE_MM;
  ow = rail_outer_w() - 1;
  difference() {
    union() {
      clip_tongue(quality);
      // 輪の外形（穴はあとで抜く）
      multmatrix(M) linear_extrude(height = height, center = true) clip_ring_2d(tool_d, wall, opening_ratio, tpu);
      // 腕：板の上の太い根元の台（親指側の縁から内側へ CLIP_ROOT_X、前寄り）と、輪の手の側（開きの反対側）を hull でつなぐ。
      // 根元が太く先が細い片持ち梁になる（厚みゼロの縁で板に付けていた最初の形は、根元で折れやすかった）
      // 輪の側の箱は側面をわずかに傾ける（下 W−0.4、上 W+0.4）。側面が輪の軸と平行だと、輪の多角形の縦の辺と
      // ぴったり重なる太さがあり（例：12mm で 7.85×sin22.5°＝3.00）、閉じない立体になった（2026-11-08）
      hull() {
        translate([-clip_side() * (ow / 2 - CLIP_ROOT_X / 2), clip_tongue_y0() + clip_tongue_len() / 2 + 2.5, plate_top + CLIP_ROOT_H / 2 - 0.01])
          cube([CLIP_ROOT_X, CLIP_ROOT_Y, CLIP_ROOT_H], center = true);
        multmatrix(M) translate([-ro + 0.6, 0, 0]) hull() {
          translate([0, 0, -height * 0.4]) cube([1.2, CLIP_ARM_W - 0.4, 0.01], center = true);
          translate([0, 0, height * 0.4]) cube([1.2, CLIP_ARM_W + 0.4, 0.01], center = true);
        }
      }
    }
    // 道具の通る穴（輪の高さの分だけ。腕を貫かない）
    multmatrix(M) cylinder(r = ri, h = height + 2, center = true);
    // 開きは clip_ring_2d で切ってある（内側は幅 w、ri+0.2 から外へ面取り）。ここで台形をもう一度引いてはいけない：
    // 中心から広がる台形だと内側の口が w より広くなり（8.5mm で 7.5mm、12mm で 11.1mm に実測）道具を保持できず、
    // 2D の切り口と面がほぼ重なって閉じない立体になる太さがあった（2026-11-08）
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

// 刷る向き：舌の底を机に置く（レールの座標のまま、いちばん低い所を z=0 へ）。z<0 は切る
module c_clip_print(tool_d, wall, opening_ratio, height, tilt, grip_ribs, tpu, quality = "print") {
  intersection() {
    translate([0, 0, -clip_print_zmin(tool_d, wall, height, tilt, tpu)])
      c_clip_rail(tool_d, wall, opening_ratio, height, tilt, grip_ribs, tpu, quality);
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

module tpu_sleeve_rail(tool_d, wall, height, tilt, quality = "preview") {
  c = clip_center(tool_d, wall, height, tilt, true);
  multmatrix(clip_ring_matrix(c, tilt)) tpu_sleeve_local(tool_d, height, quality);
}
