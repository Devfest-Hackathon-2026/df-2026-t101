import 'package:flutter_test/flutter_test.dart';
import 'package:jijogu_app/core/models/param_step.dart';

/// S7「数値で細かく直す」の −／＋ボタン（曲がった指でもスライダーを1段ずつ動かせるように。2026-11-22）
void main() {
  test('mm は0.1ずつ、小数の誤差を残さない', () {
    expect(stepParam(2.5, 1, lo: 1.5, hi: 4.0, isInt: false), 2.6);
    expect(stepParam(2.6, 1, lo: 1.5, hi: 4.0, isInt: false), 2.7);
    expect(stepParam(2.5, -1, lo: 1.5, hi: 4.0, isInt: false), 2.4);
  });

  test('個・本は1ずつ、整数で返す', () {
    final v = stepParam(6, 1, lo: 0, hi: 10, isInt: true);
    expect(v, 7);
    expect(v, isA<int>());
    expect(stepParam(6, -1, lo: 0, hi: 10, isInt: true), 5);
  });

  test('範囲の外には出ない', () {
    expect(stepParam(4.0, 1, lo: 1.5, hi: 4.0, isInt: false), 4.0);
    expect(stepParam(1.5, -1, lo: 1.5, hi: 4.0, isInt: false), 1.5);
    expect(stepParam(10, 1, lo: 0, hi: 10, isInt: true), 10);
  });

  test('端ではそちら側のボタンを押せない', () {
    expect(canStep(4.0, 1, lo: 1.5, hi: 4.0), isFalse);
    expect(canStep(4.0, -1, lo: 1.5, hi: 4.0), isTrue);
    expect(canStep(1.5, -1, lo: 1.5, hi: 4.0), isFalse);
    expect(canStep(2.5, 1, lo: 1.5, hi: 4.0), isTrue);
  });
}
