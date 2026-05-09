import 'package:flutter/material.dart';

import 'bp_palette.dart';

/// Centralised Material 3 theming for the app. Seed colour matches the
/// InnovateAsterisk Browser-Phone accent (#3478F3) so light and dark
/// schemes produce the same recognisable softphone look.
class AppTheme {
  AppTheme._();

  static const Color seed = BPColors.primary;

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    var scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    if (isDark) {
      // Pin the dark surfaces to the exact greys from
      // `phone.dark.css`, so the chrome reads as the BP softphone
      // instead of Flutter's default purple-tinted dark surfaces.
      //   body              #222222   (page)
      //   .buddy:hover      #333333
      //   .buddySelected    #404040
      //   .streamSection    #292929
      //   .callStatus       #333333
      //   borders           #3e3e3e
      //   text              #cccccc
      scheme = scheme.copyWith(
        surface: const Color(0xFF222222),
        onSurface: const Color(0xFFCCCCCC),
        surfaceContainerLowest: const Color(0xFF1B1B1B),
        surfaceContainerLow: const Color(0xFF222222),
        surfaceContainer: const Color(0xFF292929),
        surfaceContainerHigh: const Color(0xFF333333),
        surfaceContainerHighest: const Color(0xFF404040),
        onSurfaceVariant: const Color(0xFF999999),
        outline: const Color(0xFF3E3E3E),
        outlineVariant: const Color(0xFF333333),
      );
    }

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      visualDensity: VisualDensity.standard,
      extensions: <ThemeExtension<dynamic>>[
        isDark ? BrowserPhoneColors.dark : BrowserPhoneColors.light,
      ],
    );
    return base.copyWith(
      scaffoldBackgroundColor: isDark ? BPColors.pageDark : BPColors.pageLight,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: false,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerHighest,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        indicatorColor: scheme.primaryContainer,
        backgroundColor: scheme.surface,
        elevation: 1,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
