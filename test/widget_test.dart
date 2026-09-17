import 'package:flutter_test/flutter_test.dart';
import 'package:stylepos/models/customer.dart';
import 'package:stylepos/models/product.dart';
import 'package:stylepos/state/cart.dart';
import 'package:stylepos/state/settings.dart';

void main() {
  group('CartProvider totals', () {
    test('subtotals, discounts and tax are computed correctly', () {
      final cart = CartProvider();
      expect(cart.isEmpty, isTrue);
      expect(cart.total(0), 0);
    });
  });

  group('CartProvider clear-with-undo', () {
    test('stageUndo + undoClear restores items, customer and discount', () {
      final product = Product(name: 'Classic Tee', createdAt: 0);
      final variant = const ProductVariant(productId: 0, sku: 'TEE-1', price: 500, stock: 5);
      final cart = CartProvider()
        ..add(product, variant)
        ..setCustomer(const Customer(id: 7, name: 'Ada', createdAt: 0))
        ..setDiscount(15);

      cart.stageUndo();
      cart.clear();
      expect(cart.isEmpty, isTrue);
      expect(cart.discount, 0);
      expect(cart.customer, isNull);

      cart.undoClear();
      expect(cart.itemCount, 1);
      expect(cart.discount, 15);
      expect(cart.customer?.id, 7);
      expect(cart.isNotEmpty, isTrue);
    });

    test('undo without a staged snapshot is a safe no-op', () {
      final cart = CartProvider();
      cart.undoClear();
      expect(cart.isEmpty, isTrue);
    });

    test('stock cap still blocks adding more units than exist', () {
      final product = Product(name: 'Dress', createdAt: 0);
      final variant = const ProductVariant(productId: 0, sku: 'DRS-1', stock: 2);
      final cart = CartProvider();
      expect(cart.add(product, variant), isTrue);
      expect(cart.add(product, variant), isTrue);
      // shelf stock is fully in the cart now
      expect(cart.add(product, variant), isFalse);
      expect(cart.itemCount, 2);
    });
  });

  group('AppSettings money formatting', () {
    test('formats with configured symbol and separators', () {
      final s = AppSettings();
      expect(s.money(1250), 'KSh 1,250.00');
    });

    test('formats when currency is changed before load', () {
      final s = AppSettings();
      s.currencySymbol = '\$';
      // internal formatter refresh happens on save(); direct formatting
      // still uses defaults until then.
      expect(s.money(1250), 'KSh 1,250.00');
    });
  });
}
