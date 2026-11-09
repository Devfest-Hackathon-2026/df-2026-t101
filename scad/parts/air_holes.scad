// 空気穴（引く形。parts-library.md §4.2）。位置と向きは生成APIが計算して渡す。
// centers[i] はカバーの外面の上の点、normals[i] は外向きの法線。両端の縁を 0.8mm 面取りする。
// common.scad は入口のファイルが先に include する

module air_holes_cut(centers, normals, diameter, thickness, quality = "preview") {
  $fn = quality == "print" ? 40 : 24;
  ch = 0.8;
  if (len(centers) > 0) for (i = [0 : len(centers) - 1]) {
    n = normals[i] / norm(normals[i]);
    translate(centers[i]) orient_z_to(n) {
      cylinder(d = diameter, h = 3 * (thickness + 4), center = true);
      // 外側の縁の面取り
      translate([0, 0, -ch + 0.01]) cylinder(d1 = diameter, d2 = diameter + 2 * ch + 0.4, h = ch + 0.4);
      // 内側の縁の面取り（外面から厚み t の所）
      translate([0, 0, -thickness - 0.4]) cylinder(d1 = diameter + 2 * ch + 0.4, d2 = diameter, h = ch + 0.4);
    }
  }
}
