import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stylepos/data/database.dart';
import 'package:stylepos/state/cart.dart';
import 'package:stylepos/state/catalog.dart';
import 'package:stylepos/state/customers.dart';
import 'package:stylepos/state/sales.dart';
import 'package:stylepos/state/settings.dart';

/// End-to-end test of the POS core: schema + seed data, cart -> checkout
/// transaction (stock decrement + receipt number + loyalty), refund and
/// report queries. Runs against a throwaway SQLite database via FFI.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CatalogProvider catalog;
  late SalesProvider sales;
  late AppSettings settings;
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('stylepos_e2e');
    DB.useDirectory(tempDir.path);
  });

  tearDownAll(() async {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

    setUp(() async {
    catalog = CatalogProvider();
    sales = SalesProvider();
    settings = AppSettings();
    await catalog.reload();
    await settings.load();
  });

  test('database seeds admin, categories, products and variants', () async {
    final db = await DB.instance();
    Future<int> count(String table) async =>
        (await db.rawQuery('SELECT COUNT(*) AS n FROM $table')).first['n'] as int;
    expect(await count('users'), 1); // default admin
    expect(await count('categories'), 7);
    expect(await count('products'), 8);
    expect(await count('variants'), greaterThan(10));
    expect(await count('customers'), 1); // walk-in
    expect(catalog.products, isNotEmpty);
    expect(catalog.products.first.variants, isNotEmpty);
  });

  test('barcode lookup finds the right variant', () {
    final p = catalog.products.first;
    final v = p.variants.first;
    final hit = catalog.findByCode(v.sku);
    expect(hit, isNotNull);
    expect(hit!.$2.id, v.id);
    // wrong code -> no hit
    expect(catalog.findByCode('nonexistent-code'), isNull);
  });

  test('checkout decrements stock, writes receipt number and awards points',
      () async {
    final customers = CustomersProvider()..reload();
    await customers.reload();
    final walkIn = customers.customers.first;

    final product = catalog.products.firstWhere((p) => p.variants.length >= 2);
    final variant = product.variants.first;
    final stockBefore = variant.stock;

    final cart = CartProvider()
      ..add(product, variant)
      ..add(product, variant)
      ..setCustomer(walkIn)
      ..setDiscount(10);

    final sale = await sales.checkout(
      cart: cart,
      userId: 1,
      paymentMethod: 'cash',
      amountPaid: 100000,
      settings: settings,
    );

    expect(sale.receiptNo, 'R-000001');
    expect(sale.total, closeTo(sale.subtotal - 10 + sale.tax, 0.01));
    expect(sale.changeDue, closeTo(100000 - sale.total, 0.01));
    expect(sale.customerName, walkIn.name);

    // checkout does not mutate the cart; the UI clears it afterwards
    cart.clear();
    expect(cart.isEmpty, isTrue);

    // stock decremented by 2
    await catalog.reload();
    final after =
        catalog.products.firstWhere((p) => p.id == product.id).variants.first;
    expect(after.stock, stockBefore - 2);

    // loyalty awarded: 1 point per loyaltyStep (default 100)
    final customers2 = CustomersProvider();
    await customers2.reload();
    final walkIn2 = customers2.customers.firstWhere((c) => c.id == walkIn.id);
    expect(walkIn2.points, greaterThanOrEqualTo(1));

    // movement audit trail recorded
    final db = await DB.instance();
    final movements = await db.query('stock_movements',
        where: 'reason = ?', whereArgs: ['sale']);
    expect(movements, isNotEmpty);
  });

  test('refund restores stock and flags the sale', () async {
    final all = await sales.listSales(days: 0);
    expect(all, hasLength(1));
    final sale = all.first;
    expect(sale.isRefunded, isFalse);

    await catalog.reload();
    final product = catalog.products.first;
    final variant = product.variants.first;
    final stockBefore = variant.stock;

    await sales.refund(sale, 1);
    await catalog.reload();

    final after =
        catalog.products.firstWhere((p) => p.id == product.id).variants.first;
    // refund restored the 2 sold units
    expect(after.stock, stockBefore + 2);

    final refunded = (await sales.listSales(days: 0)).first;
    expect(refunded.isRefunded, isTrue);
  });

  test('report queries execute and stay consistent', () async {
    // Everything was refunded above -> completed revenue resets to zero.
    final today = await sales.summary(1);
    expect(today.revenue, 0);
    expect(today.orders, 0);

    final days = await sales.revenueByDay(7);
    expect(days, hasLength(7));

    final top = await sales.topProducts(30);
    expect(top, isEmpty);

    final share = await sales.categoryShare(30);
    expect(share, isEmpty);

    final low = await sales.lowStockCount();
    expect(low, greaterThanOrEqualTo(0));
  });

  test('stock adjustment writes a restock movement', () async {
    await catalog.reload();
    final product = catalog.products.first;
    final variant = product.variants.first;
    final before = variant.stock;

    await catalog.adjustStock(variant, 5, 'restock', 'test delivery', 1);
    await catalog.reload();
    final after =
        catalog.products.firstWhere((p) => p.id == product.id).variants.first;
    expect(after.stock, before + 5);

    final db = await DB.instance();
    final movements = await db.query('stock_movements',
        where: 'reason = ?', whereArgs: ['restock']);
    expect(movements, isNotEmpty);
  });
}
