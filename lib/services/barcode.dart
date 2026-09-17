import 'dart:math';

/// Barcode helpers for tagging shop items.
///
/// Every variant carries its own scannable code so the sales person can
/// ring up an item with a single scan. Codes are generated as EAN-13
/// numbers in the GS1 *in-store* range (prefix 200-299), which is reserved
/// for retailer-internal use, so no global registration is required and
/// ordinary retail scanners read them out of the box.
class BarcodeGen {
  BarcodeGen._();

  /// Computes the EAN-13 check digit for a 12-digit body.
  static int checkDigit(String digits12) {
    assert(digits12.length == 12, 'EAN-13 body must be 12 digits');
    var sum = 0;
    for (var i = 0; i < 12; i++) {
      final d = digits12.codeUnitAt(i) - 48;
      sum += d * (i.isEven ? 1 : 3);
    }
    return (10 - (sum % 10)) % 10;
  }

  /// True when [code] is a structurally valid EAN-13 number.
  static bool isValidEan13(String code) {
    if (code.length != 13) return false;
    for (final ch in code.split('')) {
      if (int.tryParse(ch) == null) return false;
    }
    return checkDigit(code.substring(0, 12)) == code.codeUnitAt(12) - 48;
  }

  /// Generates a unique 13-digit in-store EAN-13 code (prefix 200).
  ///
  /// [isTaken] lets the caller reject codes that already exist in the
  /// catalog so two variants can never share one barcode.
  static String generateInStore({
    required bool Function(String code) isTaken,
    Random? rng,
  }) {
    final r = rng ?? Random();
    for (var attempt = 0; attempt < 200; attempt++) {
      final buf = StringBuffer('200');
      for (var i = 0; i < 9; i++) {
        buf.write(r.nextInt(10));
      }
      final body = buf.toString(); // 12 digits
      final code = '$body${checkDigit(body)}';
      if (!isTaken(code)) return code;
    }
    throw StateError('Could not generate a unique barcode');
  }
}
