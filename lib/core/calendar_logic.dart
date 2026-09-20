/// Pure calendar math for the sales calendar — no Flutter imports, so the
/// day-bucketing rules the owner sees are pinned by fast unit tests.
library;

/// Local midnight of the 1st of the month [d] falls in.
DateTime monthStart(DateTime d) => DateTime(d.year, d.month, 1);

/// Local midnight one month after [start] (start = any midnight in a month;
/// Dart rolls over year boundaries automatically).
DateTime nextMonthStart(DateTime start) =>
    DateTime(start.year, start.month + 1, 1);

/// Local midnight of the day after [day].
DateTime nextDayStart(DateTime day) =>
    DateTime(day.year, day.month, day.day + 1);

/// `YYYY-MM-DD` key of a local day — the join key between calendar cells
/// and the day-bucket maps.
String dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Epoch seconds of local midnight for [day] and of the next midnight —
/// the half-open `[start, end)` window one day's sales live in.
(int, int) dayEpochRange(DateTime day) {
  final start = DateTime(day.year, day.month, day.day);
  return (start.millisecondsSinceEpoch ~/ 1000,
      nextDayStart(start).millisecondsSinceEpoch ~/ 1000);
}

/// Epoch seconds of local midnight on the 1st and of the 1st of the next
/// month — the half-open window a calendar month's sales live in.
(int, int) monthEpochRange(DateTime month) {
  final start = monthStart(month);
  return (start.millisecondsSinceEpoch ~/ 1000,
      nextMonthStart(start).millisecondsSinceEpoch ~/ 1000);
}

/// Month grid for a Monday-first calendar: leading `null`s for the blank
/// cells before the 1st, then one [DateTime] (local midnight) per day.
List<DateTime?> monthGrid(DateTime month) {
  final first = monthStart(month);
  final daysInMonth = nextMonthStart(first).subtract(const Duration(days: 1)).day;
  final lead = first.weekday - DateTime.monday; // 0..6 blanks
  return [
    ...List<DateTime?>.filled(lead, null),
    for (var i = 1; i <= daysInMonth; i++) DateTime(month.year, month.month, i),
  ];
}

/// One completed sale reduced to what the calendar needs:
/// (created_at epoch seconds, total amount).
typedef SaleStamp = (int epoch, double total);

/// Buckets completed sales by local day. Keys are [dayKey] strings so the
/// calendar can look a cell up without tz math of its own.
Map<String, ({int orders, double revenue})> bucketSalesByDay(
    Iterable<SaleStamp> sales) {
  final out = <String, ({int orders, double revenue})>{};
  for (final (epoch, total) in sales) {
    final key = dayKey(
        DateTime.fromMillisecondsSinceEpoch(epoch * 1000)); // device-local
    final cur = out[key] ?? (orders: 0, revenue: 0.0);
    out[key] = (orders: cur.orders + 1, revenue: cur.revenue + total);
  }
  return out;
}

/// Compact money for tight calendar cells: `950`, `12.5k`, `1.25M` — the
/// currency symbol lives in the card title, not repeated 31 times.
String compactMoney(num v) {
  if (v >= 1000000) return '${_trim(v / 1000000)}M';
  if (v >= 1000) return '${_trim(v / 1000)}k';
  return v.round().toString();
}

String _trim(num v) {
  var s = v.toStringAsFixed(2); // "12.50" | "1.25" | "3.00"
  if (s.contains('.')) {
    s = s.replaceAll(RegExp(r'0+$'), ''); // "12.5" | "1.25" | "3."
    if (s.endsWith('.')) s = s.substring(0, s.length - 1); // "3"
  }
  return s;
}
