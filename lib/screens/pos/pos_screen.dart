import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/product.dart';
import '../../state/cart.dart';
import '../../state/catalog.dart';
import '../../state/settings.dart';
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
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: grid),
              const SizedBox(width: 12),
              SizedBox(width: 370, child: const CartPanel(scrollable: true)),
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
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            builder: (_) => SizedBox(
              height: MediaQuery.of(context).size.height * 0.75,
              child: const CartPanel(scrollable: false),
            ),
          ),
          icon: const Icon(Icons.shopping_cart_outlined),
          label: Consumer<CartProvider>(
            builder: (context, cart, _) => Text(cart.isEmpty ? 'Cart' : 'Cart (${cart.itemCount})'),
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
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _search,
                focusNode: _scanFocus,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onSubmitted: _onSearchSubmit,
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: 'Scan barcode or search name / SKU…',
                  prefixIcon: const Icon(Icons.qr_code_scanner),
                  suffixIcon: _query.isEmpty
                      ? const Icon(Icons.search)
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                            _scanFocus.requestFocus();
                          },
                        ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // category chips
        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              _chip(context, 'All', -1),
              const SizedBox(width: 6),
              for (final cat in catalog.categories) ...[
                _chip(context, cat.name, cat.id ?? -1),
                const SizedBox(width: 6),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),

        // product grid
        Expanded(
          child: products.isEmpty
              ? const Center(child: Text('No products match. Add products under the Products tab.'))
              : GridView.builder(
                  padding: const EdgeInsets.only(bottom: 80),
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 190,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.92,
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
      onSelected: (_) => setState(() => _categoryFilter = value),
    );
  }
}

class _ProductCard extends StatelessWidget {
  final Product product;
  final AppSettings settings;
  final VoidCallback onTap;

  const _ProductCard({required this.product, required this.settings, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final low = product.hasLowStock;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    _iconFor(product),
                    size: 36,
                    color: theme.colorScheme.primary.withValues(alpha: 0.7),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                product.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, height: 1.15),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${settings.currencySymbol} ${product.priceLabel}',
                      style: TextStyle(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  Text(
                    low ? 'Low: ${product.totalStock}' : '${product.totalStock} in stock',
                    style: TextStyle(
                      fontSize: 11,
                      color: low ? theme.colorScheme.error : Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconFor(Product p) {
    final n = p.name.toLowerCase();
    if (n.contains('jean') || n.contains('trouser')) {
      return Icons.checkroom;
    }
    if (n.contains('dress')) {
      return Icons.woman_outlined;
    }
    if (n.contains('shirt') || n.contains('tee') || n.contains('top')) {
      return Icons.dry_cleaning;
    }
    if (n.contains('shoe') || n.contains('sneaker') || n.contains('boot')) {
      return Icons.hiking;
    }
    if (n.contains('jacket') || n.contains('coat')) {
      return Icons.storm_outlined;
    }
    if (n.contains('belt') || n.contains('hat') || n.contains('beanie') ||
        n.contains('scarf') || n.contains('accessor')) {
      return Icons.watch_outlined;
    }
    return Icons.checkroom;
  }
}
