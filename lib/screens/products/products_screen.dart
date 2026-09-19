import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/product.dart';
import '../../state/auth.dart';
import '../../state/catalog.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';
import 'label_print_dialog.dart';
import 'product_csv.dart';
import 'product_edit_screen.dart';
import 'stock_adjust_dialog.dart';

/// Inventory browser: search, filter by category, low-stock filter,
/// edit products, quick stock adjustments, archive.
class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key});

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

/// Barcode shown in the catalog row: the product-level default code if set,
/// otherwise the first variant that carries one. The old code only looked
/// at the product-level field and printed "no barcode" even when every
/// variant had a scannable code.
String? _rowBarcode(Product product) {
  if (product.barcode != null && product.barcode!.trim().isNotEmpty) {
    return product.barcode;
  }
  for (final v in product.variants) {
    if (v.barcode != null && v.barcode!.trim().isNotEmpty) return v.barcode;
  }
  return null;
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
        content: SizedBox(
          width: 380,
          child: Text(
              '"${p.name}" will be hidden from the POS and inventory. Past sales are kept.'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Archive'),
          ),
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
    final auth = context.watch<AuthProvider>();
    final canManage = auth.user?.isAdmin ?? false;
    final products = _filtered(catalog);
    final lowCount = catalog.products.where((p) => p.hasLowStock).length;

    return Padding(
      padding: const EdgeInsets.all(AppSpace.s4),
      child: Column(
        children: [
          PageHeader(
            title: 'Products',
            subtitle:
                '${catalog.products.length} in catalog · $lowCount need restocking'
                '${canManage ? '' : ' · view only'}',
            actions: [
              if (canManage)
                OutlinedButton.icon(
                  onPressed: () => showLabelPrintDialog(
                    context,
                    groups: [
                      for (final p in products)
                        if (p.variants.isNotEmpty) LabelGroup(p, p.variants),
                    ],
                  ),
                  icon: const Icon(Icons.style_outlined, size: 17),
                  label: const Text('Print labels'),
                ),
              if (canManage)
                OutlinedButton.icon(
                  onPressed: () => _manageCategories(context),
                  icon: const Icon(Icons.category_outlined, size: 17),
                  label: const Text('Categories'),
                ),
              if (canManage)
                PopupMenuButton<String>(
                  tooltip: 'Bulk catalog CSV',
                  icon: const Icon(Icons.import_export_rounded, size: 21),
                  onSelected: (v) {
                    if (v == 'export') ProductCsv.export(context);
                    if (v == 'import') ProductCsv.import(context);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'export',
                      child: ListTile(
                        leading: Icon(Icons.file_download_outlined, size: 19),
                        title: Text('Export CSV'),
                        dense: true,
                      ),
                    ),
                    PopupMenuItem(
                      value: 'import',
                      child: ListTile(
                        leading: Icon(Icons.file_upload_outlined, size: 19),
                        title: Text('Import CSV'),
                        dense: true,
                      ),
                    ),
                  ],
                ),
              if (canManage)
                FilledButton.icon(
                  onPressed: () async {
                    await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const ProductEditScreen()));
                  },
                  icon: const Icon(Icons.add_rounded, size: 19),
                  label: const Text('New product'),
                ),
            ],
          ),
          // Responsive filter bar: on phones the search gets its own row
          // and the category dropdown expands, instead of an overflow.
          LayoutBuilder(builder: (context, fc) {
            final narrow = fc.maxWidth < 560;
            final search = SearchField(
              controller: _search,
              hint: 'Search products, SKU or barcode…',
              onChanged: (v) => setState(() => _query = v),
              onClear: () {
                _search.clear();
                setState(() => _query = '');
              },
            );
            final dropdown = DropdownButtonFormField<int>(
              initialValue: _categoryFilter,
              isDense: true,
              isExpanded: true,
              icon: const Icon(Icons.expand_more_rounded, size: 19),
              decoration: const InputDecoration(
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12)),
              items: [
                const DropdownMenuItem(value: -1, child: Text('All categories')),
                for (final c in catalog.categories)
                  DropdownMenuItem(value: c.id, child: Text(c.name)),
              ],
              onChanged: (v) => setState(() => _categoryFilter = v ?? -1),
            );
            final chip = FilterChip(
              label: const Text('Low stock'),
              selected: _lowOnly,
              showCheckmark: false,
              labelStyle: TextStyle(
                fontFamily: 'Carlito',
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: _lowOnly ? AppColors.warning : AppColors.muted,
              ),
              selectedColor: AppColors.warningSoft,
              checkmarkColor: AppColors.warning,
              side: BorderSide(
                  color: _lowOnly ? AppColors.warning.withValues(alpha: 0.35) : AppColors.border),
              avatar: Icon(
                Icons.warning_amber_rounded,
                size: 15,
                color: _lowOnly ? AppColors.warning : AppColors.faint,
              ),
              onSelected: (v) => setState(() => _lowOnly = v),
            );
            if (narrow) {
              return Column(
                children: [
                  search,
                  const SizedBox(height: AppSpace.s2),
                  Row(
                    children: [
                      Expanded(child: dropdown),
                      const SizedBox(width: AppSpace.s2),
                      chip,
                    ],
                  ),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: search),
                const SizedBox(width: AppSpace.s2),
                SizedBox(width: 192, child: dropdown),
                const SizedBox(width: AppSpace.s2),
                chip,
              ],
            );
          }),
          const SizedBox(height: 12),
          Expanded(
            child: products.isEmpty
                ? EmptyState(
                    icon: Icons.inventory_2_outlined,
                    // "Not found" is for filtered views; a fresh shop with
                    // zero rows should read as a welcome, not a failure.
                    title: _query.isNotEmpty || _lowOnly || _categoryFilter >= 0
                        ? 'No products found'
                        : 'No products yet',
                    message: _query.isNotEmpty || _lowOnly || _categoryFilter >= 0
                        ? 'Try clearing the search or filters.'
                        : 'Add your first product to start tracking stock.',
                    actionLabel: canManage ? 'New product' : null,
                    onAction: canManage
                        ? () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const ProductEditScreen()))
                        : null,
                  )
                : ListView.separated(
                    itemCount: products.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _ProductTile(
                  product: products[i],
                  settings: settings,
                  canManage: canManage,
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
  final bool canManage;
  final Future<void> Function(Product) onArchive;
  const _ProductTile({
    required this.product,
    required this.settings,
    required this.canManage,
    required this.onArchive,
  });

  @override
  Widget build(BuildContext context) {
    final p = product;
    final lowVariants = p.variants.where((v) => v.stock <= p.lowStock).length;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: canManage
            ? () async {
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => ProductEditScreen(product: product)));
              }
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.s4, vertical: AppSpace.s3),
          child: Row(
            children: [
              ProductThumb(
                image: product.image,
                size: 44,
                radius: AppRadius.md,
                icon: Icons.checkroom_rounded,
                iconSize: 22,
              ),
              const SizedBox(width: AppSpace.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(product.name,
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: AppColors.ink)),
                    const SizedBox(height: 2),
                    Text(
                      '${product.variants.length} variant${product.variants.length == 1 ? '' : 's'}'
                      ' · ${product.variants.isEmpty ? '-' : settings.priceLabel(product.minPrice, product.maxPrice)}'
                      ' · ${_rowBarcode(product) ?? 'no barcode'}',
                      style: TextStyle(fontFamily: 'Carlito', fontSize: 12, color: AppColors.muted),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (lowVariants > 0) ...[
                const SizedBox(width: AppSpace.s2),
                StatusPill.build(context,
                    label: '$lowVariants low', foreground: AppColors.warning, background: AppColors.warningSoft),
              ],
              const SizedBox(width: AppSpace.s2),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.s3, vertical: AppSpace.s1),
                decoration: BoxDecoration(
                  color: AppColors.surfaceTint,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(color: AppColors.borderSoft),
                ),
                child: Text(
                  '${product.totalStock} pcs',
                  style: TextStyle(
                    fontFamily: 'Carlito',
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: lowVariants > 0 ? AppColors.warning : AppColors.body,
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.s2),
              if (canManage)
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert_rounded, size: 20, color: AppColors.muted),
                  onSelected: (v) async {
                    if (v == 'stock') {
                      showDialog(
                        context: context,
                        builder: (_) => StockAdjustDialog(product: product),
                      );
                    } else if (v == 'labels') {
                      if (product.variants.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text('Add a variant first — labels are printed per size/color.')));
                        return;
                      }
                      showLabelPrintDialog(context,
                          groups: [LabelGroup(product, product.variants)]);
                    } else if (v == 'archive') {
                      await onArchive(product);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'stock', child: Text('Adjust stock')),
                    PopupMenuItem(value: 'labels', child: Text('Print labels')),
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
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, AppSpace.s4, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      title: Row(children: [
        Icon(Icons.category_outlined, size: 22, color: AppColors.primary),
        SizedBox(width: AppSpace.s3),
        Text('Categories'),
      ]),
      content: SizedBox(
        width: 380,
        height: 388,
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                itemCount: catalog.categories.length,
                itemBuilder: (context, i) {
                  final c = catalog.categories[i];
                  return ListTile(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        side: BorderSide(color: AppColors.borderSoft)),
                    leading: Icon(Icons.label_outline, size: 19, color: AppColors.muted),
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
                                content: SizedBox(
                                    width: 360,
                                    child: TextField(
                                        controller: ctrl, autofocus: true)),
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
                              size: 18, color: AppColors.danger),
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
            const SizedBox(height: AppSpace.s3),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _new,
                    decoration: const InputDecoration(labelText: 'New category'),
                  ),
                ),
                const SizedBox(width: AppSpace.s2),
                FilledButton.tonalIcon(
                  onPressed: () async {
                    if (_new.text.trim().isEmpty) return;
                    await catalog.addCategory(_new.text);
                    _new.clear();
                  },
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add'),
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
