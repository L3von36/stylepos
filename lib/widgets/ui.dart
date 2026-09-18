import 'package:flutter/material.dart';

import '../services/photo_store.dart';

/// StylePOS design system — built on the Material Design 3 (2021) spec.
///
/// Tokens follow the official M3 guidelines:
///  * Color ........ 26 color roles in a full [ColorScheme]; semantic extras
///                   (success/warning/info) follow the same tonal-pair pattern.
///  * Typography ... M3 type scale roles (display/headline/title/body/label)
///                   in Carlito. Only w400/w700 are registered, so the scale
///                   sticks to those weights (no faux-bold rendering).
///  * Shape ........ M3 shape scale: small 8 / medium 12 / large 16 /
///                   extra-large 28 / full (stadium). No other radii.
///  * Spacing ...... 4dp baseline grid — every gap/padding is a multiple of 4.
///  * Elevation .... M3 levels: cards 0 (outlined), menus 2, dialogs/complex
///                   surfaces 3, FAB 6 (lowered variant 3).
///  * Targets ...... 48dp minimum touch targets, 8dp separation.
///  * Motion ....... M3 page transitions + standard easing/duration tokens.

// ---------------------------------------------------------------------------
// Spacing — 4dp baseline grid (M3 "Spacing methods")
// ---------------------------------------------------------------------------

abstract final class AppSpace {
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 20;
  static const double s6 = 24;
  static const double s8 = 32;
  static const double s10 = 40;
  static const double s12 = 48;
}

// ---------------------------------------------------------------------------
// Shape — M3 shape scale
// ---------------------------------------------------------------------------

abstract final class AppRadius {
  /// Small components: chips, text fields, snackbars, tooltips.
  static const double sm = 8;

  /// Medium components: cards, list tiles, menus, steppers.
  static const double md = 12;

  /// Large components: FAB, hero panels.
  static const double lg = 16;

  /// Extra-large components: dialogs, modal bottom sheets.
  static const double xl = 28;

  /// Full rounding: buttons, status pills.
  static const double pill = 999;
}

// ---------------------------------------------------------------------------
// Motion — M3 duration + easing tokens
// ---------------------------------------------------------------------------

abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 150); // short4
  static const Duration normal = Duration(milliseconds: 200); // short4+ (M3 medium-ish)
  static const Duration slow = Duration(milliseconds: 300);
  static const Curve emphasized = Curves.easeInOutCubicEmphasized;
  static const Curve standard = Curves.easeOutCubic;
}

// ---------------------------------------------------------------------------
// Palette — brand + semantic tones (paired like M3 container roles)
// ---------------------------------------------------------------------------

abstract final class AppColors {
  // Brand (indigo)
  static const primary = Color(0xFF4F46E5); // indigo 600
  static const primaryDark = Color(0xFF3730A3); // indigo 800
  static const primarySoft = Color(0xFFEEF2FF); // indigo 50
  static const primaryContainer = Color(0xFFE0E7FF); // indigo 100

  /// Brand gradient for logo tiles (app bar, sidebar header, receipts).
  static const List<Color> brandGradient = [Color(0xFF4F46E5), Color(0xFF6D28D9)];

  // Neutrals (slate)
  static const ink = Color(0xFF0F172A); // headings
  static const body = Color(0xFF334155); // body text
  static const muted = Color(0xFF64748B); // secondary text (4.8:1 on white)
  static const faint = Color(0xFF94A3B8); // hints / disabled text
  static const border = Color(0xFFCBD5E1); // outline
  static const borderSoft = Color(0xFFE2E8F0); // outlineVariant
  static const background = Color(0xFFF4F5F9);
  static const surfaceTint = Color(0xFFF8FAFC);

  // Semantic (fixed fg + container pairs, M3-style)
  static const success = Color(0xFF059669);
  static const successSoft = Color(0xFFD1FAE5);
  static const warning = Color(0xFFB45309);
  static const warningSoft = Color(0xFFFEF3C7);
  static const danger = Color(0xFFDC2626);
  static const dangerSoft = Color(0xFFFEE2E2);
  static const info = Color(0xFF0284C7);
  static const infoSoft = Color(0xFFE0F2FE);

  /// Coordinated chart palette (reports screen).
  static const chart = [
    Color(0xFF4F46E5), // indigo
    Color(0xFF0D9488), // teal
    Color(0xFFF59E0B), // amber
    Color(0xFFDB2777), // pink
    Color(0xFF7C3AED), // violet
    Color(0xFF0284C7), // sky
    Color(0xFF65A30D), // lime
    Color(0xFFEA580C), // orange
  ];
}

// ---------------------------------------------------------------------------
// Shared component styles
// ---------------------------------------------------------------------------

/// Segmented-button selection in the primary tone. The theme's mint
/// secondaryContainer reads as "success" — right for the payment toggle
/// (money = green), wrong for tabs that select a time range.
ButtonStyle primarySegmentStyle() => ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? AppColors.primarySoft
              : null),
      foregroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? AppColors.primaryDark
              : null),
      side: WidgetStateProperty.resolveWith((states) => BorderSide(
            color: states.contains(WidgetState.selected)
                ? AppColors.primary.withValues(alpha: 0.35)
                : AppColors.border,
          )),
    );

// ---------------------------------------------------------------------------
// Theme — global M3 component themes
// ---------------------------------------------------------------------------

abstract final class AppTheme {
  static ThemeData build() {
    const scheme = ColorScheme(
      brightness: Brightness.light,
      primary: AppColors.primary,
      onPrimary: Colors.white,
      primaryContainer: AppColors.primaryContainer,
      onPrimaryContainer: AppColors.primaryDark,
      secondary: Color(0xFF0F766E),
      onSecondary: Colors.white,
      secondaryContainer: Color(0xFFCCFBF1),
      onSecondaryContainer: Color(0xFF115E59),
      tertiary: Color(0xFF7C3AED),
      onTertiary: Colors.white,
      tertiaryContainer: Color(0xFFEDE9FE),
      onTertiaryContainer: Color(0xFF5B21B6),
      error: AppColors.danger,
      onError: Colors.white,
      errorContainer: AppColors.dangerSoft,
      onErrorContainer: Color(0xFF991B1B),
      surface: Colors.white,
      onSurface: AppColors.ink,
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: AppColors.surfaceTint,
      surfaceContainer: Color(0xFFF1F5F9),
      surfaceContainerHigh: Color(0xFFE8ECF3),
      surfaceContainerHighest: AppColors.borderSoft,
      onSurfaceVariant: AppColors.muted,
      outline: AppColors.border,
      outlineVariant: AppColors.borderSoft,
      shadow: Color(0xFF0F172A),
      inverseSurface: Color(0xFF1E293B),
      onInverseSurface: Color(0xFFF8FAFC),
      inversePrimary: Color(0xFFA5B4FC),
      // Elevated surfaces (dialogs, menus) receive the M3 primary tint.
      surfaceTint: AppColors.primary,
    );

    final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: 'Carlito');

    return base.copyWith(
      scaffoldBackgroundColor: AppColors.background,
      textTheme: _textTheme(base.textTheme),

      // -- App bar: flat, surface-colored, hairline bottom (M3 surface role) --
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: 'Carlito',
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: AppColors.ink,
          height: 28 / 20,
        ),
        shape: Border(bottom: BorderSide(color: AppColors.borderSoft)),
      ),

      // -- Cards: M3 *outlined card* — level-0 elevation, outlineVariant stroke --
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: const BorderSide(color: AppColors.borderSoft),
        ),
      ),

      // -- Dialogs: M3 basic dialog — extra-large shape, level-3 elevation --
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 3,
        shadowColor: const Color(0x240F172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.xl)),
        titleTextStyle: const TextStyle(
          fontFamily: 'Carlito',
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: AppColors.ink,
          height: 28 / 20,
        ),
        contentTextStyle: const TextStyle(
          fontFamily: 'Carlito',
          fontSize: 14,
          height: 20 / 14,
          color: AppColors.body,
        ),
      ),

      // -- Text fields: M3 outlined style — 1dp outline, 2dp active indicator --
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        hintStyle: const TextStyle(color: AppColors.faint),
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.s4, vertical: AppSpace.s3 + 1),
        border: _inputBorder(AppColors.border),
        enabledBorder: _inputBorder(AppColors.border),
        focusedBorder: _inputBorder(AppColors.primary, width: 2),
        errorBorder: _inputBorder(AppColors.danger),
        focusedErrorBorder: _inputBorder(AppColors.danger, width: 2),
      ),

      // -- Buttons: M3 full-round (stadium) shapes, 40dp height, labelLarge --
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          elevation: 0,
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.s5),
          textStyle: const TextStyle(
              fontFamily: 'Carlito', fontSize: 14, fontWeight: FontWeight.w700, letterSpacing: 0.1),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(AppRadius.pill)),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.s4),
          foregroundColor: AppColors.primaryDark,
          side: const BorderSide(color: AppColors.border),
          textStyle: const TextStyle(
              fontFamily: 'Carlito', fontSize: 14, fontWeight: FontWeight.w700, letterSpacing: 0.1),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(AppRadius.pill)),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primary,
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.s3),
          textStyle: const TextStyle(
              fontFamily: 'Carlito', fontSize: 14, fontWeight: FontWeight.w700, letterSpacing: 0.1),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(AppRadius.pill)),
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          side: const WidgetStatePropertyAll(BorderSide(color: AppColors.border)),
          minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontFamily: 'Carlito', fontSize: 13.5, fontWeight: FontWeight.w700),
          ),
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(AppRadius.pill))),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          // M3 touch-target rule: never shrink below 48dp unless density demands.
          minimumSize: const Size(40, 40),
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
      ),

      // -- Chips: small shape (8dp), 32dp height --
      chipTheme: ChipThemeData(
        backgroundColor: Colors.white,
        side: const BorderSide(color: AppColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
        labelStyle: const TextStyle(fontFamily: 'Carlito', fontSize: 13, color: AppColors.body),
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.s2 + 2, vertical: AppSpace.s1),
      ),

      // -- FAB: large shape (16dp), lowered elevation (3) --
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 3,
        focusElevation: 3,
        hoverElevation: 4,
        highlightElevation: 6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
      ),

      // -- Bottom navigation (phones): primaryContainer indicator pill so the
      //    selected tab matches the desktop sidebar's primary selection —
      //    mint (secondaryContainer) stays reserved for success/money --
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: AppColors.primaryContainer,
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
              color: states.contains(WidgetState.selected)
                  ? AppColors.primaryDark
                  : AppColors.muted,
            )),
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
              fontFamily: 'Carlito',
              fontSize: 12,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w700
                  : FontWeight.w400,
              color: states.contains(WidgetState.selected)
                  ? AppColors.primaryDark
                  : AppColors.muted,
            )),
      ),

      // -- List items: 16dp horizontal content padding (M3 list metrics) --
      listTileTheme: ListTileThemeData(
        iconColor: AppColors.muted,
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.s4),
        titleTextStyle: const TextStyle(
            fontFamily: 'Carlito', fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.ink),
        subtitleTextStyle: const TextStyle(
            fontFamily: 'Carlito', fontSize: 12.5, height: 17 / 12.5, color: AppColors.muted),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
      ),

      // -- Snackbars: inverse surface, level-3 elevation, small shape --
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        elevation: 3,
        contentTextStyle: const TextStyle(
            fontFamily: 'Carlito', fontSize: 13.5, color: Color(0xFFF8FAFC), letterSpacing: 0.2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
      ),

      // -- Menus / popovers: medium shape, level-2 elevation --
      popupMenuTheme: PopupMenuThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 3,
        shadowColor: const Color(0x240F172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
        textStyle: const TextStyle(fontFamily: 'Carlito', fontSize: 13.5, color: AppColors.body),
      ),

      dividerTheme: const DividerThemeData(color: AppColors.borderSoft, thickness: 1, space: 1),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.primary,
        linearTrackColor: AppColors.borderSoft,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        textStyle: const TextStyle(fontFamily: 'Carlito', fontSize: 12, color: Color(0xFFF8FAFC)),
      ),

      // -- M3 page transitions (forward + fade) --
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
      }),
    );
  }

  static OutlineInputBorder _inputBorder(Color color, {double width = 1}) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: BorderSide(color: color, width: width),
      );

  /// M3 type scale (2021) in Carlito. Sizes/line-heights follow the spec;
  /// weights are reduced to the two registered cuts (400/700) to avoid
  /// faux-bold synthesis, and display/headline get the spec's -0.25 tracking.
  static TextTheme _textTheme(TextTheme base) {
    const f = 'Carlito';
    return base.copyWith(
      // Headline (largest on-screen text, section/page headers)
      headlineMedium: const TextStyle(
          fontFamily: f, fontSize: 28, height: 36 / 28, letterSpacing: -0.25,
          fontWeight: FontWeight.w700, color: AppColors.ink),
      headlineSmall: const TextStyle(
          fontFamily: f, fontSize: 24, height: 32 / 24, letterSpacing: -0.25,
          fontWeight: FontWeight.w700, color: AppColors.ink),
      // Title (medium-emphasis headers of components)
      titleLarge: const TextStyle(
          fontFamily: f, fontSize: 20, height: 28 / 20,
          fontWeight: FontWeight.w700, color: AppColors.ink),
      titleMedium: const TextStyle(
          fontFamily: f, fontSize: 16, height: 24 / 16, letterSpacing: 0.15,
          fontWeight: FontWeight.w700, color: AppColors.ink),
      titleSmall: const TextStyle(
          fontFamily: f, fontSize: 14, height: 20 / 14, letterSpacing: 0.1,
          fontWeight: FontWeight.w700, color: AppColors.ink),
      // Body (reading text)
      bodyLarge: const TextStyle(
          fontFamily: f, fontSize: 15, height: 22 / 15, letterSpacing: 0.2,
          fontWeight: FontWeight.w400, color: AppColors.body),
      bodyMedium: const TextStyle(
          fontFamily: f, fontSize: 14, height: 20 / 14, letterSpacing: 0.2,
          fontWeight: FontWeight.w400, color: AppColors.body),
      bodySmall: const TextStyle(
          fontFamily: f, fontSize: 12.5, height: 17 / 12.5, letterSpacing: 0.3,
          fontWeight: FontWeight.w400, color: AppColors.muted),
      // Label (buttons, pills, captions, overlines)
      labelLarge: const TextStyle(
          fontFamily: f, fontSize: 14, height: 20 / 14, letterSpacing: 0.1,
          fontWeight: FontWeight.w700, color: AppColors.ink),
      labelMedium: const TextStyle(
          fontFamily: f, fontSize: 12, height: 16 / 12, letterSpacing: 0.3,
          fontWeight: FontWeight.w700, color: AppColors.muted),
      labelSmall: const TextStyle(
          fontFamily: f, fontSize: 11, height: 16 / 11, letterSpacing: 0.4,
          fontWeight: FontWeight.w700, color: AppColors.muted),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared widgets
// ---------------------------------------------------------------------------

/// Screen-level header: headline title, optional subtitle and trailing actions.
class PageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;

  const PageHeader({super.key, required this.title, this.subtitle, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.s4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
                if (subtitle != null) ...[
                  const SizedBox(height: AppSpace.s1),
                  Text(subtitle!, style: Theme.of(context).textTheme.bodyMedium),
                ],
              ],
            ),
          ),
          for (final a in actions) ...[
            const SizedBox(width: AppSpace.s2),
            a,
          ],
        ],
      ),
    );
  }
}

/// White card with an icon + title header and optional trailing action.
class SectionCard extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String? subtitle;
  final Widget? action;
  final EdgeInsets padding;
  final List<Widget> children;

  const SectionCard({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    this.action,
    this.padding = const EdgeInsets.all(AppSpace.s4 + 2),
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: AppColors.primarySoft,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Icon(icon, size: 18, color: AppColors.primary),
                  ),
                  const SizedBox(width: AppSpace.s2 + 2),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: Theme.of(context).textTheme.titleMedium),
                      if (subtitle != null)
                        Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                ?action,
              ],
            ),
            const SizedBox(height: AppSpace.s4),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Soft rounded pill used for stock levels, statuses, roles…
class StatusPill {
  static Widget build(
    BuildContext context, {
    required String label,
    required Color foreground,
    Color? background,
    IconData? icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.s2 + 2, vertical: AppSpace.s1),
      decoration: BoxDecoration(
        color: background ?? Color.lerp(foreground, Colors.white, 0.88),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: foreground),
            const SizedBox(width: AppSpace.s1),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              height: 16 / 12,
              fontWeight: FontWeight.w700,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }

  static Widget stock(BuildContext context, int qty, {String? label}) {
    if (qty <= 0) {
      return build(context,
          label: label ?? 'Out of stock', foreground: AppColors.danger, background: AppColors.dangerSoft);
    }
    if (qty <= 5) {
      return build(context,
          label: label ?? 'Low · $qty', foreground: AppColors.warning, background: AppColors.warningSoft);
    }
    return build(context,
        label: label ?? '$qty in stock', foreground: AppColors.success, background: AppColors.successSoft);
  }
}

/// Friendly empty / zero state.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: const BoxDecoration(
                  color: AppColors.surfaceTint, shape: BoxShape.circle),
              child: Icon(icon, size: 34, color: AppColors.faint),
            ),
            const SizedBox(height: AppSpace.s4),
            Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: AppSpace.s2),
              Text(
                message!,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
            if (actionLabel != null) ...[
              const SizedBox(height: AppSpace.s4),
              // Primary-filled (not tonal): the empty state is THE call to
              // action of a fresh shop — mint/tonal reads as "success chip",
              // not as "tap me".
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// KPI card for reports & dashboards.
class KpiCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final Color soft;

  const KpiCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.color = AppColors.primary,
    this.soft = AppColors.primarySoft,
  });

  @override
  Widget build(BuildContext context) {
    final valueColor = color == AppColors.primary ? AppColors.ink : color;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                      color: soft, borderRadius: BorderRadius.circular(AppRadius.sm)),
                  child: Icon(icon, size: 19, color: color),
                ),
                const SizedBox(width: AppSpace.s2 + 2),
                Expanded(
                  child: Text(
                    label.toUpperCase(),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: AppColors.muted),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.s3),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontSize: 22, color: valueColor),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rounded-square initials avatar.
class InitialsAvatar extends StatelessWidget {
  final String name;
  final double size;
  final Color? color;
  final Color? soft;

  const InitialsAvatar(this.name, {super.key, this.size = 40, this.color, this.soft});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.primary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: soft ?? Color.lerp(c, Colors.white, 0.9),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      alignment: Alignment.center,
      child: Text(
        name.isEmpty ? '?' : name.trim()[0].toUpperCase(),
        style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w700, color: c),
      ),
    );
  }
}

/// Consistent search field used across list screens.
class SearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final VoidCallback? onClear;
  final IconData icon;

  const SearchField({
    super.key,
    required this.controller,
    required this.hint,
    required this.onChanged,
    this.onClear,
    this.icon = Icons.search_rounded,
  });

  @override
  Widget build(BuildContext context) {
    final hasText = controller.text.isNotEmpty;
    return TextField(
      controller: controller,
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(icon, size: 20, color: AppColors.muted),
        suffixIcon: hasText
            ? IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: onClear ?? () => controller.clear(),
              )
            : null,
      ),
    );
  }
}

/// Compact − qty + stepper for cart lines (48dp-friendly hit areas).
class QtyStepper extends StatelessWidget {
  final int qty;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  const QtyStepper({super.key, required this.qty, required this.onMinus, required this.onPlus});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.borderSoft),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _btn(Icons.remove_rounded, onMinus),
          SizedBox(
            width: 28,
            child: Text('$qty',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.ink)),
          ),
          _btn(Icons.add_rounded, onPlus),
        ],
      ),
    );
  }

  Widget _btn(IconData icon, VoidCallback onTap) => SizedBox(
        width: 40,
        height: 40,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          onTap: onTap,
          child: Icon(icon, size: 16, color: AppColors.muted),
        ),
      );
}

/// Product photo thumbnail with a graceful branded fallback.
///
/// Pass [size] for a fixed square, or leave it null to expand to the
/// parent's bounded constraints (e.g. inside an Expanded grid tile).
class ProductThumb extends StatelessWidget {
  final String? image; // relative filename from the product row
  final double? size;
  final IconData icon;
  final double iconSize;
  final double radius;

  const ProductThumb({
    super.key,
    required this.image,
    this.size,
    this.icon = Icons.checkroom_rounded,
    this.iconSize = 24,
    this.radius = AppRadius.sm,
  });

  Widget _fallback() => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.primarySoft,
              Color(0xFFE0E7FF),
            ],
          ),
        ),
        child: Icon(icon, size: iconSize, color: AppColors.primary.withValues(alpha: 0.7)),
      );

  @override
  Widget build(BuildContext context) {
    final name = image?.trim() ?? '';
    if (name.isEmpty) {
      return ClipRRect(borderRadius: BorderRadius.circular(radius), child: _fallback());
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final decodeWidth = ((size ?? 320) * dpr).round().clamp(64, 1600);
    final prov = photoProvider(name, cacheWidth: decodeWidth);
    if (prov == null) {
      return ClipRRect(borderRadius: BorderRadius.circular(radius), child: _fallback());
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image(
        image: prov,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _fallback(),
      ),
    );
  }
}
