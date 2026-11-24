// dataUrlBytes：同じ data URL には同じバイト列（同じオブジェクト）を返すこと。
// Image.memory（MemoryImage）はバイト列が同じオブジェクトかで画像のキャッシュを引くので、毎回作り直すと
// 描き直すたびに画像をデコードし直していた（S5 の点を動かすと1秒に約60回。2026-11-24）
import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jijogu_app/core/ui/widgets.dart';

String _url(int n) => 'data:image/jpeg;base64,${base64Encode(List.filled(64, n))}';

void main() {
  test('同じ文字列なら同じバイト列を返し、MemoryImage が同じ画像として扱う', () {
    final a = _url(1);
    final copy = String.fromCharCodes(a.codeUnits); // 中身が同じ別の文字列（画面が読み直したときの形）
    expect(identical(dataUrlBytes(a), dataUrlBytes(a)), isTrue);
    expect(identical(dataUrlBytes(a), dataUrlBytes(copy)), isTrue);
    expect(MemoryImage(dataUrlBytes(a)), MemoryImage(dataUrlBytes(copy)));
    expect(dataUrlBytes(a), List.filled(64, 1));
  });

  test('違う画像は違うバイト列。古いものは数に上限があって追い出される', () {
    final first = dataUrlBytes(_url(0));
    expect(dataUrlBytes(_url(2)), List.filled(64, 2));
    for (var i = 10; i < 40; i++) {
      dataUrlBytes(_url(i));
    }
    // 追い出されたあとも、中身は正しく作り直す
    final again = dataUrlBytes(_url(0));
    expect(identical(first, again), isFalse);
    expect(again, List.filled(64, 0));
  });
}
