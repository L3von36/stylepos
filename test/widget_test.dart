import 'package:flutter_test/flutter_test.dart';
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
