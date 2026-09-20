import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stylepos/core/calendar_logic.dart';
import 'package:stylepos/data/database.dart';
import 'package:stylepos/state/sales.dart';

/// The sales calendar's data plumbing: local-day month buckets, the
/// per-day receipt list and the per-cashier "who sold that day" split —
/// against a throwaway SQLite database via FFI.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('stylepos_dayq');
    DB.useDirectory(tmp.path);
  });

  tearDown(() async {
    await DB.closeAndReset();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  int ts(DateTime d, int hour) =>
      DateTime(d.year, d.month, d.day, hour).millisecondsSinceEpoch ~/ 1000;

  test('monthDayTotals / salesOnDay / staffOnDay bucket by local day',
      () async {
    final db = await DB.instance();
    final now = DateTime.now();

    final aliceId = await db.insert('users', {
      'name': 'Alice', 'email': 'alice@dayq.test',
      'pass_hash': 'x', 'salt': 'y', 'role': 'admin',
      'active': 1, 'created_at': 1,
    });
    final bobId = await db.insert('users', {
      'name': 'Bob', 'email': 'bob@dayq.test',
      'pass_hash': 'x', 'salt': 'y', 'role': 'admin',
      'active': 1, 'created_at': 1,
    });

    // Fixed mid-month days (15th/16th) so no test run can straddle a
    // month boundary; a previous-month sale proves the window filter.
    final d15 = DateTime(now.year, now.month, 15);
    final d16 = DateTime(now.year, now.month, 16);
    final prevMonth15 = DateTime(now.year, now.month - 1, 15);

    Future<int> addSale({
      required int userId,
      required DateTime d,
      required int hour,
      required double total,
      String status = 'completed',
    }) =>
        db.insert('sales', {
          'receipt_no': 'R-DQ-$userId-${ts(d, hour)}',
          'user_id': userId,
          'subtotal': total,
          'total': total,
          'payment_method': 'cash',
          'status': status,
          'created_at': ts(d, hour),
          'cloud_id': null,
          'dirty': 0,
          'updated_at': ts(d, hour),
        });

    // Day 15: Alice sells 500 + 200; Bob's 300 sale was refunded.
    await addSale(userId: aliceId, d: d15, hour: 12, total: 500);
    await addSale(userId: aliceId, d: d15, hour: 13, total: 200);
    await addSale(
        userId: bobId, d: d15, hour: 14, total: 300, status: 'refunded');
    // Day 16: Bob sells 400.
    await addSale(userId: bobId, d: d16, hour: 10, total: 400);
    // Previous month: one 100 sale — must never leak into this month.
    await addSale(userId: aliceId, d: prevMonth15, hour: 11, total: 100);

    final sales = SalesProvider();

    // ---- month buckets (completed only, local days) ----
    final buckets = await sales.monthDayTotals(DateTime(now.year, now.month, 1));
    expect(buckets[dayKey(d15)], (orders: 2, revenue: 700.0));
    expect(buckets[dayKey(d16)], (orders: 1, revenue: 400.0));
    expect(buckets.containsKey(dayKey(prevMonth15)), isFalse);

    // previous month sees its own sale
    final prevBuckets =
        await sales.monthDayTotals(DateTime(now.year, now.month - 1, 1));
    expect(prevBuckets[dayKey(prevMonth15)], (orders: 1, revenue: 100.0));
    expect(prevBuckets.containsKey(dayKey(d15)), isFalse);

    // ---- per-day receipts ----
    final on15 = await sales.salesOnDay(d15);
    expect(on15.length, 3); // includes the refunded receipt
    expect(on15.every((s) => dayKey(DateTime
        .fromMillisecondsSinceEpoch(s.createdAt * 1000)) == dayKey(d15)),
        isTrue);

    final on16 = await sales.salesOnDay(d16);
    expect(on16.length, 1);
    expect(on16.first.total, 400);

    // ---- who sold that day (completed only, per cashier) ----
    final staff15 = await sales.staffOnDay(d15);
    expect(staff15, hasLength(1)); // Bob's only sale that day was refunded
    expect(staff15.first.name, 'Alice');
    expect(staff15.first.orders, 2);
    expect(staff15.first.revenue, 700.0);

    final staff16 = await sales.staffOnDay(d16);
    expect(staff16, hasLength(1));
    expect(staff16.first.name, 'Bob');
    expect(staff16.first.revenue, 400.0);

    // ---- explicit window query ----
    final (ps, pe) = monthEpochRange(DateTime(now.year, now.month - 1, 1));
    final prevSales = await sales.listSalesBetween(ps, pe);
    expect(prevSales, hasLength(1));
    expect(prevSales.first.total, 100);
  });
}
