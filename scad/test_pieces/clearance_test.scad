// 試し刷り3（parts-library.md §6）：カバーとこぶしのすき間 c を 1.0／1.5／2.0 で比べる。
// 生成APIの api/app/geometry が、実寸の手のメッシュから人差し指と中指の付け根の関節の山のまわりだけを切り出した
// 小さな殻を3つ作り（clearance_c10.stl など）、ここで並べる。ファイルは -D で渡す。
c10_file = "";
c15_file = "";
c20_file = "";
files = [c10_file, c15_file, c20_file];
labels = ["1.0", "1.5", "2.0"];
for (i = [0 : 2]) if (files[i] != "") translate([i * 60, 0, 0]) {
  import(files[i], convexity = 10);
  translate([0, -12, 0]) linear_extrude(0.6) text(labels[i], size = 5);
}
