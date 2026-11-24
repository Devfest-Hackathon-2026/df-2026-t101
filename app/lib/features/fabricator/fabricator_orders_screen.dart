import 'package:flutter/material.dart';

import 'package:jijogu_app/app/paths.dart';
import 'package:jijogu_app/core/api/api.dart';
import 'package:jijogu_app/core/ui/ui.dart';
import 'package:jijogu_app/features/order/order_logic.dart';

/// 受けた注文（Figma 4。設計 §5.3）。受託者を切り替え、状態ごとに並べる
class FabricatorOrdersScreen extends StatefulWidget {
  const FabricatorOrdersScreen({super.key});
  @override
  State<FabricatorOrdersScreen> createState() => _FabricatorOrdersScreenState();
}

class _FabricatorOrdersScreenState extends State<FabricatorOrdersScreen> {
  List<Map<String, dynamic>>? _fabs;
  String? _fid;
  List<Map<String, dynamic>>? _orders;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadMe();
  }

  Future<void> _loadMe() async {
    setState(() => _error = null);
    try {
      final r = await Api.instance.get('/v1/fabricator/me');
      final list = [for (final f in (r['fabricators'] as List? ?? const [])) Map<String, dynamic>.from(f as Map)];
      if (!mounted) return;
      setState(() {
        _fabs = list;
        _fid = list.isEmpty ? null : '${list.first['id']}';
      });
      await _loadOrders();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _loadOrders() async {
    final fid = _fid;
    if (fid == null) return;
    try {
      final r = await Api.instance.get('/v1/fabricator/orders?fabricator_id=$fid');
      if (!mounted || fid != _fid) return;
      setState(() => _orders = [for (final o in (r['orders'] as List? ?? const [])) Map<String, dynamic>.from(o as Map)]);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _open(String oid) async {
    await Navigator.of(context).pushNamed(Paths.fabricatorOrder(oid));
    if (mounted) await _loadOrders();
  }

  @override
  Widget build(BuildContext context) {
    final orders = _orders;
    return AppPage(
      title: '受けた注文',
      actions: [
        IconButton(tooltip: '読み込み直す', onPressed: _loadOrders, icon: const Icon(Icons.refresh_rounded)),
      ],
      children: [
        const InfoCard(
          tone: NoticeTone.warning,
          child: Text('$fictionalNotice デモ用にチームのアカウントで工房として操作できます。'),
        ),
        if (_error != null) ErrorCard(message: '読み込めませんでした（$_error）', onRetry: _loadMe),
        if (_fabs == null && _error == null) const BusyCard(text: '読み込んでいます'),
        if (_fabs != null && _fabs!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: LayoutBuilder(
              builder: (context, c) => DropdownMenu<String>(
                width: c.maxWidth,
                label: const Text('工房'),
                initialSelection: _fid,
                leadingIcon: const Icon(Icons.storefront_rounded),
                dropdownMenuEntries: [
                  for (final f in _fabs!) DropdownMenuEntry(value: '${f['id']}', label: '${f['name']}'),
                ],
                onSelected: (v) {
                  setState(() {
                    _fid = v;
                    _orders = null;
                  });
                  _loadOrders();
                },
              ),
            ),
          ),
        if (orders != null)
          for (final st in const ['received', 'printing', 'shipped', 'delivered', 'cancelled']) ...[
            SectionLabel('${orderStatusJa(st)}（${orders.where((o) => o['status'] == st).length}）'),
            for (final o in orders.where((o) => o['status'] == st))
              _OrderRow(order: o, onTap: () => _open('${o['order_id']}')),
          ],
      ],
    );
  }
}

class _OrderRow extends StatelessWidget {
  const _OrderRow({required this.order, required this.onTap});
  final Map<String, dynamic> order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final parts = [for (final i in (order['items'] as List? ?? const [])) '${i['name_ja']}'].join('＋');
    final title = '#${order['display_id']} $parts ×${order['quantity']}';
    final sub = '${shortTime(order['created_at'])}${order['felt'] == true ? ' ・ フェルトを貼る' : ''}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Semantics(
        button: true,
        label: '$title、$sub',
        excludeSemantics: true,
        child: Material(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 72),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                child: Row(
                  children: [
                    const CircleAvatar(
                      radius: 20,
                      backgroundColor: AppColors.primaryContainer,
                      child: Icon(Icons.receipt_long_rounded, color: AppColors.onPrimaryContainer, size: 22),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: AppText.bodyLarge),
                          Text(sub, style: AppText.supporting),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded, color: AppColors.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
