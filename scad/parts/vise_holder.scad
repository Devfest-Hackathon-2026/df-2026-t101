// 万力式の取り付け具（2026-11-23、feat/attachment-variants）。生成APIからはまだ呼ばない。
// しくみ：受け具の穴の手の側（−X）を 90度の V 字にし、外側（+X）から刷ったねじを回して、道具の柄を V 字へ押し付ける。
//   ねじのつまみは T 字で、こぶしの外側（+X）に出る（介護する人が回しやすい側）。
// 部品は 2 つ：受け具（舌・腕と一体）と、ねじ（つまみ付き）。ねじは BOSL2 の台形ねじ（M12、ピッチ 3mm）。
// 2026-11-24：右手・70°・太さ 6〜12mm 用を刷り、元の自助具に付けて具合がよかった（$slop 0.10 で回った）。
//
// 引数は C字クリップと同じ「道具の太さ tool_d」と「角度 tilt（60／70／80）」（2026-11-24）。
//   挟める太さ：tool_d ± VISE_RANGE_MM。ただし穴は、ねじ（直径 12mm）が通る大きさより小さくしない（VISE_DMAX_MIN_MM）。
//   tool_d = 8.5 のとき 6〜12mm になり、試し刷りの形とまったく同じになる。
//   細い道具（挟める下限が約 5.4mm 未満）では、ねじの先を細くして（VISE_NOSE_D_MM）V 字の奥まで届かせる。
//   手の側の端（腕を付ける所）は太さによらず同じ所に置き、太い道具では外へ広がる（手との距離が変わらない）。
// 左手は hand = "left" で描く。鏡に映して作ってはいけない（めねじが左ねじになり、ねじが入らない）。

VISE_H_MM = 20;                // 受け具の高さ（道具の軸の向き）。C字の輪の高さと同じ
VISE_WALL_MM = 2.5;            // 穴のまわりの肉
VISE_SCREW_D_MM = 12;
VISE_SCREW_PITCH_MM = 3.0;
VISE_SCREW_SLOP_MM = 0.10;     // BOSL2 の $slop。2026-11-24 の試し刷りで回った値
VISE_BOSS_LEN_MM = 10;         // めねじのかかる長さ（穴の縁から外へ）
VISE_KNOB_SPAN_MM = 32;        // T 字のつまみの長さ
VISE_KNOB_T_MM = 9;            // つまみの太さ
VISE_LAT_MM = 26;              // 太さ 12mm までの穴のとき、受け具の中心を親指側へ出す量（手の側の端が C字の輪とほぼ同じ所に来る）
VISE_DOWN_MM = 6;
VISE_FWD_MM = 5;
VISE_RANGE_MM = 2.5;           // 挟める太さの幅（tool_d から上下に）
VISE_DMAX_MIN_MM = 12;         // 穴の大きさの下限（いちばん太い道具の太さで）。穴の径 13mm 未満ではねじが通らない
VISE_DMIN_MIN_MM = 2.5;        // 挟める太さの下限の下限（ねじの先を細くしても、これより細いと届かない）
VISE_NOSE_D_MM = 6;            // 細い道具用の、ねじの先の細い部分の径

function vise_dmax(tool_d) = max(VISE_DMAX_MIN_MM, tool_d + VISE_RANGE_MM);
function vise_dmin(tool_d) = max(VISE_DMIN_MIN_MM, tool_d - VISE_RANGE_MM);
function vise_r(dmax) = dmax / 2 + 0.5;                     // 穴の丸い側の半径（いちばん太い道具＋0.5）
function vise_apex_x(dmax) = -vise_r(dmax) * sqrt(2);         // V 字の頂点（90度の V が半径 vise_r の円に接する）
function vise_tool_x(d, dmax) = vise_apex_x(dmax) + d / sqrt(2);   // 太さ d の道具が V 字に収まったときの中心
function vise_tip_x(d, dmax) = vise_tool_x(d, dmax) + d / 2;       // 太さ d の道具に当たったときの、ねじの先
function vise_boss_end(dmax) = vise_r(dmax) + VISE_BOSS_LEN_MM;
function vise_outer_min_x(dmax) = vise_apex_x(dmax) - VISE_WALL_MM - 0.3;
// 受け具の中心。手の側の端（vise_outer_min_x）が、穴がいちばん小さいときと同じ所に来るよう、太い道具では外へずらす
function vise_lat(dmax) = VISE_LAT_MM + vise_outer_min_x(VISE_DMAX_MIN_MM) - vise_outer_min_x(dmax);
function vise_center(tool_d) = holder_center(vise_lat(vise_dmax(tool_d)), VISE_DOWN_MM, VISE_FWD_MM);
// ねじの長さ：いちばん細い道具に届き、つまみが受け具から 3mm 離れる
function vise_screw_len(tool_d) = vise_boss_end(vise_dmax(tool_d)) - vise_tip_x(vise_dmin(tool_d), vise_dmax(tool_d)) + 3;
// ねじの先の細い部分の長さ。ねじ山（半径 6）が V 字の壁に当たらない所まで、細い先だけを出す（0 なら細い先なし）。
// V 字の頂点からねじの先までは (1/√2 + 1/2)·d。そこから半径 6＋0.5 の所までを細くする
function vise_nose_len(tool_d) =
  let(dmin = vise_dmin(tool_d), n = VISE_SCREW_D_MM / 2 + 0.5 - dmin * (1 / sqrt(2) + 0.5))
  n > 0.01 ? n : 0;

module vise_cavity_2d(dmax) {
  hull() {
    circle(r = vise_r(dmax));
    translate([vise_apex_x(dmax), 0]) circle(r = 0.3, $fn = 12);
  }
}

// 受け具の本体（局所座標）。穴とめねじはあとで抜く
module vise_body_local(dmax, quality) {
  $fn = fn_for(quality);
  translate([0, 0, -VISE_H_MM / 2]) linear_extrude(height = VISE_H_MM) offset(r = VISE_WALL_MM) vise_cavity_2d(dmax);
  // ねじのボス（+X）。刷る向き（局所 −Z が下）では、丸いボスの下端が机から 1mm 浮いてサポートが要ったので、
  // 下を 45度の斜面で机の面（z = −VISE_H_MM/2）まで伸ばし、細い帯で机に着ける（2026-11-24）
  R = (VISE_SCREW_D_MM + 6) / 2;
  zb = -VISE_H_MM / 2;
  foot_w = max(0.4, R * sin(45) - (-zb - R * cos(45)));   // 45度の接線が机に届く所の半幅
  hull() {
    rotate([0, 90, 0]) cylinder(r = R, h = vise_boss_end(dmax));
    translate([0, -foot_w, zb]) cube([vise_boss_end(dmax), 2 * foot_w, 0.01]);
  }
}

module vise_cuts_local(dmax, quality) {
  $fn = fn_for(quality);
  translate([0, 0, -VISE_H_MM / 2 - 1]) linear_extrude(height = VISE_H_MM + 2) vise_cavity_2d(dmax);
  // めねじ（X の向き）
  translate([vise_r(dmax) * 0.5, 0, 0]) rotate([0, 90, 0])
    trapezoidal_threaded_rod(d = VISE_SCREW_D_MM, l = vise_boss_end(dmax) - vise_r(dmax) * 0.5 + 0.02,
                             pitch = VISE_SCREW_PITCH_MM, internal = true, $slop = VISE_SCREW_SLOP_MM,
                             bevel1 = false, bevel2 = true, anchor = BOTTOM, $fa = 4, $fs = 0.5);
}

// レールの座標に組んだ形（受け具だけ）
module vise_holder_rail(tool_d = 8.5, tilt = 70, quality = "preview") {
  dmax = vise_dmax(tool_d);
  c = vise_center(tool_d);
  M = holder_matrix(c, tilt);
  difference() {
    union() {
      holder_tongue_and_arm(c, tilt, vise_outer_min_x(dmax) + 0.3, -VISE_H_MM * 0.4, VISE_H_MM * 0.4, quality);
      multmatrix(M) vise_body_local(dmax, quality);
    }
    multmatrix(M) vise_cuts_local(dmax, quality);
  }
}

// 刷る向き：道具の軸を立てる（めねじが横向きになる。ピッチ 3mm の台形ねじは横でも刷れた。2026-11-24）
module vise_holder_print(tool_d = 8.5, tilt = 70, quality = "print") {
  holder_print(vise_center(tool_d), tilt, -VISE_H_MM / 2) vise_holder_rail(tool_d, tilt, quality);
}

// ねじ（Z=0 が下端。つまみを下にして立てて刷る）。ねじは左右の手で同じ
module vise_screw(tool_d = 8.5, quality = "print") {
  $fn = fn_for(quality);
  L = vise_screw_len(tool_d);
  n = vise_nose_len(tool_d);
  // T 字のつまみ
  hull() for (s = [-1, 1]) translate([s * (VISE_KNOB_SPAN_MM / 2 - VISE_KNOB_T_MM / 2), 0, 0])
    cylinder(d = VISE_KNOB_T_MM, h = VISE_KNOB_T_MM);
  cylinder(d = VISE_SCREW_D_MM + 4, h = VISE_KNOB_T_MM);
  translate([0, 0, VISE_KNOB_T_MM - 0.01])
    trapezoidal_threaded_rod(d = VISE_SCREW_D_MM, l = n > 0 ? L - n + 0.01 : L, pitch = VISE_SCREW_PITCH_MM,
                             bevel1 = false, bevel2 = true, anchor = BOTTOM, $fa = 4, $fs = 0.5);
  // 細い道具用の細い先（先の角を少し落とす）
  if (n > 0)
    translate([0, 0, VISE_KNOB_T_MM + L - n - 0.5])
      cylinder(d1 = VISE_NOSE_D_MM, d2 = VISE_NOSE_D_MM - 1, h = n + 0.5);
}

// assembled の表示用：ねじを、太さ d の道具に当たるところまで入れた位置（局所座標）
module vise_screw_at(d, tool_d = 8.5, quality = "preview") {
  tip = vise_tip_x(d, vise_dmax(tool_d));
  L = vise_screw_len(tool_d);
  translate([tip + L + VISE_KNOB_T_MM, 0, 0]) rotate([0, -90, 0]) vise_screw(tool_d, quality);
}
