import 'package:flutter/material.dart';

/// StylePOS design system.
///
/// A single place for the brand palette, the global [AppTheme] and the
/// shared building blocks (page headers, section cards, status pills,
/// KPI cards, empty states…) so every screen looks like one product.

// ---------------------------------------------------------------------------
// Palette
// ---------------------------------------------------------------------------

abstract final class AppColors {
  // Brand
  static const primary = Color(0xFF4F46E5); // indigo 600
  static const primaryDark = Color(0xFF3730A3); // indigo 800
  static const primarySoft = Color(0xFFEEF2FF); // indigo 50

  // Neutrals (slate)
  static const ink = Color(0xFF0F172A); // headings
  static const body = Color(0xFF334155); // body text
  static const muted = Color(0xFF64748B); // secondary text
  static const faint = Color(0xFF94A3B8); // hints / disabled text
  static const border = Color(0xFFE2E8F0);
  static const borderSoft = Color(0xFFEDF0F5);
  static const background = Color(0xFFF4F5F9);
  static const surfaceTint = Color(0xFFF8FAFC);

  // Semantic
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
// Theme
// ---------------------------------------------------------------------------

abstract final class AppTheme {
  static ThemeData build() {
    const scheme = ColorScheme(
      brightness: Brightness.light,
      primary: AppColors.primary,
      onPrimary: Colors.white,
      primaryContainer: Color(0xFFE0E7FF),
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
      surfaceContainerHighest: AppColors.border,
      onSurfaceVariant: AppColors.muted,
      outline: Color(0xFFCBD5E1),
      outlineVariant: AppColors.border,
      shadow: Color(0xFF0F172A),
      inverseSurface: Color(0xFF1E293B),
      onInverseSurface: Color(0xFFF8FAFC),
      inversePrimary: Color(0xFFA5B4FC),
      surfaceTint: Colors.transparent,
    );

    final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: 'Carlito');

    return base.copyWith(
      scaffoldBackgroundColor: AppColors.background,
      textTheme: _textTheme(base.textTheme),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: 'Carlito',
          fontSize: 19,
          fontWeight: FontWeight.w700,
          color: AppColors.ink,
        ),
        shape: Border(bottom: BorderSide(color: AppColors.borderSoft)),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.borderSoft),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        titleTextStyle: const TextStyle(
          fontFamily: 'Carlito',
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: AppColors.ink,
        ),
        contentTextStyle: const TextStyle(
          fontFamily: 'Carlito',
          fontSize: 14,
          color: AppColors.body,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        hintStyle: const TextStyle(color: AppColors.faint),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        border: _inputBorder(AppColors.border),
        enabledBorder: _inputBorder(AppColors.border),
        focusedBorder: _inputBorder(AppColors.primary, width: 1.6),
        errorBorder: _inputBorder(AppColors.danger),
        focusedErrorBorder: _inputBorder(AppColors.danger, width: 1.6),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          elevation: 0,
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          textStyle: const TextStyle(fontFamily: 'Carlito', fontSize: 14.5, fontWeight: FontWeight.w700),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          foregroundColor: AppColors.primaryDark,
          side: const BorderSide(color: AppColors.border),
          textStyle: const TextStyle(fontFamily: 'Carlito', fontSize: 14.5, fontWeight: FontWeight.w700),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primary,
          textStyle: const TextStyle(fontFamily: 'Carlito', fontSize: 14, fontWeight: FontWeight.w700),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          side: const WidgetStatePropertyAll(BorderSide(color: AppColors.border)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontFamily: 'Carlito', fontSize: 13.5, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.white,
        side: const BorderSide(color: AppColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        labelStyle: const TextStyle(fontFamily: 'Carlito', fontSize: 13, color: AppColors.body),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: Colors.white,
        indicatorColor: AppColors.primarySoft,
        selectedIconTheme: const IconThemeData(color: AppColors.primary),
        unselectedIconTheme: const IconThemeData(color: AppColors.muted),
        selectedLabelTextStyle: const TextStyle(
            fontFamily: 'Carlito', fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.primary),
        unselectedLabelTextStyle:
            const TextStyle(fontFamily: 'Carlito', fontSize: 13, color: AppColors.muted),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: AppColors.muted,
        titleTextStyle: const TextStyle(
            fontFamily: 'Carlito', fontSize: 14.5, fontWeight: FontWeight.w600, color: AppColors.ink),
        subtitleTextStyle:
            const TextStyle(fontFamily: 'Carlito', fontSize: 12.5, color: AppColors.muted),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF1E293B),
        contentTextStyle: const TextStyle(fontFamily: 'Carlito', fontSize: 13.5, color: Color(0xFFF8FAFC)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dividerTheme: const DividerThemeData(color: AppColors.borderSoft, thickness: 1, space: 1),
      popupMenuTheme: PopupMenuThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shadowColor: const Color(0x1F0F172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontFamily: 'Carlito', fontSize: 13.5, color: AppColors.body),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.primary,
        linearTrackColor: AppColors.borderSoft,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: const TextStyle(fontFamily: 'Carlito', fontSize: 12, color: Color(0xFFF8FAFC)),
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: color, width: width),
      );

  static TextTheme _textTheme(TextTheme base) {
    const f = 'Carlito';
    return base.copyWith(
      headlineMedium: const TextStyle(fontFamily: f, fontSize: 30, fontWeight: FontWeight.w700, color: AppColors.ink),
      headlineSmall: const TextStyle(fontFamily: f, fontSize: 24, fontWeight: FontWeight.w700, color: AppColors.ink),
      titleLarge: const TextStyle(fontFamily: f, fontSize: 19, fontWeight: FontWeight.w700, color: AppColors.ink),
      titleMedium: const TextStyle(fontFamily: f, fontSize: 15.5, fontWeight: FontWeight.w700, color: AppColors.ink),
      titleSmall: const TextStyle(fontFamily: f, fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.ink),
      bodyLarge: const TextStyle(fontFamily: f, fontSize: 14.5, color: AppColors.body),
      bodyMedium: const TextStyle(fontFamily: f, fontSize: 14, color: AppColors.body),
      bodySmall: const TextStyle(fontFamily: f, fontSize: 12.5, color: AppColors.muted),
      labelLarge: const TextStyle(fontFamily: f, fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.ink),
      labelSmall: const TextStyle(fontFamily: f, fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.muted),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared widgets
// ---------------------------------------------------------------------------

/// Screen-level header: big title, optional subtitle and trailing actions.
class PageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;

  const PageHeader({super.key, required this.title, this.subtitle, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
          for (final a in actions) ...[
            const SizedBox(width: 10),
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
    this.padding = const EdgeInsets.all(18),
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
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: AppColors.primarySoft,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(icon, size: 17, color: AppColors.primary),
                  ),
                  const SizedBox(width: 10),
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
            const SizedBox(height: 14),
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
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: background ?? Color.lerp(foreground, Colors.white, 0.88),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: foreground),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
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
      return build(context, label: label ?? 'Out of stock', foreground: AppColors.danger, background: AppColors.dangerSoft);
    }
    if (qty <= 5) {
      return build(context, label: label ?? 'Low · $qty', foreground: AppColors.warning, background: AppColors.warningSoft);
    }
    return build(context, label: label ?? '$qty in stock', foreground: AppColors.success, background: AppColors.successSoft);
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
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: const BoxDecoration(color: AppColors.surfaceTint, shape: BoxShape.circle),
              child: Icon(icon, size: 34, color: AppColors.faint),
            ),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(
                message!,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
            if (actionLabel != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonal(onPressed: onAction, child: Text(actionLabel!)),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(color: soft, borderRadius: BorderRadius.circular(10)),
                  child: Icon(icon, size: 18, color: color),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 21, color: color == AppColors.primary ? AppColors.ink : color),
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

  const InitialsAvatar(this.name, {super.key, this.size = 42, this.color, this.soft});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.primary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: soft ?? Color.lerp(c, Colors.white, 0.9),
        borderRadius: BorderRadius.circular(size * 0.3),
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

/// Compact − qty + stepper for cart lines.
class QtyStepper extends StatelessWidget {
  final int qty;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  const QtyStepper({super.key, required this.qty, required this.onMinus, required this.onPlus});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _btn(Icons.remove_rounded, onMinus),
          SizedBox(
            width: 26,
            child: Text('$qty', textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.ink)),
          ),
          _btn(Icons.add_rounded, onPlus),
        ],
      ),
    );
  }

  Widget _btn(IconData icon, VoidCallback onTap) => InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
          child: Icon(icon, size: 16, color: AppColors.muted),
        ),
      );
}
