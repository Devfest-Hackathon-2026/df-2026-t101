// カバー（parts-library.md §4.1）。殻（cover_shell.stl）は生成APIが距離場で作る。
// ここでは殻を import して、スリットと空気穴を引き、アリ溝のレールを足し、最後に手を c だけ広げた立体（keepout）を引く。
// 座標は実際の手の座標（mm）。鏡像は生成APIが済ませている（ここでは反転しない）。
// common.scad・rail.scad・strap_slits.scad・air_holes.scad は入口のファイルが先に include する

module cover_part(shell_file, keepout_file, thickness,
                  slit_centers, slit_normals, slit_axes, strap_width, strap_thickness,
                  hole_centers, hole_normals, hole_diameter,
                  rail_origin, rail_frame, palm_plane = [], quality = "preview") {
  difference() {
    union() {
      difference() {
        import(shell_file, convexity = 10);
        if (len(slit_centers) > 0)
          strap_slits_cut(slit_centers, slit_normals, slit_axes, strap_width, strap_thickness, quality);
        air_holes_cut(hole_centers, hole_normals, hole_diameter, thickness, quality);
      }
      if (len(rail_origin) == 3) rail_on_cover(rail_origin, rail_frame, quality);
    }
    // 内側の面を守る：レールの土台などが手の側へ出た分を削る
    if (keepout_file != "") import(keepout_file, convexity = 10);
    // 手のひら側の面より先を捨てる（レールの角が手のひら側へ出ないように）。palm_plane = [nx, ny, nz, d]：n・p > d を捨てる
    if (len(palm_plane) == 4) {
      n = [palm_plane[0], palm_plane[1], palm_plane[2]];
      translate(n * palm_plane[3]) orient_z_to(n) translate([-500, -500, 0]) cube([1000, 1000, 500]);
    }
  }
}
