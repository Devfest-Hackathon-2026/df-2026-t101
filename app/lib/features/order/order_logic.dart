/// 発注の計算と表示（docs/superpowers/specs/2026-11-21-in-app-ordering-design.md §6.2）。
/// 金額の式は生成APIの app/fabrication.py と同じ。画面ではこれでその場で計算し、保存する値はサーバーが計算し直す
library;

const fictionalNotice = 'デモ用の架空の受託者です。実在の会社ではありません。';

/// 10円単位の四捨五入（サーバーの round10 と同じ）
int round10(num yen) => ((yen / 10) + 0.5).floor() * 10;

/// 金額の目安：parts = 基本料 + 1gあたり × 選んだ部品の重さの合計 × 個数、felt = フェルト料 × 個数
Map<String, int> quoteOrder(
  Map<String, dynamic> fab,
  Map<String, num> grams,
  List<String> keys,
  int quantity,
  bool felt,
) {
  final g = keys.fold<num>(0, (s, k) => s + (grams[k] ?? 0));
  final parts = round10((fab['base_fee_yen'] as num) + (fab['yen_per_gram'] as num) * g * quantity);
  final feltYen = felt ? round10((fab['felt_fee_yen'] as num) * quantity) : 0;
  return {'parts_yen': parts, 'felt_yen': feltYen, 'total_yen': parts + feltYen};
}

String _comma(int v) {
  final s = v.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

String yen(int v) => '約${_comma(v)}円';

String gramsJa(num g) => '約${g.round()}g';

/// 60分未満は5分単位なしでそのまま（約40分）、それ以上は30分単位（約2時間、約1時間30分）
String minutesJa(num m) {
  if (m < 60) return '約${m.round()}分';
  final half = (m / 30).round() * 30;
  final h = half ~/ 60;
  final rest = half % 60;
  return rest == 0 ? '約$h時間' : '約$h時間$rest分';
}

const orderSteps = ['received', 'printing', 'shipped', 'delivered'];

String orderStatusJa(String? s) => switch (s) {
  'received' => '受付',
  'printing' => '造形中',
  'shipped' => '発送済み',
  'delivered' => '受け取った',
  'cancelled' => '取り消し',
  _ => '',
};

/// 届く目安：発送日＋日数（未発送なら null）
DateTime? deliveryEstimate(Map<String, dynamic> order, int daysAfterShip) {
  final s = order['shipped_at'];
  if (s == null) return null;
  final t = DateTime.tryParse('$s');
  return t?.toLocal().add(Duration(days: daysAfterShip));
}

/// 11/22 14:05 の形
String shortTime(Object? iso) {
  final t = iso == null ? null : DateTime.tryParse('$iso')?.toLocal();
  if (t == null) return '';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.month}/${t.day} ${two(t.hour)}:${two(t.minute)}';
}

/// 11/25 の形
String shortDate(DateTime? t) => t == null ? '' : '${t.month}/${t.day}';

/// S10 で出す注文を分ける：この版の注文（新しい順のまま）と、前の版の進行中の注文。
/// 前の版の注文も、取り消し・受け取ったを押せるようにするため（版を作り直すと、前の版の S10 には戻れない）
(List<Map<String, dynamic>>, List<Map<String, dynamic>>) splitOrders(
  List<Map<String, dynamic>> orders,
  String designId,
) {
  const live = {'received', 'printing', 'shipped'};
  return (
    [for (final o in orders) if (o['design_id'] == designId) o],
    [for (final o in orders) if (o['design_id'] != designId && live.contains(o['status'])) o],
  );
}
