// TPUの筒（parts-library.md §4.6）。形は c_clip.scad の tpu_sleeve_local / tpu_sleeve_rail。
// このファイルは、筒だけを刷る試し用の入口（main.scad の mode="sleeve" と同じ形）。
include <../lib/common.scad>
include <rail.scad>
include <c_clip.scad>

tool_d_mm = 8.5;
height_mm = 12;
tpu_sleeve_local(tool_d_mm, height_mm, "print");
