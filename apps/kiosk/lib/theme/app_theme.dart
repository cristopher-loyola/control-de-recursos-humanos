import 'package:flutter/material.dart';

ThemeData createAppTheme() {
  const ink = Color(0xFF182925);
  const muted = Color(0xFF53645E);
  const accent = Color(0xFF0F766E);
  const line = Color(0xFFDCE4DF);
  final scheme = ColorScheme.fromSeed(seedColor: accent).copyWith(
    primary: accent,
    onPrimary: Colors.white,
    surface: Colors.white,
    onSurface: ink,
    onSurfaceVariant: muted,
    outline: const Color(0xFF7A8B83),
    outlineVariant: line,
    error: const Color(0xFFB42318),
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  final type = base.textTheme.apply(bodyColor: ink, displayColor: ink);
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(10));
  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: const BorderSide(color: line),
  );

  return base.copyWith(
    scaffoldBackgroundColor: const Color(0xFFF5F7F5),
    materialTapTargetSize: MaterialTapTargetSize.padded,
    textTheme: type.copyWith(
      headlineMedium: type.headlineMedium?.copyWith(
        fontSize: 30,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.6,
      ),
      titleLarge: type.titleLarge?.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
      titleMedium: type.titleMedium?.copyWith(
        fontSize: 17,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: type.bodyLarge?.copyWith(fontSize: 16, height: 1.45),
      bodyMedium: type.bodyMedium?.copyWith(fontSize: 15, height: 1.45),
      bodySmall: type.bodySmall?.copyWith(color: muted, height: 1.4),
    ),
    appBarTheme: const AppBarThemeData(
      backgroundColor: Colors.white,
      foregroundColor: ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: ink,
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
      shape: Border(bottom: BorderSide(color: line)),
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: shape.copyWith(side: const BorderSide(color: line)),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      iconColor: accent,
      textColor: ink,
      minVerticalPadding: 12,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      labelStyle: const TextStyle(color: muted),
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(
        borderSide: const BorderSide(color: accent, width: 2),
      ),
      errorBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: scheme.error, width: 2),
      ),
      errorMaxLines: 3,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        shape: shape,
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: accent,
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        shape: shape,
        side: const BorderSide(color: accent),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accent,
        minimumSize: const Size(48, 48),
        shape: shape,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: accent,
        minimumSize: const Size(48, 48),
      ),
    ),
    dividerTheme: const DividerThemeData(color: line, thickness: 1),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: accent),
  );
}
