import 'package:flutter_test/flutter_test.dart';
import 'package:stylepos/services/barcode.dart';

void main() {
  group('BarcodeGen.checkDigit', () {
    test('computes the standard EAN-13 check digit', () {
      // Well-known valid EAN-13: 4006381333931
      expect(BarcodeGen.checkDigit('400638133393'), 1);
    });

    test('validates complete codes', () {
      expect(BarcodeGen.isValidEan13('4006381333931'), isTrue);
      expect(BarcodeGen.isValidEan13('4006381333932'), isFalse);
      expect(BarcodeGen.isValidEan13('40063813339'), isFalse); // too short
      expect(BarcodeGen.isValidEan13('40063813339310'), isFalse); // too long
      expect(BarcodeGen.isValidEan13('40063813339A'), isFalse); // not digits
    });
  });

  group('BarcodeGen.generateInStore', () {
    test('generates valid 13-digit in-store codes', () {
      final code = BarcodeGen.generateInStore(isTaken: (_) => false);
      expect(code.length, 13);
      expect(code.startsWith('200'), isTrue); // GS1 in-store range
      expect(BarcodeGen.isValidEan13(code), isTrue);
    });

    test('never returns a code reported as taken', () {
      final taken = <String>{};
      for (var i = 0; i < 50; i++) {
        final code = BarcodeGen.generateInStore(isTaken: taken.contains);
        expect(taken.contains(code), isFalse);
        taken.add(code);
      }
      expect(taken.length, 50);
    });

    test('respects an existing catalog of codes', () {
      // Pretend every code starting with 200 exists by rejecting on the
      // prefix; the generator must still produce a usable code.
      final code = BarcodeGen.generateInStore(
          isTaken: (c) => c.startsWith('2000'));
      expect(BarcodeGen.isValidEan13(code), isTrue);
      expect(code.startsWith('2000'), isFalse);
    });
  });
}
