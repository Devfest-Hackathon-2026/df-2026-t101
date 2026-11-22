// S7「数値で細かく直す」の −／＋ボタンで、値を1段動かす。
// スライダーのドラッグだけでは、曲がった指で狙った値に止められなかったため（2026-11-22）

/// 1段で動かす量（mm は0.1、個・本は1。スライダーの目盛りと同じ）
double paramStepSize(bool isInt) => isInt ? 1 : 0.1;

/// [dir] の向き（+1 / −1）に1段動かした値。範囲に収め、mm は0.1に丸める（0.1を足し続けたときの誤差を残さない）
num stepParam(
  num value,
  int dir, {
  required double lo,
  required double hi,
  required bool isInt,
}) {
  final x = (value + dir * paramStepSize(isInt)).clamp(lo, hi);
  return isInt ? x.round() : double.parse(x.toStringAsFixed(1));
}

/// その向きのボタンを押せるか（端まで来たら押せない）
bool canStep(num value, int dir, {required double lo, required double hi}) =>
    dir > 0 ? value < hi - 1e-9 : value > lo + 1e-9;
