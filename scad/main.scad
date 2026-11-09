// 入口（parts-library.md §2・§4.7）。全引数の既定値をここで宣言し、生成APIは -D でこの変数だけを上書きする。
// -D の名前は <部品ID>_<引数名>。位置・向き・ファイルは生成APIが計算した値だけを渡す（Gemini は触らない）。
//   mode = "cover"（カバーを刷る向きで）／"clip"・"c_clip"（クリップを刷る向きで）／"sleeve"・"tpu_sleeve"（TPUの筒）／
//          "assembled"（手の座標に組んだ位置。part で部品を選ぶ）
include <lib/common.scad>
include <parts/rail.scad>
include <parts/strap_slits.scad>
include <parts/air_holes.scad>
include <parts/c_clip.scad>
include <parts/cover.scad>

mode = "assembled";
part = "cover";            // assembled のとき："cover"／"c_clip"／"tpu_sleeve"
quality = "preview";
hand = "right";            // 記録用（鏡像は生成APIが済ませている）

// カバー
cover_shell_file = "";
cover_keepout_file = "";
cover_cover_thickness_mm = 2.5;
cover_print_matrix = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]];
cover_palm_plane = [];    // [nx, ny, nz, d]：手のひら側の面（n は手のひら向き）

// 空気穴
air_holes_diameter_mm = 6;
air_holes_centers = [];
air_holes_normals = [];

// ベルトのスリット
strap_slits_strap_width_mm = 25;
strap_slits_strap_thickness_mm = 2.0;
strap_slits_centers = [];
strap_slits_normals = [];
strap_slits_axes = [];

// レール（寸法は固定。位置と向きだけ渡す）
rail_origin = [];
rail_frame = [[1, 0, 0], [0, 1, 0], [0, 0, 1]];
rail_foot_mm = 6.0;        // 土台の深さ（common.scad の RAIL_FOOT_MM と同じ。スリットを避けて台をずらしたときだけ深くする）

// C字クリップ
c_clip_tool_d_mm = 8.5;
c_clip_wall_mm = 2.0;
c_clip_opening_ratio = 0.75;
c_clip_height_mm = 20;     // catalog.json の既定（固定）と同じ。2026-11-08 に 12 から
c_clip_angle_deg = 70;     // catalog.json の既定と同じ（60／70／80。2026-11-08 に 0／20／40 から）
c_clip_grip_ribs = true;
c_clip_tpu_sleeve = false;

module the_cover() {
  cover_part(cover_shell_file, cover_keepout_file, cover_cover_thickness_mm,
             strap_slits_centers, strap_slits_normals, strap_slits_axes,
             strap_slits_strap_width_mm, strap_slits_strap_thickness_mm,
             air_holes_centers, air_holes_normals, air_holes_diameter_mm,
             rail_origin, rail_frame, cover_palm_plane, quality, rail_foot_mm);
}

module the_clip_rail() {
  c_clip_rail(c_clip_tool_d_mm, c_clip_wall_mm, c_clip_opening_ratio, c_clip_height_mm,
              c_clip_angle_deg, c_clip_grip_ribs, c_clip_tpu_sleeve, quality);
}

if (mode == "cover") {
  multmatrix(cover_print_matrix) the_cover();
} else if (mode == "clip" || mode == "c_clip") {
  c_clip_print(c_clip_tool_d_mm, c_clip_wall_mm, c_clip_opening_ratio, c_clip_height_mm,
               c_clip_angle_deg, c_clip_grip_ribs, c_clip_tpu_sleeve, quality);
} else if (mode == "sleeve" || mode == "tpu_sleeve") {
  translate([0, 0, c_clip_height_mm / 2]) tpu_sleeve_local(c_clip_tool_d_mm, c_clip_height_mm, quality);
} else if (mode == "assembled") {
  if (part == "cover") the_cover();
  else if (part == "c_clip") {
    if (len(rail_origin) == 3) multmatrix(frame_matrix(rail_origin, rail_frame)) the_clip_rail();
    else the_clip_rail();
  } else if (part == "tpu_sleeve") {
    if (len(rail_origin) == 3) multmatrix(frame_matrix(rail_origin, rail_frame))
      tpu_sleeve_rail(c_clip_tool_d_mm, c_clip_wall_mm, c_clip_height_mm, c_clip_angle_deg, quality);
  }
}
