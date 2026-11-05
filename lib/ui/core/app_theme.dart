import 'package:flutter/material.dart';

class AppTheme {
  static const Color bgDark = Color(0xFF14161A);
  static const Color cardDark = Color(0xFF1E2127);
  static const Color borderDark = Color(0xFF33373F);
  static const Color fgText = Color(0xFFE8E8E8);
  static const Color mutedText = Color(0xFF8B909C);
  static const Color accentAmber = Color(0xFFF5A623);
  static const Color accentEmerald = Color(0xFF46A758);
  static const Color alertRed = Color(0xFFE5484D);

  static ThemeData get darkTheme {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: bgDark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accentAmber,
        brightness: Brightness.dark,
        surface: cardDark,
        primary: accentAmber,
        secondary: accentEmerald,
        error: alertRed,
      ),
      cardTheme: CardThemeData(
        color: cardDark,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: borderDark),
        ),
      ),
      dividerColor: borderDark,
      appBarTheme: const AppBarTheme(
        backgroundColor: cardDark,
        foregroundColor: fgText,
        elevation: 0,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        prefixIconConstraints: BoxConstraints(
          minWidth: 32,
          minHeight: 0,
          maxHeight: 32,
        ),
      ),
    );
  }
}
