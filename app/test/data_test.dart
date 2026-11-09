import 'package:flutter_test/flutter_test.dart';
import 'package:jijogu_app/data/api_error.dart';
import 'package:jijogu_app/data/attachments.dart';
import 'package:jijogu_app/data/mock_backend.dart';
import 'package:jijogu_app/data/requirements.dart';
import 'package:jijogu_app/paths.dart';

void main() {
  group('選択式の答え（api.md §3.2 の名前）', () {
    test('mmで入れたときは tool_d_mm を送り、区分は送らない', () {
      final a = Answers()
        ..activity = 'draw'
        ..toolType = 'brush'
        ..handSide = 'right'
        ..toolDmm = 9.5
        ..shaftSize = 'medium'
        ..shaftShape = 'round'
        ..donningBy = 'helper'
        ..fingerState = 'fist'
        ..captureBy = 'helper';
      final j = a.toJson();
      expect(j['tool_d_mm'], 9.5);
      expect(j['tool_shaft_size'], isNull);
      expect(j['donning_by'], 'helper');
      expect(j['finger_state'], 'fist');
      expect(j.containsKey('nut_operator'), isFalse);
    });
    test('区分を選んだときは tool_shaft_size だけを送る', () {
      final a = Answers()..shaftSize = 'thick';
      expect(a.toJson()['tool_d_mm'], isNull);
      expect(a.toJson()['tool_shaft_size'], 'thick');
      expect(a.isAnswered(2), isTrue);
    });
    test('保存済みの答えを戻す（mmで入れたとき）', () {
      final a = Answers()
        ..loadFrom({
          'activity': 'draw', 'tool_type': 'brush', 'hand_side': 'left',
          'tool_d_mm': 9.5, 'tool_d_source': 'user', 'tool_shaft_size': null,
          'tool_shaft_shape': 'round', 'donning_by': 'helper',
          'finger_state': 'fist', 'capture_by': 'self', 'notes': ['筆は細め'],
        });
      expect(a.toolDmm, 9.5);
      expect(a.shaftSize, isNull);
      expect(a.handSide, 'left');
      expect(a.isComplete, isTrue);
    });
    test('区分で答えたときは、サーバーが入れた目安の mm ではなく区分として戻す', () {
      final a = Answers()
        ..loadFrom({
          'tool_d_mm': 11.5, 'tool_d_source': 'category', 'tool_shaft_size': 'thick',
        });
      expect(a.toolDmm, isNull);
      expect(a.shaftSize, 'thick');
      expect(a.toJson()['tool_shaft_size'], 'thick');
      expect(a.isComplete, isFalse);
    });
  });

  group('道具の一覧と取り付け具', () {
    test('読むだけでは tools を作らない', () {
      final a = Answers();
      expect(a.activity, isNull);
      expect(a.toolDmm, isNull);
      expect(a.primary.toolType, isNull);
      expect(a.tools, isEmpty);
      expect(a.isAnswered(0), isFalse);
    });
    test('activity がない道具は Q0 の答えにならない', () {
      final a = Answers()..shaftShape = 'round';
      expect(a.tools.length, 1);
      expect(a.isAnswered(0), isFalse);
      a.activity = 'draw';
      expect(a.isAnswered(0), isTrue);
    });
    test('道具を2つ選ぶと tools と主な道具の項目を送る', () {
      final a = Answers()
        ..tools = [ToolAnswer()..activity = 'eat'..toolType = 'spoon'..toolDmm = 10..shaftShape = 'flat',
                   ToolAnswer()..activity = 'write'..toolType = 'pen'..shaftSize = 'thin'..shaftShape = 'round'];
      final j = a.toJson();
      expect((j['tools'] as List).length, 2);
      expect(j['tool_type'], 'pen');
      expect(j['tool_shaft_size'], 'thin');
      expect(j['tool_d_mm'], isNull);
      expect((j['tools'] as List)[0].keys.toSet(),
          {'activity', 'tool_type', 'tool_d_mm', 'tool_shaft_size', 'tool_shaft_shape'});
    });
    test('保存済みの tools を順番どおりに戻す', () {
      final a = Answers()..loadFrom({'tools': [
        {'activity': 'draw', 'tool_type': 'brush', 'tool_d_mm': 9.5, 'tool_d_source': 'user', 'tool_shaft_shape': 'round'},
        {'activity': 'eat', 'tool_type': 'spoon', 'tool_d_mm': 11.5, 'tool_d_source': 'category', 'tool_shaft_size': 'thick', 'tool_shaft_shape': 'round'}]});
      expect(a.tools.map((t) => t.toolType), ['brush', 'spoon']);
      expect(a.tools[1].toolDmm, isNull);
      expect(a.tools[1].shaftSize, 'thick');
    });
    test('古い版は取り付け具1つとして読む', () {
      final atts = attachmentsOf({'params': [{'part_id': 'c_clip', 'name': 'angle_deg', 'value': 70},
                                             {'part_id': 'c_clip', 'name': 'tool_d_mm', 'value': 9.5}],
                                  'files': {'parts': {'c_clip': {'preview_stl': 'x/c_clip_70.preview.stl'}}}, 'clip_angle_deg': 70});
      expect(atts.length, 1);
      expect(atts[0]['angle_deg'], 70);
      expect(atts[0]['files']['preview_stl'], 'x/c_clip_70.preview.stl');
      expect(atts[0]['print_key'], 'c_clip');
      expect(atts[0].containsKey('tool'), isTrue);
    });
    test('古い版の tool を取り付け具に載せる', () {
      final atts = attachmentsOf({'tool': {'type': 'pen'}, 'clip_angle_deg': 60});
      expect(atts[0]['tool'], {'type': 'pen'});
    });
    test('呼び名：同じ道具があるときだけ太さを付ける', () {
      final all = [
        {'id': 'a1', 'tool_type': 'pen', 'tool_d_mm': 12},
        {'id': 'a2', 'tool_type': 'pen', 'tool_d_mm': 8.5},
        {'id': 'a3', 'tool_type': 'brush', 'tool_d_mm': 8.0},
      ];
      expect(attachmentLabel(all[0], all), 'ペン 12mm');
      expect(attachmentLabel(all[1], all), 'ペン 8.5mm');
      expect(attachmentLabel(all[2], all), '筆');
    });
  });

  group('聞き取りで道具を複数選ぶ（S2）', () {
    test('チャットの提案は主な道具に当たる', () {
      final a = Answers()
        ..tools = [ToolAnswer()..toolType = 'spoon'..shaftShape = 'flat', ToolAnswer()..toolType = 'pen'..shaftShape = 'round'];
      a.toolDmm = 9.0;                 // _applySuggestion が使うセッター
      expect(a.primary.toolType, 'pen');
      expect(a.primary.toolDmm, 9.0);
    });
    test('今までの項目は主な道具を読む', () {
      final a = Answers()
        ..tools = [ToolAnswer()..activity = 'eat'..shaftShape = 'flat', ToolAnswer()..activity = 'write'..shaftShape = 'round'];
      expect(a.activity, 'write');
      a.shaftShape = 'flat'; // 主な道具（ペン）を平たいにすると、丸い柄がなくなり最初が主になる
      expect(a.tools[1].shaftShape, 'flat');
      expect(a.activity, 'eat');
    });
    test('道具が空のときもセッターは1つ作る', () {
      final a = Answers()..toolDmm = 7.5;
      expect(a.tools.length, 1);
      expect(a.toolDmm, 7.5);
    });
    test('質問1は押すたびに選ぶ／外す（選んだ順を保つ）', () {
      final a = Answers();
      a.toggleActivity('write');
      a.toggleActivity('eat');
      expect(a.tools.map((t) => (t.activity, t.toolType)), [('write', 'pen'), ('eat', 'spoon')]);
      a.toggleActivity('write');
      expect(a.tools.map((t) => t.activity), ['eat']);
      a.toggleActivity('other');
      a.toggleActivity('draw');
      expect(a.tools.map((t) => (t.activity, t.toolType)),
          [('eat', 'spoon'), ('other', 'brush'), ('draw', 'brush')]);
      expect(a.hasActivity('other'), isTrue);
      expect(a.hasActivity('write'), isFalse);
    });
  });

  group('質問の並びと進み具合（S2a）', () {
    test('道具が0・1つなら7問、2つなら9問', () {
      expect(interviewTotal(0), 7);
      expect(interviewTotal(1), 7);
      expect(interviewTotal(2), 9);
    });
    test('道具がないときは質問3・4の段を作らない（番号がはみ出さない）', () {
      expect(interviewSteps(0), [(0, 0), (1, 0), (4, 0), (5, 0), (6, 0)]);
      expect(interviewSteps(2),
          [(0, 0), (1, 0), (2, 0), (3, 0), (2, 1), (3, 1), (4, 0), (5, 0), (6, 0)]);
    });
  });

  group('モックの PUT requirements（道具の一覧）', () {
    Future<String> newCase() async =>
        (await MockBackend.instance.handle('POST', '/v1/cases', {'title': 't'}))['case_id'] as String;

    test('道具2つ：tools を正規化して保存し、今までの項目は主な道具', () async {
      final id = await newCase();
      final a = Answers()
        ..tools = [
          ToolAnswer()..activity = 'eat'..toolType = 'spoon'..shaftSize = 'unknown'..shaftShape = 'flat',
          ToolAnswer()..activity = 'write'..toolType = 'pen'..shaftSize = 'thin'..shaftShape = 'round',
        ]
        ..handSide = 'right'..donningBy = 'self'..fingerState = 'fist'..captureBy = 'helper';
      final res = await MockBackend.instance.handle('PUT', '/v1/cases/$id/requirements', a.toJson());
      final r = Map<String, dynamic>.from(res['requirements'] as Map);
      final tools = [for (final t in r['tools'] as List) Map<String, dynamic>.from(t as Map)];
      expect(tools.length, 2);
      expect(tools[0]['tool_d_mm'], 11.5); // わからない → スプーンの目安
      expect(tools[0]['tool_d_source'], 'category');
      expect(tools[1]['tool_d_mm'], 6.0); // 細い
      expect(tools[1]['tool_d_source'], 'category');
      expect(r['tool_type'], 'pen');
      expect(r['activity'], 'write');
      expect(r['tool_d_mm'], 6.0);
      expect(r['tool_shaft_size'], 'thin');
      expect(r['tool_shaft_shape'], 'round');
      // 開き直すと、道具の順と区分が戻る
      final c = await MockBackend.instance.handle('GET', '/v1/cases/$id', null);
      final b = Answers()..loadFrom(Map<String, dynamic>.from(c['requirements'] as Map));
      expect(b.tools.map((t) => t.toolType), ['spoon', 'pen']);
      expect(b.tools[0].shaftSize, 'unknown');
      expect(b.tools[1].shaftSize, 'thin');
      expect(b.tools[1].toolDmm, isNull);
      expect(b.isComplete, isTrue);
    });

    test('道具1つ：今と同じ項目を返し、tools は1件', () async {
      final id = await newCase();
      final a = Answers()
        ..activity = 'draw'..toolType = 'brush'..toolDmm = 9.5..shaftShape = 'round'
        ..handSide = 'left'..donningBy = 'helper'..fingerState = 'bent'..captureBy = 'self';
      final res = await MockBackend.instance.handle('PUT', '/v1/cases/$id/requirements', a.toJson());
      final r = Map<String, dynamic>.from(res['requirements'] as Map);
      expect(res['case_status'], 'measuring');
      expect((r['tools'] as List).length, 1);
      expect((r['tools'] as List)[0]['tool_d_source'], 'user');
      expect(r['tool_d_mm'], 9.5);
      expect(r['tool_d_source'], 'user');
      expect(r['tool_type'], 'brush');
      expect(r['hand_side'], 'left');
      expect(r['assumptions'], isEmpty);
    });

    test('tools のない古い形の本文も1つの道具として扱う', () async {
      final id = await newCase();
      final res = await MockBackend.instance.handle('PUT', '/v1/cases/$id/requirements', {
        'activity': 'eat', 'tool_type': 'spoon', 'tool_d_mm': null,
        'tool_shaft_size': 'unknown', 'tool_shaft_shape': 'round', 'hand_side': 'right',
      });
      final r = Map<String, dynamic>.from(res['requirements'] as Map);
      expect((r['tools'] as List).length, 1);
      expect(r['tool_d_mm'], 11.5);
      expect(r['tool_d_source'], 'category');
      expect(r['assumptions'], isNotEmpty);
    });
  });

  group('APIのエラー（api.md §5）', () {
    test('error の形を ApiError にする', () {
      expect(
        () => parseApiBody(
          422,
          '{"error":{"code":"MEASUREMENT_INVALID","message":"範囲外です","retryable":false}}',
        ),
        throwsA(
          isA<ApiError>()
              .having((e) => e.code, 'code', 'MEASUREMENT_INVALID')
              .having((e) => e.retryable, 'retryable', false),
        ),
      );
    });
    test('FastAPI の detail に包まれた error も読む', () {
      expect(
        () => parseApiBody(
          503,
          '{"detail":{"error":{"code":"AI_UNAVAILABLE","message":"混雑","retryable":true}}}',
        ),
        throwsA(
          isA<ApiError>()
              .having((e) => e.code, 'code', 'AI_UNAVAILABLE')
              .having((e) => e.retryable, 'retryable', true),
        ),
      );
    });
    test('JSONでない本文でも落ちない', () {
      expect(
        () => parseApiBody(500, 'Internal Server Error'),
        throwsA(isA<ApiError>()),
      );
      expect(parseApiBody(200, '{"ok":true}'), {'ok': true});
    });
  });

  test('続きの画面（screens.md §1）', () {
    expect(
      continueRoute({'case_id': 'c1', 'status': 'interviewing'}),
      '/cases/c1/interview',
    );
    expect(
      continueRoute({'case_id': 'c1', 'status': 'measuring'}),
      '/cases/c1/capture',
    );
    expect(
      continueRoute({'case_id': 'c1', 'status': 'designing'}),
      '/cases/c1/designs/new',
    );
    expect(
      continueRoute({
        'case_id': 'c1',
        'status': 'approved',
        'current_design_id': 'd2',
      }),
      '/cases/c1/designs/d2/print',
    );
  });
}
