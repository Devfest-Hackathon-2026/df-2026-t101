import 'package:flutter/material.dart';

import 'package:jijogu_app/app/paths.dart';
import 'package:jijogu_app/core/api/api.dart';
import 'package:jijogu_app/core/ui/ui.dart';
import 'package:jijogu_app/features/order/order_logic.dart';

/// 受託者を選ぶ（Figma 2。設計 §5.1・§6.4）。頼めたら true を返して S10 に戻る
class FabricatorListScreen extends StatefulWidget {
  const FabricatorListScreen({super.key, required this.caseId, required this.designId});
  final String caseId;
  final String designId;
  @override
  State<FabricatorListScreen> createState() => _FabricatorListScreenState();
}

class _FabricatorListScreenState extends State<FabricatorListScreen> {
  Map<String, dynamic>? _data;
  bool _demo = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final c = await Api.instance.get('/v1/cases/${widget.caseId}');
      final r = await Api.instance.get('/v1/cases/${widget.caseId}/designs/${widget.designId}/fabricators');
      if (!mounted) return;
      setState(() {
        _demo = c['demo'] == true;
        _data = Map<String, dynamic>.from(r as Map);
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _choose(String fid) async {
    final ok = await Navigator.of(context).pushNamed(Paths.orderForm(widget.caseId, widget.designId, fid));
    if (ok == true && mounted) Navigator.of(context).pop(true);
  }

  String _weights() {
    final est = Map<String, dynamic>.from(_data?['estimates'] ?? {});
    final names = Map<String, dynamic>.from(_data?['names'] ?? {});
    return [for (final e in est.entries) '${names[e.key] ?? e.key}${gramsJa(e.value['grams'] as num)}'].join('＋');
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final list = [for (final f in (d?['fabricators'] as List? ?? const [])) Map<String, dynamic>.from(f as Map)];
    return AppPage(
      title: '工房を選ぶ',
      children: [
        if (_demo) const DemoBanner(),
        const InfoCard(tone: NoticeTone.warning, child: Text(fictionalNotice)),
        if (_error != null) ErrorCard(message: '読み込めませんでした（$_error）', onRetry: _load),
        if (d == null && _error == null) const BusyCard(text: '読み込んでいます'),
        if (d != null) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '指定の機種（${d['printer']?['model'] ?? ''}）に対応している工房だけを表示しています。金額の安い順です。',
              style: AppText.bodyLarge.copyWith(color: AppColors.onSurfaceVariant),
            ),
          ),
          for (final f in list) _FabricatorCard(fab: f, model: '${d['printer']?['model'] ?? ''}', onChoose: () => _choose('${f['id']}')),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('金額は、部品の重さ（${_weights()}）から計算した目安です。', style: AppText.supporting),
          ),
        ],
      ],
    );
  }
}

class _FabricatorCard extends StatelessWidget {
  const _FabricatorCard({required this.fab, required this.model, required this.onChoose});
  final Map<String, dynamic> fab;
  final String model;
  final VoidCallback onChoose;

  @override
  Widget build(BuildContext context) {
    final total = (fab['price']?['total_yen'] as num?)?.toInt() ?? 0;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.surfaceContainerLow, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('${fab['name']}', style: AppText.titleMedium)),
              if (fab['fictional'] == true) const StatusLabel(label: '架空'),
            ],
          ),
          Text('${fab['region'] ?? ''}', style: AppText.supporting),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(yen(total), style: AppText.headlineSmall),
              const SizedBox(width: 6),
              Text('（目安）', style: AppText.supporting),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const Icon(Icons.local_shipping_rounded, size: 20, color: AppColors.onSurfaceVariant),
              const SizedBox(width: 6),
              Text('発送まで${fab['lead_days']}日', style: AppText.bodyLarge),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              StatusLabel(label: model, icon: Icons.print_rounded),
              if (fab['felt_service'] == true)
                const StatusLabel(label: 'フェルトを貼って送れる', tone: StatusTone.success),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: onChoose,
            child: Text('${fab['name']}に頼む'),
          ),
        ],
      ),
    );
  }
}
