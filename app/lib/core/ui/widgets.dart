import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:jijogu_app/core/ui/theme.dart';

/// 画面の枠。M3 の上のバー（小）＋本文＋下のボタンの並び。幅はスマホくらいに抑えて真ん中に置く（PCでも同じ並び）。
/// [large] にすると、大きな見出しのバー（S1 ホームなど。戻るボタンなし）
class AppPage extends StatelessWidget {
  const AppPage({
    super.key,
    required this.title,
    required this.children,
    this.bottom,
    this.onBack,
    this.actions,
    this.large = false,
    this.floatingActionButton,
    this.showAppBar = true,
  });
  final String title;
  final List<Widget> children;
  final Widget? bottom;
  final VoidCallback? onBack;
  final List<Widget>? actions;
  final bool large;
  final Widget? floatingActionButton;
  final bool showAppBar;

  static const maxWidth = 720.0;
  static const bodyPadding = EdgeInsets.fromLTRB(24, 8, 24, 24);

  Widget _center(Widget child) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final leading = onBack == null ? null : BackButton(onPressed: onBack);
    final Widget body;
    if (large) {
      body = CustomScrollView(
        slivers: [
          // 大きな見出しは Figma と同じ Display Small（36）。Flutter の既定は headlineMedium（28）なので差し替える
          Theme(
            data: Theme.of(context).copyWith(
              textTheme: Theme.of(context).textTheme.copyWith(
                headlineMedium: AppText.displaySmall.copyWith(
                  color: AppColors.onSurface,
                ),
              ),
            ),
            child: SliverAppBar.large(
              title: Text(title),
              leading: leading,
              actions: actions,
            ),
          ),
          SliverToBoxAdapter(
            child: _center(
              Padding(
                padding: bodyPadding.copyWith(
                  bottom: floatingActionButton == null ? 24 : 112,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
          ),
        ],
      );
    } else {
      body = _center(
        ListView(
          padding: bodyPadding.copyWith(
            bottom: floatingActionButton == null ? 24 : 112,
          ),
          children: children,
        ),
      );
    }
    return Scaffold(
      appBar: large || !showAppBar
          ? null
          : AppBar(
              title: Text(title),
              leading: leading,
              actions: actions,
            ),
      body: SafeArea(child: body),
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: bottom == null
          ? null
          : SafeArea(
              child: Center(
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: maxWidth),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                    // 下のボタンは横いっぱい（Figma の Bottom actions）
                    child: SizedBox(width: double.infinity, child: bottom),
                  ),
                ),
              ),
            ),
    );
  }
}

/// 本文の中の小見出し（Title Medium・onSurfaceVariant）。例：S1「作りかけ・作った道具」
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 4),
    child: Semantics(
      header: true,
      child: Text(
        text,
        style: AppText.titleMedium.copyWith(color: AppColors.onSurfaceVariant),
      ),
    ),
  );
}

/// お知らせの種類（Figma の M3/Notice）。色だけで伝えないよう、必ずアイコンも変える
enum NoticeTone { info, warning, error, helper, progress, success }

extension on NoticeTone {
  Color get bg => switch (this) {
    NoticeTone.info => AppColors.surfaceContainerHigh,
    NoticeTone.warning => AppColors.warningContainer,
    NoticeTone.error => AppColors.errorContainer,
    NoticeTone.helper => AppColors.secondaryContainer,
    NoticeTone.progress => AppColors.primaryContainer,
    NoticeTone.success => AppColors.successContainer,
  };
  Color get fg => switch (this) {
    NoticeTone.info => AppColors.onSurface,
    NoticeTone.warning => AppColors.onWarningContainer,
    NoticeTone.error => AppColors.onErrorContainer,
    NoticeTone.helper => AppColors.onSecondaryContainer,
    NoticeTone.progress => AppColors.onPrimaryContainer,
    NoticeTone.success => AppColors.onSuccessContainer,
  };
  Color get iconColor => switch (this) {
    NoticeTone.info => AppColors.primary,
    NoticeTone.warning => AppColors.warning,
    NoticeTone.error => AppColors.error,
    NoticeTone.helper => AppColors.onSecondaryContainer,
    NoticeTone.progress => AppColors.onPrimaryContainer,
    NoticeTone.success => AppColors.success,
  };
  IconData get icon => switch (this) {
    NoticeTone.info => Icons.info_outline_rounded,
    NoticeTone.warning => Icons.warning_amber_rounded,
    NoticeTone.error => Icons.error_outline_rounded,
    NoticeTone.helper => Icons.group_rounded,
    NoticeTone.progress => Icons.hourglass_top_rounded,
    NoticeTone.success => Icons.check_circle_outline_rounded,
  };
}

/// お知らせのカード（Figma の M3/Notice）。角丸16、左にアイコン24、本文16px。
/// [tone] を付けると色とアイコンが決まる。[icon] だけ渡すと info の色でそのアイコンを出す
class InfoCard extends StatelessWidget {
  const InfoCard({
    super.key,
    required this.child,
    this.tone,
    this.icon,
    this.color,
  });
  final Widget child;
  final NoticeTone? tone;
  final IconData? icon;

  /// 背景色を直接決めたいとき（ふつうは [tone] を使う）
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = tone ?? NoticeTone.info;
    final showIcon = tone != null || icon != null;
    final fg = t.fg;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: color ?? (tone == null ? AppColors.surfaceContainerLow : t.bg),
        borderRadius: BorderRadius.circular(16),
      ),
      child: DefaultTextStyle.merge(
        style: AppText.bodyLarge.copyWith(color: fg),
        child: IconTheme.merge(
          data: IconThemeData(color: fg),
          child: !showIcon
              ? child
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(icon ?? t.icon, color: t.iconColor, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: child),
                  ],
                ),
        ),
      ),
    );
  }
}

/// デモ用のケースの表示（docs/screens.md S7・S10）
class DemoBanner extends StatelessWidget {
  const DemoBanner({super.key});
  @override
  Widget build(BuildContext context) => const InfoCard(
    tone: NoticeTone.warning,
    child: Text('デモ用：OTの確認を省略しています。実際に使う前には、必ず作業療法士の確認が必要です。'),
  );
}

/// 選択式の質問の1行（Figma の M3/List row – Radio）。行全体が押せる。高さ72以上。選択中は secondaryContainer
class ChoiceButton extends StatelessWidget {
  const ChoiceButton({
    super.key,
    required this.label,
    this.sub,
    required this.selected,
    required this.onTap,
    this.multi = false,
  });
  final String label;
  final String? sub;
  final bool selected;
  final VoidCallback onTap;

  /// いくつでも選べる問い（丸ではなく四角の印。読み上げも「どれか1つ」にしない）
  final bool multi;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Semantics(
        inMutuallyExclusiveGroup: !multi,
        checked: selected,
        button: true,
        child: Material(
          color: selected
              ? AppColors.secondaryContainer
              : AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 72),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            label,
                            style: AppText.bodyLarge.copyWith(
                              color: selected
                                  ? AppColors.onSecondaryContainer
                                  : AppColors.onSurface,
                            ),
                          ),
                          if (sub != null) Text(sub!, style: AppText.supporting),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    ExcludeSemantics(
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: Icon(
                          switch ((multi, selected)) {
                            (false, true) => Icons.radio_button_checked_rounded,
                            (false, false) => Icons.radio_button_unchecked_rounded,
                            (true, true) => Icons.check_box_rounded,
                            (true, false) => Icons.check_box_outline_blank_rounded,
                          },
                          color: selected
                              ? AppColors.primary
                              : AppColors.onSurfaceVariant,
                        ),
                      ),
                    ),
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

Future<void> showError(BuildContext context, Object e) async {
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(e.toString())));
}

/// 提案のボタン（よく使う指示など。M3 の提案チップの見た目）。
/// ActionChip は読み上げで「チェックボックス」になるため、ボタンにする
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: AppText.labelLarge.copyWith(fontSize: 16),
        foregroundColor: AppColors.onSurfaceVariant,
        side: const BorderSide(color: AppColors.outlineVariant),
      ),
      child: Text(label),
    );
  }
}

/// 状態の札（Figma の M3/Status label）。アイコンと文字を必ず添える
enum StatusTone { neutral, warning, success, error }

class StatusLabel extends StatelessWidget {
  const StatusLabel({
    super.key,
    required this.label,
    this.tone = StatusTone.neutral,
    this.icon,
  });
  final String label;
  final StatusTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, ic, defIcon) = switch (tone) {
      StatusTone.neutral => (
        AppColors.surfaceContainerHighest,
        AppColors.onSurfaceVariant,
        AppColors.onSurfaceVariant,
        Icons.info_outline_rounded,
      ),
      StatusTone.warning => (
        AppColors.warningContainer,
        AppColors.onWarningContainer,
        AppColors.onWarningContainer,
        Icons.hourglass_top_rounded,
      ),
      StatusTone.success => (
        AppColors.successContainer,
        AppColors.onSuccessContainer,
        AppColors.success,
        Icons.check_circle_outline_rounded,
      ),
      StatusTone.error => (
        AppColors.errorContainer,
        AppColors.onErrorContainer,
        AppColors.error,
        Icons.error_outline_rounded,
      ),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon ?? defIcon, size: 16, color: ic),
          const SizedBox(width: 4),
          Text(label, style: AppText.labelMedium.copyWith(color: fg)),
        ],
      ),
    );
  }
}

/// data:image/jpeg;base64,... をバイト列にする
Uint8List dataUrlBytes(String dataUrl) =>
    base64Decode(dataUrl.substring(dataUrl.indexOf(',') + 1));

/// 1秒を超える処理の「いま何をしているか」（docs/screens.md §2：くるくる回るだけの表示は使わない）。
/// Figma の M3/Notice（Progress）＋進み具合の棒
class BusyCard extends StatelessWidget {
  const BusyCard({super.key, required this.text, this.value});
  final String text;
  final double? value;
  @override
  Widget build(BuildContext context) => InfoCard(
    tone: NoticeTone.progress,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text),
        const SizedBox(height: 10),
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
    tone: NoticeTone.error,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(message),
        if (onRetry != null) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: onRetry,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(48, 48),
              foregroundColor: AppColors.onErrorContainer,
              side: const BorderSide(color: AppColors.onErrorContainer),
            ),
            icon: const Icon(Icons.refresh_rounded),
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
    tone: NoticeTone.helper,
    child: Text('家族や支援者が操作してもかまいません。'),
  );
}
