import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stylepos/services/approvals.dart';
import 'package:stylepos/widgets/ui.dart';

/// Quick-discount chips + the shared sheet widgets introduced with the
/// v1.23.0 UI pass (waiter dashboard, More drawer, cart drawer polish).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('quickDiscounts — one-tap chip eligibility', () {
    test('manager gets every chip', () {
      final chips = quickDiscounts(
          subtotal: 2500, isAdmin: true, canDiscount: false, discountCap: 0);
      expect(chips.map((c) => c.percent).toList(), [5, 10, 15]);
      expect(chips.first.amount, 125); // 2500 * 5 / 100
      expect(chips.last.amount, 375);
    });

    test('user without any discount rights gets none', () {
      final chips = quickDiscounts(
          subtotal: 2500, isAdmin: false, canDiscount: false, discountCap: 0);
      expect(chips, isEmpty);
    });

    test('granted salesperson: chips beyond the cap are filtered out', () {
      // Subtotal 1000 -> 5% = 50 (fits cap 50), 10% = 100 and 15% = 150 don't.
      final chips = quickDiscounts(
          subtotal: 1000, isAdmin: false, canDiscount: true, discountCap: 50);
      expect(chips.map((c) => c.percent).toList(), [5]);
    });

    test('granted salesperson with unlimited cap sees all chips', () {
      final chips = quickDiscounts(
          subtotal: 1000, isAdmin: false, canDiscount: true, discountCap: 0);
      expect(chips.length, 3);
    });

    test('every returned chip passes discountNeedsApproval for its user', () {
      const threshold = 200.0;
      for (final chip in quickDiscounts(
          subtotal: 1000, isAdmin: false, canDiscount: true, discountCap: 80)) {
        expect(
          discountNeedsApproval(
              isAdmin: false,
              discount: chip.amount,
              threshold: threshold,
              canDiscount: true,
              discountCap: 80),
          isFalse,
          reason: 'chip ${chip.percent}% must never require a PIN',
        );
      }
    });

    test('empty basket offers no chips', () {
      final chips = quickDiscounts(
          subtotal: 0, isAdmin: true, canDiscount: true, discountCap: 0);
      expect(chips, isEmpty);
    });
  });

  group('sheet widgets', () {
    testWidgets('SheetTile renders title/subtitle and fires onTap',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [
            const SheetHandle(),
            SheetTile(
              icon: Icons.local_shipping_outlined,
              title: 'Purchasing',
              subtitle: 'Restock orders and suppliers',
              onTap: () => taps++,
            ),
          ]),
        ),
      ));
      expect(find.text('Purchasing'), findsOneWidget);
      expect(find.text('Restock orders and suppliers'), findsOneWidget);
      await tester.tap(find.text('Purchasing'));
      expect(taps, 1);
    });

    testWidgets('SheetTile without subtitle keeps a single text line',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SheetTile(icon: Icons.lock_reset_outlined, title: 'Change password'),
        ),
      ));
      expect(find.text('Change password'), findsOneWidget);
      expect(find.byType(TintIconBox), findsOneWidget);
    });
  });
}
