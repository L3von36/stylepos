import 'package:flutter_test/flutter_test.dart';
import 'package:stylepos/services/scan_gate.dart';

void main() {
  group('ScanGate', () {
    test('accepts the first scan of a code', () {
      final gate = ScanGate();
      expect(gate.accept('6001234000011'), isTrue);
    });

    test('rejects an immediate repeat of the same code (double-scan guard)',
        () {
      final gate = ScanGate();
      expect(gate.accept('6001234000011'), isTrue);
      expect(gate.accept('6001234000011'), isFalse);
      expect(gate.accept('6001234000011'), isFalse);
    });

    test('accepts the same code again after the cooldown elapses', () async {
      final gate = ScanGate(cooldown: const Duration(milliseconds: 40));
      expect(gate.accept('6001234000011'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(gate.accept('6001234000011'), isTrue);
    });

    test('accepts a different code immediately', () {
      final gate = ScanGate();
      expect(gate.accept('6001234000011'), isTrue);
      expect(gate.accept('6001234000012'), isTrue);
    });

    test('ignores empty input', () {
      final gate = ScanGate();
      expect(gate.accept(''), isFalse);
      expect(gate.accept('   '), isFalse);
    });

    test('trims surrounding whitespace from scanner payloads', () {
      final gate = ScanGate();
      expect(gate.accept('  6001234000011 '), isTrue);
      // same logical code, still inside cooldown even with padding
      expect(gate.accept('6001234000011'), isFalse);
    });

    test('counts rejected duplicates', () {
      final gate = ScanGate();
      gate.accept('A');
      gate.accept('A');
      gate.accept('A');
      expect(gate.rejected, 2);
    });

    test('reset forgets the previous code', () {
      final gate = ScanGate();
      expect(gate.accept('6001234000011'), isTrue);
      gate.reset();
      expect(gate.accept('6001234000011'), isTrue);
    });
  });
}
