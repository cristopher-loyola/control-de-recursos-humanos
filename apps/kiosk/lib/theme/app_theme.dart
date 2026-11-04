import 'package:flutter/material.dart';

/// Minimalismo funcional: neutros cálidos, un solo acento verde usado con
/// moderación, bordes de 1 px, radios pequeños y sin sombras ni degradados.
abstract final class AppColors {
  static const ink = Color(0xFF1C1B19);
  static const muted = Color(0xFF6B6963);
  static const line = Color(0xFFE5E3DE);
  static const background = Color(0xFFF7F6F3);
  static const surface = Color(0xFFFFFFFF);
  static const selected = Color(0xFFEFEDE8);
  static const accent = Color(0xFF2F5D46);
  static const accentPressed = Color(0xFF244A37);
  static const danger = Color(0xFFA8322A);
}

ThemeData createAppTheme() {
  const ink = AppColors.ink;
  const muted = AppColors.muted;
  const accent = AppColors.accent;
  const line = AppColors.line;
  final scheme = ColorScheme.fromSeed(seedColor: accent).copyWith(
    primary: accent,
    onPrimary: Colors.white,
    secondary: ink,
    onSecondary: Colors.white,
    surface: AppColors.surface,
    onSurface: ink,
    onSurfaceVariant: muted,
    surfaceContainerHighest: AppColors.selected,
    outline: const Color(0xFFB9B6AE),
    outlineVariant: line,
    error: AppColors.danger,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  final type = base.textTheme.apply(bodyColor: ink, displayColor: ink);
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(6));
  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(6),
    borderSide: const BorderSide(color: line),
  );

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    splashFactory: NoSplash.splashFactory,
    textTheme: type.copyWith(
      headlineMedium: type.headlineMedium?.copyWith(
        fontSize: 26,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.4,
      ),
      headlineSmall: type.headlineSmall?.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
      titleLarge: type.titleLarge?.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
      titleMedium: type.titleMedium?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: type.bodyLarge?.copyWith(fontSize: 16, height: 1.45),
      bodyMedium: type.bodyMedium?.copyWith(fontSize: 15, height: 1.45),
      bodySmall: type.bodySmall?.copyWith(color: muted, height: 1.4),
      labelLarge: type.labelLarge?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
    ),
    appBarTheme: const AppBarThemeData(
      backgroundColor: AppColors.surface,
      foregroundColor: ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: ink,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
      shape: Border(bottom: BorderSide(color: line)),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: shape.copyWith(side: const BorderSide(color: line)),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      iconColor: muted,
      textColor: ink,
      minVerticalPadding: 10,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      labelStyle: const TextStyle(color: muted),
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(
        borderSide: const BorderSide(color: ink, width: 1.5),
      ),
      errorBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: scheme.error, width: 1.5),
      ),
      errorMaxLines: 3,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        disabledBackgroundColor: AppColors.selected,
        disabledForegroundColor: muted,
        minimumSize: const Size(48, 46),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: shape,
        elevation: 0,
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ink,
        minimumSize: const Size(48, 46),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: shape,
        side: const BorderSide(color: line),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accent,
        minimumSize: const Size(48, 44),
        shape: shape,
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: ink,
        minimumSize: const Size(48, 48),
      ),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: ink,
      unselectedLabelColor: muted,
      indicatorColor: ink,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: line,
      labelStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      unselectedLabelStyle: TextStyle(fontSize: 15),
    ),
    dividerTheme: const DividerThemeData(color: line, thickness: 1, space: 1),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: line),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: ink,
      behavior: SnackBarBehavior.floating,
      elevation: 0,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: accent,
      linearTrackColor: line,
    ),
  );
}
