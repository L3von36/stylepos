import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/product.dart';
import '../../services/scan_gate.dart';
import '../../state/attendance.dart';
import '../../state/auth.dart';
import '../../state/cart.dart';
import '../../state/catalog.dart';
import '../../state/commissions.dart';
import '../../state/nav.dart';
import '../../state/sales.dart';
import '../../state/sell_view.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';
import 'cart_panel.dart';
import 'scan_dialog.dart';
import 'variant_picker_dialog.dart';

/// The sell screen: product grid on the left, cart on the right (wide),
/// or a cart FAB + bottom sheet on narrow screens (phones).
///
/// Barcode workflow: hardware scanners type into the focused field and
/// press Enter; on phones the camera button opens a live scanner. The
/// [ScanGate] guarantees one physical scan adds exactly one item even
/// though scanners/cameras can emit the same code several times.
class PosScreen extends StatefulWidget {
  const PosScreen({super.key});

  @override
  State<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends State<PosScreen> {
  final _search = TextEditingController();
  final _scanFocus = FocusNode();
  final ScanGate _gate = ScanGate();
  // Search text + category chip live in SellViewState (provider-owned,
  // restored/persisted with the rest of the shell state) — this State
  // only owns widgets: the text controller and the scan focus node.

  bool get _cameraAvailable => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void dispose() {
    _search.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  void _refocus() {
    _search.clear();
    context.read<SellViewState>().setQuery('');
    _scanFocus.requestFocus();
  }

  void _toast(String msg, Color color) {
    if (!mounted) return;
    // Fixed-width snackbars overflow small phones — only use the compact
    // centered shape when the screen is wide enough for it.
    final screenW = MediaQuery.sizeOf(context).width;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        width: screenW >= 428 ? 380 : null,
        backgroundColor: color,
        duration: const Duration(milliseconds: 1600),
      ));
  }

  /// Tries to ring up [code] as an exact item code.
  /// Returns true when handled (added or rejected as duplicate).
  /// When [strict] is set (camera path) unknown codes show an error;
  /// from the keyboard path unknown codes fall through to text search.
  bool _tryRingUp(String rawCode, {required bool strict}) {
    final code = rawCode.trim();
    if (code.isEmpty) return false;

    final catalog = context.read<CatalogProvider>();
    final cart = context.read<CartProvider>();

    // One scan = one item: swallow repeats inside the cooldown window.
    if (!_gate.accept(code)) {
      _toast('Already added just now — scan again to repeat', AppColors.warning);
      return true;
    }

    // Exact variant barcode / SKU -> add one unit.
    final match = catalog.findByCode(code);
    if (match != null) {
      final ok = cart.add(match.$1, match.$2);
      if (ok) {
        HapticFeedback.selectionClick();
      } else {
        HapticFeedback.heavyImpact();
        _toast('Only ${match.$2.stock} in stock — all are in the cart',
            AppColors.warning);
      }
      _refocus();
      return true;
    }

    // Product-level barcode -> single variant adds straight away,
    // multi-variant products open the size/color picker.
    Product? product;
    for (final p in catalog.products) {
      if ((p.barcode ?? '').trim().toLowerCase() == code.toLowerCase()) {
        product = p;
        break;
      }
    }
    if (product != null && product.variants.isNotEmpty) {
      if (product.variants.length == 1) {
        final ok = cart.add(product, product.variants.first);
        if (ok) {
          HapticFeedback.selectionClick();
        } else {
          HapticFeedback.heavyImpact();
          _toast('Only ${product.variants.first.stock} in stock — all are in the cart',
              AppColors.warning);
        }
      } else {
        showDialog(
          context: context,
          builder: (_) => VariantPickerDialog(product: product!),
        );
      }
      _refocus();
      return true;
    }

    if (strict) {
      HapticFeedback.heavyImpact();
      _toast('No item tagged "$code" in this shop', AppColors.danger);
      _refocus();
      return true;
    }
    return false;
  }

  /// Scanner workflow: type/scan a code, press Enter -> exact SKU/barcode
  /// match is added straight to the cart. Anything else becomes a filter.
  void _onSearchSubmit(String value) {
    final v = value.trim();
    if (v.isEmpty) return;
    if (_tryRingUp(v, strict: false)) {
      _refocus();
    } else {
      context.read<SellViewState>().setQuery(v);
    }
  }

  /// Camera scanning path (phones): returns exactly one code per scan.
  Future<void> _openCameraScanner() async {
    _gate.reset();
    final code = await openScanner(context);
    if (code == null || !mounted) return;
    _tryRingUp(code, strict: true);
    _scanFocus.requestFocus();
  }

  List<Product> _filtered(CatalogProvider catalog, SellViewState view) {
    Iterable<Product> out = catalog.products;
    if (view.categoryFilter >= 0) {
      out = out.where((p) => p.categoryId == view.categoryFilter);
    }
    if (view.query.trim().isNotEmpty) {
      final q = view.query.trim().toLowerCase();
      out = out.where((p) =>
          p.name.toLowerCase().contains(q) ||
          (p.barcode ?? '').contains(q) ||
          p.variants.any((v) => v.matchesCode(q)));
    }
    return out.toList();
  }

  void _openProduct(Product product) {
    if (product.variants.isEmpty) return;
    if (product.variants.length == 1) {
      context.read<CartProvider>().add(product, product.variants.first);
      return;
    }
    showDialog(
      context: context,
      builder: (_) => VariantPickerDialog(product: product),
    );
  }

  @override
  Widget build(BuildContext context) {
    final catalog = context.watch<CatalogProvider>();
    final settings = context.watch<AppSettings>();
    final sellView = context.watch<SellViewState>();
    final products = _filtered(catalog, sellView);

    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= 1100;
      final grid =
          _buildCatalogArea(context, catalog, settings, products, sellView);

      if (wide) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.s4, AppSpace.s4, AppSpace.s4, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: grid),
              const SizedBox(width: AppSpace.s4),
              SizedBox(width: 380, child: CartPanel(scrollable: true)),
            ],
          ),
        );
      }
      // Phones: the catalog needs the same screen-edge margin as every
      // other tab — cards used to sit flush against the glass (clipped
      // look). Same insets as the wide layout, bottom 0 (cart bar owns it).
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.s4, AppSpace.s4, AppSpace.s4, 0),
          child: grid,
        ),
        // Always-visible cart bar (commerce pattern): total + item count
        // stay reachable with one thumb while the cashier scrolls products.
        bottomNavigationBar: _MobileCartBar(onOpen: _openCartSheet),
      );
    });
  }

  void _openCartSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        // M3 modal bottom sheet: extra-large top corners
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.78,
        child: Column(
          children: [
            const SheetHandle(),
            const Expanded(child: CartPanel(scrollable: false)),
          ],
        ),
      ),
    );
  }

  Widget _buildCatalogArea(
    BuildContext context,
    CatalogProvider catalog,
    AppSettings settings,
    List<Product> products,
    SellViewState sellView,
  ) {
    final auth = context.watch<AuthProvider>();
    final user = auth.user;

    return Column(
      children: [
        // my-shift strip
        if (user != null) _MyTodayStrip(userId: user.id!),
        const SizedBox(height: AppSpace.s3),

        // scan / search bar. No autofocus on camera devices: the
        // on-screen keyboard would cover half the product grid the
        // moment the Sell tab opens. Desktop (scanner-wedge) keeps it.
        TextField(
          controller: _search,
          focusNode: _scanFocus,
          autofocus: !_cameraAvailable,
          textInputAction: TextInputAction.search,
          onSubmitted: _onSearchSubmit,
          onChanged: (v) => context.read<SellViewState>().setQuery(v),
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Scan barcode or search name / SKU…',
            prefixIcon: Container(
              margin: const EdgeInsets.fromLTRB(AppSpace.s2, AppSpace.s2, 0, AppSpace.s2),
              padding: const EdgeInsets.all(AppSpace.s2),
              decoration: BoxDecoration(
                color: AppColors.primarySoft,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Icon(Icons.qr_code_scanner_rounded, size: 19, color: AppColors.primary),
            ),
            prefixIconConstraints: const BoxConstraints(minWidth: 40),
            suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
              if (_cameraAvailable)
                IconButton(
                  tooltip: 'Scan with camera',
                  icon: Icon(Icons.photo_camera_outlined, size: 20, color: AppColors.primary),
                  onPressed: _openCameraScanner,
                ),
              if (sellView.query.isEmpty)
                const SizedBox(width: AppSpace.s3)
              else
                IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.close_rounded, size: 19),
                  onPressed: () {
                    _search.clear();
                    context.read<SellViewState>().setQuery('');
                    _scanFocus.requestFocus();
                  },
                ),
            ]),
          ),
        ),
        const SizedBox(height: AppSpace.s3),

        // category chips
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              _chip(context, 'All', -1, sellView),
              const SizedBox(width: AppSpace.s2),
              for (final cat in catalog.categories) ...[
                _chip(context, cat.name, cat.id ?? -1, sellView),
                const SizedBox(width: AppSpace.s2),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpace.s4),

        // product catalog. Products WITH an uploaded photo render as image
        // tiles in the grid; products WITHOUT a photo render as compact list
        // rows — a sea of identical placeholder icons reads as broken
        // thumbnails, and a row carries the name/price/stock far better than
        // an empty picture frame (see _CatalogGrid for the split rule).
        Expanded(
          child: products.isEmpty
              ? EmptyState(
                  icon: Icons.storefront_outlined,
                  // An empty catalog is a different situation from a search
                  // that matched nothing — say so, and offer the way out.
                  title: sellView.query.isEmpty ? 'No products yet' : 'No products match',
                  message: sellView.query.isEmpty
                      ? 'Add your first product under the Products tab, then come back here to sell.'
                      : 'Try a different search term or clear the filters.',
                  actionLabel: sellView.query.isEmpty ? 'Go to Products' : null,
                  onAction: sellView.query.isEmpty
                      ? () => context.read<NavProvider>().goTo(NavId.products)
                      : null,
                )
              : _CatalogGrid(
                  products: products,
                  settings: settings,
                  onTap: _openProduct,
                ),
        ),
      ],
    );
  }

  Widget _chip(
      BuildContext context, String label, int value, SellViewState sellView) {
    final selected = sellView.categoryFilter == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      labelPadding: const EdgeInsets.symmetric(horizontal: AppSpace.s4, vertical: AppSpace.s1),
      labelStyle: TextStyle(
        fontFamily: 'Carlito',
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: selected ? AppColors.primaryDark : AppColors.muted,
      ),
      selectedColor: AppColors.primarySoft,
      backgroundColor: AppColors.surface,
      side: BorderSide(color: selected ? AppColors.primary.withValues(alpha: 0.35) : AppColors.border),
      // M3 chips use the small shape (8dp)
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
      onSelected: (_) => sellView.setCategoryFilter(value),
    );
  }
}

/// Splits the visible catalog by whether a photo was actually uploaded.
/// A blank/whitespace image field counts as "no photo" — the edit screen
/// can leave stray spaces behind when a picture is removed.
({List<Product> withPhotos, List<Product> withoutPhotos}) splitByPhoto(
    List<Product> products) {
  final withPhotos = <Product>[];
  final withoutPhotos = <Product>[];
  for (final p in products) {
    ((p.image ?? '').trim().isEmpty ? withoutPhotos : withPhotos).add(p);
  }
  return (withPhotos: withPhotos, withoutPhotos: withoutPhotos);
}

/// Garment-flavoured fallback icon, guessed from the product name.
IconData garmentIconFor(Product p) {
  final n = p.name.toLowerCase();
  if (n.contains('jean') || n.contains('trouser')) {
    return Icons.checkroom_rounded;
  }
  if (n.contains('dress')) {
    return Icons.woman_rounded;
  }
  if (n.contains('shirt') || n.contains('tee') || n.contains('top')) {
    return Icons.dry_cleaning_rounded;
  }
  if (n.contains('shoe') || n.contains('sneaker') || n.contains('boot')) {
    return Icons.hiking_rounded;
  }
  if (n.contains('jacket') || n.contains('coat')) {
    return Icons.storm_rounded;
  }
  if (n.contains('belt') || n.contains('hat') || n.contains('beanie') ||
      n.contains('scarf') || n.contains('accessor')) {
    return Icons.watch_outlined;
  }
  return Icons.checkroom_rounded;
}

/// The scrollable catalog area on the Sell tab.
///
/// Layout rule: photo'd products get the familiar image-tile grid;
/// photo-less products are rendered as a compact list under the caption
/// "WITHOUT PHOTOS" (only shown when both kinds are on screen). A shop
/// that never uploaded pictures therefore sees its whole stock as a
/// tidy list instead of a wall of identical icon placeholders, and a
/// fully-photographed shop sees exactly the old grid.
class _CatalogGrid extends StatelessWidget {
  final List<Product> products;
  final AppSettings settings;
  final void Function(Product) onTap;

  const _CatalogGrid({
    required this.products,
    required this.settings,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final split = splitByPhoto(products);
    final hasBoth = split.withPhotos.isNotEmpty && split.withoutPhotos.isNotEmpty;

    return CustomScrollView(slivers: [
      if (split.withPhotos.isNotEmpty)
        SliverPadding(
          padding: const EdgeInsets.only(bottom: AppSpace.s2),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 200,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.86,
            ),
            itemCount: split.withPhotos.length,
            itemBuilder: (context, i) => _ProductCard(
              product: split.withPhotos[i],
              settings: settings,
              onTap: () => onTap(split.withPhotos[i]),
            ),
          ),
        ),
      if (hasBoth)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
          sliver: SliverToBoxAdapter(
            child: Text('WITHOUT PHOTOS',
                style: TextStyle(
                    fontFamily: 'Carlito',
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: AppColors.muted)),
          ),
        ),
      if (split.withoutPhotos.isNotEmpty)
        SliverPadding(
          padding: const EdgeInsets.only(bottom: AppSpace.s4),
          sliver: SliverList.builder(
            itemCount: split.withoutPhotos.length,
            itemBuilder: (context, i) {
              final p = split.withoutPhotos[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ProductRow(
                  product: p,
                  settings: settings,
                  onTap: () => onTap(p),
                ),
              );
            },
          ),
        ),
    ]);
  }
}

/// Compact sell-row for products without an uploaded photo: name, price,
/// variant count and stock stay visible — everything the big tile showed,
/// minus the empty picture frame. Tap behaviour is identical to the grid
/// cards (single variant adds straight to the cart, multi opens picker).
class _ProductRow extends StatelessWidget {
  final Product product;
  final AppSettings settings;
  final VoidCallback onTap;

  const _ProductRow({
    required this.product,
    required this.settings,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = product;
    final out = p.totalStock <= 0;
    final lowVariants = p.variants.where((v) => v.stock <= p.lowStock).length;

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.s3, vertical: AppSpace.s2 + 2),
          child: Row(
            children: [
              ProductThumb(
                image: p.image,
                size: 40,
                radius: AppRadius.sm,
                icon: garmentIconFor(p),
                iconSize: 20,
              ),
              const SizedBox(width: AppSpace.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontFamily: 'Carlito',
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: AppColors.ink),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${p.variants.isEmpty ? '-' : settings.priceLabel(p.minPrice, p.maxPrice)}'
                      ' · ${p.variants.length} variant${p.variants.length == 1 ? '' : 's'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontFamily: 'Carlito',
                          fontSize: 12,
                          color: AppColors.muted),
                    ),
                  ],
                ),
              ),
              if (out) ...[
                const SizedBox(width: AppSpace.s2),
                StatusPill.build(context,
                    label: 'Out',
                    foreground: AppColors.danger,
                    background: AppColors.dangerSoft),
              ] else if (p.hasLowStock) ...[
                const SizedBox(width: AppSpace.s2),
                StatusPill.build(context,
                    label: 'Low',
                    foreground: AppColors.warning,
                    background: AppColors.warningSoft),
              ],
              const SizedBox(width: AppSpace.s2),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.s3, vertical: AppSpace.s1),
                decoration: BoxDecoration(
                  color: AppColors.surfaceTint,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(color: AppColors.borderSoft),
                ),
                child: Text(
                  '${p.totalStock} pcs',
                  style: TextStyle(
                    fontFamily: 'Carlito',
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: lowVariants > 0 ? AppColors.warning : AppColors.body,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Slim strip showing the logged-in staff member's sales since midnight.
/// Refreshes automatically after every checkout or refund.
class _MyTodayStrip extends StatefulWidget {
  final int userId;
  const _MyTodayStrip({required this.userId});

  @override
  State<_MyTodayStrip> createState() => _MyTodayStripState();
}

class _MyTodayStripState extends State<_MyTodayStrip> {
  Future<({int orders, double revenue, int itemsSold})>? _future;
  int _lastRevision = -1;

  void _sync() {
    final sales = context.watch<SalesProvider>();
    if (_future == null || sales.revision != _lastRevision) {
      _lastRevision = sales.revision;
      _future = sales.todaySummaryForUser(widget.userId);
    }
  }

  Future<void> _togglePunch(bool currentlyIn) async {
    final attendance = context.read<AttendanceProvider>();
    if (currentlyIn) {
      await attendance.clockOut(widget.userId);
    } else {
      await attendance.clockIn(widget.userId);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(currentlyIn
          ? 'Clocked out — shift saved to the log'
          : 'Clocked in — have a great shift!'),
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    _sync();
    final settings = context.watch<AppSettings>();
    final auth = context.watch<AuthProvider>();
    final attendance = context.watch<AttendanceProvider>();

    return FutureBuilder<({int orders, double revenue, int itemsSold})>(
      future: _future,
      builder: (context, snap) {
        final s = snap.data;
        final hasData = s != null && (s.orders > 0 || s.revenue > 0);
        return InkWell(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: () => _showMyDashboard(context),
          child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.s4, vertical: AppSpace.s2),
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
          ),
          child: Row(
            children: [
              Icon(Icons.badge_outlined, size: 16, color: AppColors.primary),
              const SizedBox(width: AppSpace.s2),
              // Both texts flex + ellipsis: a long name / long hint used to
              // hard-overflow the strip and clip the clock pill off-screen.
              Flexible(
                child: Text(
                  '${auth.user?.name ?? 'You'} · ${auth.user?.isAdmin == true ? 'Manager' : 'Sales'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: 'Carlito', fontSize: 12, fontWeight: FontWeight.w700,
                      color: AppColors.primaryDark),
                ),
              ),
              const SizedBox(width: AppSpace.s2),
              Expanded(
                child: hasData
                    ? Text(
                        'Today: ${s.orders} sale${s.orders == 1 ? '' : 's'} · '
                        '${s.itemsSold} item${s.itemsSold == 1 ? '' : 's'} · '
                        '${settings.money(s.revenue)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontFamily: 'Carlito', fontSize: 12, color: AppColors.body),
                      )
                    : Text(
                        'No sales yet today — scan a garment to start',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontFamily: 'Carlito', fontSize: 12, color: AppColors.muted),
                      ),
              ),
              const SizedBox(width: AppSpace.s2),
              // Personal dashboard: clock in/out for the shift log. The
              // pill shows the running shift length while clocked in.
              FutureBuilder<Shift?>(
                future: attendance.openShift(widget.userId),
                builder: (context, shiftSnap) {
                  final shift = shiftSnap.data;
                  final onDuty = shift != null;
                  return Tooltip(
                    message: onDuty
                        ? 'Clock out — ends this shift in the log'
                        : 'Clock in — start a shift in the log',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      onTap: () => _togglePunch(onDuty),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppSpace.s3, vertical: 4),
                        decoration: BoxDecoration(
                          color: onDuty ? AppColors.successSoft : AppColors.surface,
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                          border: Border.all(
                              color: onDuty
                                  ? AppColors.success.withValues(alpha: 0.4)
                                  : AppColors.border),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              onDuty
                                  ? Icons.logout_rounded
                                  : Icons.login_rounded,
                              size: 13,
                              color: onDuty
                                  ? AppColors.success
                                  : AppColors.primary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              onDuty
                                  ? 'On duty · ${shift.durationLabel}'
                                  '  ·  Clock out'
                                  : 'Clock in',
                              style: TextStyle(
                                  fontFamily: 'Carlito',
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: onDuty
                                      ? AppColors.success
                                      : AppColors.primary),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(width: AppSpace.s1),
              Icon(Icons.expand_more_rounded, size: 15, color: AppColors.primary),
            ],
          ),
          ),
        );
      },
    );
  }

  /// Personal dashboard: own sales totals (today / week / month), own
  /// commission progress, shift clock. Salespeople see ONLY their own
  /// numbers here — shop-wide financials stay manager-only in Reports.
  void _showMyDashboard(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (_) => _MyDashboardSheet(userId: widget.userId),
    );
  }
}

class _ProductCard extends StatefulWidget {
  final Product product;
  final AppSettings settings;
  final VoidCallback onTap;

  const _ProductCard({required this.product, required this.settings, required this.onTap});

  @override
  State<_ProductCard> createState() => _ProductCardState();
}

class _ProductCardState extends State<_ProductCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final out = p.totalStock <= 0;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedScale(
        duration: AppMotion.fast,
        curve: AppMotion.standard,
        scale: _hover ? 1.02 : 1,
        child: AnimatedContainer(
        duration: AppMotion.fast,
        curve: AppMotion.standard,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: _hover ? AppColors.primary.withValues(alpha: 0.45) : AppColors.borderSoft,
        ),
        boxShadow: _hover
            ? [BoxShadow(color: AppColors.primary.withValues(alpha: AppColors.isDark ? 0.28 : 0.10), blurRadius: 14, offset: const Offset(0, 6))]
            : const [],
      ),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.s3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      // Garment photo (falls back to a branded icon tile).
                      Positioned.fill(
                        child: ProductThumb(
                          image: p.image,
                          radius: AppRadius.sm,
                          icon: garmentIconFor(p),
                          iconSize: 34,
                        ),
                      ),
                      if (out)
                        Positioned(
                          top: AppSpace.s2,
                          right: AppSpace.s2,
                          child: StatusPill.build(
                            context,
                            label: 'Out',
                            foreground: AppColors.danger,
                            background: AppColors.dangerSoft,
                          ),
                        )
                      else if (p.hasLowStock)
                        Positioned(
                          top: AppSpace.s2,
                          right: AppSpace.s2,
                          child: StatusPill.build(
                            context,
                            label: 'Low',
                            foreground: AppColors.warning,
                            background: AppColors.warningSoft,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpace.s2),
                Text(
                  p.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: 'Carlito',
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      height: 1.2,
                      color: AppColors.ink),
                ),
                const SizedBox(height: AppSpace.s1),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        p.variants.isEmpty
                            ? '-'
                            : widget.settings.priceLabel(p.minPrice, p.maxPrice),
                        style: TextStyle(
                          fontFamily: 'Carlito',
                          color: AppColors.primary,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Text(
                      '${p.variants.length} var',
                      style: TextStyle(fontFamily: 'Carlito', fontSize: 11, color: AppColors.faint),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        ),
      ),
    );
  }
}

/// Fixed bottom cart summary for phones — the standard commerce pattern.
/// Slides in when the first item is added, bumps its badge on every
/// add, and shows the running total so the cashier always knows the
/// amount before opening the cart.
class _MobileCartBar extends StatelessWidget {
  final VoidCallback onOpen;
  const _MobileCartBar({required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartProvider>();
    final settings = context.watch<AppSettings>();
    final visible = cart.isNotEmpty || cart.heldCount > 0;
    final bottomPad = MediaQuery.paddingOf(context).bottom;

    return ClipRect(
      child: AnimatedContainer(
        duration: AppMotion.normal,
        curve: AppMotion.emphasized,
        height: visible ? 64 + bottomPad : 0,
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.borderSoft)),
          boxShadow: [
            BoxShadow(
                color: AppColors.isDark ? const Color(0x40000000) : const Color(0x140F172A),
                blurRadius: 12,
                offset: const Offset(0, -4)),
          ],
        ),
        // Slide the row down while collapsing so nothing pokes out.
        child: AnimatedSlide(
          duration: AppMotion.normal,
          curve: AppMotion.emphasized,
          offset: visible ? Offset.zero : const Offset(0, 1),
          child: Padding(
            padding: EdgeInsets.only(bottom: bottomPad),
            child: InkWell(
              onTap: visible ? onOpen : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.s4),
                child: Row(
                  children: [
                    // cart icon with animated count badge
                    TweenAnimationBuilder<double>(
                      key: ValueKey(cart.itemCount),
                      tween: Tween(begin: 1.25, end: 1),
                      duration: AppMotion.normal,
                      curve: Curves.easeOutCubic,
                      builder: (context, scale, child) =>
                          Transform.scale(scale: scale, child: child),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: AppColors.primarySoft,
                              borderRadius: BorderRadius.circular(AppRadius.md),
                            ),
                            child: Icon(Icons.shopping_cart_outlined,
                                size: 20, color: AppColors.primary),
                          ),
                          if (cart.itemCount > 0)
                            Positioned(
                              top: -5,
                              right: -5,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 5, vertical: 1),
                                constraints:
                                    const BoxConstraints(minWidth: 18),
                                decoration: BoxDecoration(
                                  color: AppColors.primary,
                                  borderRadius:
                                      BorderRadius.circular(AppRadius.pill),
                                  border: Border.all(color: AppColors.onPrimary, width: 1.5),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  '${cart.itemCount}',
                                  style: TextStyle(
                                      fontFamily: 'Carlito',
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.onPrimary),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpace.s3),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            cart.isNotEmpty
                                ? '${cart.itemCount} item${cart.itemCount == 1 ? '' : 's'} in cart'
                                : '${cart.heldCount} sale${cart.heldCount == 1 ? '' : 's'} held',
                            style: TextStyle(
                                fontFamily: 'Carlito',
                                fontSize: 12,
                                color: AppColors.muted),
                          ),
                          Text(
                            cart.isNotEmpty
                                ? settings.money(cart.total(settings.taxRate))
                                : 'Tap to review',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontFamily: 'Carlito',
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: AppColors.primaryDark),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpace.s4, vertical: AppSpace.s2 + 1),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Row(
                        children: [
                          Text('View cart',
                              style: TextStyle(
                                  fontFamily: 'Carlito',
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.onPrimary)),
                          const SizedBox(width: AppSpace.s1),
                          Icon(Icons.expand_less_rounded,
                              size: 18, color: AppColors.onPrimary),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The salesperson's own dashboard: personal sales totals, commission
/// progress and the shift clock — everything scoped to THIS user only.
/// Styled as a proper Android bottom sheet: grabber, hero identity header,
/// icon stat cards and a single clear shift CTA.
class _MyDashboardSheet extends StatelessWidget {
  final int userId;
  const _MyDashboardSheet({required this.userId});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final auth = context.watch<AuthProvider>();
    final attendance = context.watch<AttendanceProvider>();
    final user = auth.user;
    final now = DateTime.now();
    final weekStart = DateTime(now.year, now.month, now.day - now.weekday + 1);
    final monthStart = DateTime(now.year, now.month, 1);
    final period =
        '${now.year}-${now.month.toString().padLeft(2, '0')}';
    final sales = context.read<SalesProvider>();
    final commissions = context.read<CommissionsProvider>();

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
            AppSpace.s5, AppSpace.s1, AppSpace.s5, AppSpace.s5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHandle(),

            // -- hero identity header ------------------------------------------
            Padding(
              padding: const EdgeInsets.fromLTRB(0, AppSpace.s3, 0, AppSpace.s4),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: AppColors.brandGradient),
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                    ),
                    child: Icon(Icons.badge_rounded,
                        size: 24, color: AppColors.onBrand),
                  ),
                  const SizedBox(width: AppSpace.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('My dashboard',
                            style: TextStyle(
                                fontFamily: 'Carlito',
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: AppColors.ink)),
                        const SizedBox(height: 2),
                        Text(
                            '${user?.name ?? ''} · ${user?.isAdmin == true ? 'Manager' : 'Sales'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontFamily: 'Carlito',
                                fontSize: 12,
                                color: AppColors.muted)),
                      ],
                    ),
                  ),
                  // Live duty pill: green while the shift is running.
                  FutureBuilder<Shift?>(
                    future: attendance.openShift(userId),
                    builder: (context, snap) {
                      final onDuty = snap.data != null;
                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppSpace.s3, vertical: 5),
                        decoration: BoxDecoration(
                          color: onDuty
                              ? AppColors.successSoft
                              : AppColors.surfaceTint,
                          borderRadius:
                              BorderRadius.circular(AppRadius.pill),
                          border: Border.all(
                              color: onDuty
                                  ? AppColors.success.withValues(alpha: 0.35)
                                  : AppColors.borderSoft),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: onDuty
                                    ? AppColors.success
                                    : AppColors.faint,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Text(onDuty ? 'On duty' : 'Off duty',
                                style: TextStyle(
                                    fontFamily: 'Carlito',
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: onDuty
                                        ? AppColors.success
                                        : AppColors.muted)),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),

            // -- sales stats: today / week / month -------------------------------
            FutureBuilder(
              future: Future.wait([
                sales.summarySinceForUser(userId,
                    DateTime(now.year, now.month, now.day).millisecondsSinceEpoch ~/ 1000),
                sales.summarySinceForUser(userId, weekStart.millisecondsSinceEpoch ~/ 1000),
                sales.summarySinceForUser(userId, monthStart.millisecondsSinceEpoch ~/ 1000),
                commissions.myProgress(userId, period),
              ]),
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Padding(
                    padding: EdgeInsets.all(AppSpace.s6),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final today = snap.data![0]
                    as ({int orders, double revenue, int itemsSold});
                final week = snap.data![1]
                    as ({int orders, double revenue, int itemsSold});
                final month = snap.data![2]
                    as ({int orders, double revenue, int itemsSold});
                final comm = snap.data![3] as ({double pending, double paid});
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: [
                      _dashCard(context,
                          settings: settings,
                          icon: Icons.receipt_rounded,
                          label: 'Today',
                          value: settings.money(today.revenue),
                          sub:
                              '${today.orders} sale${today.orders == 1 ? '' : 's'} · ${today.itemsSold} item${today.itemsSold == 1 ? '' : 's'}'),
                      const SizedBox(width: AppSpace.s2),
                      _dashCard(context,
                          settings: settings,
                          icon: Icons.view_week_outlined,
                          label: 'Week',
                          value: settings.money(week.revenue),
                          sub:
                              '${week.orders} sale${week.orders == 1 ? '' : 's'} · ${week.itemsSold} item${week.itemsSold == 1 ? '' : 's'}'),
                      const SizedBox(width: AppSpace.s2),
                      _dashCard(context,
                          settings: settings,
                          icon: Icons.calendar_month_rounded,
                          label: 'Month',
                          value: settings.money(month.revenue),
                          sub:
                              '${month.orders} sale${month.orders == 1 ? '' : 's'} · ${month.itemsSold} item${month.itemsSold == 1 ? '' : 's'}'),
                    ]),
                    const SizedBox(height: AppSpace.s3),

                    // -- commission ----------------------------------------------------
                    Container(
                      padding: const EdgeInsets.all(AppSpace.s4),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: AppColors.brandGradient,
                        ),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.payments_rounded,
                                  size: 15,
                                  color: AppColors.onBrand.withValues(alpha: 0.85)),
                              const SizedBox(width: AppSpace.s1),
                              Text('COMMISSION THIS MONTH',
                                  style: TextStyle(
                                      fontFamily: 'Carlito',
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.6,
                                      color: AppColors.onBrand
                                          .withValues(alpha: 0.85))),
                            ],
                          ),
                          const SizedBox(height: AppSpace.s1),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(settings.money(comm.pending),
                                  style: TextStyle(
                                      fontFamily: 'Carlito',
                                      fontSize: 22,
                                      height: 26 / 22,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.onBrand)),
                              const SizedBox(width: AppSpace.s2),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 2),
                                child: Text(
                                    comm.paid > 0
                                        ? 'pending · ${settings.money(comm.paid)} paid'
                                        : 'pending payout',
                                    style: TextStyle(
                                        fontFamily: 'Carlito',
                                        fontSize: 12,
                                        color: AppColors.onBrand
                                            .withValues(alpha: 0.85))),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: AppSpace.s3),

            // -- shift clock -------------------------------------------------------
            FutureBuilder<Shift?>(
              future: attendance.openShift(userId),
              builder: (context, snap) {
                final shift = snap.data;
                final onDuty = shift != null;
                return FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 48),
                    backgroundColor:
                        onDuty ? AppColors.danger : AppColors.primary,
                    foregroundColor:
                        onDuty ? AppColors.onError : AppColors.onPrimary,
                  ),
                  onPressed: () async {
                    final att = context.read<AttendanceProvider>();
                    if (onDuty) {
                      await att.clockOut(userId);
                    } else {
                      await att.clockIn(userId);
                    }
                  },
                  icon: Icon(onDuty ? Icons.logout_rounded : Icons.login_rounded,
                      size: 18),
                  label: Text(onDuty
                      ? 'Clock out · ${shift.durationLabel}'
                      : 'Clock in — start my shift'),
                );
              },
            ),
            const SizedBox(height: AppSpace.s2),
            Text(
              'Shift punches are saved to the shop log your manager sees.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontFamily: 'Carlito', fontSize: 11, color: AppColors.faint),
            ),
          ],
        ),
      ),
    );
  }

  /// One period stat card: soft icon tile, label, revenue figure and a
  /// "N sales · M items" subline.
  Widget _dashCard(
    BuildContext context, {
    required AppSettings settings,
    required IconData icon,
    required String label,
    required String value,
    required String sub,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(AppSpace.s3),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.borderSoft),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TintIconBox(icon: icon, color: AppColors.primary, soft: AppColors.primarySoft, size: 28),
            const SizedBox(height: AppSpace.s2),
            Text(label.toUpperCase(),
                style: TextStyle(
                    fontFamily: 'Carlito',
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: AppColors.faint)),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value,
                  style: TextStyle(
                      fontFamily: 'Carlito',
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink)),
            ),
            const SizedBox(height: 1),
            Text(sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: 'Carlito', fontSize: 10.5, color: AppColors.muted)),
          ],
        ),
      ),
    );
  }
}
