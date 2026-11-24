import 'package:flutter/material.dart';

import 'package:jijogu_app/core/api/api.dart';
import 'package:jijogu_app/core/ui/ui.dart';
import 'package:jijogu_app/features/order/order_logic.dart';
import 'package:jijogu_app/features/order/order_widgets.dart';

/// 注文の内容（Figma 3。設計 §5.2・§6.4）。頼めたら true を返して戻る
class OrderFormScreen extends StatefulWidget {
  const OrderFormScreen({super.key, required this.caseId, required this.designId, required this.fabricatorId});
  final String caseId;
  final String designId;
  final String fabricatorId;
  @override
  State<OrderFormScreen> createState() => _OrderFormScreenState();
}

class _OrderFormScreenState extends State<OrderFormScreen> {
  Map<String, dynamic>? _data;
  Map<String, dynamic>? _fab;
  bool _demo = false;
  String? _error;
  bool _busy = false;
  final _keys = <String>{};
  int _qty = 1;
  bool _felt = false;
  final _name = TextEditingController();
  final _postal = TextEditingController();
  final _address = TextEditingController();
  final _phone = TextEditingController();

  @override
  void initState() {
    super.initState();
    for (final c in [_name, _postal, _address, _phone]) {
      c.addListener(() => setState(() {}));
    }
    _load();
  }

  @override
  void dispose() {
    for (final c in [_name, _postal, _address, _phone]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final c = await Api.instance.get('/v1/cases/${widget.caseId}');
      final r = Map<String, dynamic>.from(
        await Api.instance.get('/v1/cases/${widget.caseId}/designs/${widget.designId}/fabricators') as Map,
      );
      final fab = (r['fabricators'] as List).map((f) => Map<String, dynamic>.from(f as Map)).firstWhere(
        (f) => f['id'] == widget.fabricatorId,
        orElse: () => <String, dynamic>{},
      );
      if (!mounted) return;
      setState(() {
        _demo = c['demo'] == true;
        _data = r;
        _fab = fab.isEmpty ? null : fab;
        _keys
          ..clear()
          ..addAll(Map<String, dynamic>.from(r['estimates'] as Map).keys);
        _felt = fab['felt_service'] == true;
        if (_fab == null) _error = '受託者が見つかりませんでした';
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Map<String, num> get _grams => {
    for (final e in Map<String, dynamic>.from(_data?['estimates'] ?? {}).entries) e.key: e.value['grams'] as num,
  };

  bool get _hasCover => _keys.contains('cover');
  bool get _feltOn => _felt && _hasCover && _fab?['felt_service'] == true;

  bool get _canSubmit =>
      !_busy &&
      _fab != null &&
      _keys.isNotEmpty &&
      [_name, _postal, _address, _phone].every((c) => c.text.trim().isNotEmpty);

  List<String> get _orderedKeys => [
    for (final k in Map<String, dynamic>.from(_data?['estimates'] ?? {}).keys)
      if (_keys.contains(k)) k,
  ];

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() => _busy = true);
    try {
      await Api.instance.post('/v1/cases/${widget.caseId}/designs/${widget.designId}/orders', {
        'fabricator_id': widget.fabricatorId,
        'print_keys': _orderedKeys,
        'quantity': _qty,
        'felt': _feltOn,
        'shipping': {
          'name': _name.text.trim(),
          'postal_code': _postal.text.trim(),
          'address': _address.text.trim(),
          'phone': _phone.text.trim(),
        },
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final fab = _fab;
    final names = Map<String, dynamic>.from(d?['names'] ?? {});
    final materials = Map<String, dynamic>.from(d?['materials'] ?? {});
    final q = fab == null ? null : quoteOrder(fab, _grams, _orderedKeys, _qty, _feltOn);
    final matLine = {for (final k in _orderedKeys) '${materials[k]}（${names[k]}）'}.join('・');
    return AppPage(
      title: fab == null ? '注文の内容' : '${fab['name']}に頼む',
      bottom: FilledButton(
        onPressed: _canSubmit ? _submit : null,
        child: Text(_busy ? '送っています' : 'この内容で頼む'),
      ),
      children: [
        if (_demo) const DemoBanner(),
        const InfoCard(tone: NoticeTone.warning, child: Text(fictionalNotice)),
        if (_error != null) ErrorCard(message: _error!, onRetry: _load),
        if (d == null && _error == null) const BusyCard(text: '読み込んでいます'),
        if (d != null && fab != null) ...[
          const OrderHeading(icon: Icons.check_box_rounded, text: '刷る部品'),
          for (final k in Map<String, dynamic>.from(d['estimates'] as Map).keys)
            ChoiceButton(
              label: '${names[k] ?? k}',
              sub: '${materials[k] ?? ''}・${gramsJa(_grams[k] ?? 0)}',
              selected: _keys.contains(k),
              multi: true,
              onTap: () => setState(() => _keys.contains(k) ? _keys.remove(k) : _keys.add(k)),
            ),
          const OrderHeading(icon: Icons.tag_rounded, text: '個数'),
          OrderPanel(
            child: Row(
              children: [
                Expanded(child: Text('同じものをいくつ刷るか', style: AppText.bodyLarge)),
                IconButton.outlined(
                  tooltip: '1つ減らす',
                  onPressed: _qty > 1 ? () => setState(() => _qty--) : null,
                  icon: const Icon(Icons.remove_rounded),
                ),
                SizedBox(
                  width: 40,
                  child: Text('$_qty', textAlign: TextAlign.center, style: AppText.headlineSmall),
                ),
                IconButton.filledTonal(
                  tooltip: '1つ増やす',
                  onPressed: _qty < 3 ? () => setState(() => _qty++) : null,
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ),
          ),
          if (fab['felt_service'] == true) ...[
            const OrderHeading(icon: Icons.layers_rounded, text: 'フェルト'),
            ChoiceButton(
              label: 'フェルトを貼って送ってもらう（+${fab['felt_fee_yen']}円）',
              sub: _hasCover
                  ? '届いたらそのまま着けられます。厚さ${d['felt']?['thickness_mm'] ?? 1}mm'
                  : 'カバーを選ぶと選べます',
              selected: _feltOn,
              multi: true,
              onTap: () {
                if (_hasCover) setState(() => _felt = !_felt);
              },
            ),
          ],
          const OrderHeading(icon: Icons.lock_rounded, text: '材料と機種'),
          OrderPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (matLine.isNotEmpty) IconLine(icon: Icons.category_rounded, text: '材料：$matLine'),
                ...printerLines(Map<String, dynamic>.from(d['printer'] ?? {})),
                ColorLine(color: Map<String, dynamic>.from(d['color'] ?? {})),
                const SizedBox(height: 4),
                Text('アプリが決めた値です。変えられません。', style: AppText.supporting),
              ],
            ),
          ),
          const OrderHeading(icon: Icons.home_rounded, text: '届け先'),
          _field(_name, 'お名前', TextInputType.name),
          _field(_postal, '郵便番号', TextInputType.phone),
          _field(_address, '住所', TextInputType.streetAddress),
          _field(_phone, '電話番号', TextInputType.phone),
          if (q != null)
            OrderPanel(
              color: AppColors.secondaryContainer,
              child: DefaultTextStyle.merge(
                style: const TextStyle(color: AppColors.onSecondaryContainer),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Expanded(child: Text('合計', style: AppText.titleMedium)),
                        Text(yen(q['total_yen']!), style: AppText.headlineSmall),
                      ],
                    ),
                    Text(
                      '部品 ${yen(q['parts_yen']!)}${_feltOn ? ' ＋ フェルト ${q['felt_yen']}円' : ''}（目安）',
                      style: AppText.bodyMedium,
                    ),
                    const SizedBox(height: 4),
                    IconLine(icon: Icons.local_shipping_rounded, text: '発送まで${fab['lead_days']}日'),
                    IconLine(
                      icon: Icons.info_outline_rounded,
                      text: '支払いの画面はありません（デモ）',
                      style: AppText.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _field(TextEditingController c, String label, TextInputType type) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: TextField(
      controller: c,
      keyboardType: type,
      decoration: InputDecoration(labelText: label),
    ),
  );
}
