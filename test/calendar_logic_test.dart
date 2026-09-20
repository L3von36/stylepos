import 'package:flutter_test/flutter_test.dart';
import 'package:stylepos/core/calendar_logic.dart';

/// Pins the calendar math the owner sees: Monday-first month grids,
/// local-day bucketing keys and the compact money shown in day cells.
void main() {
  group('monthGrid', () {
    test('September 2026 starts Tuesday (1 blank) with 30 days', () {
      // 2026-09-01 is a Tuesday → one leading blank on a Monday-first grid.
      final grid = monthGrid(DateTime(2026, 9, 15));
      expect(grid.length, 31); // 1 blank + 30 days
      expect(grid.first, isNull);
      final days = grid.whereType<DateTime>().toList();
      expect(days.first.day, 1);
      expect(days.last.day, 30);
    });

    test('leap February 2024 has 29 days, 2025 has 28', () {
      // 2024-02-01 is a Thursday → 3 leading blanks.
      final leap = monthGrid(DateTime(2024, 2, 10));
      expect(leap.length, 3 + 29);
      expect(leap.whereType<DateTime>().last.day, 29);

      // 2025-02-01 is a Saturday → 5 leading blanks.
      final flat = monthGrid(DateTime(2025, 2, 10));
      expect(flat.length, 5 + 28);
      expect(flat.whereType<DateTime>().last.day, 28);
    });

    test('every non-null cell is local midnight of its day', () {
      final grid = monthGrid(DateTime(2026, 4, 20));
      for (final d in grid.whereType<DateTime>()) {
        expect(d.hour, 0);
        expect(d.minute, 0);
        expect(d.second, 0);
      }
    });
  });

  group('dayKey / epoch ranges', () {
    test('dayKey is zero-padded YYYY-MM-DD', () {
      expect(dayKey(DateTime(2026, 9, 4)), '2026-09-04');
      expect(dayKey(DateTime(2026, 1, 27)), '2026-01-27');
    });

    test('dayEpochRange is a half-open 86400s window at local midnight', () {
      final (start, end) = dayEpochRange(DateTime(2026, 9, 4));
      expect(end - start, 86400);
      final startDt =
          DateTime.fromMillisecondsSinceEpoch(start * 1000); // local
      expect(startDt.hour, 0);
      expect(startDt.day, 4);
    });

    test('monthEpochRange covers the whole month', () {
      final (start, end) = monthEpochRange(DateTime(2026, 2, 15));
      final startDt = DateTime.fromMillisecondsSinceEpoch(start * 1000);
      final endDt = DateTime.fromMillisecondsSinceEpoch(end * 1000);
      expect(startDt.day, 1);
      expect(endDt.month, 3);
      expect(endDt.day, 1);
    });
  });

  group('bucketSalesByDay', () {
    int ts(int y, int m, int d, int h) =>
        DateTime(y, m, d, h).millisecondsSinceEpoch ~/ 1000;

    test('accumulates same-day sales and splits different days', () {
      final buckets = bucketSalesByDay([
        (ts(2026, 9, 4, 10), 500.0),
        (ts(2026, 9, 4, 18), 200.0),
        (ts(2026, 9, 5, 9), 90.0),
      ]);
      expect(buckets['2026-09-04'], (orders: 2, revenue: 700.0));
      expect(buckets['2026-09-05'], (orders: 1, revenue: 90.0));
      expect(buckets.length, 2);
    });

    test('local-day boundary: 23:59 and 00:01 land on different keys', () {
      final buckets = bucketSalesByDay([
        (ts(2026, 9, 4, 23), 100.0),
        (ts(2026, 9, 5, 0), 100.0),
      ]);
      expect(buckets.length, 2);
    });
  });

  group('compactMoney', () {
    test('plain numbers under 1k', () {
      expect(compactMoney(0), '0');
      expect(compactMoney(950), '950');
      expect(compactMoney(999.4), '999');
    });

    test('thousands collapse to k', () {
      expect(compactMoney(1000), '1k');
      expect(compactMoney(12500), '12.5k');
      expect(compactMoney(123456), '123.46k');
      expect(compactMoney(300000), '300k');
    });

    test('millions collapse to M', () {
      expect(compactMoney(1000000), '1M');
      expect(compactMoney(1250000), '1.25M');
      expect(compactMoney(9999999), '10M');
    });
  });
}
