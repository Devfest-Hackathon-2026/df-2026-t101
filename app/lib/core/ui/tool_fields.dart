import 'package:flutter/material.dart';

import 'package:jijogu_app/core/ui/ui.dart';

/// 柄の太さの区分の1行目と2行目（Figma S2a Q3 の並び。S7 の取り付け具を足す画面でも使う）
const shaftRows = <String, (String, String)>{
  'thin': ('細い', '約6mm'),
  'medium': ('ふつう', '約8.5mm'),
  'thick': ('太い', '約11.5mm'),
  'unknown': ('わからない', '道具ごとの目安にします（あとで確かめます）'),
};

/// 「mmで入れる」を選んだときのカード（Figma の mm input (selected)）。＋−の大きなボタンで0.5mmずつ
class ToolDmmCard extends StatelessWidget {
  const ToolDmmCard({super.key, required this.value, required this.onChanged});
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final v = value;
    Widget b(IconData i, String tip, double d) => IconButton.filled(
      tooltip: tip,
      iconSize: 28,
      style: IconButton.styleFrom(fixedSize: const Size(64, 64)),
      onPressed: () => onChanged((v + d).clamp(3.5, 20.0)),
      icon: Icon(i),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
        decoration: BoxDecoration(
          color: AppColors.secondaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              inMutuallyExclusiveGroup: true,
              checked: true,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'mmで入れる',
                          style: AppText.bodyLarge.copyWith(
                            color: AppColors.onSecondaryContainer,
                          ),
                        ),
                        Text(
                          'おすすめ。定規で測った太さを入れます',
                          style: AppText.supporting,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const ExcludeSemantics(
                    child: Icon(
                      Icons.radio_button_checked_rounded,
                      size: 20,
                      color: AppColors.primary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                b(Icons.remove_rounded, '0.5mm細く', -0.5),
                const SizedBox(width: 16),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: v.toStringAsFixed(1),
                            style: AppText.displaySmall.copyWith(
                              color: AppColors.onSecondaryContainer,
                            ),
                          ),
                          TextSpan(
                            text: ' mm',
                            style: AppText.titleMedium.copyWith(
                              color: AppColors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                b(Icons.add_rounded, '0.5mm太く', 0.5),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
