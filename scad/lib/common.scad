// 固定値（parts-library.md §3）。AI は変えられない。値は 11/9 の朝の試し刷りで決め直す（仮の値に「仮」）。
// 生成API（api/app/geometry/consts.py）も同じ値を catalog.json から読む。変えるときは catalog.json と一緒に。

NOZZLE_MM = 0.4;
MIN_WALL_MM = 2.0;
MIN_EDGE_RADIUS_MM = 1.5;
MAX_OVERHANG_DEG = 45;
HAND_CLEARANCE_MM = 1.5;        // 仮。フェルトの厚みを含む
FELT_THICKNESS_MM = 1.0;        // 要確認
DOVETAIL_CLEARANCE_MM = 0.25;   // 仮。アリ溝のすき間（片側）
CLIP_INTERFERENCE_MM = 0.3;     // 仮。クリップのしめしろ
CLIP_ENTRY_CHAMFER_DEG = 30;
CLIP_ROOT_NOTCH_MM = 0.6;
CLIP_GROOVE_W = 1.0;            // 内側の溝の幅
CLIP_GROOVE_D = 0.4;            // 内側の溝の深さ
CLIP_GROOVE_PITCH = 3.0;        // 内側の溝の間隔
TPU_SLEEVE_WALL_MM = 1.2;       // 仮
WRIST_FREE_MM = 25;
THUMB_EXTRA_MM = 2.0;
BED_MM = [180, 180, 180];
FN_PREVIEW = 48;
FN_PRINT = 128;

// アリ溝のレール（固定。parts-library.md §4.4）
RAIL_WIDTH_MM = 10;     // 溝の口の幅
RAIL_DEPTH_MM = 4;      // 溝の深さ
RAIL_LENGTH_MM = 24;
RAIL_DOVETAIL_DEG = 60; // 溝の壁と底のなす角
RAIL_DETENT_MM = 0.6;   // 止めの出っ張りの高さ
RAIL_WALL_MM = 2.5;     // 溝のまわりの肉
RAIL_BASE_MM = 2.0;     // 溝の底の下の肉
RAIL_FOOT_MM = 6.0;     // 殻の中へ入り込ませる土台（内側へ出た分は keepout で削る）
RAIL_DETENT_FROM_END_MM = 3.0;

// 溝の底の幅（口より広い）
function rail_bottom_w(clr = 0) = RAIL_WIDTH_MM + 2 * RAIL_DEPTH_MM / tan(RAIL_DOVETAIL_DEG) - 2 * clr;
function rail_outer_w() = rail_bottom_w() + 2 * RAIL_WALL_MM;
function rail_height() = RAIL_DEPTH_MM + RAIL_BASE_MM;

function fn_for(quality) = quality == "print" ? FN_PRINT : FN_PREVIEW;

// 角を丸めた長方形（2D、中心）
module rounded_rect(size, r) {
  r2 = min(r, min(size[0], size[1]) / 2 - 0.01);
  offset(r = r2) square([size[0] - 2 * r2, size[1] - 2 * r2], center = true);
}

// 4x4 行列（行のリスト）から multmatrix 用の形へ
function frame_matrix(origin, rows) = [
  [rows[0][0], rows[1][0], rows[2][0], origin[0]],
  [rows[0][1], rows[1][1], rows[2][1], origin[1]],
  [rows[0][2], rows[1][2], rows[2][2], origin[2]],
  [0, 0, 0, 1]
];

// 向き v（単位ベクトル）を Z に合わせる回転（v の向きに穴を開けるとき使う）
module orient_z_to(v) {
  vx = v[0]; vy = v[1]; vz = v[2];
  b = acos(max(-1, min(1, vz)));
  a = atan2(vy, vx);
  rotate([0, b, a]) children();
}
