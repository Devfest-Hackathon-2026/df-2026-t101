import 'package:flutter_test/flutter_test.dart';
import 'package:jijogu_app/core/api/mock_backend.dart';
import 'package:jijogu_app/core/models/attachments.dart';
import 'package:jijogu_app/core/models/requirements.dart';

/// S10 の行・S9 の取り付け具の一覧（ADR-0014 §5）。行の決め方は純粋な関数で、流れはモックで確かめる
void main() {
  final mock = MockBackend.instance;
  Map<String, dynamic> m(Object? x) => Map<String, dynamic>.from(x as Map);

  Future<(String, Map<String, dynamic>)> caseWith(List<ToolAnswer> tools) async {
    final id = (await mock.handle('POST', '/v1/cases', {'title': 't'}))['case_id'] as String;
    final a = Answers()
      ..tools = tools
      ..handSide = 'right'..donningBy = 'self'..fingerState = 'fist'..captureBy = 'helper';
    await mock.handle('PUT', '/v1/cases/$id/requirements', a.toJson());
    await mock.handle('PUT', '/v1/cases/$id/measurement', {
      'capture': {'mesh_id': 'hm_1'},
      'palm': {'hand_width_mcp_mm': 75},
    });
    final r = await mock.handle('POST', '/v1/cases/$id/designs', {'style': {'color': '#2A9D8F'}});
    return (id, m(r['design']));
  }

  ToolAnswer pen() => ToolAnswer()..activity = 'write'..toolType = 'pen'..toolDmm = 9.0..shaftShape = 'round';
  ToolAnswer spoon() => ToolAnswer()..activity = 'eat'..toolType = 'spoon'..shaftSize = 'thick'..shaftShape = 'round';

  group('モックの印刷用ファイル', () {
    test('取り付け具2つ：prepare-print が3つのキーを返す', () async {
      final (cid, d) = await caseWith([pen(), spoon()]);
      final r = await mock.handle('POST', '/v1/cases/$cid/designs/${d['design_id']}/prepare-print', {});
      final print = m(r['files']['print']);
      expect(print.keys.toSet(), {'cover', 'c_clip', 'c_clip_a2'});
      expect(print['cover'], 'demo/cover.print.stl');
      expect(print['c_clip'], 'demo/c_clip_60.print.stl');
      expect(print['c_clip_a2'], 'demo/c_clip_60.print.stl');
    });

    test('取り付け具1つ：cover と c_clip だけ', () async {
      final (cid, d) = await caseWith([pen()]);
      final r = await mock.handle('POST', '/v1/cases/$cid/designs/${d['design_id']}/prepare-print', {});
      expect(m(r['files']['print']).keys.toSet(), {'cover', 'c_clip'});
    });

    test('承認も取り付け具ごとのキーを返す', () async {
      final (cid, d) = await caseWith([pen(), spoon()]);
      final r = await mock.handle('POST', '/v1/cases/$cid/designs/${d['design_id']}/approval',
          {'decision': 'approve', 'comment_ja': 'ok'});
      expect(m(r['files']['print']).keys.toSet(), {'cover', 'c_clip', 'c_clip_a2'});
    });

    test('版の取り付け具に R6f・R6h の結果がある', () async {
      final (_, d) = await caseWith([pen(), spoon()]);
      for (final a in d['attachments'] as List) {
        expect([for (final c in a['checks']) c['rule']], ['R6f', 'R6h']);
      }
    });
  });

  group('S10 の行', () {
    test('取り付け具1つ：今までと同じ「C字クリップ（70度）」、案内の行なし', () {
      final d = {
        'params': [{'part_id': 'c_clip', 'name': 'angle_deg', 'value': 70}],
        'files': {'print': {'cover': 'demo/cover.print.stl', 'c_clip': 'demo/c_clip_70.print.stl'}},
      };
      final rows = printRows(d, null);
      expect(rows.map((r) => r.key), ['cover', 'c_clip']);
      expect(rows.map((r) => r.name), ['カバー', 'C字クリップ（70度）']);
      expect(rows[1].path, 'demo/c_clip_70.print.stl');
      expect(rows[1].partId, 'c_clip');
      expect(showSwapGuide(d), isFalse);
    });

    test('取り付け具2つ：カバー＋道具ごとの行、案内あり', () async {
      final (cid, d) = await caseWith([pen(), spoon()]);
      final r = await mock.handle('POST', '/v1/cases/$cid/designs/${d['design_id']}/prepare-print', {});
      final dd = m(r['design']);
      final rows = printRows(dd, null);
      expect(rows.map((r) => r.key), ['cover', 'c_clip', 'c_clip_a2']);
      expect(rows.map((r) => r.name), ['カバー', 'ペン クリップ（9mm・60度）', 'スプーン クリップ（11.5mm・60度）']);
      expect(rows[2].path, 'demo/c_clip_60.print.stl');
      expect(showSwapGuide(dd), isTrue);
    });

    test('同じ道具が2つなら太さで見分ける。キーがない取り付け具の行は出さない', () {
      final d = {
        'attachments': [
          {'id': 'a1', 'tool_type': 'pen', 'tool_d_mm': 8.0, 'angle_deg': 60, 'print_key': 'c_clip'},
          {'id': 'a2', 'tool_type': 'pen', 'tool_d_mm': 10.0, 'angle_deg': 60, 'print_key': 'c_clip_a2'},
        ],
        'files': {'print': {'cover': 'c.stl', 'c_clip': 'a.stl'}},
      };
      expect(printRows(d, null).map((r) => r.name), ['カバー', 'ペン 8mm クリップ（8mm・60度）']);
    });

    test('古い版は要求の道具で呼ぶ。TPUの筒は最後に残す', () {
      final d = {
        'params': [{'part_id': 'c_clip', 'name': 'angle_deg', 'value': 70}],
        'files': {'print': {'cover': 'c.stl', 'c_clip': 'a.stl', 'tpu_sleeve': 't.stl'}},
      };
      final rows = printRows(d, {'tool_type': 'brush', 'tool_d_mm': 8});
      expect(rows.map((r) => r.name), ['カバー', 'C字クリップ（70度）', 'TPUの筒']);
    });
  });

  group('S10 から取り付け具を足す（ADR-0014 §4）', () {
    final one = {
      'origin': 'refine_add_attachment',
      'attachments': [{'id': 'a1'}, {'id': 'a2'}],
    };
    test('刷れる版で、まだ足せるときだけボタンを出す', () {
      expect(canAddFromPrint(one, null, ready: true), isTrue);
      expect(canAddFromPrint(one, null, ready: false), isFalse);
      final four = {'attachments': [for (var i = 1; i <= 4; i++) {'id': 'a$i'}]};
      expect(canAddFromPrint(four, null, ready: true), isFalse);
      // 平たい柄の道具も数に入れる（生成APIと同じ）
      expect(canAddFromPrint(one, {'tools': List.filled(4, {})}, ready: true), isFalse);
    });
    test('足した・太さを直した版には、刷ってあるカバーを使える知らせを出す', () {
      expect(coverKept(one), isTrue);
      expect(coverKept({'origin': 'refine_tool_d'}), isTrue);
      expect(coverKept({'origin': 'initial'}), isFalse);
      expect(coverKept({'origin': 'refine_clip_angle'}), isFalse);
    });
  });

  group('S9 の取り付け具の一覧', () {
    test('道具・太さ・角度と検査の結果', () {
      final d = {
        'attachments': [
          {
            'id': 'a1', 'tool_type': 'pen', 'tool_d_mm': 9.0, 'angle_deg': 60,
            'checks': [
              {'rule': 'R6f', 'ok': true, 'value': 1, 'message_ja': 'クリップの開きは足りています'},
              {'rule': 'R6h', 'ok': false, 'value': 3, 'message_ja': '道具が当たります'},
            ],
          },
        ],
      };
      final l = reviewAttachments(d, null);
      expect(l.single.title, 'ペン');
      expect(l.single.summary, '太さ9mm・角度60度');
      expect(l.single.checks.map((c) => (c.rule, c.ok, c.resultJa)),
          [('R6f', true, '合格'), ('R6h', false, '注意')]);
      expect(l.single.checks[1].messageJa, '道具が当たります');
    });

    test('古い版は検査なしの1行', () {
      final d = {'params': [{'part_id': 'c_clip', 'name': 'angle_deg', 'value': 70}]};
      final l = reviewAttachments(d, {'tool_type': 'brush'});
      expect(l.single.title, '筆');
      expect(l.single.checks, isEmpty);
    });
  });

  group('OTに頼むときの版の要約', () {
    final cover = {'part_id': 'cover', 'name': 'cover_thickness_mm', 'value': 2.5};

    test('取り付け具が2つ以上：道具ごとの角度を並べる', () {
      final d = {
        'params': [cover],
        'attachments': [
          {'id': 'a1', 'tool_type': 'brush', 'tool_d_mm': 8.5, 'angle_deg': 70},
          {'id': 'a2', 'tool_type': 'pen', 'tool_d_mm': 6.0, 'angle_deg': 60},
          {'id': 'a3', 'tool_type': 'spoon', 'tool_d_mm': 11.5, 'angle_deg': 60},
        ],
      };
      expect(versionSummary(d), 'カバー 2.5mm・筆 70度・ペン 60度・スプーン 60度');
    });

    test('同じ道具が2つ：太さで見分ける', () {
      final d = {
        'params': [cover],
        'attachments': [
          {'id': 'a1', 'tool_type': 'pen', 'tool_d_mm': 6.0, 'angle_deg': 60},
          {'id': 'a2', 'tool_type': 'pen', 'tool_d_mm': 9.0, 'angle_deg': 70},
        ],
      };
      expect(versionSummary(d), 'カバー 2.5mm・ペン 6mm 60度・ペン 9mm 70度');
    });

    test('取り付け具が1つ・古い版：今までどおり「クリップ」', () {
      final one = {
        'params': [cover],
        'attachments': [
          {'id': 'a1', 'tool_type': 'pen', 'tool_d_mm': 6.0, 'angle_deg': 60},
        ],
      };
      expect(versionSummary(one), 'カバー 2.5mm・クリップ 60度');
      final old = {
        'params': [cover, {'part_id': 'c_clip', 'name': 'angle_deg', 'value': 70}],
      };
      expect(versionSummary(old), 'カバー 2.5mm・クリップ 70度');
    });
  });
}
