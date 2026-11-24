import 'package:flutter/material.dart';

import 'package:jijogu_app/core/api/api.dart';
import 'package:jijogu_app/core/ui/ui.dart';
import 'package:jijogu_app/features/fabricator/api_download.dart';
import 'package:jijogu_app/features/order/order_logic.dart';
import 'package:jijogu_app/features/order/order_status_card.dart';
import 'package:jijogu_app/features/order/order_widgets.dart';

/// 注文の詳細（受託する側。Figma 5。設計 §5.3）。見せるのは注文の中身だけ（手の3D・採寸・聞き取りは見せない）
class FabricatorOrderScreen extends StatefulWidget {
  const FabricatorOrderScreen({super.key, required this.orderId});
  final String orderId;
  @override
  State<FabricatorOrderScreen> createState() => _FabricatorOrderScreenState();
}

class _FabricatorOrderScreenState extends State<FabricatorOrderScreen> {
  Map<String, dynamic>? _order;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await Api.instance.get('/v1/fabricator/orders/${widget.orderId}');
      if (mounted) setState(() => _order = Map<String, dynamic>.from(r['order'] as Map));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _setStatus(String to) async {
    setState(() => _busy = true);
    try {
      final r = await Api.instance.post('/v1/fabricator/orders/${widget.orderId}/status', {'status': to});
      if (mounted) setState(() => _order = Map<String, dynamic>.from(r['order'] as Map));
    } catch (e) {
      if (mounted) showError(context, e);
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download(Map<String, dynamic> item) async {
    final key = '${item['print_key']}';
    try {
      await downloadFromApi(
        '/v1/fabricator/orders/${widget.orderId}/files/$key',
        '$key.stl',
        mockPath: item['path'] as String?,
      );
    } catch (e) {
      if (mounted) showError(context, 'ダウンロードできませんでした。もう一度試してください。（$e）');
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = _order;
    final status = '${o?['status'] ?? ''}';
    final items = [for (final i in (o?['items'] as List? ?? const [])) Map<String, dynamic>.from(i as Map)];
    final ap = Map<String, dynamic>.from(o?['approval'] ?? {});
    final ship = Map<String, dynamic>.from(o?['shipping'] ?? {});
    final Widget? bottom = switch (status) {
      'received' => FilledButton.icon(
        onPressed: _busy ? null : () => _setStatus('printing'),
        icon: const Icon(Icons.play_arrow_rounded),
        label: const Text('造形を始める'),
      ),
      'printing' => FilledButton.icon(
        onPressed: _busy ? null : () => _setStatus('shipped'),
        icon: const Icon(Icons.local_shipping_rounded),
        label: const Text('発送した'),
      ),
      _ => null,
    };
    return AppPage(
      title: o == null ? '注文' : '注文 #${o['display_id']}',
      bottom: bottom,
      children: [
        if (_error != null) ErrorCard(message: '読み込めませんでした（$_error）', onRetry: _load),
        if (o == null && _error == null) const BusyCard(text: '読み込んでいます'),
        if (o != null) ...[
          Row(
            children: [
              StatusLabel(label: orderStatusJa(status), tone: OrderStatusCard.toneOf(status)),
              const SizedBox(width: 8),
              Expanded(child: Text('${shortTime(o['created_at'])} に届いた注文', style: AppText.supporting)),
            ],
          ),
          const SizedBox(height: 8),
          InfoCard(
            tone: ap['kind'] == 'ot' ? NoticeTone.success : NoticeTone.warning,
            child: Text(
              ap['kind'] == 'ot'
                  ? 'OTの確認：済み（${shortTime(ap['decided_at'])}）'
                  : 'デモ：OTの確認を省略しています',
            ),
          ),
          const OrderHeading(icon: Icons.view_in_ar_rounded, text: '刷る部品'),
          for (final it in items)
            OrderPanel(
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${it['name_ja']} ×${o['quantity']}', style: AppText.titleMedium),
                        const SizedBox(height: 4),
                        StatusLabel(label: '${it['material']}'),
                        const SizedBox(height: 4),
                        Text(
                          '${it['print_key']}.stl ・ ${gramsJa((it['grams'] as num?) ?? 0)}・${minutesJa((it['minutes'] as num?) ?? 0)}',
                          style: AppText.supporting,
                        ),
                      ],
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: '${it['name_ja']}をダウンロード',
                    onPressed: status == 'cancelled' ? null : () => _download(it),
                    icon: const Icon(Icons.download_rounded),
                  ),
                ],
              ),
            ),
          if (status != 'cancelled')
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: FilledButton.tonalIcon(
                onPressed: () async {
                  for (final it in items) {
                    await _download(it);
                  }
                },
                icon: const Icon(Icons.download_rounded),
                label: const Text('まとめてダウンロード'),
              ),
            ),
          const OrderHeading(icon: Icons.tune_rounded, text: '印刷設定（アプリが決めた値）'),
          OrderPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...printerLines(Map<String, dynamic>.from(o['printer'] ?? {})),
                ColorLine(color: Map<String, dynamic>.from(o['color'] ?? {})),
              ],
            ),
          ),
          const OrderHeading(icon: Icons.layers_rounded, text: 'フェルト'),
          OrderPanel(
            child: o['felt'] == true
                ? const Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      IconLine(icon: Icons.check_circle_rounded, text: '貼って送る（厚さ1mm・粘着付き）', color: AppColors.success),
                      SizedBox(height: 4),
                      Text('カバーの内側のサポートの跡を落としてから、内側全体に貼ります。'),
                    ],
                  )
                : const IconLine(icon: Icons.remove_circle_outline_rounded, text: '貼らずに送る'),
          ),
          const OrderHeading(icon: Icons.home_rounded, text: '個数・届け先'),
          OrderPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                IconLine(icon: Icons.tag_rounded, text: '${o['quantity']}個'),
                IconLine(icon: Icons.person_rounded, text: '${ship['name'] ?? ''}'),
                IconLine(icon: Icons.home_rounded, text: '〒${ship['postal_code'] ?? ''} ${ship['address'] ?? ''}'),
                IconLine(icon: Icons.call_rounded, text: '${ship['phone'] ?? ''}'),
                IconLine(icon: Icons.payments_rounded, text: '${yen((o['price']?['total_yen'] as num?)?.toInt() ?? 0)}（目安）'),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('手の3D・採寸・聞き取りの内容は、受託者には見せません。', style: AppText.supporting),
          ),
        ],
      ],
    );
  }
}
