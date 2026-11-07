// ベルトのスリット（引く形。parts-library.md §4.3）。位置と向きは生成APIが計算して渡す（実際の手の座標）。
// common.scad は入口のファイルが先に include する

// centers[i]：スリットの中心（カバーの壁の中ほど）、normals[i]：壁を抜く向き、axes[i]：長い辺の向き
module strap_slits_cut(centers, normals, axes, strap_width, strap_thickness, quality = "preview") {
  $fn = 24;
  for (i = [0 : len(centers) - 1]) {
    n = normals[i] / norm(normals[i]);
    a0 = axes[i] - (axes[i] * n) * n;
    a = a0 / norm(a0);
    x = cross(a, n);
    M = [[x[0], a[0], n[0], centers[i][0]], [x[1], a[1], n[1], centers[i][1]], [x[2], a[2], n[2], centers[i][2]], [0, 0, 0, 1]];
    multmatrix(M) {
      // 穴（角を丸めた長方形を壁に垂直に抜く）
      linear_extrude(height = 24, center = true)
        rounded_rect([strap_thickness + 1.5, strap_width + 1.0], 1.0);
    }
  }
}
