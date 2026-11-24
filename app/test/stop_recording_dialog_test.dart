import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jijogu_app/core/ui/ui.dart';
import 'package:jijogu_app/features/measure/stop_recording_dialog.dart';

/// S3 録画中に閉じようとしたときの確かめる画面（持ち直したときに「×」に触れて撮影が消えないように。2026-11-22）
void main() {
  Future<bool?> open(WidgetTester tester, String tap) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async =>
                    result = await confirmStopRecording(context),
                child: const Text('開く'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();
    expect(find.text('撮影をやめますか？'), findsOneWidget);
    expect(find.text('ここまで撮った分は消えます。'), findsOneWidget);
    // ボタンは縦に並べ、幅いっぱい・高さ48px以上（主なボタンの決まり）
    final keep = tester.getRect(find.text('撮影を続ける').hitTestable());
    final stop = tester.getRect(find.text('やめる').hitTestable());
    expect(keep.top < stop.top, isTrue, reason: '「撮影を続ける」が上');
    for (final label in ['撮影を続ける', 'やめる']) {
      final button = find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      );
      final size = tester.getSize(button.first);
      expect(size.height, greaterThanOrEqualTo(48));
      expect(size.width, greaterThan(200));
    }
    await tester.tap(find.text(tap));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('「撮影を続ける」なら false', (tester) async {
    expect(await open(tester, '撮影を続ける'), isFalse);
  });

  testWidgets('「やめる」なら true', (tester) async {
    expect(await open(tester, 'やめる'), isTrue);
  });
}
