import 'package:flutter_test/flutter_test.dart';
import 'package:jijogu_app/core/models/refine_choice.dart';

/// S7 で直し方を選んでから、下のボタンで送る（押し間違いで作り直さないため。2026-11-22）
void main() {
  final oldDesign = <String, dynamic>{'design_id': 'd1'}; // 取り付け具の一覧がない古い版
  final newDesign = <String, dynamic>{
    'design_id': 'd2',
    'attachments': [
      {'id': 'a1', 'primary': true},
    ],
  };

  group('よく使う指示', () {
    test('ボタンの文・送る本文・待つ文・できた文', () {
      final c = RefineChoice.instruction('もう少しゆるく', newDesign, 'a1');
      expect(c.buttonLabel, '「もう少しゆるく」で直す');
      expect(c.body, {'instruction': 'もう少しゆるく', 'attachment_id': 'a1'});
      expect(c.busyText, '「もう少しゆるく」に合わせて直しています');
      expect(c.doneText, '「もう少しゆるく」に合わせて直しました');
    });

    test('古い版には取り付け具の ID を添えない', () {
      final c = RefineChoice.instruction('カバーを薄く', oldDesign, 'a1');
      expect(c.body, {'instruction': 'カバーを薄く'});
    });

    test('同じ指示なら同じ選択', () {
      expect(
        RefineChoice.instruction('もう少しきつく', newDesign, 'a1'),
        RefineChoice.instruction('もう少しきつく', newDesign, 'a1'),
      );
      expect(
        RefineChoice.instruction('もう少しきつく', newDesign, 'a1') ==
            RefineChoice.instruction('もう少しゆるく', newDesign, 'a1'),
        isFalse,
      );
    });
  });

  group('留め具の角度', () {
    test('取り付け具が1つなら道具の名前を付けない', () {
      final c = RefineChoice.angle(80, newDesign, 'a1');
      expect(c.angle, 80);
      expect(c.buttonLabel, '留め具を80度で作り直す');
      expect(c.body, {'clip_angle_deg': 80, 'attachment_id': 'a1'});
      expect(c.busyText, '留め具を80度で作り直しています（カバーはそのままです）');
      expect(c.doneText, '留め具を80度にしました（カバーはそのままです）');
    });

    test('取り付け具が2つ以上なら道具の名前を付ける', () {
      final c = RefineChoice.angle(60, newDesign, 'a1', toolLabel: 'ペン');
      expect(c.buttonLabel, 'ペンの留め具を60度で作り直す');
      expect(c.busyText, 'ペンの留め具を60度で作り直しています（カバーはそのままです）');
      expect(c.doneText, 'ペンの留め具を60度にしました（カバーはそのままです）');
    });

    test('指示の選択には角度がない', () {
      expect(
        RefineChoice.instruction('もう少しゆるく', newDesign, 'a1').angle,
        isNull,
      );
    });
  });

  test('直すと新しい形になることの注意（OTに頼んだあと・確認済みのときだけ）', () {
    expect(reReviewNote('none'), isNull);
    expect(reReviewNote('rejected'), isNull);
    expect(reReviewNote('requested'), '直すと新しい形になるため、もう一度OTに確認を頼む必要があります。');
    expect(reReviewNote('approved'), '直すと新しい形になるため、もう一度OTに確認を頼む必要があります。');
  });
}
