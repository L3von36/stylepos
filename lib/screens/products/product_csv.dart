import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/category.dart';
import '../../models/product.dart';
import '../../services/audit.dart';
import '../../services/csv_util.dart';
import '../../state/auth.dart';
import '../../state/catalog.dart';
import '../../state/settings.dart';

/// Bulk catalog import/export (manager): CSV rows are one variant per line
/// and round-trip with the export format.
///
///   name,category,barcode,description,low_stock,size,color,sku,variant_barcode,price,cost,stock
///
/// Import matches products by name (case-insensitive) and variants by SKU
/// (else size+color). Missing categories are created. Stock differences on
/// matched variants are applied as 'count' stock movements so the movement
/// history stays truthful.
class ProductCsv {
  ProductCsv._();

  static const _headers = [
    'name', 'category', 'barcode', 'description', 'low_stock',
    'size', 'color', 'sku', 'variant_barcode', 'price', 'cost', 'stock',
  ];

  // ------------------------------------------------------------- export

  static Future<void> export(BuildContext context) async {
    final catalog = context.read<CatalogProvider>();
    final messenger = ScaffoldMessenger.of(context);

    final buf = StringBuffer('${_headers.join(',')}\n');
    String s(String? v) => v ?? '';
    for (final p in catalog.products) {
      final cat = catalog.categoryName(p.categoryId) ?? '';
      for (final v in p.variants) {
        buf.writeln([
          p.name, cat, s(p.barcode), s(p.description), '${p.lowStock}',
          v.size, v.color, v.sku, s(v.barcode),
          v.price.toStringAsFixed(2), v.cost.toStringAsFixed(2), '${v.stock}',
        ].map(CsvUtil.escape).join(','));
      }
    }

    final name =
        'Sami-products-${DateTime.now().toIso8601String().substring(0, 10)}.csv';
    try {
      final res = await CsvUtil.saveFile(
          name: name, data: CsvUtil.encodeUtf8(buf.toString()));
      if (res != null) messenger.showSnackBar(SnackBar(content: Text('CSV $res')));
    } catch (_) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Export failed — please try again')));
    }
  }

  // ------------------------------------------------------------- import

  /// Opens a CSV file, previews it and applies it on confirm.
  static Future<void> import(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'txt'],
      withData: true,
    );
    final file = picked?.files.singleOrNull;
    if (file == null) return;
    final raw = file.bytes != null
        ? String.fromCharCodes(file.bytes!)
        : '';
    if (raw.trim().isEmpty) {
      messenger.showSnackBar(
          const SnackBar(content: Text('That file is empty or unreadable')));
      return;
    }

    final rows = CsvUtil.parse(raw);
    if (rows.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('No rows found')));
      return;
    }
    final idx = CsvUtil.headerIndex(rows.first, _headers);
    if (idx['name']! < 0) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Missing "name" column — export a CSV first to see '
            'the expected format'),
      ));
      return;
    }

    // Build the row records (skip the header row).
    final records = <Map<String, String>>[];
    for (final r in rows.skip(1)) {
      String cell(String col) {
        final i = idx[col]!;
        return i >= 0 && i < r.length ? r[i].trim() : '';
      }

      records.add({
        for (final h in _headers) h: cell(h),
      });
    }
    final withName = records.where((r) => r['name']!.isNotEmpty).toList();
    if (withName.isEmpty) {
      messenger.showSnackBar(const SnackBar(
          content: Text('No usable rows — every row needs a product name')));
      return;
    }

    if (!context.mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Import catalog?'),
        content: SizedBox(
          width: 420,
          child: Text(
            '${withName.length} row${withName.length == 1 ? '' : 's'} found.\n\n'
            '• Products are matched by name, variants by SKU (then size + color).\n'
            '• Missing products, variants and categories are created.\n'
            '• Price, cost and stock are updated; stock changes are recorded '
            'as count adjustments.\n\n'
            'Existing sales history is never touched.',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(c, true),
            icon: const Icon(Icons.upload_file_outlined, size: 17),
            label: const Text('Import'),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return;

    final catalog = context.read<CatalogProvider>();
    final settings = context.read<AppSettings>();
    final me = context.read<AuthProvider>().user;

    var created = 0;
    var updated = 0;
    var skipped = 0;
    final errors = <String>[];

    String two(int n) => n.toString().padLeft(2, '0');

    try {
      // ---- pre-pass: create missing categories ------------------------
      final wanted = {
        for (final r in withName)
          if (r['category']!.isNotEmpty) r['category']!.toLowerCase(),
      };
      for (final w in wanted) {
        final exists = catalog.categories.any(
            (c) => c.name.trim().toLowerCase() == w);
        if (!exists) await catalog.addCategory(w);
      }
      Category? findCategory(String name) {
        for (final c in catalog.categories) {
          if (c.name.trim().toLowerCase() == name.trim().toLowerCase()) {
            return c;
          }
        }
        return null;
      }

      // ---- row loop ----------------------------------------------------
      for (var i = 0; i < withName.length; i++) {
        final r = withName[i];
        final rowLabel = 'row ${two(i + 2)}'; // +2: header + 1-index
        try {
          final name = r['name']!;
          double? price = double.tryParse(r['price']!.replaceAll(',', ''));
          double? cost = double.tryParse(r['cost']!.replaceAll(',', ''));
          int? stock = int.tryParse(r['stock']!);
          int? lowStock = int.tryParse(r['low_stock']!);

          // Fresh provider state: saveProduct reloads after every save.
          Product? product;
          for (final p in catalog.products) {
            if (p.name.trim().toLowerCase() == name.toLowerCase()) {
              product = p;
              break;
            }
          }

          if (product == null) {
            // ---- create product + its first variant -------------------
            final sku = _uniqueSku(r['sku']!, name, r['size']!, r['color']!, i, catalog);
            final cat = r['category']!.isEmpty ? null : findCategory(r['category']!);
            final variant = ProductVariant(
              productId: 0,
              size: r['size']!,
              color: r['color']!,
              sku: sku,
              barcode: r['variant_barcode']!.isEmpty ? null : r['variant_barcode'],
              price: price ?? 0,
              cost: cost ?? 0,
              stock: stock ?? 0,
            );
            final newProduct = Product(
              name: name,
              categoryId: cat?.id,
              barcode: r['barcode']!.isEmpty ? null : r['barcode'],
              description: r['description']!.isEmpty ? null : r['description'],
              lowStock: lowStock ?? settings.lowStockDefault,
              createdAt: 0,
              variants: [variant],
            );
            await catalog.saveProduct(newProduct);
            created++;
            continue;
          }

          // ---- match or create the variant -----------------------------
          ProductVariant? variant;
          final csvSku = r['sku']!.toLowerCase();
          final csvSize = r['size']!.toLowerCase();
          final csvColor = r['color']!.toLowerCase();
          for (final v in product.variants) {
            final skuMatch =
                csvSku.isNotEmpty && v.sku.trim().toLowerCase() == csvSku;
            final scMatch = csvSku.isEmpty &&
                v.size.trim().toLowerCase() == csvSize &&
                v.color.trim().toLowerCase() == csvColor;
            if (skuMatch || scMatch) {
              variant = v;
              break;
            }
          }

          if (variant == null) {
            final sku = _uniqueSku(r['sku']!, name, r['size']!, r['color']!, i, catalog);
            final newVariant = ProductVariant(
              productId: product.id!,
              size: r['size']!,
              color: r['color']!,
              sku: sku,
              barcode: r['variant_barcode']!.isEmpty ? null : r['variant_barcode'],
              price: price ?? 0,
              cost: cost ?? 0,
              stock: stock ?? 0,
            );
            await catalog.saveProduct(
              product.copyWith(variants: [...product.variants, newVariant]),
            );
            updated++;
            continue;
          }

          // ---- update existing variant + product fields ----------------
          final updatedVariant = variant.copyWith(
            price: price ?? variant.price,
            cost: cost ?? variant.cost,
            barcode: r['variant_barcode']!.isEmpty
                ? variant.barcode
                : r['variant_barcode'],
          );
          final updatedProduct = product.copyWith(
            categoryId: r['category']!.isEmpty
                ? product.categoryId
                : (findCategory(r['category']!)?.id ?? product.categoryId),
            barcode: r['barcode']!.isEmpty ? product.barcode : r['barcode'],
            description:
                r['description']!.isEmpty ? product.description : r['description'],
            lowStock: lowStock ?? product.lowStock,
            variants: [
              for (final v in product.variants)
                v.id == variant.id ? updatedVariant : v,
            ],
          );
          await catalog.saveProduct(updatedProduct);
          updated++;

          // Stock: apply the difference as a count movement (movement
          // history stays truthful).
          if (stock != null && stock != variant.stock) {
            await catalog.adjustStock(
              updatedVariant,
              stock - variant.stock,
              'count',
              'CSV import',
              me?.id,
            );
          }
        } catch (e) {
          skipped++;
          if (errors.length < 3) errors.add('$rowLabel: $e');
        }
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Import failed: $e')));
      return;
    }

    await Audit.add(
      'csv_import',
      '$created created · $updated updated'
      '${skipped == 0 ? '' : ' · $skipped skipped'}',
      userId: me?.id,
      userName: me?.name,
    );

    final msg = StringBuffer('Imported: $created new · $updated updated');
    if (skipped > 0) msg.write(' · $skipped skipped');
    if (errors.isNotEmpty) msg.write('\n${errors.join('\n')}');
    messenger.showSnackBar(SnackBar(
      content: Text(msg.toString()),
      duration: const Duration(seconds: 5),
    ));
  }

  /// Uses the CSV SKU when present; otherwise builds a slug from the
  /// product/variant fields, kept unique against the live catalog.
  static String _uniqueSku(String csvSku, String name, String size, String color,
      int row, CatalogProvider catalog) {
    final base = csvSku.isNotEmpty
        ? csvSku
        : [name, size, color]
            .where((p) => p.trim().isNotEmpty)
            .join('-')
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
            .replaceAll(RegExp(r'^-+|-+$'), '');
    final existing = <String>{
      for (final p in catalog.products)
        for (final v in p.variants) v.sku.trim().toLowerCase(),
    };
    var sku = base.isEmpty ? 'import-$row' : base;
    if (existing.contains(sku.toLowerCase())) sku = '$sku-$row';
    return sku;
  }
}
