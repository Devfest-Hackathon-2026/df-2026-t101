import 'package:flutter_test/flutter_test.dart';
import 'package:jijogu_app/core/text_ja.dart';

/// AI が書いた文に混ざった項目名を、表示の前に取り除く（2026-11-10。形を確かめる画面に
/// 「スプーン(tool_type=spoon)で食べる。(activity=eat)」と出ていた）。生成APIの clean_ja と同じ決まり
void main() {
  group('cleanJa：項目名を取り除く', () {
    const cases = {
      'スプーン(tool_type=spoon)で食べる。(activity=eat)': 'スプーンで食べる。',
      'ペン（tool_type=pen）で字を書く（activity=write）ので60度にしました': 'ペンで字を書くので60度にしました',
      '手首から中指の付け根まで78mm（hand.wrist_to_middle_mcp_mm=78）なので': '手首から中指の付け根まで78mmなので',
      '道具の太さ tool_d_mm=9 に合わせました': '道具の太さ 9 に合わせました',
      '角度は (angle_deg) 70度です。': '角度は 70度です。',
    };
    cases.forEach((raw, want) {
      test(raw, () => expect(cleanJa(raw), want));
    });
  });

  group('cleanJa：ふつうの文は変えない', () {
    for (final t in [
      'PLA（ポリ乳酸）は熱に弱いので、熱いお湯につけないでください',
      'クリップの角度 60度（おすすめ）',
      'R6h の検査で、道具が手に当たりました',
      '材料は PETG（使えれば）がおすすめです',
      'C字クリップ（70度）',
      '',
    ]) {
      test(t, () => expect(cleanJa(t), t));
    }
  });
}
