import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// 共通の見た目。docs/screens.md §2（押せる範囲48px以上、本文16px以上、色だけで伝えない）
class AppColors {
  static const ink = Color(0xFF1F2A2E);
  static const sub = Color(0xFF5A666B);
  static const paper = Color(0xFFFBF9F4);
  static const card = Colors.white;
  static const primary = Color(0xFF2F6F8F);
  static const accent = Color(0xFFE07A5F);
  static const ok = Color(0xFF2F7D6D);
  static const warn = Color(0xFFB7791F);
  static const line = Color(0xFFE4DED2);
}

ThemeData appTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      surface: AppColors.paper,
    ),
    scaffoldBackgroundColor: AppColors.paper,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.ink,
      displayColor: AppColors.ink,
      fontSizeFactor: 1.08,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.paper,
      foregroundColor: AppColors.ink,
      elevation: 0,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        textStyle: const TextStyle(fontSize: 17),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
  );
}

/// 画面の幅をスマホくらいに抑えて真ん中に置く（PCでも同じ並び）
class AppPage extends StatelessWidget {
  const AppPage({
    super.key,
    required this.title,
    required this.children,
    this.bottom,
    this.onBack,
  });
  final String title;
  final List<Widget> children;
  final Widget? bottom;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        leading: onBack == null ? null : BackButton(onPressed: onBack),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: children,
            ),
          ),
        ),
      ),
      bottomNavigationBar: bottom == null
          ? null
          : SafeArea(
              child: Center(
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: bottom,
                  ),
                ),
              ),
            ),
    );
  }
}

class InfoCard extends StatelessWidget {
  const InfoCard({
    super.key,
    required this.child,
    this.color = AppColors.card,
    this.icon,
  });
  final Widget child;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.line),
      ),
      child: icon == null
          ? child
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: AppColors.ink),
                const SizedBox(width: 12),
                Expanded(child: child),
              ],
            ),
    );
  }
}

/// デモ用のケースの表示（docs/screens.md S7・S10）
class DemoBanner extends StatelessWidget {
  const DemoBanner({super.key});
  @override
  Widget build(BuildContext context) => const InfoCard(
    color: Color(0xFFFFF4E0),
    icon: Icons.info_outline,
    child: Text('デモ用：OTの確認を省略しています。実際に使う前には、必ず作業療法士の確認が必要です。'),
  );
}

/// 大きな選択肢のボタン
class ChoiceButton extends StatelessWidget {
  const ChoiceButton({
    super.key,
    required this.label,
    this.sub,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final String? sub;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Material(
        color: selected ? const Color(0xFFE3EEF3) : AppColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: selected ? AppColors.primary : AppColors.line,
            width: selected ? 2 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: const TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (sub != null)
                          Text(
                            sub!,
                            style: const TextStyle(
                              color: AppColors.sub,
                              fontSize: 15,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Icon(
                    selected ? Icons.check_circle : Icons.circle_outlined,
                    color: selected ? AppColors.primary : AppColors.line,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showError(BuildContext context, Object e) async {
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(e.toString())));
}

/// 提案のボタン（よく使う指示など）。ActionChip は読み上げで「チェックボックス」になるため、ボタンにする
class SuggestButton extends StatelessWidget {
  const SuggestButton({
    super.key,
    required this.label,
    required this.onPressed,
  });
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        textStyle: const TextStyle(fontSize: 16),
      ),
      child: Text(label),
    );
  }
}

/// data:image/jpeg;base64,... をバイト列にする
Uint8List dataUrlBytes(String dataUrl) =>
    base64Decode(dataUrl.substring(dataUrl.indexOf(',') + 1));

/// 1秒を超える処理の「いま何をしているか」（docs/screens.md §2：くるくる回るだけの表示は使わない）
class BusyCard extends StatelessWidget {
  const BusyCard({super.key, required this.text, this.value});
  final String text;
  final double? value;
  @override
  Widget build(BuildContext context) => InfoCard(
    icon: Icons.hourglass_top,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: value),
      ],
    ),
  );
}

/// エラーの文と、retryable なら「もう一度試す」（docs/screens.md §2）
class ErrorCard extends StatelessWidget {
  const ErrorCard({super.key, required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => InfoCard(
    color: const Color(0xFFFDECEA),
    icon: Icons.error_outline,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(message),
        if (onRetry != null) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('もう一度試す'),
          ),
        ],
      ],
    ),
  );
}

/// 「家族や支援者が操作してもかまいません」（docs/screens.md の決めたこと3）
class HelperNote extends StatelessWidget {
  const HelperNote({super.key});
  @override
  Widget build(BuildContext context) => const InfoCard(
    icon: Icons.people_outline,
    child: Text('家族や支援者が操作してもかまいません。'),
  );
}
