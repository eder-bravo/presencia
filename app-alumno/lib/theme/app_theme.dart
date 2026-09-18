import 'package:flutter/material.dart';

abstract final class AppColors {
  // Presencia design tokens shared by the student dashboard.
  static const navy = Color(0xFF003B5C);
  static const navySoft = Color(0xFF174D6B);
  static const background = Color(0xFFF7F8FA);
  static const border = Color(0xFFDCE5EA);
  static const muted = Color(0xFF607382);
  static const steel = Color(0xFFB5CBD9);
  static const apricot = Color(0xFFFFBA82);
  static const action = Color(0xFFB94F00);
  static const pale = Color(0xFFFFF0E4);
  static const green = Color(0xFF18764A);
  static const mint = Color(0xFFE5F3EB);
  static const brandRed = Color(0xFFD01018);
  static const brandRedDark = Color(0xFFE00E17);
  static const indigo = Color(0xFF1D10D0);
  static const indigoDark = Color(0xFF3324F2);
  static const orange = Color(0xFFE8800F);
  static const success = Color(0xFF16A34A);
}

abstract final class AppSpacing {
  static const xs = 8.0;
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 20.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

/// Colores de las pantallas académicas, ajustados al tema activo.
class AppPalette {
  const AppPalette({
    required this.background,
    required this.surface,
    required this.ink,
    required this.muted,
    required this.border,
    required this.header,
    required this.headerSoft,
    required this.headerMuted,
    required this.headerAccent,
    required this.accent,
    required this.accentSurface,
    required this.success,
    required this.successSurface,
    required this.warning,
    required this.warningSurface,
    required this.freeSurface,
  });

  final Color background, surface, ink, muted, border;
  final Color header, headerSoft, headerMuted, headerAccent;
  final Color accent, accentSurface;
  final Color success, successSurface;
  final Color warning, warningSurface, freeSurface;

  static AppPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  static const light = AppPalette(
    background: AppColors.background,
    surface: Colors.white,
    ink: AppColors.navy,
    muted: AppColors.muted,
    border: AppColors.border,
    header: AppColors.navy,
    headerSoft: AppColors.navySoft,
    headerMuted: AppColors.steel,
    headerAccent: AppColors.apricot,
    accent: AppColors.action,
    accentSurface: AppColors.pale,
    success: Color(0xFF146B43),
    successSurface: Color(0xFFE8F5ED),
    warning: Color(0xFF895900),
    warningSurface: Color(0xFFFFF3D9),
    freeSurface: Color(0xFFEAF1F5),
  );

  static const dark = AppPalette(
    background: Color(0xFF101B22),
    surface: Color(0xFF192B35),
    ink: Color(0xFFF3F8FA),
    muted: Color(0xFFADC1CB),
    border: Color(0xFF36505E),
    header: Color(0xFF082D42),
    headerSoft: Color(0xFF1A4B61),
    headerMuted: Color(0xFFB2CCD8),
    headerAccent: Color(0xFFFFD3A6),
    accent: Color(0xFFFFBC80),
    accentSurface: Color(0xFF443428),
    success: Color(0xFF8CE4B2),
    successSurface: Color(0xFF1B3A32),
    warning: Color(0xFFFFD47C),
    warningSurface: Color(0xFF473B28),
    freeSurface: Color(0xFF253A46),
  );
}

ThemeData buildAppTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final background = dark ? AppPalette.dark.background : Colors.white;
  final surface = dark ? AppPalette.dark.surface : const Color(0xFFF7F7F7);
  final text = dark ? AppPalette.dark.ink : const Color(0xFF1E1E1F);
  final muted = dark ? AppPalette.dark.muted : const Color(0xFF78787A);
  final border = dark ? AppPalette.dark.border : const Color(0xFFDDDDDE);

  return ThemeData(
    useMaterial3: true,
    fontFamily: 'Inter',
    brightness: brightness,
    scaffoldBackgroundColor: background,
    colorScheme: ColorScheme.fromSeed(
      seedColor: dark ? AppColors.brandRedDark : AppColors.brandRed,
      brightness: brightness,
      primary: dark ? AppColors.brandRedDark : AppColors.brandRed,
      secondary: dark ? AppColors.indigoDark : AppColors.indigo,
      surface: surface,
    ),
    textTheme: TextTheme(
      headlineSmall: TextStyle(
        fontSize: 23,
        fontWeight: FontWeight.w700,
        color: text,
      ),
      titleLarge: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: text,
      ),
      titleMedium: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: text,
      ),
      bodyLarge: TextStyle(fontSize: 14, color: text),
      bodyMedium: TextStyle(fontSize: 13, color: muted),
      bodySmall: TextStyle(fontSize: 12, color: muted),
      labelSmall: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        color: muted,
      ),
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? AppPalette.dark.surface : const Color(0xFFF0F0F0),
      constraints: const BoxConstraints(minHeight: 52),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.brandRed, width: 1.5),
      ),
    ),
  );
}

Color appSurface(BuildContext context) => Theme.of(context).cardTheme.color!;

Color appMuted(BuildContext context) =>
    Theme.of(context).textTheme.bodyMedium!.color!;
