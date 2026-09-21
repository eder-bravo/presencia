import 'package:flutter/material.dart';

abstract final class AppColors {
  // RGB sampled from the supplied UAT identity reference (screen approximations).
  static const uatOrange = Color(0xFFCF5F2B); // Pantone 159 C
  static const uatTerracotta = Color(0xFFBA4B2A); // Pantone 1525 C
  static const uatGray = Color(0xFF55575B); // Pantone Cool Gray 11 C
  static const uatBlue = Color(0xFF003E5B); // Pantone 302 C

  // Institutional tints mixed with white.
  static const orange60 = Color(0xFFE29F80);
  static const orange40 = Color(0xFFECBFAA);
  static const terracotta40 = Color(0xFFE3B7AA);
  static const gray40 = Color(0xFFBBBCBD);
  static const gray20 = Color(0xFFDDDDDE);
  static const blue80 = Color(0xFF33657C);
  static const blue40 = Color(0xFF99B2BD);
  static const blue20 = Color(0xFFCCD8DE);

  // Subtle neutral and tinted surfaces keep small accent labels legible.
  static const background = Color(0xFFF7F7F5);
  static const orangeSurface = Color(0xFFFBF2EE);
  static const terracottaSurface = Color(0xFFFBF1EE);
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
    ink: Color(0xFF252629),
    muted: AppColors.uatGray,
    border: AppColors.gray20,
    header: AppColors.uatBlue,
    headerSoft: AppColors.blue80,
    headerMuted: AppColors.blue20,
    headerAccent: AppColors.orange40,
    accent: AppColors.uatTerracotta,
    accentSurface: AppColors.orangeSurface,
    success: AppColors.uatBlue,
    successSurface: AppColors.blue20,
    warning: AppColors.uatTerracotta,
    warningSurface: AppColors.terracottaSurface,
    freeSurface: Color(0xFFEEEEEF),
  );

  static const dark = AppPalette(
    background: Color(0xFF161617),
    surface: Color(0xFF232325),
    ink: Color(0xFFF3F3F3),
    muted: AppColors.gray40,
    border: Color(0xFF37383A),
    header: AppColors.uatBlue,
    headerSoft: AppColors.blue80,
    headerMuted: AppColors.blue20,
    headerAccent: AppColors.orange40,
    accent: AppColors.orange60,
    accentSurface: Color(0xFF382A25),
    success: AppColors.blue40,
    successSurface: Color(0xFF20313B),
    warning: AppColors.terracotta40,
    warningSurface: Color(0xFF392A26),
    freeSurface: Color(0xFF2A2B2D),
  );
}

ThemeData buildAppTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final palette = dark ? AppPalette.dark : AppPalette.light;
  final background = palette.background;
  final surface = palette.surface;
  final text = palette.ink;
  final muted = palette.muted;
  final border = palette.border;

  return ThemeData(
    useMaterial3: true,
    fontFamily: 'Inter',
    brightness: brightness,
    scaffoldBackgroundColor: background,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.uatOrange,
      brightness: brightness,
      primary: palette.accent,
      onPrimary: dark ? palette.background : Colors.white,
      primaryContainer: palette.accentSurface,
      onPrimaryContainer: palette.accent,
      secondary: palette.success,
      onSecondary: dark ? palette.background : Colors.white,
      secondaryContainer: palette.successSurface,
      onSecondaryContainer: palette.success,
      tertiary: palette.warning,
      onTertiary: dark ? palette.background : Colors.white,
      tertiaryContainer: palette.warningSurface,
      onTertiaryContainer: palette.warning,
      error: palette.warning,
      onError: dark ? palette.background : Colors.white,
      errorContainer: palette.warningSurface,
      onErrorContainer: palette.warning,
      surface: surface,
      onSurface: text,
      outline: border,
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
      fillColor: palette.freeSurface,
      constraints: const BoxConstraints(minHeight: 52),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: palette.accent, width: 1.5),
      ),
    ),
  );
}

Color appSurface(BuildContext context) => Theme.of(context).cardTheme.color!;

Color appMuted(BuildContext context) =>
    Theme.of(context).textTheme.bodyMedium!.color!;
