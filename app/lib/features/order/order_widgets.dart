import 'package:flutter/material.dart';

import 'package:jijogu_app/core/ui/ui.dart';

/// 発注の画面で共通に使う小さな部品（見た目は S10 の見出し・枠と同じ）

/// 小見出し（アイコン20＋Title Medium）
class OrderHeading extends StatelessWidget {
  const OrderHeading({super.key, required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 22, bottom: 6),
    child: Semantics(
      header: true,
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppColors.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: AppText.titleMedium)),
        ],
      ),
    ),
  );
}

/// 角丸16の枠
class OrderPanel extends StatelessWidget {
  const OrderPanel({super.key, required this.child, this.color = AppColors.surfaceContainerLow});
  final Widget child;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(vertical: 6),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(16)),
    child: child,
  );
}

/// アイコン＋文の1行
class IconLine extends StatelessWidget {
  const IconLine({super.key, required this.icon, required this.text, this.color, this.style});
  final IconData icon;
  final String text;
  final Color? color;
  final TextStyle? style;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Icon(icon, size: 20, color: color ?? AppColors.onSurfaceVariant),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: style ?? AppText.bodyLarge.copyWith(color: color))),
      ],
    ),
  );
}

Color? parseHexColor(String? hex) {
  var h = (hex ?? '').replaceFirst('#', '');
  if (h.length == 6) h = 'FF$h';
  final v = int.tryParse(h, radix: 16);
  return h.length == 8 && v != null ? Color(v) : null;
}

/// 刷る色（色の丸と名前）
class ColorLine extends StatelessWidget {
  const ColorLine({super.key, required this.color});
  final Map<String, dynamic>? color;
  @override
  Widget build(BuildContext context) {
    final c = parseHexColor(color?['hex'] as String?);
    final name = '${color?['name_ja'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: c ?? AppColors.surfaceContainerHigh,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.outlineVariant),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '刷る色：${name.isEmpty ? (color?['hex'] ?? '指定なし') : name}',
              style: AppText.bodyLarge,
            ),
          ),
        ],
      ),
    );
  }
}

/// 印刷の決まり（機種・積層・充填・サポート・向き）を行で並べる
List<Widget> printerLines(Map<String, dynamic>? p) => [
  IconLine(icon: Icons.print_rounded, text: '機種：${p?['model'] ?? ''}'),
  IconLine(icon: Icons.layers_rounded, text: '積層ピッチ：${p?['layer_mm'] ?? ''}mm'),
  IconLine(icon: Icons.grid_on_rounded, text: '充填率：${p?['infill_pct'] ?? ''}%'),
  IconLine(icon: Icons.construction_rounded, text: 'サポート：${p?['supports_ja'] ?? ''}'),
  IconLine(icon: Icons.screen_rotation_alt_rounded, text: '刷る向き：${p?['orientation_ja'] ?? ''}'),
];
