import 'package:flutter_test/flutter_test.dart';
import 'package:jijogu_app/core/api/api_error.dart';
import 'package:jijogu_app/core/api/mock_backend.dart';
import 'package:jijogu_app/core/models/attachments.dart';
import 'package:jijogu_app/core/models/requirements.dart';

/// S7 で取り付け具を切り替え・足す・直す（ADR-0014 §4・§5）。画面の決め方は純粋な関数で、流れはモックで確かめる
void main() {
  final mock = MockBackend.instance;

  Map<String, dynamic> m(Object? x) => Map<String, dynamic>.from(x as Map);
  List<Map<String, dynamic>> atts(Map<String, dynamic> d) =>
      [for (final a in d['attachments'] as List) m(a)];
  Map<String, dynamic> att(Map<String, dynamic> d, String id) =>
      atts(d).firstWhere((a) => a['id'] == id);
  num? param(Map<String, dynamic> d, String name) => (d['params'] as List)
      .firstWhere((p) => p['part_id'] == 'c_clip' && p['name'] == name)['value'] as num?;

  /// ケースを作り、道具を保存し、採寸して、最初の版を作る
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

  Future<Map<String, dynamic>> refine(String cid, Map<String, dynamic> d, Map<String, dynamic> body) async =>
      m((await mock.handle('POST', '/v1/cases/$cid/designs/${d['design_id']}/refine', body))['design']);

  ToolAnswer pen() => ToolAnswer()..activity = 'write'..toolType = 'pen'..toolDmm = 9.0..shaftShape = 'round';
  ToolAnswer spoon() => ToolAnswer()..activity = 'eat'..toolType = 'spoon'..shaftSize = 'thick'..shaftShape = 'round';
  ToolAnswer brush() => ToolAnswer()..activity = 'draw'..toolType = 'brush'..toolDmm = 8.0..shaftShape = 'round';

  group('モックの版の取り付け具', () {
    test('道具2つ：取り付け具が2つ、主は最初。今までの項目は主と同じ', () async {
      final (_, d) = await caseWith([pen(), spoon()]);
      final l = atts(d);
      expect(l.map((a) => a['id']), ['a1', 'a2']);
      expect(l.map((a) => a['tool_type']), ['pen', 'spoon']);
      expect(l.map((a) => a['primary']), [true, false]);
      expect(l.map((a) => a['angle_deg']), [60, 60]);
      expect(l[1]['tool_d_mm'], 11.5);
      expect(l[1]['tool_d_source'], 'category');
      expect(l[0]['files']['preview_stl'], 'demo/c_clip_60.stl');
      expect(d['files']['parts']['c_clip']['preview_stl'], 'demo/c_clip_60.stl');
      expect(param(d, 'angle_deg'), 60);
      expect(param(d, 'tool_d_mm'), 9.0);
    });

    test('平たい柄の道具は取り付け具を作らず知らせる', () async {
      final (_, d) = await caseWith([
        ToolAnswer()..activity = 'eat'..toolType = 'spoon'..toolDmm = 10..shaftShape = 'flat',
        pen(),
      ]);
      expect(atts(d).map((a) => a['tool_type']), ['pen']);
      expect(atts(d)[0]['id'], 'a2');
      expect(d['status'], 'needs_attention');
      expect('${d['review']['unresolved_issues']}', contains(flatReason('spoon')));
    });

    test('道具1つ（筆）：今と同じ70度のクリップ1つ', () async {
      final (_, d) = await caseWith([brush()]);
      expect(atts(d).length, 1);
      expect(param(d, 'angle_deg'), 70);
      expect(d['files']['parts']['c_clip']['preview_stl'], 'demo/c_clip_70.stl');
      expect(d['status'], 'ready');
    });

    test('角度：attachment_id の取り付け具だけ変わる', () async {
      final (cid, d) = await caseWith([pen(), spoon()]);
      final n = await refine(cid, d, {'clip_angle_deg': 80, 'attachment_id': 'a2'});
      expect(n['design_id'], isNot(d['design_id']));
      expect(att(n, 'a2')['angle_deg'], 80);
      expect(att(n, 'a2')['angle_source'], 'user');
      expect(att(n, 'a2')['files']['preview_stl'], 'demo/c_clip_80.stl');
      expect(att(n, 'a1')['angle_deg'], 60);
      expect(param(n, 'angle_deg'), 60); // 主はそのまま
      expect(n['origin'], 'refine_clip_angle');
      // 主の角度を変えると今までの項目も変わる
      final p = await refine(cid, n, {'clip_angle_deg': 70, 'attachment_id': 'a1'});
      expect(param(p, 'angle_deg'), 70);
      expect(att(p, 'a1')['angle_deg'], 70);
      expect(att(p, 'a2')['angle_deg'], 80);
      expect(p['files']['parts']['c_clip']['preview_stl'], 'demo/c_clip_70.stl');
    });

    test('足す：取り付け具が1つ増え、要求の道具の最後に加わる。5つ目は INVALID_ARGUMENT', () async {
      final (cid, d) = await caseWith([pen(), spoon()]);
      final n = await refine(cid, d, {'add_attachment': brush().toJson()});
      expect(atts(n).map((a) => a['id']), ['a1', 'a2', 'a3']);
      expect(att(n, 'a3')['tool_type'], 'brush');
      expect(att(n, 'a3')['tool_index'], 2);
      expect(att(n, 'a3')['angle_deg'], 70);
      expect(att(n, 'a3')['primary'], false);
      expect(n['origin'], 'refine_add_attachment');
      expect(n['approval']['status'], 'none');
      expect(coverKept(n), isTrue);
      final c = m(await mock.handle('GET', '/v1/cases/$cid', null));
      expect((c['requirements']['tools'] as List).length, 3);
      expect(c['current_design_id'], n['design_id']);
      final four = await refine(cid, n, {
        'add_attachment': (ToolAnswer()..activity = 'write'..toolType = 'pen'..shaftSize = 'thin'..shaftShape = 'round').toJson(),
      });
      expect(atts(four).length, 4);
      expect(addBlockedReason(four, m(m(await mock.handle('GET', '/v1/cases/$cid', null))['requirements'])),
          '取り付け具は4つまでです');
      await expectLater(
        refine(cid, four, {'add_attachment': brush().toJson()}),
        throwsA(isA<ApiError>()
            .having((e) => e.code, 'code', 'INVALID_ARGUMENT')
            .having((e) => e.message, 'message', '取り付け具は4つまでです')),
      );
    });

    test('平たい柄は足せない（INVALID_ARGUMENT）', () async {
      final (cid, d) = await caseWith([pen()]);
      await expectLater(
        refine(cid, d, {
          'add_attachment': (ToolAnswer()..activity = 'eat'..toolType = 'spoon'..toolDmm = 10..shaftShape = 'flat').toJson(),
        }),
        throwsA(isA<ApiError>()
            .having((e) => e.code, 'code', 'INVALID_ARGUMENT')
            .having((e) => e.message, 'message', flatReason('spoon'))),
      );
    });

    test('太さ：attachment_id の取り付け具と要求の道具を直す', () async {
      final (cid, d) = await caseWith([pen(), spoon()]);
      final n = await refine(cid, d, {'tool_d_mm': 10.5, 'attachment_id': 'a2'});
      expect(att(n, 'a2')['tool_d_mm'], 10.5);
      expect(att(n, 'a2')['tool_d_source'], 'user');
      expect(att(n, 'a1')['tool_d_mm'], 9.0);
      expect(param(n, 'tool_d_mm'), 9.0);
      expect(n['origin'], 'refine_tool_d');
      final c = m(await mock.handle('GET', '/v1/cases/$cid', null));
      expect(c['requirements']['tools'][1]['tool_d_mm'], 10.5);
      expect(c['requirements']['tools'][1]['tool_d_source'], 'user');
      // 主の太さは今までの項目も直す
      final p = await refine(cid, n, {'tool_d_mm': 7.5, 'attachment_id': 'a1'});
      expect(param(p, 'tool_d_mm'), 7.5);
      final c2 = m(await mock.handle('GET', '/v1/cases/$cid', null));
      expect(c2['requirements']['tool_d_mm'], 7.5);
      await expectLater(refine(cid, p, {'tool_d_mm': 25, 'attachment_id': 'a1'}),
          throwsA(isA<ApiError>().having((e) => e.code, 'code', 'INVALID_ARGUMENT')));
    });

    test('版にない attachment_id・色と一緒の attachment_id は INVALID_ARGUMENT', () async {
      final (cid, d) = await caseWith([pen()]);
      await expectLater(refine(cid, d, {'clip_angle_deg': 70, 'attachment_id': 'a9'}),
          throwsA(isA<ApiError>().having((e) => e.code, 'code', 'INVALID_ARGUMENT')));
      await expectLater(refine(cid, d, {'style': {'color': '#264653'}, 'attachment_id': 'a1'}),
          throwsA(isA<ApiError>().having((e) => e.code, 'code', 'INVALID_ARGUMENT')));
      // 言葉で直すにも添えられる（取り付け具はそのまま引き継ぐ）
      final n = await refine(cid, d, {'instruction': 'もう少しゆるく', 'attachment_id': 'a1'});
      expect(atts(n).length, 1);
      expect(coverKept(n), isFalse);
    });
  });

  group('S7 の決め方', () {
    final two = {
      'attachments': [
        {'id': 'a1', 'tool_type': 'pen', 'primary': true, 'angle_deg': 60, 'angle_source': 'ai'},
        {'id': 'a2', 'tool_type': 'spoon', 'primary': false, 'angle_deg': 70, 'angle_source': 'user'},
      ],
    };

    test('選ぶ取り付け具：あればそれ、なければ主', () {
      final l = viewAttachments(two, null);
      expect(selectAttachment(l, 'a2'), 'a2');
      expect(selectAttachment(l, 'a9'), 'a1');
      expect(selectAttachment(l, null), 'a1');
    });

    test('新しい版：足したものを選ぶ。それ以外は今の選択を保つ', () {
      final before = viewAttachments(two, null);
      final after = [...before, {'id': 'a3', 'tool_type': 'brush', 'primary': false}];
      expect(selectionAfter(before, after, 'a1'), 'a3');
      expect(selectionAfter(before, before, 'a2'), 'a2');
      expect(selectionAfter(before, [before[0]], 'a2'), 'a1'); // 外れたら主
    });

    test('古い版の呼び名は要求の道具から', () {
      final l = viewAttachments({'clip_angle_deg': 70, 'params': [
        {'part_id': 'c_clip', 'name': 'angle_deg', 'value': 70, 'source': 'ai'},
      ]}, {'tool_type': 'brush', 'tool_d_source': 'category'});
      expect(l.length, 1);
      expect(attachmentLabel(l[0], l), '筆');
      expect(l[0]['angle_source'], 'ai');
      expect(l[0]['tool_d_source'], 'category');
      expect(attachmentLabel(viewAttachments({}, null)[0], viewAttachments({}, null)), '道具');
    });

    test('本文に attachment_id を添えるのは、版が取り付け具の一覧を持つときだけ', () {
      expect(withAttachment({'clip_angle_deg': 80}, two, 'a2'), {'clip_angle_deg': 80, 'attachment_id': 'a2'});
      expect(withAttachment({'clip_angle_deg': 80}, {'params': []}, 'a1'), {'clip_angle_deg': 80});
      expect(withAttachment({'instruction': 'x'}, two, null), {'instruction': 'x'});
    });

    test('足せるか：4つまで（要求の道具の数も数える）', () {
      expect(addBlockedReason(two, {'tools': [{}, {}]}), isNull);
      expect(addBlockedReason(two, {'tools': [{}, {}, {}, {}]}), '取り付け具は4つまでです');
      expect(addBlockedReason({'attachments': List.filled(4, {'id': 'x'})}, null), '取り付け具は4つまでです');
      expect(addBlockedReason({}, null), isNull);
    });

    test('足す画面：平たいは知らせて押せない。太さは mm か区分', () {
      final t = newTool('spoon');
      expect(canSubmitTool(t), isFalse);
      t.shaftSize = 'unknown';
      expect(canSubmitTool(t), isFalse); // 形がまだ
      t.shaftShape = 'flat';
      expect(flatNotice(t), flatReason('spoon'));
      expect(flatReason('spoon'), 'スプーン：平たい柄はクリップで挟めません。太柄スポンジなどで丸くしてください');
      expect(canSubmitTool(t), isFalse);
      t.shaftShape = 'round';
      expect(flatNotice(t), isNull);
      expect(canSubmitTool(t), isTrue);
      expect(newTool('pen').activity, 'write');
      expect(newTool('brush').activity, 'draw');
      expect(newTool('spoon').activity, 'eat');
      // 太さを直すときは形を聞かない
      expect(canSubmitTool(ToolAnswer()..toolType = 'pen'..shaftSize = 'thin', fixOnly: true), isTrue);
    });

    test('太さの値：mm、なければ区分の目安、わからなければ道具の目安', () {
      expect(toolDOf(ToolAnswer()..toolDmm = 9.5), 9.5);
      expect(toolDOf(ToolAnswer()..shaftSize = 'thin'), 6.0);
      expect(toolDOf(ToolAnswer()..toolType = 'spoon'..shaftSize = 'unknown'), 11.5);
      expect(toolDOf(ToolAnswer()..toolType = 'pen'..shaftSize = 'unknown'), 8.5);
    });

    test('おすすめの角度：AIが選んだ角度を取り付け具ごとに覚える（前の版の分は残す）', () {
      expect(recommendedAngles(two, const {}), {'a1': 60});
      expect(recommendedAngles(two, const {'a1': 70, 'a2': 80}), {'a1': 70, 'a2': 80});
      expect(recommendedAngles({'params': [
        {'part_id': 'c_clip', 'name': 'angle_deg', 'value': 70, 'source': 'ai'},
      ]}, const {}), {'a1': 70});
    });

    test('カバーは前の版と同じか：足した・太さを直した版', () {
      expect(coverKept({'origin': 'refine_add_attachment'}), isTrue);
      expect(coverKept({'origin': 'refine_tool_d'}), isTrue);
      expect(coverKept({'origin': 'refine_text'}), isFalse);
      expect(coverKept({}), isFalse);
    });
  });
}
