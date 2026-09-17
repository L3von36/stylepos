import 'package:flutter/foundation.dart' hide Category;

import '../data/database.dart';
import '../models/category.dart';
import '../models/product.dart';

/// Loads and manages products, variants, categories and stock movements.
class CatalogProvider extends ChangeNotifier {
  List<Category> categories = [];
  List<Product> products = [];
  bool loading = false;

  Future<void> reload() async {
    loading = true;
    notifyListeners();
    try {
      final db = await DB.instance();
      final catRows = await db.query('categories', orderBy: 'name');
      categories = catRows.map(Category.fromMap).toList();

      final prodRows = await db.query('products',
          where: 'archived = 0', orderBy: 'name');
      final prodIds = prodRows.map((r) => r['id'] as int).toList();

      final Map<int, List<ProductVariant>> byProduct = {};
      if (prodIds.isNotEmpty) {
        final placeholders = List.filled(prodIds.length, '?').join(',');
        final varRows = await db.query('variants',
            where: 'product_id IN ($placeholders) AND archived = 0',
            whereArgs: prodIds,
            orderBy: 'id');
        for (final r in varRows) {
          final v = ProductVariant.fromMap(r);
          byProduct.putIfAbsent(v.productId, () => []).add(v);
        }
      }

      products = prodRows.map((r) {
        final p = Product.fromMap(r);
        return p.copyWith(variants: byProduct[p.id] ?? const []);
      }).toList();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  String? categoryName(int? id) {
    if (id == null) return null;
    for (final c in categories) {
      if (c.id == id) return c.name;
    }
    return null;
  }

  // ---- categories ----

  Future<void> addCategory(String name) async {
    final db = await DB.instance();
    await db.insert('categories', Category(name: name.trim()).toMap());
    await reload();
  }

  Future<void> renameCategory(Category c, String newName) async {
    final db = await DB.instance();
    await db.update('categories', Category(name: newName.trim()).toMap(),
        where: 'id = ?', whereArgs: [c.id]);
    await reload();
  }

  /// Returns null on success, or an error (e.g. products still assigned).
  Future<String?> deleteCategory(Category c) async {
    final db = await DB.instance();
    final used = await db.query('products',
        where: 'category_id = ?', whereArgs: [c.id], limit: 1);
    if (used.isNotEmpty) {
      return 'Cannot delete: products are still assigned to this category.';
    }
    await db.delete('categories', where: 'id = ?', whereArgs: [c.id]);
    await reload();
    return null;
  }

  // ---- products & variants ----

  /// Saves a product and its variants in one transaction.
  /// `removeVariantIds` archives variants that were removed in the editor.
  Future<void> saveProduct(Product product, {List<int>? removeVariantIds}) async {
    final db = await DB.instance();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    await db.transaction((txn) async {
      int pid;
      if (product.id == null) {
        pid = await txn.insert(
            'products', product.copyWith(createdAt: now).toMap());
      } else {
        pid = product.id!;
        await txn.update('products', product.toMap(),
            where: 'id = ?', whereArgs: [pid]);
      }

      for (final v in product.variants) {
        final attached = v.copyWith(productId: pid);
        if (attached.id == null) {
          final vid = await txn.insert('variants', attached.toMap());
          if (attached.stock > 0) {
            await txn.insert('stock_movements', {
              'variant_id': vid,
              'qty': attached.stock,
              'reason': 'initial',
              'note': 'Opening stock',
              'user_id': null,
              'created_at': now,
            });
          }
        } else {
          await txn.update('variants', attached.toMap(),
              where: 'id = ?', whereArgs: [attached.id]);
        }
      }

      for (final vid in removeVariantIds ?? const <int>[]) {
        await txn.update('variants', {'archived': 1},
            where: 'id = ?', whereArgs: [vid]);
      }
    });

    await reload();
  }

  Future<void> archiveProduct(Product product) async {
    final db = await DB.instance();
    await db.update('products', {'archived': 1},
        where: 'id = ?', whereArgs: [product.id]);
    await reload();
  }

  /// Applies a signed stock delta to a variant and records the movement.
  Future<void> adjustStock(
      ProductVariant variant, int delta, String reason, String? note, int? userId) async {
    if (delta == 0) return;
    final db = await DB.instance();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await db.transaction((txn) async {
      final newStock = (variant.stock + delta).clamp(0, 1 << 30);
      await txn.update('variants', {'stock': newStock},
          where: 'id = ?', whereArgs: [variant.id]);
      await txn.insert('stock_movements', {
        'variant_id': variant.id,
        'qty': delta,
        'reason': reason,
        'note': note,
        'user_id': userId,
        'created_at': now,
      });
    });
    await reload();
  }

  /// Exact SKU / barcode lookup used by the POS scan-in field.
  (Product, ProductVariant)? findByCode(String code) {
    final c = code.trim();
    if (c.isEmpty) return null;
    for (final p in products) {
      for (final v in p.variants) {
        if (v.matchesCode(c)) return (p, v);
      }
    }
    return null;
  }

  /// All (product, variant) pairs at or below their low-stock threshold.
  List<(Product, ProductVariant)> lowStockItems() {
    final out = <(Product, ProductVariant)>[];
    for (final p in products) {
      for (final v in p.variants) {
        if (v.stock <= p.lowStock) out.add((p, v));
      }
    }
    out.sort((a, b) => a.$2.stock.compareTo(b.$2.stock));
    return out;
  }
}
