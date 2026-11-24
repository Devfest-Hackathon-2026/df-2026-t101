// 試作：コレット式の取り付け具（2026-11-23、feat/attachment-variants）。C字クリップと比べる試し刷り用で、生成APIからはまだ呼ばない。
// proto ブランチの scad/parts/collet.scad（ADR-0005。握り本体の上に付けていた形）を、レールの舌に載せ替えたもの。
//   局所座標（holder_base.scad）で下から：ハブ（腕が付く）→ おねじ → 割り片（先が外へ広がる）。
//   ナットを上からかぶせて回すと、ナットの円すいが割り片の先を内へ押し、道具の柄を締める。
// ねじは BOSL2 の台形ねじ。すき間（COLLET_THREAD_SLOP_MM）と締まる幅は試し刷りで決める（要確認）。

COLLET_WALL_MM = 2.0;          // 割り片の厚さ
COLLET_THREAD_PITCH_MM = 3.0;
COLLET_THREAD_SLOP_MM = 0.10;  // 仮。BOSL2 の $slop（めねじ側を広げる量）
COLLET_THREAD_LEN_MM = 10;     // proto は 15。3回転あれば足りるとみて短くした（要確認）
COLLET_FINGER_LEN_MM = 14;     // proto は 16
COLLET_TAPER_DEG = 10;
COLLET_TAPER_LEN_MM = 8;       // proto は 9
COLLET_CLAMP_RANGE_MM = 3.0;   // 締めて吸収したい太さの幅（割りの幅を決める）
COLLET_HUB_H_MM = 8;           // 腕が付くハブの高さ
COLLET_NUT_LIP_MM = 2;
COLLET_LAT_MM = 26;            // ハブの中心を親指側へ出す量。C字は 20。ナットが太いので離した（こぶしに当たらないか要確認）
COLLET_DOWN_MM = 6;
COLLET_FWD_MM = 5;

function collet_bore_d(tool_d) = tool_d + 0.6;   // 道具の太さ＋0.6（ADR-0005）。細い分はナットで締める
function collet_slot_w(slots) = PI * COLLET_CLAMP_RANGE_MM / slots + 0.4;
function collet_flare() = COLLET_TAPER_LEN_MM * tan(COLLET_TAPER_DEG);
// ねじの外径：ナットは上から割り片の先を越えて下りるので、めねじの谷（外径 − ピッチくらい）が、広がった先より 1.5mm 太くなるようにする。
// proto の式（穴の径＋9）だと、めねじの谷が広がった先より細く、ナットが通らなかった
function collet_thread_d(tool_d) =
  max(16, 2 * ceil((collet_bore_d(tool_d) + 2 * (COLLET_WALL_MM + collet_flare()) + COLLET_THREAD_PITCH_MM + 1.5) / 2));
function collet_hub_d(tool_d) = collet_thread_d(tool_d) + 4;
function collet_center() = holder_center(COLLET_LAT_MM, COLLET_DOWN_MM, COLLET_FWD_MM);
function collet_hub_zmin() = -COLLET_HUB_H_MM / 2;

// ハブ＋おねじ＋割り片（局所座標）。穴と割りはここでは抜かない（腕と足してから抜く）
module collet_body_local(tool_d, quality) {
  r_in = collet_bore_d(tool_d) / 2;
  r_out = r_in + COLLET_WALL_MM;
  z_thr = COLLET_HUB_H_MM / 2;
  z_fin = z_thr + COLLET_THREAD_LEN_MM;
  translate([0, 0, -COLLET_HUB_H_MM / 2]) cylinder(d = collet_hub_d(tool_d), h = COLLET_HUB_H_MM + 0.01, $fn = fn_for(quality));
  translate([0, 0, z_thr])
    trapezoidal_threaded_rod(d = collet_thread_d(tool_d), l = COLLET_THREAD_LEN_MM + 0.01, pitch = COLLET_THREAD_PITCH_MM,
                             bevel1 = false, bevel2 = true, anchor = BOTTOM, $fa = 4, $fs = 0.5);
  // 割り片：根もとは r_out、先の COLLET_TAPER_LEN_MM で外へ広がる（ナットの円すいがここを押す）
  translate([0, 0, z_fin - 0.01]) rotate_extrude($fn = fn_for(quality))
    polygon([[r_in, 0], [r_out, 0],
             [r_out, COLLET_FINGER_LEN_MM - COLLET_TAPER_LEN_MM],
             [r_out + collet_flare(), COLLET_FINGER_LEN_MM - 0.5],
             [r_out + collet_flare() - 0.5, COLLET_FINGER_LEN_MM],
             [r_in, COLLET_FINGER_LEN_MM]]);
}

// 道具の穴と割り（局所座標）
module collet_cuts_local(tool_d, slots, quality) {
  r_in = collet_bore_d(tool_d) / 2;
  z_thr = COLLET_HUB_H_MM / 2;
  top = z_thr + COLLET_THREAD_LEN_MM + COLLET_FINGER_LEN_MM;
  sw = collet_slot_w(slots);
  translate([0, 0, -COLLET_HUB_H_MM / 2 - 1]) cylinder(r = r_in, h = top + COLLET_HUB_H_MM / 2 + 2, $fn = fn_for(quality));
  // 割り：ねじの上 1mm から先まで（ねじの部分は割らない）
  for (i = [0 : slots - 1]) rotate([0, 0, 45 + i * 360 / slots])   // 45度ずらし、割りが腕の付け根（−X）に来ないようにする
    translate([0, -sw / 2, z_thr + COLLET_THREAD_LEN_MM + 1]) cube([r_in + COLLET_WALL_MM + collet_flare() + 2, sw, COLLET_FINGER_LEN_MM + 1]);
}

// レールの座標に組んだ形
module collet_holder_rail(tool_d, tilt = 70, slots = 4, quality = "preview") {
  c = collet_center();
  M = holder_matrix(c, tilt);
  difference() {
    union() {
      holder_tongue_and_arm(c, tilt, -collet_hub_d(tool_d) / 2, -COLLET_HUB_H_MM / 2 + 0.5, COLLET_HUB_H_MM / 2 - 0.5, quality);
      multmatrix(M) collet_body_local(tool_d, quality);
    }
    multmatrix(M) collet_cuts_local(tool_d, slots, quality);
  }
}

// 刷る向き：道具の軸を立て、割り片を上にする（舌と板は斜めになるのでサポートが要る）
module collet_holder_print(tool_d, tilt = 70, slots = 4, quality = "print") {
  holder_print(collet_center(), tilt, collet_hub_zmin()) collet_holder_rail(tool_d, tilt, slots, quality);
}

// 締めナット（Z=0 が下端。そのまま刷る）。下から、めねじ → 割り片の逃げ → 円すい → 上の縁
// variant：wings（羽根。手のひらでも回せる）／knurl（ぎざぎざ。小さい）
module collet_nut(tool_d, variant = "wings", wing_span = 40, quality = "print") {
  r_in = collet_bore_d(tool_d) / 2;
  r_out = r_in + COLLET_WALL_MM;
  td = collet_thread_d(tool_d);
  od = td + 8;
  h = COLLET_THREAD_LEN_MM + COLLET_FINGER_LEN_MM + COLLET_NUT_LIP_MM;
  cone_z = h - COLLET_NUT_LIP_MM - COLLET_TAPER_LEN_MM;
  $fn = fn_for(quality);
  difference() {
    union() {
      cylinder(d = od, h = h);
      if (variant == "wings") {
        wt = 7;
        wh = h * 0.75;
        hull() for (s = [-1, 1]) translate([s * (wing_span / 2 - wt / 2), 0, h - wh]) cylinder(d = wt, h = wh, $fn = 32);
      }
    }
    // めねじ
    translate([0, 0, -0.01])
      trapezoidal_threaded_rod(d = td, l = COLLET_THREAD_LEN_MM + 0.02, pitch = COLLET_THREAD_PITCH_MM, internal = true,
                               $slop = COLLET_THREAD_SLOP_MM, bevel1 = true, bevel2 = false, anchor = BOTTOM, $fa = 4, $fs = 0.5);
    // 割り片の逃げ（広がった先が通る太さ）
    translate([0, 0, COLLET_THREAD_LEN_MM - 0.01]) cylinder(r = r_out + collet_flare() + 0.6, h = cone_z - COLLET_THREAD_LEN_MM + 0.02);
    // 円すい：下が広く、上が細い（割り片の先を内へ押す）
    translate([0, 0, cone_z]) cylinder(r1 = r_out + collet_flare() + 0.6, r2 = r_out + 0.2, h = COLLET_TAPER_LEN_MM);
    // 上の縁の穴（道具が通る）
    translate([0, 0, h - COLLET_NUT_LIP_MM - 0.5]) cylinder(r = r_out + 0.2, h = COLLET_NUT_LIP_MM + 1);
    if (variant == "knurl")
      for (i = [0 : 23]) rotate([0, 0, i * 15]) translate([od / 2, 0, -1]) cylinder(d = 2, h = h + 2, $fn = 12);
  }
}
