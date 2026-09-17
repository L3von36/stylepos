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

  test('cart.add cannot oversell the shelf stock', () {
    final product = catalog.products.first;
    final variant = product.variants.first;
    final cart = CartProvider();

    var added = 0;
    for (var i = 0; i < variant.stock + 3; i++) {
      if (cart.add(product, variant)) added++;
    }
    expect(added, variant.stock);
    expect(cart.itemCount, variant.stock);
  });

  test('held sales: park, resume, discard and survive restart', () async {
    final cart = CartProvider();
    await cart.loadHeld();
    expect(cart.heldCount, 0);

    final product = catalog.products.first;
    final variant = product.variants.first;
    cart.add(product, variant);
    cart.add(product, variant);
    cart.setDiscount(50);

    final held = await cart.holdCurrentSale();
    expect(cart.isEmpty, isTrue);
    expect(cart.heldCount, 1);
    expect(held.lines.single.qty, 2);

    // resume rebuilds the cart from the live catalog
    final ok = await cart.resumeHeld(held, catalog.findVariantById);
    expect(ok, isTrue);
    expect(cart.items.single.qty, 2);
    expect(cart.orderDiscount, 50);
    expect(cart.heldCount, 0);

    // park again -> persists -> a "fresh" provider sees it after reload
    cart.clear();
    cart.add(product, variant);
    await cart.holdCurrentSale();
    expect(cart.heldCount, 1);

    final cart2 = CartProvider();
    await cart2.loadHeld();
    expect(cart2.heldCount, 1);
    expect(cart2.held.first.itemCount, 1);

    // resuming on the fresh provider removes it from persistence too
    final resumed =
        await cart2.resumeHeld(cart2.held.first, catalog.findVariantById);
    expect(resumed, isTrue);
    final cart3 = CartProvider();
    await cart3.loadHeld();
    expect(cart3.heldCount, 0);

    // The original provider still holds its own reference to the parked
    // sale that cart2 consumed from persistence; discard it to stay in
    // sync (mirrors two screens sharing one persisted store).
    await cart.dropHeld(cart.held.first);
    expect(cart.heldCount, 0);

    // lines whose variant no longer exists are not restorable
    cart.add(product, variant);
    final h3 = await cart.holdCurrentSale();
    final bogus = HeldSale(
        id: 'x',
        heldAt: 0,
        lines: const [(variantId: 999999, qty: 1)]);
    expect(await cart.resumeHeld(bogus, catalog.findVariantById), isFalse);
    await cart.dropHeld(h3);
    expect(cart.heldCount, 0);
  });

  test('manager reports: staff performance, profit, payment mix, my day',
      () async {
    // Complete one fresh sale (the earlier one was refunded above).
    await catalog.reload();
    final product = catalog.products.first;
    final variant = product.variants.first;
    final cart = CartProvider()..add(product, variant);
    final sale = await sales.checkout(
      cart: cart,
      userId: 1,
      paymentMethod: 'mobile',
      amountPaid: 999999,
      settings: settings,
    );
    expect(sale.total, greaterThan(0));
    cart.clear();

    final staff = await sales.staffPerformance(7);
    expect(staff, isNotEmpty);
    expect(staff.first.name, 'Admin');
    expect(staff.first.orders, 1);
    expect(staff.first.revenue, greaterThan(0));

    final cost = await sales.cogs(7);
    expect(cost, greaterThan(0));

    final pays = await sales.paymentBreakdown(7);
    expect(pays, isNotEmpty);
    expect(pays.first.method, 'mobile');
    expect(pays.first.total, greaterThan(0));

    final mine = await sales.todaySummaryForUser(1);
    expect(mine.orders, 1);
    expect(mine.revenue, greaterThan(0));
    expect(mine.itemsSold, 1);
  });
}
