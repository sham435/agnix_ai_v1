/// The Shams AI design system.
///
/// Every colour here is a fixed hex from the design brief - no package fonts,
/// no theme derivation surprises. The platform default font (SF Pro on macOS,
/// Roboto on Android) is used everywhere by simply *not* specifying a family.
///
/// The palettes are declared as named tokens ([ShamsPalette.dark] and
/// [ShamsPalette.light]) and [shamsTheme] maps them onto Material 3's
/// [ColorScheme] slots, so a screen asks for "the elevated surface" rather than
/// a hex - restyling a surface later means touching one token, not N screens.
library;

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// The cyan accent of the brief - links, focus accents, small highlights.
///
/// The *brand* gradient ([brandGradient]) mixes this with the violet and blue
/// primaries; per-element decoration chooses which tone to lean on instead of
/// one accent flooding every surface.
const Color accent = Color(0xFF22D3EE);

/// The teal channel of the brief, used as a soft tertiary accent.
const Color teal = Color(0xFF2DD4BF);

/// Fixed tokens from the design brief, split per brightness.
///
/// Kept private to this file on purpose: widgets read them back through the
/// ambient [ColorScheme] (or [shamsTheme]) so a restyle stays a one-file affair.
class ShamsPalette {
  ShamsPalette._();

  // Dark.
  static const Color darkBackground = Color(0xFF0B1020);
  static const Color darkSurface = Color(0xFF121A2B);
  static const Color darkElevated = Color(0xFF1B2740);
  static const Color darkPrimary = Color(0xFF8B5CF6);
  static const Color darkSecondary = Color(0xFF3B82F6);
  static const Color darkAccent = Color(0xFF22D3EE);
  static const Color darkTeal = Color(0xFF2DD4BF);
  static const Color darkText = Color(0xFFF5F7FF);
  static const Color darkSecondaryText = Color(0xFFA5B0C5);
  static const Color darkSuccess = Color(0xFF34D399);
  static const Color darkWarning = Color(0xFFFBBF24);
  static const Color darkError = Color(0xFFFB7185);
  // Derived darks (not in the brief, but needed by material slots): the deep
  // code-block panel and the hairline borders that keep surfaces apart.
  static const Color darkCodeBlock = Color(0xFF0A0F1E);
  static const Color darkBorder = Color(0xFF232F4B);
  static const Color darkBorderStrong = Color(0xFF31405F);

  // Light.
  static const Color lightBackground = Color(0xFFF6F7FC);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightElevated = Color(0xFFEEF1FA);
  static const Color lightPrimary = Color(0xFF7048E8);
  static const Color lightSecondary = Color(0xFF2563EB);
  static const Color lightAccent = Color(0xFF0891B2);
  static const Color lightText = Color(0xFF182033);
  static const Color lightSecondaryText = Color(0xFF667085);
  static const Color lightSuccess = Color(0xFF059669);
  static const Color lightWarning = Color(0xFFB45309);
  static const Color lightError = Color(0xFFE11D48);
  // Derived lights, same purpose as the derived darks above.
  static const Color lightCodeBlock = Color(0xFFF6F8FE);
  static const Color lightBorder = Color(0xFFE2E6F2);
  static const Color lightBorderStrong = Color(0xFFD3D9EC);
}

/// The violet -> blue -> cyan brand gradient of the brief.
///
/// Used sparingly - the emblem, the welcome heading underline and selected
/// interactive elements such as the send button - never as page decoration.
const List<Color> brandGradient = <Color>[
  Color(0xFF8B5CF6),
  Color(0xFF3B82F6),
  Color(0xFF22D3EE),
];

/// A ready-made [LinearGradient] of [brandGradient], horizontal by default.
LinearGradient brandLinearGradient({Alignment begin = Alignment.centerLeft,
    Alignment end = Alignment.centerRight}) {
  return LinearGradient(colors: brandGradient, begin: begin, end: end);
}

/// The user message bubble: violet-tinted on dark, near-black inverse on light.
///
/// Solid by design - gradients are reserved for the selected interactive
/// elements listed in the brief, and a gradient behind every pathname the user
/// would have been visual noise.
Color userBubbleColor(Brightness brightness) => brightness == Brightness.dark
    ? const Color(0xFF253356)
    : const Color(0xFF121A2B);

/// Text drawn on top of [userBubbleColor] - white in both modes.
const Color userBubbleTextColor = Colors.white;

/// The one-off palette of a nested surface (prompt cards, the composer fill).
Color chipColor(Brightness brightness) => brightness == Brightness.dark
    ? ShamsPalette.darkElevated
    : ShamsPalette.lightElevated;

/// Builds the whole [ThemeData] for a brightness. Follows the OS unless a
/// [ThemeMode] override is in place (`MaterialApp` resolves `theme`/`darkTheme`
/// against the ambient brightness, so nothing in-theme needs to know which
/// mode is showing).
ThemeData shamsTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final appBg = isDark ? ShamsPalette.darkBackground : ShamsPalette.lightBackground;
  final surface = isDark ? ShamsPalette.darkSurface : ShamsPalette.lightSurface;
  final elevated = isDark ? ShamsPalette.darkElevated : ShamsPalette.lightElevated;
  final border = isDark ? ShamsPalette.darkBorder : ShamsPalette.lightBorder;
  final borderStrong = isDark
      ? ShamsPalette.darkBorderStrong
      : ShamsPalette.lightBorderStrong;

  final scheme = ColorScheme.fromSeed(
    seedColor: isDark ? ShamsPalette.darkPrimary : ShamsPalette.lightPrimary,
    brightness: brightness,
  ).copyWith(
    primary: isDark ? ShamsPalette.darkPrimary : ShamsPalette.lightPrimary,
    onPrimary: Colors.white,
    secondary: isDark ? ShamsPalette.darkSecondary : ShamsPalette.lightSecondary,
    onSecondary: Colors.white,
    tertiary: isDark ? ShamsPalette.darkTeal : ShamsPalette.lightAccent,
    onTertiary: isDark ? const Color(0xFF04241F) : Colors.white,
    primaryContainer: isDark
        ? const Color(0xFF2B1E52)
        : const Color(0xFFE7DEFF),
    onPrimaryContainer: isDark
        ? const Color(0xFFD7C6FF)
        : const Color(0xFF2A1666),
    error: isDark ? ShamsPalette.darkError : ShamsPalette.lightError,
    errorContainer: isDark
        ? const Color(0xFF4C1F33)
        : const Color(0xFFFFE4E9),
    onErrorContainer: isDark
        ? const Color(0xFFFFC9D4)
        : const Color(0xFF7A0C24),
    surface: appBg,
    onSurface: isDark ? ShamsPalette.darkText : ShamsPalette.lightText,
    onSurfaceVariant: isDark
        ? ShamsPalette.darkSecondaryText
        : ShamsPalette.lightSecondaryText,
    surfaceContainerLowest: isDark
        ? ShamsPalette.darkCodeBlock
        : ShamsPalette.lightSurface,
    surfaceContainerLow: surface,
    surfaceContainer: elevated,
    surfaceContainerHigh: isDark
        ? const Color(0xFF22304D)
        : ShamsPalette.lightBorder,
    surfaceContainerHighest: isDark
        ? const Color(0xFF2A3A5C)
        : ShamsPalette.lightBorderStrong,
    outline: border,
    outlineVariant: borderStrong,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: appBg,
    textTheme: TextTheme(
      bodyLarge: TextStyle(fontSize: 16, height: 1.45, color: scheme.onSurface),
      bodyMedium: TextStyle(fontSize: 15, height: 1.4, color: scheme.onSurface),
      bodySmall: TextStyle(
        fontSize: 13,
        height: 1.35,
        color: scheme.onSurfaceVariant,
      ),
      titleLarge: TextStyle(
        fontSize: 18,
        height: 1.3,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        height: 1.3,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      titleSmall: TextStyle(
        fontSize: 14,
        height: 1.3,
        fontWeight: FontWeight.w500,
        color: scheme.onSurface,
      ),
      headlineMedium: TextStyle(
        fontSize: 26,
        height: 1.25,
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
      ),
      labelLarge: TextStyle(
        fontSize: 14,
        height: 1.2,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        height: 1.2,
        fontWeight: FontWeight.w500,
        color: scheme.onSurface,
      ),
      labelSmall: TextStyle(
        fontSize: 12,
        height: 1.2,
        fontWeight: FontWeight.w500,
        color: scheme.onSurfaceVariant,
      ),
    ),
    colorSchemeSeed: null,
    appBarTheme: AppBarTheme(
      backgroundColor: appBg,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
        height: 1.3,
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: scheme.primary,
      selectionColor: scheme.primary.withValues(alpha: 0.3),
      selectionHandleColor: scheme.primary,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: Colors.white,
        disabledBackgroundColor: isDark
            ? const Color(0xFF3A4462)
            : const Color(0xFFD9DCE8),
        disabledForegroundColor: Colors.white.withValues(alpha: 0.55),
        shape: const StadiumBorder(),
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: Colors.white,
      shape: const StadiumBorder(),
      elevation: 1,
      focusElevation: 1,
      hoverElevation: 2,
      highlightElevation: 2,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainer,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      hintStyle: TextStyle(fontSize: 16, color: scheme.onSurfaceVariant),
      labelStyle: TextStyle(fontSize: 16, color: scheme.onSurfaceVariant),
      floatingLabelStyle: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: scheme.onSurfaceVariant,
      ),
      border: _inputRadius(14, BorderSide(color: scheme.outline)),
      enabledBorder: _inputRadius(14, BorderSide(color: scheme.outline)),
      focusedBorder: _inputRadius(
        14,
        BorderSide(color: scheme.primary, width: 1.5),
      ),
      disabledBorder: _inputRadius(14, BorderSide(color: scheme.outline)),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      iconColor: scheme.onSurfaceVariant,
      titleTextStyle: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: scheme.onSurface,
      ),
      subtitleTextStyle: TextStyle(
        fontSize: 12.5,
        color: scheme.onSurfaceVariant,
      ),
      selectedTileColor: scheme.surfaceContainer,
    ),
    dividerTheme: DividerThemeData(color: border, thickness: 0.5, space: 0.5),
    drawerTheme: DrawerThemeData(
      backgroundColor: surface,
      shape: const RoundedRectangleBorder(),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      showDragHandle: false,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: isDark ? elevated : ShamsPalette.lightText,
      contentTextStyle: const TextStyle(fontSize: 14, color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHighest,
    ),
    extensions: [_markdown(brightness, scheme)],
  );
}

OutlineInputBorder _inputRadius(double radius, BorderSide side) =>
    OutlineInputBorder(
      borderRadius: BorderRadius.circular(radius),
      borderSide: side,
    );

/// The Markdown look the assistant transcript renders with.
///
/// `GptMarkdown` reads this from the ambient theme, so every reply shares one
/// definition of a heading, a link, inline `code`. Links and focus accents
/// follow the primary violet; inline code chips get the 12px rounding and an
/// elevated fill; fenced code blocks live on the deep panel with their own
/// copy affordance (the renderer's built-in one).
GptMarkdownThemeData _markdown(Brightness brightness, ColorScheme scheme) {
  final isDark = brightness == Brightness.dark;
  final headlineBase = TextStyle(height: 1.35, color: scheme.onSurface);
  return GptMarkdownThemeData(
    brightness: brightness,
    linkColor: scheme.primary,
    linkHoverColor: scheme.secondary,
    h1: headlineBase.copyWith(fontSize: 20, fontWeight: FontWeight.w600),
    h2: headlineBase.copyWith(fontSize: 18, fontWeight: FontWeight.w600),
    h3: headlineBase.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
    hrLineColor: scheme.outline,
    autoAddDividerLineAfterH1: false,
    inlineCode: InlineCodeStyle(
      color: scheme.onSurface,
      backgroundColor: scheme.surfaceContainerHigh,
      borderColor: Colors.transparent,
      borderWidth: 0,
      borderRadius: const Radius.circular(12),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    ),
    styleSheet: GptMarkdownStyleSheet(
      codeBlock: CodeBlockStyle(
        backgroundColor: isDark
            ? ShamsPalette.darkCodeBlock
            : ShamsPalette.lightCodeBlock,
        textColor: scheme.onSurface,
        borderColor: scheme.outline,
        // The copy affordance on every fenced block - "Copy code" while
        // idle, flipping to the renderer's confirmation label once taken
        // (the labels are fixed defaults; only the *presence* is ours).
        showCopyButton: true,
      ),
    ),
  );
}
