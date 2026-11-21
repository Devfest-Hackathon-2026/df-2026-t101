import 'package:flutter/material.dart';

import 'package:jijogu_app/core/ui/ui.dart';
import 'package:jijogu_app/features/order/order_logic.dart';

/// S10 の「刷ってもらう」「自分で刷る」の大きな2つのボタン（Figma 1a）。
/// [compact] は発注後（1b）に小さく残すとき
class PrintChoice extends StatelessWidget {
  const PrintChoice({
    super.key,
    required this.onOrder,
    required this.onSelfPrint,
    required this.fabricators,
    this.compact = false,
    this.unavailableReason,
    this.selfPrintOpen = false,
  });

  /// 「自分で刷る」のダウンロードの欄を開いているか（もう一度押すと閉じる）
  final bool selfPrintOpen;

  /// null なら「刷ってもらう」は押せず、[unavailableReason] を出す
  final VoidCallback? onOrder;
  final String? unavailableReason;
  final VoidCallback onSelfPrint;

  /// `GET …/fabricators` の応答（あれば「約1,240円から（目安）」を出す）
  final Map<String, dynamic>? fabricators;
  final bool compact;

  int? get _fromYen {
    final list = fabricators?['fabricators'] as List?;
    if (list == null || list.isEmpty) return null;
    return list.map((f) => (f['price']?['total_yen'] as num?)?.toInt() ?? 0).reduce((a, b) => a < b ? a : b);
  }

  @override
  Widget build(BuildContext context) {
    final from = _fromYen;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Option(
          primary: !compact,
          compact: compact,
          icon: Icons.local_shipping_rounded,
          title: compact ? 'もう一度頼む' : '刷ってもらう',
          sub: onOrder == null
              ? (unavailableReason ?? 'いまは頼めません')
              : 'プリンタがなくても大丈夫です。受託者が刷って届けます。${from == null ? '' : '${yen(from)}から（目安）'}',
          onTap: onOrder,
        ),
        _Option(
          primary: false,
          compact: compact,
          icon: Icons.download_rounded,
          title: '自分で刷る',
          sub: '印刷用のファイル（STL）をダウンロードします',
          onTap: onSelfPrint,
          trailing: selfPrintOpen ? Icons.expand_less_rounded : Icons.expand_more_rounded,
          expanded: selfPrintOpen,
        ),
      ],
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    required this.primary,
    required this.compact,
    required this.icon,
    required this.title,
    required this.sub,
    required this.onTap,
    this.trailing = Icons.chevron_right_rounded,
    this.expanded,
  });
  final IconData trailing;

  /// 開け閉めするボタンなら、開いているか（読み上げに伝える）
  final bool? expanded;
  final bool primary;
  final bool compact;
  final IconData icon;
  final String title;
  final String sub;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final primary = this.primary && enabled;
    final fg = primary ? AppColors.onPrimaryContainer : (enabled ? AppColors.onSurface : AppColors.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Semantics(
        button: true,
        enabled: enabled,
        expanded: expanded,
        label: '$title。$sub',
        excludeSemantics: true,
        child: Material(
          color: primary ? AppColors.primaryContainer : AppColors.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: primary ? BorderSide.none : const BorderSide(color: AppColors.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: compact ? 72 : 96),
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, compact ? 12 : 16, 12, compact ? 12 : 16),
                child: Row(
                  children: [
                    Icon(icon, size: compact ? 24 : 32, color: primary ? fg : (enabled ? AppColors.primary : AppColors.outline)),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: (compact ? AppText.titleMedium : AppText.titleLarge).copyWith(color: fg)),
                          const SizedBox(height: 2),
                          Text(
                            sub,
                            style: AppText.bodyMedium.copyWith(
                              color: primary ? AppColors.onPrimaryContainer : AppColors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (enabled) Icon(trailing, color: fg),
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
