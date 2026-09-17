import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../data/database.dart';
import '../models/customer.dart';
import '../models/product.dart';
import 'settings.dart';

/// One line in the shopping cart.
class CartItem {
  final Product product;
  final ProductVariant variant;
  int qty;

  CartItem({required this.product, required this.variant, this.qty = 1});

  double get lineTotal => variant.price * qty;

  String get key => 'v${variant.id}';
}

/// A cart parked aside so the customer can keep browsing.
/// Only lightweight references are stored; the full cart is rebuilt
/// from the catalog when the sale is resumed.
class HeldSale {
  final String id;
  final int heldAt;
  final int? customerId;
  final String? customerName;
  final double discount;
  final List<({int variantId, int qty})> lines;

  const HeldSale({
    required this.id,
    required this.heldAt,
    this.customerId,
    this.customerName,
    this.discount = 0,
    required this.lines,
  });

  int get itemCount => lines.fold(0, (s, l) => s + l.qty);

  Map<String, Object?> toMap() => {
        'id': id,
        'heldAt': heldAt,
        'customerId': customerId,
        'customerName': customerName,
        'discount': discount,
        'lines': [
          for (final l in lines) {'v': l.variantId, 'q': l.qty},
        ],
      };

  factory HeldSale.fromMap(Map<String, Object?> m) => HeldSale(
        id: m['id'] as String,
        heldAt: m['heldAt'] as int? ?? 0,
        customerId: m['customerId'] as int?,
        customerName: m['customerName'] as String?,
        discount: (m['discount'] as num?)?.toDouble() ?? 0,
        lines: [
          for (final l in (m['lines'] as List? ?? []))
            (
              variantId: l['v'] as int,
              qty: l['q'] as int? ?? 1,
            ),
        ],
      );
}

/// Holds the current sale-in-progress. Stock is decremented at checkout,
/// not when items are added, so the cart can be abandoned safely.
/// Full sales can also be parked (held) and resumed later.
class CartProvider extends ChangeNotifier {
  final Map<String, CartItem> _items = {};
  Customer? customer;
  double orderDiscount = 0; // flat amount off the subtotal

  final List<HeldSale> _held = [];

  List<CartItem> get items => _items.values.toList(growable: false);
  bool get isEmpty => _items.isEmpty;
  bool get isNotEmpty => _items.isNotEmpty;
  int get itemCount => _items.values.fold(0, (s, i) => s + i.qty);

  List<HeldSale> get held => List.unmodifiable(_held);
  int get heldCount => _held.length;

  /// Adds one unit. Returns false when the shelf stock for this variant
  /// is already fully in the cart — repeated scans of the same garment
  /// can never oversell it.
  bool add(Product product, ProductVariant variant) {
    final k = 'v${variant.id}';
    final existing = _items[k];
    final inCart = existing?.qty ?? 0;
    if (inCart >= variant.stock) {
      notifyListeners();
      return false;
    }
    if (existing != null) {
      existing.qty += 1;
    } else {
      _items[k] = CartItem(product: product, variant: variant);
    }
    notifyListeners();
    return true;
  }

  void setQty(String key, int qty) {
    if (qty <= 0) {
      _items.remove(key);
    } else {
      _items[key]?.qty = qty;
    }
    notifyListeners();
  }

  void remove(String key) {
    _items.remove(key);
    notifyListeners();
  }

  void setCustomer(Customer? c) {
    customer = c;
    notifyListeners();
  }

  void setDiscount(double v) {
    orderDiscount = v.clamp(0, double.maxFinite);
    notifyListeners();
  }

  void clear() {
    _items.clear();
    customer = null;
    orderDiscount = 0;
    notifyListeners();
  }

  // ---- clear-with-undo (shop-floor safety) ----

  List<CartItem>? _undoSnapshot;
  Customer? _undoCustomer;
  double _undoDiscount = 0;

  /// Captures the current cart so the next [clear] can be reversed with
  /// [undoClear]. Only the cart's Clear button stages this — never the
  /// checkout flow (there the clear must be final: stock is already
  /// decremented and the receipt exists).
  void stageUndo() {
    _undoSnapshot = items;
    _undoCustomer = customer;
    _undoDiscount = orderDiscount;
  }

  /// Restores the cart captured by [stageUndo], replacing whatever is in
  /// the cart now. No-op when nothing was staged.
  void undoClear() {
    final snap = _undoSnapshot;
    if (snap == null) return;
    _undoSnapshot = null;
    _items
      ..clear()
      ..addEntries([for (final i in snap) MapEntry(i.key, i)]);
    customer = _undoCustomer;
    orderDiscount = _undoDiscount;
    notifyListeners();
  }

  // ---- held / parked sales ----

  /// Loads held sales persisted in the settings store (survive restarts).
  Future<void> loadHeld() async {
    try {
      final db = await DB.instance();
      final rows = await db.query('settings',
          where: 'key = ?', whereArgs: ['held_sales']);
      final raw = rows.isEmpty ? null : rows.first['value'] as String?;
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw) as List;
      _held
        ..clear()
        ..addAll([
          for (final e in list) HeldSale.fromMap(e as Map<String, Object?>),
        ]);
      notifyListeners();
    } catch (_) {
      // Corrupt payload -> drop it rather than crash the shop floor.
      _held.clear();
    }
  }

  Future<void> _persistHeld() async {
    try {
      final db = await DB.instance();
      await db.insert(
        'settings',
        {
          'key': 'held_sales',
          'value': jsonEncode([for (final h in _held) h.toMap()]),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {
      // Persistence is best-effort; the in-memory list still works.
    }
  }

  /// Parks the current cart and empties it for the next customer.
  Future<HeldSale> holdCurrentSale() async {
    final h = HeldSale(
      id: 'h${DateTime.now().millisecondsSinceEpoch}',
      heldAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      customerId: customer?.id,
      customerName: customer?.name,
      discount: orderDiscount,
      lines: [
        for (final i in _items.values)
          (variantId: i.variant.id!, qty: i.qty),
      ],
    );
    _held.insert(0, h);
    _items.clear();
    customer = null;
    orderDiscount = 0;
    notifyListeners();
    await _persistHeld();
    return h;
  }

  /// Restores a parked sale into the cart.
  /// [lookup] resolves variant ids against the live catalog; lines whose
  /// variant no longer exists are skipped. Returns false if nothing was
  /// restorable (the held sale is removed in that case).
  Future<bool> resumeHeld(
    HeldSale h,
    ({Product product, ProductVariant variant})? Function(int variantId) lookup,
  ) async {
    _items.clear();
    customer = null;
    orderDiscount = 0;
    var restored = 0;
    for (final line in h.lines) {
      final match = lookup(line.variantId);
      if (match == null) continue;
      final k = 'v${match.variant.id}';
      final existing = _items[k];
      if (existing != null) {
        existing.qty += line.qty;
      } else {
        _items[k] = CartItem(
          product: match.product,
          variant: match.variant,
          qty: line.qty,
        );
      }
      restored += line.qty;
    }
    _held.remove(h);
    if (restored > 0) {
      orderDiscount = h.discount;
      if (h.customerId != null) {
        customer = Customer(
          id: h.customerId,
          name: h.customerName ?? 'Customer',
          createdAt: 0,
        );
      }
    }
    notifyListeners();
    await _persistHeld();
    return restored > 0;
  }

  /// Discards a parked sale without restoring it.
  Future<void> dropHeld(HeldSale h) async {
    _held.remove(h);
    notifyListeners();
    await _persistHeld();
  }

  double get subtotal => _items.values.fold(0, (s, i) => s + i.lineTotal);
  double get discount => orderDiscount.clamp(0, subtotal);
  double get taxable => subtotal - discount;
  double tax(double taxRatePercent) => taxable * taxRatePercent / 100;
  double total(double taxRatePercent) => taxable + tax(taxRatePercent);
}

/// Convenience extension used by checkout to push totals into the DB layer.
extension CartTotals on CartProvider {
  ({double subtotal, double discount, double tax, double total})
      totalsWith(AppSettings settings) {
    final t = total(settings.taxRate);
    return (
      subtotal: subtotal,
      discount: discount,
      tax: tax(settings.taxRate),
      total: t,
    );
  }
}
