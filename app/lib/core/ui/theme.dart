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

  /// 写真の後ろの暗い色（Figma の写真の枠と同じ）
  static const photoBackdrop = Color(0xFF2C3134);
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
