import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jijogu_app/core/api/api_error.dart';
import 'package:jijogu_app/core/api/mock_backend.dart';
import 'package:jijogu_app/features/order/order_logic.dart';
import 'package:jijogu_app/features/order/print_choice.dart';

const umikaze = {
  'id': 'umikaze',
  'base_fee_yen': 800,
  'yen_per_gram': 20,
  'felt_service': true,
  'felt_fee_yen': 200,
};

void main() {
  group('発注の計算（設計 §6.2）', () {
    test('金額は Figma のモックと同じ', () {
      final g = {'cover': 18, 'c_clip': 4};
      expect(quoteOrder(umikaze, g, ['cover', 'c_clip'], 1, false), {
        'parts_yen': 1240,
        'felt_yen': 0,
        'total_yen': 1240,
      });
      expect(quoteOrder(umikaze, g, ['cover', 'c_clip'], 1, true)['total_yen'], 1440);
      expect(quoteOrder(umikaze, g, ['c_clip'], 2, false)['parts_yen'], 960);
      expect(yen(1440), '約1,440円');
      expect(yen(980), '約980円');
    });
    test('10円単位の四捨五入はサーバーと同じ', () {
      expect(round10(1234.9), 1230);
      expect(round10(1235), 1240);
    });
    test('重さと時間の表示', () {
      expect(gramsJa(17.6), '約18g');
      expect(minutesJa(40), '約40分');
      expect(minutesJa(118), '約2時間');
      expect(minutesJa(95), '約1時間30分');
    });
    test('状態の名前', () {
      expect(orderSteps, ['received', 'printing', 'shipped', 'delivered']);
      expect(orderStatusJa('received'), '受付');
      expect(orderStatusJa('printing'), '造形中');
      expect(orderStatusJa('shipped'), '発送済み');
      expect(orderStatusJa('delivered'), '受取済み');
      expect(orderStatusJa('cancelled'), '取り消し');
    });
    test('届く目安は発送日＋日数', () {
      final o = {'status': 'shipped', 'shipped_at': '2026-11-23T10:10:00Z'};
      expect(deliveryEstimate(o, 2)!.day, 25);
      expect(deliveryEstimate({'status': 'printing'}, 2), isNull);
    });
  });

  group('モックの裏側の発注', () {
    test('mock: 頼む → 造形中 → 発送 → 受け取った', () async {
      final m = MockBackend.instance;
      final cid = (await m.handle('POST', '/v1/cases', {'title': 't'}))['case_id'] as String;
      await m.handle('PUT', '/v1/cases/$cid/requirements', {
        'activity': 'draw',
        'tool_type': 'brush',
        'hand_side': 'right',
        'tool_d_mm': 9.5,
        'tool_shaft_shape': 'round',
      });
      final d = (await m.handle('POST', '/v1/cases/$cid/designs', {}))['design'] as Map;
      final did = d['design_id'] as String;
      await m.handle('POST', '/v1/cases/$cid/designs/$did/prepare-print', {});

      final f = await m.handle('GET', '/v1/cases/$cid/designs/$did/fabricators', null);
      expect([for (final x in f['fabricators'] as List) x['id']], ['umikaze', 'hoshizora', 'komorebi']);
      expect((f['estimates'] as Map)['cover']['grams'], 18);

      final keys = (d['files']?['print'] as Map?)?.keys.toList() ??
          ((await m.handle('GET', '/v1/cases/$cid/designs/$did', null))['design']['files']['print'] as Map).keys.toList();
      final o = (await m.handle('POST', '/v1/cases/$cid/designs/$did/orders', {
        'fabricator_id': 'umikaze',
        'print_keys': keys,
        'quantity': 1,
        'felt': true,
        'shipping': {'name': '見本', 'postal_code': '000-0000', 'address': '見本', 'phone': '000'},
      }))['order'] as Map;
      expect(o['status'], 'received');
      expect(o['price']['total_yen'], 1440);
      final oid = o['order_id'] as String;

      expect(((await m.handle('GET', '/v1/cases/$cid/orders', null))['orders'] as List).length, 1);
      expect((await m.handle('GET', '/v1/cases', null))['cases'].firstWhere((c) => c['case_id'] == cid)['latest_order'],
          {'order_id': oid, 'status': 'received'});
      expect(((await m.handle('GET', '/v1/fabricator/me', null))['fabricators'] as List).length, 3);
      expect(((await m.handle('GET', '/v1/fabricator/orders?fabricator_id=umikaze', null))['orders'] as List)
          .any((x) => x['order_id'] == oid), isTrue);

      var s = await m.handle('POST', '/v1/fabricator/orders/$oid/status', {'status': 'printing'});
      expect(s['order']['status'], 'printing');
      s = await m.handle('POST', '/v1/fabricator/orders/$oid/status', {'status': 'shipped'});
      expect(s['order']['status'], 'shipped');
      expect(s['order']['shipped_at'], isNotNull);
      s = await m.handle('POST', '/v1/orders/$oid/delivered', {});
      expect(s['order']['status'], 'delivered');
      expect(
        () => m.handle('POST', '/v1/orders/$oid/cancel', {}),
        throwsA(isA<ApiError>().having((e) => e.code, 'code', 'CONFLICT')),
      );
    });
  });

  group('最後のレビューで見つかった点', () {
    test('この版の注文と、前の版の進行中の注文を分ける', () {
      final orders = [
        {'order_id': 'o3', 'design_id': 'd2', 'status': 'received'},
        {'order_id': 'o2', 'design_id': 'd1', 'status': 'printing'},
        {'order_id': 'o1', 'design_id': 'd1', 'status': 'delivered'},
        {'order_id': 'o0', 'design_id': 'd0', 'status': 'cancelled'},
      ];
      final (mine, otherLive) = splitOrders(orders, 'd2');
      expect([for (final o in mine) o['order_id']], ['o3']);
      expect([for (final o in otherLive) o['order_id']], ['o2']);
    });
    testWidgets('頼めないときは「刷ってもらう」を押せず、理由を出す', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PrintChoice(
            onOrder: null,
            onSelfPrint: () {},
            fabricators: null,
            unavailableReason: '形が新しくなっています。今の版の画面から頼んでください',
          ),
        ),
      ));
      expect(find.textContaining('今の版の画面から頼んでください'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right_rounded), findsNothing); // 「刷ってもらう」は押せない
      expect(find.byIcon(Icons.expand_more_rounded), findsOneWidget); // 押せるのは「自分で刷る」だけ
    });
    test('mock: 受託者にはOTのメールを見せない', () async {
      final m = MockBackend.instance;
      final cid = (await m.handle('POST', '/v1/cases', {'title': 't'}))['case_id'] as String;
      await m.handle('PUT', '/v1/cases/$cid/requirements', {
        'activity': 'draw', 'tool_type': 'brush', 'hand_side': 'right', 'tool_d_mm': 9.5, 'tool_shaft_shape': 'round',
      });
      final did = ((await m.handle('POST', '/v1/cases/$cid/designs', {}))['design'] as Map)['design_id'] as String;
      await m.handle('POST', '/v1/cases/$cid/review-request', {'reviewer_email': 'ot@example.com', 'design_id': did});
      await m.handle('POST', '/v1/cases/$cid/designs/$did/approval', {'decision': 'approve'});
      final o = (await m.handle('POST', '/v1/cases/$cid/designs/$did/orders', {
        'fabricator_id': 'umikaze', 'print_keys': ['cover'], 'quantity': 1, 'felt': false,
        'shipping': {'name': '見本', 'postal_code': '000', 'address': '見本', 'phone': '000'},
      }))['order'] as Map;
      final v = (await m.handle('GET', '/v1/fabricator/orders/${o['order_id']}', null))['order'] as Map;
      expect(v['approval']['kind'], 'ot');
      expect((v['approval'] as Map).containsKey('reviewer_email'), isFalse);
      expect('$v'.contains('ot@example.com'), isFalse);
    });
  });

  group('自分で刷る（開いて、もう一度押すと閉じる）', () {
    Widget choice(bool open, VoidCallback onSelf) => MaterialApp(
      home: Scaffold(
        body: PrintChoice(onOrder: () {}, onSelfPrint: onSelf, fabricators: null, selfPrintOpen: open),
      ),
    );
    testWidgets('閉じているときは下向き、開いているときは上向きの矢印（説明の文は変えない）', (tester) async {
      await tester.pumpWidget(choice(false, () {}));
      expect(find.byIcon(Icons.expand_more_rounded), findsOneWidget);
      expect(find.byIcon(Icons.expand_less_rounded), findsNothing);
      await tester.pumpWidget(choice(true, () {}));
      expect(find.byIcon(Icons.expand_less_rounded), findsOneWidget);
      expect(find.textContaining('もう一度押すと閉じます'), findsNothing); // 矢印の向きだけで伝える
      expect(find.text('印刷用のファイル（STL）をダウンロードします'), findsOneWidget);
    });
    testWidgets('押すたびに呼ばれる', (tester) async {
      var n = 0;
      await tester.pumpWidget(choice(false, () => n++));
      await tester.tap(find.text('自分で刷る'));
      await tester.tap(find.text('自分で刷る'));
      expect(n, 2);
    });
  });
}
