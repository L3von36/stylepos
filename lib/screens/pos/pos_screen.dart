import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/product.dart';
import '../../state/cart.dart';
import '../../state/catalog.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';
import 'cart_panel.dart';
import 'variant_picker_dialog.dart';

/// The sell screen: product grid on the left, cart on the right (wide),
/// or a cart FAB + bottom sheet on narrow screens.
class PosScreen extends StatefulWidget {
  const PosScreen({super.key});

  @override
  State<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends State<PosScreen> {
  final _search = TextEditingController();
  final _scanFocus = FocusNode();
  int _categoryFilter = -1; // -1 = all
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  /// Scanner workflow: type/scan a code, press Enter -> exact SKU/barcode
  /// match is added straight to the cart. Anything else becomes a filter.
  void _onSearchSubmit(String value) {
    final catalog = context.read<CatalogProvider>();
    final match = catalog.findByCode(value);
    if (match != null) {
      context.read<CartProvider>().add(match.$1, match.$2);
      _search.clear();
      setState(() => _query = '');
      _scanFocus.requestFocus();
      return;
    }
    setState(() => _query = value);
  }

  List<Product> _filtered(CatalogProvider catalog) {
    Iterable<Product> out = catalog.products;
    if (_categoryFilter >= 0) {
      final catId = _categoryFilter == 0 ? null : _categoryFilter;
      out = out.where((p) => p.categoryId == catId);
      if (_categoryFilter == 0) out = out.where((p) => p.categoryId == null);
    }
    if (_query.trim().isNotEmpty) {
      final q = _query.trim().toLowerCase();
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
    final products = _filtered(catalog);

    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= 1100;
      final grid = _buildCatalogArea(context, catalog, settings, products);

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
      return Scaffold(
        backgroundColor: Colors.transparent,
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.white,
            shape: const RoundedRectangleBorder(
              // M3 modal bottom sheet: extra-large top corners
              borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
            ),
            builder: (_) => SizedBox(
              height: MediaQuery.of(context).size.height * 0.78,
              child: const CartPanel(scrollable: false),
            ),
          ),
          icon: const Icon(Icons.shopping_cart_outlined, size: 21),
          label: Consumer<CartProvider>(
            builder: (context, cart, _) => Text(cart.isEmpty ? 'Cart' : '${cart.itemCount} item${cart.itemCount == 1 ? '' : 's'}'),
          ),
        ),
        body: grid,
      );
    });
  }

  Widget _buildCatalogArea(
    BuildContext context,
    CatalogProvider catalog,
    AppSettings settings,
    List<Product> products,
  ) {
    return Column(
      children: [
        // scan / search bar
        TextField(
          controller: _search,
          focusNode: _scanFocus,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: _onSearchSubmit,
          onChanged: (v) => setState(() => _query = v),
          style: const TextStyle(fontSize: 14.5),
          decoration: InputDecoration(
            hintText: 'Scan barcode or search name / SKU…',
            prefixIcon: Container(
              margin: const EdgeInsets.fromLTRB(AppSpace.s2, AppSpace.s2, 0, AppSpace.s2),
              padding: const EdgeInsets.all(AppSpace.s2),
              decoration: BoxDecoration(
                color: AppColors.primarySoft,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: const Icon(Icons.qr_code_scanner_rounded, size: 19, color: AppColors.primary),
            ),
            prefixIconConstraints: const BoxConstraints(minWidth: 40),
            suffixIcon: _query.isEmpty
                ? const Icon(Icons.search_rounded, size: 20, color: AppColors.faint)
                : IconButton(
                    icon: const Icon(Icons.close_rounded, size: 19),
                    onPressed: () {
                      _search.clear();
                      setState(() => _query = '');
                      _scanFocus.requestFocus();
                    },
                  ),
          ),
        ),
        const SizedBox(height: AppSpace.s3),

        // category chips
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              _chip(context, 'All', -1),
              const SizedBox(width: AppSpace.s2),
              for (final cat in catalog.categories) ...[
                _chip(context, cat.name, cat.id ?? -1),
                const SizedBox(width: AppSpace.s2),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpace.s4),

        // product grid
        Expanded(
          child: products.isEmpty
              ? EmptyState(
                  icon: Icons.storefront_outlined,
                  title: 'No products match',
                  message: _query.isNotEmpty
                      ? 'Try a different search term or clear the filters.'
                      : 'Add products under the Products tab to start selling.',
                )
              : GridView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 200,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.86,
                  ),
                  itemCount: products.length,
                  itemBuilder: (context, i) => _ProductCard(
                    product: products[i],
                    settings: settings,
                    onTap: () => _openProduct(products[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _chip(BuildContext context, String label, int value) {
    final selected = _categoryFilter == value;
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
      backgroundColor: Colors.white,
      side: BorderSide(color: selected ? AppColors.primary.withValues(alpha: 0.35) : AppColors.border),
      // M3 chips use the small shape (8dp)
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
      onSelected: (_) => setState(() => _categoryFilter = value),
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
      child: AnimatedContainer(
        duration: AppMotion.fast,
        curve: AppMotion.standard,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: _hover ? AppColors.primary.withValues(alpha: 0.45) : AppColors.borderSoft,
          ),
          boxShadow: _hover
              ? const [BoxShadow(color: Color(0x1A4F46E5), blurRadius: 14, offset: Offset(0, 6))]
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
                      Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              AppColors.primarySoft,
                              AppColors.primarySoft.withValues(alpha: 0.55),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: Icon(
                          _iconFor(p),
                          size: 34,
                          color: AppColors.primary.withValues(alpha: 0.75),
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
                  style: const TextStyle(
                      fontFamily: 'Carlito',
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                      height: 1.2,
                      color: AppColors.ink),
                ),
                const SizedBox(height: AppSpace.s1),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${widget.settings.currencySymbol} ${p.priceLabel}',
                        style: const TextStyle(
                          fontFamily: 'Carlito',
                          color: AppColors.primary,
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                    Text(
                      '${p.variants.length} var',
                      style: const TextStyle(fontFamily: 'Carlito', fontSize: 11, color: AppColors.faint),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _iconFor(Product p) {
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
}
