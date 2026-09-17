import 'package:flutter/foundation.dart';

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

/// Holds the current sale-in-progress. Stock is decremented at checkout,
/// not when items are added, so the cart can be abandoned safely.
class CartProvider extends ChangeNotifier {
  final Map<String, CartItem> _items = {};
  Customer? customer;
  double orderDiscount = 0; // flat amount off the subtotal

  List<CartItem> get items => _items.values.toList(growable: false);
  bool get isEmpty => _items.isEmpty;
  int get itemCount => _items.values.fold(0, (s, i) => s + i.qty);

  void add(Product product, ProductVariant variant) {
    final k = 'v${variant.id}';
    final existing = _items[k];
    if (existing != null) {
      existing.qty += 1;
    } else {
      _items[k] = CartItem(product: product, variant: variant);
    }
    notifyListeners();
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
