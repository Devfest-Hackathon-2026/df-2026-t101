import 'package:flutter_test/flutter_test.dart';
import 'package:jijogu_app/data/api_error.dart';
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
