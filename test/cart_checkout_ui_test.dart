import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stylepos/models/product.dart';
import 'package:stylepos/screens/pos/cart_panel.dart';
import 'package:stylepos/screens/pos/checkout_dialog.dart';
import 'package:stylepos/state/auth.dart';
import 'package:stylepos/state/cart.dart';
import 'package:stylepos/state/settings.dart';

/// v1.24.0: (1) the phone cart sheet used to clip the Charge button off
/// the bottom on short screens / with the keyboard open; (2) smart
/// quick-cash chips on the payment sheet.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Real Carlito metrics: without it the test font (square Ahem glyphs)
  // renders labels ~3x wider and the totals rows overflow horizontally
  // — an artifact, not the bug under test.
  setUpAll(() async {
    final regular = File('assets/fonts/Carlito-Regular.ttf')
        .readAsBytesSync();
    final bold = File('assets/fonts/Carlito-Bold.ttf').readAsBytesSync();
    final loader = FontLoader('Carlito')
      ..addFont(Future.value(ByteData.view(regular.buffer)))
      ..addFont(Future.value(ByteData.view(bold.buffer)));
    await loader.load();
  });


  group('quickCashFor — payment quick-cash chips', () {
    test('exact amount first, then round numbers above it', () {
      final chips = quickCashFor(1080);
      expect(chips, [1080, 1100, 2000]);
    });

    test('small totals also offer the common notes', () {
      expect(quickCashFor(80), [80, 100, 200, 500]);
    });

    test('no duplicates, ascending, capped at four, all payable', () {
      for (final total in <double>[120, 250, 333.5, 999, 1500, 5000]) {
        final chips = quickCashFor(total);
        expect(chips.length, lessThanOrEqualTo(4),
            reason: 'total $total: max four chips');
        final sorted = [...chips]..sort();
        expect(chips, sorted, reason: 'total $total must be ascending');
        expect(chips.toSet().length, chips.length,
            reason: 'total $total must be deduped');
        for (final c in chips) {
          expect(c + 0.001, greaterThanOrEqualTo(total),
              reason: 'chip $c must cover total $total');
        }
      }
    });

    test('a non-integer total never gets a false "exact" chip', () {
      final chips = quickCashFor(1079.5);
      expect(chips.contains(1079.5), isFalse);
      expect(chips.first, 1080); // rounded up, still payable
    });
  });

  group('CartPanel phone sheet — charge button always visible', () {
    Widget harness(CartProvider cart, {double height = 420}) {
      return MultiProvider(
        providers: [
          ChangeNotifierProvider<CartProvider>.value(value: cart),
          ChangeNotifierProvider<AppSettings>(create: (_) => AppSettings()),
          ChangeNotifierProvider<AuthProvider>(create: (_) => AuthProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              // Deliberately SHORT — the old all-fixed Column clipped the
              // charge button on exactly this kind of screen.
              child: SizedBox(
                width: 360,
                height: height,
                child: CartPanel(scrollable: false),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('short screen: button pinned, no overflow, tappable',
        (tester) async {
      // Phone-sized surface so tapping Charge opens the MOBILE checkout
      // sheet (the production path) rather than the desktop dialog.
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final cart = CartProvider();
      void add(String name, double price) {
        final product = Product(name: name, createdAt: 0, variants: [
          ProductVariant(
              id: name.hashCode,
              productId: 0,
              sku: '$name-1',
              price: price,
              stock: 10),
        ]);
        cart.add(product, product.variants.first);
      }

      add('Test Dress', 1200);
      add('Silk Shirt', 800);

      await tester.pumpWidget(harness(cart));
      await tester.pump();

      // No RenderFlex overflow exception — the harness fails on one anyway.
      expect(tester.takeException(), isNull);

      // The pinned charge button sits fully inside the card.
      final btnRect = tester.getRect(find.byType(FilledButton));
      final cardRect = tester.getRect(find.byType(Card));
      expect(btnRect.bottom, lessThanOrEqualTo(cardRect.bottom + 0.5));
      expect(btnRect.height, greaterThanOrEqualTo(48));

      // Hit-testable: tapping opens the checkout sheet without errors.
      await tester.tap(find.byType(FilledButton));
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.takeException(), isNull);
      expect(find.text('Take payment'), findsOneWidget);
    });

    testWidgets('long basket: totals + charge stay pinned while it scrolls',
        (tester) async {
      final cart = CartProvider();
      for (var i = 0; i < 8; i++) {
        final product = Product(name: 'Item $i', createdAt: 0, variants: [
          ProductVariant(
              id: i + 1, productId: 0, sku: 'I$i', price: 100.0 + i, stock: 10),
        ]);
        cart.add(product, product.variants.first);
      }

      await tester.pumpWidget(harness(cart, height: 520));
      await tester.pump();
      expect(tester.takeException(), isNull);

      final cardRect = tester.getRect(find.byType(Card));
      final before =
          tester.getRect(find.byType(FilledButton)).bottom;
      expect(before, lessThanOrEqualTo(cardRect.bottom + 0.5));

      // The basket really overflows (it can scroll), and after scrolling
      // to the bottom the pinned charge button is still inside the card.
      final scrollable = find.descendant(
          of: find.byType(CartPanel), matching: find.byType(Scrollable));
      final pos =
          tester.state<ScrollableState>(scrollable.first).position;
      expect(pos.maxScrollExtent, greaterThan(0),
          reason: 'the long basket must overflow its viewport');
      pos.jumpTo(pos.maxScrollExtent);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.byType(FilledButton)).bottom,
          lessThanOrEqualTo(cardRect.bottom + 0.5));
    });
  });
}
