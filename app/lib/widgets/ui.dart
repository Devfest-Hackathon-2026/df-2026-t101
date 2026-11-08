import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// 色。Figma「自助具ジェネレーター UI」の変数「M3 Scheme（Google カラー）」と同じ値
/// （GoogleのGM3の色。primary は Google Blue）。
/// docs/screens.md §2（押せる範囲48px以上、本文16px以上、色だけで伝えない）
class AppColors {
  AppColors._();
  static const primary = Color(0xFF0B57D0);
  static const onPrimary = Colors.white;
  static const primaryContainer = Color(0xFFD3E3FD);
  static const onPrimaryContainer = Color(0xFF041E49);
  static const secondary = Color(0xFF00639B);
  static const secondaryContainer = Color(0xFFC2E7FF);
  static const onSecondaryContainer = Color(0xFF001D35);
  static const tertiary = Color(0xFF146C2E);
  static const tertiaryContainer = Color(0xFFC4EED0);
  static const onTertiaryContainer = Color(0xFF072711);
  static const error = Color(0xFFB3261E);
  static const errorContainer = Color(0xFFF9DEDC);
  static const onErrorContainer = Color(0xFF410E0B);
  static const warning = Color(0xFF7A5900);
  static const warningContainer = Color(0xFFFEEFC3);
  static const onWarningContainer = Color(0xFF261900);
  static const success = Color(0xFF146C2E);
  static const successContainer = Color(0xFFC4EED0);
  static const onSuccessContainer = Color(0xFF072711);
  static const surface = Color(0xFFF8FAFD);
  static const onSurface = Color(0xFF1F1F1F);
  static const onSurfaceVariant = Color(0xFF444746);
  static const surfaceDim = Color(0xFFD9DDE3);
  static const surfaceContainerLowest = Colors.white;
  static const surfaceContainerLow = Color(0xFFF3F6FC);
  static const surfaceContainer = Color(0xFFF0F4F9);
  static const surfaceContainerHigh = Color(0xFFE9EEF6);
  static const surfaceContainerHighest = Color(0xFFDDE3EA);
  static const outline = Color(0xFF747775);
  static const outlineVariant = Color(0xFFC4C7C5);
  static const inverseSurface = Color(0xFF303030);
  static const inverseOnSurface = Color(0xFFF2F2F2);
  static const inversePrimary = Color(0xFFA8C7FA);

  /// Googleの4色。飾りだけに使う（意味のある色には上の役割の色を使う）
  static const googleBlue = Color(0xFF4285F4);
  static const googleRed = Color(0xFFEA4335);
  static const googleYellow = Color(0xFFFBBC04);
  static const googleGreen = Color(0xFF34A853);

  // 前の名前（画面のコードが使っている）
  static const ink = onSurface;
  static const sub = onSurfaceVariant;
  static const paper = surface;
  static const card = surfaceContainerLow;
  static const accent = googleRed;
  static const ok = success;
  static const warn = warning;
  static const line = outlineVariant;
}

/// 文字の大きさ。Figma の「M3 JP/*」（Noto Sans JP、行の高さは日本語向けに広め）。
/// 書体は指定しない：Flutter Web は英数字を Roboto、日本語を Noto Sans JP で描く
class AppText {
  AppText._();
  static TextStyle _s(double size, double line, [FontWeight w = FontWeight.w400, double ls = 0]) =>
      TextStyle(fontSize: size, height: line / size, fontWeight: w, letterSpacing: ls);
  static final displaySmall = _s(36, 48);
  static final headlineLarge = _s(32, 44);
  static final headlineMedium = _s(28, 38);
  static final headlineSmall = _s(24, 34);
  static final titleLarge = _s(22, 30);
  static final titleMedium = _s(16, 24, FontWeight.w500, 0.08);
  static final titleSmall = _s(14, 20, FontWeight.w500, 0.07);
  static final bodyLarge = _s(16, 26);
  static final bodyMedium = _s(14, 22);
  static final bodySmall = _s(12, 18);
  static final labelLarge = _s(14, 20, FontWeight.w500, 0.07);
  static final labelMedium = _s(12, 16, FontWeight.w500, 0.06);
  static final labelSmall = _s(11, 16, FontWeight.w500, 0.06);

  /// 補足の文（リストの2行目など）。Body Medium の色付き
  static final supporting = bodyMedium.copyWith(color: AppColors.onSurfaceVariant);
}

ThemeData appTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: AppColors.primary,
    onPrimary: AppColors.onPrimary,
    primaryContainer: AppColors.primaryContainer,
    onPrimaryContainer: AppColors.onPrimaryContainer,
    secondary: AppColors.secondary,
    onSecondary: Colors.white,
    secondaryContainer: AppColors.secondaryContainer,
    onSecondaryContainer: AppColors.onSecondaryContainer,
    tertiary: AppColors.tertiary,
    onTertiary: Colors.white,
    tertiaryContainer: AppColors.tertiaryContainer,
    onTertiaryContainer: AppColors.onTertiaryContainer,
    error: AppColors.error,
    onError: Colors.white,
    errorContainer: AppColors.errorContainer,
    onErrorContainer: AppColors.onErrorContainer,
    surface: AppColors.surface,
    onSurface: AppColors.onSurface,
    onSurfaceVariant: AppColors.onSurfaceVariant,
    surfaceDim: AppColors.surfaceDim,
    surfaceBright: AppColors.surface,
    surfaceContainerLowest: AppColors.surfaceContainerLowest,
    surfaceContainerLow: AppColors.surfaceContainerLow,
    surfaceContainer: AppColors.surfaceContainer,
    surfaceContainerHigh: AppColors.surfaceContainerHigh,
    surfaceContainerHighest: AppColors.surfaceContainerHighest,
    outline: AppColors.outline,
    outlineVariant: AppColors.outlineVariant,
    inverseSurface: AppColors.inverseSurface,
    onInverseSurface: AppColors.inverseOnSurface,
    inversePrimary: AppColors.inversePrimary,
    shadow: Colors.black,
    scrim: Colors.black,
  );
  final text = TextTheme(
    displaySmall: AppText.displaySmall,
    headlineLarge: AppText.headlineLarge,
    headlineMedium: AppText.headlineMedium,
    headlineSmall: AppText.headlineSmall,
    titleLarge: AppText.titleLarge,
    titleMedium: AppText.titleMedium,
    titleSmall: AppText.titleSmall,
    bodyLarge: AppText.bodyLarge,
    // 何も指定しない Text は bodyMedium になる。本文は16px以上にするので Body Large と同じにする
    bodyMedium: AppText.bodyLarge,
    bodySmall: AppText.bodySmall,
    labelLarge: AppText.labelLarge,
    labelMedium: AppText.labelMedium,
    labelSmall: AppText.labelSmall,
  ).apply(bodyColor: AppColors.onSurface, displayColor: AppColors.onSurface);

  const pill = StadiumBorder();
  final buttonText = AppText.titleMedium;
  const buttonPad = EdgeInsets.symmetric(horizontal: 24);

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    textTheme: text,
    scaffoldBackgroundColor: AppColors.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      foregroundColor: AppColors.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      // titleTextStyle は付けない（付けると大きな見出しのバーまで小さくなる）。既定で titleLarge・onSurface になる
    ),
    // M3 のボタン（中サイズ・丸い形）。高さ56、文字16
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 56),
        padding: buttonPad,
        textStyle: buttonText,
        shape: pill,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 56),
        padding: buttonPad,
        textStyle: buttonText,
        shape: pill,
        foregroundColor: AppColors.onSurfaceVariant,
        side: const BorderSide(color: AppColors.outlineVariant),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        textStyle: AppText.labelLarge.copyWith(fontSize: 16),
        shape: pill,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(64, 56),
        padding: buttonPad,
        textStyle: buttonText,
        shape: pill,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: AppColors.primaryContainer,
      foregroundColor: AppColors.onPrimaryContainer,
      elevation: 3,
      extendedSizeConstraints: const BoxConstraints(minHeight: 80, minWidth: 80),
      extendedPadding: const EdgeInsets.symmetric(horizontal: 28),
      extendedIconLabelSpacing: 16,
      extendedTextStyle: AppText.titleLarge,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surfaceContainerLow,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    listTileTheme: ListTileThemeData(
      minTileHeight: 56,
      titleTextStyle: AppText.bodyLarge.copyWith(color: AppColors.onSurface),
      subtitleTextStyle: AppText.supporting,
      iconColor: AppColors.onSurfaceVariant,
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
      labelStyle: AppText.bodyLarge,
    ),
    chipTheme: ChipThemeData(
      labelStyle: AppText.labelLarge,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      side: const BorderSide(color: AppColors.outlineVariant),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.outlineVariant, space: 1),
    // M3 の新しい進み具合の棒（すき間と終わりの点つき）
    // ignore: deprecated_member_use
    progressIndicatorTheme: const ProgressIndicatorThemeData(year2023: false),
    sliderTheme: const SliderThemeData(
      // ignore: deprecated_member_use
      year2023: false,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      titleTextStyle: AppText.headlineSmall.copyWith(color: AppColors.onSurface),
      contentTextStyle: AppText.bodyLarge.copyWith(color: AppColors.onSurfaceVariant),
    ),
  );
}

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
  });
  final String label;
  final String? sub;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Semantics(
        inMutuallyExclusiveGroup: true,
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
                          selected
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_unchecked_rounded,
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
