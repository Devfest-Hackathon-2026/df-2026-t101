import 'package:flutter/material.dart';

import 'package:jijogu_app/core/ui/ui.dart';
import 'package:jijogu_app/features/order/order_logic.dart';
import 'package:jijogu_app/features/order/order_widgets.dart';

/// S10（発注後）の注文の状態（Figma 1b）。4つの段階・受託者・刷る色・金額・届く目安・部品
class OrderStatusCard extends StatelessWidget {
  const OrderStatusCard({
    super.key,
    required this.order,
    required this.daysAfterShip,
    this.onCancel,
    this.onDelivered,
    this.busy = false,
  });
  final Map<String, dynamic> order;
  final int daysAfterShip;
  final VoidCallback? onCancel;
  final VoidCallback? onDelivered;
  final bool busy;

  static StatusTone toneOf(String? s) => switch (s) {
    'shipped' || 'delivered' => StatusTone.success,
    'cancelled' => StatusTone.neutral,
    _ => StatusTone.warning,
  };

  @override
  Widget build(BuildContext context) {
    final status = '${order['status']}';
    final idx = orderSteps.indexOf(status);
    final fab = Map<String, dynamic>.from(order['fabricator_snapshot'] ?? {});
    final total = (order['price']?['total_yen'] as num?)?.toInt() ?? 0;
    final eta = deliveryEstimate(order, daysAfterShip);
    final qty = order['quantity'] ?? 1;
    return OrderPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('注文 #${order['display_id'] ?? ''}', style: AppText.titleMedium)),
              StatusLabel(label: orderStatusJa(status), tone: toneOf(status)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${fab['name'] ?? ''}${fab['fictional'] == true ? '（架空）' : ''}・${yen(total)}（目安）',
            style: AppText.supporting,
          ),
          const SizedBox(height: 8),
          for (final (i, step) in orderSteps.indexed)
            _StepRow(
              state: status == 'delivered' || i < idx ? _S.done : (i == idx ? _S.current : _S.todo),
              label: orderStatusJa(step),
              sub: [
                shortTime(order[step == 'received' ? 'created_at' : '${step}_at']),
                if (step == 'shipped' && eta != null && status == 'shipped') '届く目安 ${shortDate(eta)}',
              ].where((s) => s.isNotEmpty).join(' ・ '),
            ),
          const SizedBox(height: 4),
          ColorLine(color: Map<String, dynamic>.from(order['color'] ?? {})),
          for (final it in (order['items'] as List? ?? const []))
            IconLine(icon: Icons.view_in_ar_rounded, text: '${it['name_ja']} ×$qty'),
          if (order['felt'] == true)
            const IconLine(icon: Icons.layers_rounded, text: 'フェルトを貼って届きます'),
          if (status == 'shipped') ...[
            const SizedBox(height: 8),
            const InfoCard(
              tone: NoticeTone.info,
              child: Text('届いたら「受け取った」を押してください。'),
            ),
          ],
          if (onDelivered != null) ...[
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: busy ? null : onDelivered,
              icon: const Icon(Icons.inventory_2_rounded),
              label: const Text('受け取った'),
            ),
          ],
          if (onCancel != null) ...[
            const SizedBox(height: 8),
            OutlinedButton(onPressed: busy ? null : onCancel, child: const Text('この注文を取り消す')),
          ],
        ],
      ),
    );
  }
}

enum _S { done, current, todo }

class _StepRow extends StatelessWidget {
  const _StepRow({required this.state, required this.label, required this.sub});
  final _S state;
  final String label;
  final String sub;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (state) {
      _S.done => (Icons.check_circle_rounded, AppColors.success),
      _S.current => (Icons.radio_button_checked_rounded, AppColors.primary),
      _S.todo => (Icons.radio_button_unchecked_rounded, AppColors.outline),
    };
    return Semantics(
      label: '$label、${switch (state) { _S.done => '済み', _S.current => 'いまここ', _S.todo => 'まだ' }}${sub.isEmpty ? '' : '、$sub'}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: state == _S.current
                        ? AppText.titleMedium
                        : AppText.bodyLarge.copyWith(
                            color: state == _S.todo ? AppColors.onSurfaceVariant : AppColors.onSurface,
                          ),
                  ),
                  if (sub.isNotEmpty) Text(sub, style: AppText.supporting),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
