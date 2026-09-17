import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/product.dart';
import '../../state/catalog.dart';
import '../../state/settings.dart';
import 'product_edit_screen.dart';
import 'stock_adjust_dialog.dart';

/// Inventory browser: search, filter by category, low-stock filter,
/// edit products, quick stock adjustments, archive.
class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key});

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  final _search = TextEditingController();
  String _query = '';
  int _categoryFilter = -1;
  bool _lowOnly = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Product> _filtered(CatalogProvider catalog) {
    Iterable<Product> out = catalog.products;
    if (_categoryFilter >= 0) {
      out = out.where((p) => p.categoryId == _categoryFilter);
    }
    if (_lowOnly) out = out.where((p) => p.hasLowStock);
    if (_query.trim().isNotEmpty) {
      final q = _query.trim().toLowerCase();
      out = out.where((p) =>
          p.name.toLowerCase().contains(q) ||
          (p.barcode ?? '').contains(q) ||
          p.variants.any((v) => v.sku.toLowerCase().contains(q)));
    }
    return out.toList();
  }

  Future<void> _confirmArchive(Product p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Archive product?'),
        content: Text(
            '"${p.name}" will be hidden from the POS and inventory. Past sales are kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Archive')),
        ],
      ),
    );
    if (ok == true && mounted) {
      await context.read<CatalogProvider>().archiveProduct(p);
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = context.watch<CatalogProvider>();
    final settings = context.watch<AppSettings>();
    final products = _filtered(catalog);

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: 'Search products, SKU or barcode…',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _search.clear();
                              setState(() => _query = '');
                            },
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const ProductEditScreen()));
                },
                icon: const Icon(Icons.add),
                label: const Text('New product'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Flexible(
                child: DropdownButtonFormField<int>(
                  initialValue: _categoryFilter,
                  isDense: true,
                  decoration: const InputDecoration(
                      labelText: 'Category', contentPadding: EdgeInsets.symmetric(horizontal: 10)),
                  items: [
                    const DropdownMenuItem(value: -1, child: Text('All categories')),
                    for (final c in catalog.categories)
                      DropdownMenuItem(value: c.id, child: Text(c.name)),
                  ],
                  onChanged: (v) => setState(() => _categoryFilter = v ?? -1),
                ),
              ),
              const SizedBox(width: 10),
              FilterChip(
                label: const Text('Low stock'),
                selected: _lowOnly,
                onSelected: (v) => setState(() => _lowOnly = v),
              ),
              const SizedBox(width: 10),
              TextButton.icon(
                onPressed: () => _manageCategories(context),
                icon: const Icon(Icons.category_outlined, size: 18),
                label: const Text('Categories'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: products.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.inventory_2_outlined, size: 48, color: Colors.grey.shade400),
                        const SizedBox(height: 8),
                        const Text('No products found'),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: products.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, i) => _ProductTile(
                  product: products[i],
                  settings: settings,
                  onArchive: _confirmArchive,
                ),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _manageCategories(BuildContext context) async {
    await showDialog(
      context: context,
      builder: (_) => const _CategoriesDialog(),
    );
    setState(() {});
  }
}

class _ProductTile extends StatelessWidget {
  final Product product;
  final AppSettings settings;
  final Future<void> Function(Product) onArchive;
  const _ProductTile({
    required this.product,
    required this.settings,
    required this.onArchive,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lowVariants =
        product.variants.where((v) => v.stock <= product.lowStock).length;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ProductEditScreen(product: product)));
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.checkroom, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(product.name,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      '${product.variants.length} variants'
                      ' · ${settings.currencySymbol} ${product.priceLabel}'
                      ' · ${product.barcode ?? 'no barcode'}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${product.totalStock} pcs',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: lowVariants > 0 ? theme.colorScheme.error : null,
                    ),
                  ),
                  if (lowVariants > 0)
                    Text('$lowVariants low',
                        style: TextStyle(fontSize: 11, color: theme.colorScheme.error)),
                ],
              ),
              const SizedBox(width: 8),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'stock') {
                    showDialog(
                      context: context,
                      builder: (_) => StockAdjustDialog(product: product),
                    );
                  } else if (v == 'archive') {
                    await onArchive(product);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'stock', child: Text('Adjust stock')),
                  PopupMenuItem(value: 'archive', child: Text('Archive')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoriesDialog extends StatefulWidget {
  const _CategoriesDialog();

  @override
  State<_CategoriesDialog> createState() => _CategoriesDialogState();
}

class _CategoriesDialogState extends State<_CategoriesDialog> {
  final _new = TextEditingController();

  @override
  void dispose() {
    _new.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final catalog = context.watch<CatalogProvider>();

    return AlertDialog(
      title: const Text('Categories'),
      content: SizedBox(
        width: 360,
        height: 380,
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                itemCount: catalog.categories.length,
                itemBuilder: (context, i) {
                  final c = catalog.categories[i];
                  return ListTile(
                    leading: const Icon(Icons.category_outlined),
                    title: Text(c.name),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          onPressed: () async {
                            final ctrl = TextEditingController(text: c.name);
                            final name = await showDialog<String>(
                              context: context,
                              builder: (c2) => AlertDialog(
                                title: const Text('Rename category'),
                                content: TextField(
                                    controller: ctrl, autofocus: true),
                                actions: [
                                  TextButton(
                                      onPressed: () => Navigator.pop(c2),
                                      child: const Text('Cancel')),
                                  FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(c2, ctrl.text.trim()),
                                      child: const Text('Save')),
                                ],
                              ),
                            );
                            if (name != null && name.isNotEmpty && name != c.name) {
                              await catalog.renameCategory(c, name);
                            }
                          },
                        ),
                        IconButton(
                          icon: Icon(Icons.delete_outline,
                              size: 18, color: Theme.of(context).colorScheme.error),
                          onPressed: () async {
                            final err = await catalog.deleteCategory(c);
                            if (err != null && context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(err)));
                            }
                          },
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _new,
                    decoration: const InputDecoration(labelText: 'New category'),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle),
                  onPressed: () async {
                    if (_new.text.trim().isEmpty) return;
                    await catalog.addCategory(_new.text);
                    _new.clear();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    );
  }
}
