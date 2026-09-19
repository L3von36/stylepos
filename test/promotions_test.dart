import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stylepos/data/database.dart';
import 'package:stylepos/models/product.dart';
import 'package:stylepos/models/promotion.dart';
import 'package:stylepos/state/cart.dart';
import 'package:stylepos/state/catalog.dart';
import 'package:stylepos/state/promotions.dart';
import 'package:stylepos/state/sales.dart';
import 'package:stylepos/state/settings.dart';

/// Pricing & promotions (v1.16.0): promotion validation/lifecycle, cart
/// promo application (manager-created promos bypass the manual-discount
/// gate), usage counting at checkout, bulk price updates and the new
/// report queries (category margins / slow movers / monthly tax).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CatalogProvider catalog;
  late SalesProvider sales;
  late PromotionsProvider promos;
  late AppSettings settings;
  late CartProvider cart;
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('stylepos_promo');
    DB.useDirectory(tempDir.path);
    catalog = CatalogProvider();
    await catalog.reload();
    sales = SalesProvider();
    settings = AppSettings();
    await settings.load();
    cart = CartProvider();
    promos = PromotionsProvider();
    await promos.reload();

    await catalog.saveProduct(const Product(
      name: 'Promo Tee',
      barcode: 'PRM-0001',
      lowStock: 2,
      createdAt: 0,
      variants: [
        ProductVariant(
            productId: 0,
            sku: 'PRM-0001-S',
            barcode: 'PRM-0001-S1',
            price: 100,
            cost: 40,
            stock: 30),
        ProductVariant(
            productId: 0,
            sku: 'PRM-0001-M',
            barcode: 'PRM-0001-M1',
            price: 200,
            cost: 80,
            stock: 30),
      ],
    ));
  });

  tearDownAll(() async {
    await DB.closeAndReset();
    tempDir.deleteSync(recursive: true);
  });

  group('promotion model', () {
    test('percent discount is computed and clamped to the subtotal', () {
      final p = Promotion(
          name: 'Ten off', code: 'TEN', type: 'percent', value: 10, createdAt: 0);
      expect(p.discountFor(100), 10);
      expect(p.discountFor(55), 5.5);
      expect(p.discountFor(0), 0);
    });

    test('fixed discount never exceeds the subtotal', () {
      final p = Promotion(
          name: 'Flat', code: 'FLAT', type: 'fixed', value: 80, createdAt: 0);
      expect(p.discountFor(200), 80);
      expect(p.discountFor(50), 50);
    });

    test('blockedReason covers pause, window, usage limit and minimum', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final paused = Promotion(name: 'P', code: 'P', active: false, createdAt: 0);
      expect(paused.blockedReason(nowEpoch: now, subtotal: 999), contains('paused'));

      final future = Promotion(
          name: 'F', code: 'F', startsAt: now + 3600, createdAt: 0);
      expect(future.blockedReason(nowEpoch: now, subtotal: 999), contains('Not started'));

      final past = Promotion(name: 'E', code: 'E', endsAt: now - 10, createdAt: 0);
      expect(past.blockedReason(nowEpoch: now, subtotal: 999), contains('Expired'));

      final limited = Promotion(
          name: 'L', code: 'L', usageLimit: 2, usedCount: 2, createdAt: 0);
      expect(limited.blockedReason(nowEpoch: now, subtotal: 999), contains('Usage limit'));

      final minOnly = Promotion(
          name: 'M', code: 'M', minSubtotal: 500, createdAt: 0);
      expect(minOnly.blockedReason(nowEpoch: now, subtotal: 100), contains('minimum'));
      expect(minOnly.blockedReason(nowEpoch: now, subtotal: 500), isNull);
    });
  });

  group('promotion CRUD', () {
    test('saves, rejects duplicate codes and soft-deletes', () async {
      expect(
          await promos.save(
              Promotion(name: 'Welcome', code: 'WELCOME10', type: 'percent',
                  value: 10, createdAt: 0)),
          isNull);
      expect(
          await promos.save(
              Promotion(name: 'Clash', code: 'welcome10', type: 'percent',
                  value: 5, createdAt: 0)),
          contains('already in use'));
      expect(
          await promos.save(
              Promotion(name: 'Bad', code: 'TOO MUCH', type: 'percent',
                  value: 5, createdAt: 0)),
          contains('spaces'));
      expect(
          await promos.save(
              Promotion(name: 'Big', code: 'BIG', type: 'percent',
                  value: 150, createdAt: 0)),
          contains('100'));

      final saved = promos.findByCode('welcome10');
      expect(saved, isNotNull);
      expect(saved!.code, 'WELCOME10');

      // Unknown codes do not resolve.
      expect(promos.findByCode('NOPE'), isNull);

      await promos.delete(saved);
      expect(promos.findByCode('WELCOME10'), isNull);
    });
  });

  group('cart + checkout with promo', () {
    test('promo discount stacks with the manual discount without approval',
        () async {
      final product = catalog.products.first;
      final variant = product.variants.first;
      cart.add(product, variant);
      cart.setDiscount(10);
      expect(cart.discount, 10); // manual part
      expect(cart.promoDiscount, 0);

      await promos.save(Promotion(
          name: 'Welcome', code: 'WELCOME10', type: 'percent',
          value: 10, createdAt: 0));
      final promo = promos.findByCode('WELCOME10')!;
      cart.setPromo(promo);

      // subtotal 100: manual 10 + promo 10% of (100-10) = 9 → 19 total.
      expect(cart.totalDiscount, 19);
      expect(cart.total(settings.taxRate), 81);

      final sale = await sales.checkout(
        cart: cart,
        userId: 1,
        paymentMethod: 'cash',
        amountPaid: 100,
        settings: settings,
      );
      expect(sale.promoCode, 'WELCOME10');
      expect(sale.promoDiscount, 9);
      expect(sale.total, 81);

      // Usage counter bumped through the checkout transaction (the provider
      // list refreshes on the next sync — reload here to read the DB row).
      await promos.reload();
      final used = promos.findByCode('WELCOME10')!;
      expect(used.usedCount, 1);

      cart.clear();
    });

    test('held sale keeps the promo code and revalidates on resume',
        () async {
      final product = catalog.products.first;
      cart.add(product, product.variants.first);
      final promo = promos.findByCode('WELCOME10')!;
      cart.setPromo(promo);

      final held = await cart.holdCurrentSale();
      expect(held.promoCode, 'WELCOME10');
      expect(cart.promo, isNull);
      expect(cart.isEmpty, isTrue);

      // Resume with a live lookup restores the promotion.
      final ok = await cart.resumeHeld(held, catalog.findVariantById,
          promoLookup: promos.findByCode);
      expect(ok, isTrue);
      expect(cart.promo?.code, 'WELCOME10');

      // A tombstoned/expired promo silently drops on resume.
      final expiredHeld = await cart.holdCurrentSale();
      final ok2 = await cart.resumeHeld(expiredHeld, catalog.findVariantById,
          promoLookup: (code) => null);
      expect(ok2, isTrue);
      expect(cart.promo, isNull);
      cart.clear();
    });
  });

  group('bulk price update', () {
    test('moves every scoped variant price and skips no-ops', () async {
      // +10% on everything: 100 -> 110, 200 -> 220.
      final changed = await catalog.bulkPriceUpdate(
        transform: (old) => double.parse((old * 1.1).toStringAsFixed(2)),
      );
      expect(changed, 2);
      final prices = catalog.products.first.variants.map((v) => v.price).toSet();
      expect(prices, containsAll(<double>[110, 220]));

      // Scoped to a non-existent category: nothing changes.
      final scoped = await catalog.bulkPriceUpdate(
        categoryId: 99999,
        transform: (old) => old + 1,
      );
      expect(scoped, 0);
    });
  });

  group('new report queries', () {
    test('categoryMargins, slowMovers, revenueByMonth and taxByMonth run',
        () async {
      final margins = await sales.categoryMargins(30);
      expect(margins, isNotEmpty);
      expect(margins.first.revenue, greaterThan(0));

      final slow = await sales.slowMovers(30);
      // Products have stock; after the sale above at least one sold.
      expect(slow, isNotEmpty);

      final months = await sales.revenueByMonth(12);
      expect(months.length, 12);
      expect(months.last.$2, greaterThan(0));

      final tax = await sales.taxByMonth(6);
      expect(tax.length, 6);
    });
  });
}
