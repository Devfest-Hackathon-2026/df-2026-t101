import 'package:flutter_test/flutter_test.dart';
import 'package:jijogu_app/core/api/mock_backend.dart';

/// OTのホームの「確認を頼まれているケース」（GET /v1/reviews）のモック
void main() {
  Future<(String, String)> designed(MockBackend m, String title) async {
    final cid = (await m.handle('POST', '/v1/cases', {'title': title}))['case_id'] as String;
    await m.handle('PUT', '/v1/cases/$cid/requirements', {
      'activity': 'draw',
      'tool_type': 'brush',
      'hand_side': 'right',
      'tool_d_mm': 9.5,
      'tool_shaft_shape': 'round',
    });
    final d = (await m.handle('POST', '/v1/cases/$cid/designs', {}))['design'] as Map;
    return (cid, d['design_id'] as String);
  }

  List<Map> reviewsOf(dynamic r) => [for (final x in r['reviews'] as List) x as Map];

  test('mock: 頼んだケースが確認待ちで出て、差し戻すと確認待ちの後ろに回る', () async {
    final m = MockBackend.instance;
    final (c1, d1) = await designed(m, '依頼1');
    final (c2, d2) = await designed(m, '依頼2');
    await m.handle('POST', '/v1/cases/$c1/review-request',
        {'reviewer_email': 'ot.demo@example.com', 'design_id': d1, 'message_ja': '角を見てください'});
    await m.handle('POST', '/v1/cases/$c2/review-request',
        {'reviewer_email': 'ot.demo@example.com', 'design_id': d2, 'message_ja': ''});

    var list = reviewsOf(await m.handle('GET', '/v1/reviews', null));
    final r1 = list.firstWhere((x) => x['case_id'] == c1);
    expect(r1['approval_status'], 'requested');
    expect(r1['message_ja'], '角を見てください');
    expect(r1['requested_at'], isNotNull);
    expect(r1['design_id'], d1);

    await m.handle('POST', '/v1/cases/$c1/designs/$d1/approval', {'decision': 'reject', 'comment_ja': '丸く'});
    list = reviewsOf(await m.handle('GET', '/v1/reviews', null));
    final ids = [for (final x in list) x['case_id']];
    expect(ids.indexOf(c2), lessThan(ids.indexOf(c1)), reason: '確認待ちが先');
    final after = list.firstWhere((x) => x['case_id'] == c1);
    expect(after['approval_status'], 'rejected');
    expect(after['decided_at'], isNotNull);
    expect(after['message_ja'], '角を見てください', reason: '差し戻しても依頼のひとことは残る');
  });

  test('mock: 頼んでいないケースは出ない', () async {
    final m = MockBackend.instance;
    final (c, _) = await designed(m, '頼んでいない');
    final list = reviewsOf(await m.handle('GET', '/v1/reviews', null));
    expect(list.any((x) => x['case_id'] == c), isFalse);
  });
}
