import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stylepos/data/database.dart';
import 'package:stylepos/services/zreport_service.dart';
import 'package:stylepos/state/settings.dart';

/// Z-report day math + close/reopen bookkeeping against real SQLite.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('stylepos_zreport');
    DB.useDirectory(tmp.path);
  });

  tearDown(() async {
    await DB.closeAndReset();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  /// Noon and 8pm of "today", local time — the same window the service
  /// queries ([dayStart, nextDayStart)).
  int ts(DateTime day, int hour) =>
      DateTime(day.year, day.month, day.day, hour)
          .millisecondsSinceEpoch ~/
      1000;

  Future<void> seedDay(DateTime day) async {
    final db = await DB.instance();
    final noon = ts(day, 12);
    final evening = ts(day, 20);

    // Named cashiers so the staff breakdown can assert by name (the DB
    // already seeds a default admin, so let ids autoincrement).
    final aliceId = await db.insert('users', {
      'name': 'Alice', 'email': 'alice@zreport.test',
      'pass_hash': 'x', 'salt': 'y', 'role': 'admin',
      'active': 1, 'created_at': 1,
    });
    final bobId = await db.insert('users', {
      'name': 'Bob', 'email': 'bob@zreport.test',
      'pass_hash': 'x', 'salt': 'y', 'role': 'admin',
      'active': 1, 'created_at': 1,
    });

    // Two cash sales + one card sale, one refunded mobile sale (same day).
    await db.insert('sales', {
      'receipt_no': 'R-T1', 'user_id': aliceId, 'subtotal': 1000.0,
      'discount': 100.0, 'tax': 0.0, 'total': 900.0,
      'payment_method': 'cash', 'amount_paid': 1000.0, 'change_due': 100.0,
      'status': 'completed', 'created_at': noon,
    });
    await db.insert('sales', {
      'receipt_no': 'R-T2', 'user_id': aliceId, 'subtotal': 500.0,
      'discount': 0.0, 'tax': 0.0, 'total': 500.0,
      'payment_method': 'cash', 'amount_paid': 500.0, 'change_due': 0.0,
      'status': 'completed', 'created_at': noon + 60,
    });
    await db.insert('sales', {
      'receipt_no': 'R-T3', 'user_id': bobId, 'subtotal': 1200.0,
      'discount': 0.0, 'tax': 0.0, 'total': 1200.0,
      'payment_method': 'card', 'amount_paid': 1200.0, 'change_due': 0.0,
      'status': 'completed', 'created_at': evening,
    });
    // Refund processed the same day — must NOT count as takings but must
    // appear in the refund row and subtract from net.
    await db.insert('sales', {
      'receipt_no': 'R-T4', 'user_id': bobId, 'subtotal': 300.0,
      'discount': 0.0, 'tax': 0.0, 'total': 300.0,
      'payment_method': 'mobile', 'amount_paid': 300.0, 'change_due': 0.0,
      'status': 'refunded', 'created_at': evening + 120,
    });

    // Items: T1 2×300 + 1×200(=900 w/ discount? line totals are raw),
    // T2 1×500, T3 2×600, T4 1×300.
    final sales = await db.query('sales', orderBy: 'id');
    final t1 = sales[0]['id'] as int;
    final t2 = sales[1]['id'] as int;
    final t3 = sales[2]['id'] as int;
    final t4 = sales[3]['id'] as int;

    Future<int> addVariant({double cost = 0}) => db.insert('variants', {
          'product_id': 1, 'size': 'M', 'color': 'Red', 'sku': 'SKU-$cost',
          'price': 300, 'cost': cost, 'stock': 10,
        });

    final vCost = await addVariant(cost: 100); // for COGS checks
    final vPlain = await addVariant();

    await db.insert('sale_items', {
      'sale_id': t1, 'variant_id': vCost, 'product_name': 'Tee',
      'variant_desc': 'M/Red', 'unit_price': 300.0, 'qty': 2,
      'line_total': 600.0,
    });
    await db.insert('sale_items', {
      'sale_id': t2, 'variant_id': vPlain, 'product_name': 'Tee',
      'variant_desc': 'M/Red', 'unit_price': 500.0, 'qty': 1,
      'line_total': 500.0,
    });
    await db.insert('sale_items', {
      'sale_id': t3, 'variant_id': vCost, 'product_name': 'Dress',
      'variant_desc': 'M/Red', 'unit_price': 600.0, 'qty': 2,
      'line_total': 1200.0,
    });
    await db.insert('sale_items', {
      'sale_id': t4, 'variant_id': vPlain, 'product_name': 'Socks',
      'variant_desc': 'M/Red', 'unit_price': 300.0, 'qty': 1,
      'line_total': 300.0,
    });
  }

  test('buildData computes takings, refunds, payments, staff, COGS', () async {
    final now = DateTime.now();
    await seedDay(now);

    final d = await ZReportService.buildData(now);

    // Completed: 900 + 500 + 1200 = 2600 gross; refund 300 -> net 2300.
    expect(d.orders, 3);
    expect(d.gross, closeTo(2600, 0.01));
    expect(d.discounts, closeTo(100, 0.01));
    expect(d.refundCount, 1);
    expect(d.refundTotal, closeTo(300, 0.01));
    expect(d.net, closeTo(2300, 0.01));
    // Items sold counts completed sales only: 2 + 1 + 2 = 5.
    expect(d.itemsSold, 5);
    // COGS: Tee 2×100 + Dress 2×100 = 400 (refund excluded).
    expect(d.cogs, closeTo(400, 0.01));
    expect(d.grossProfit, closeTo(1900, 0.01));

    final cash = d.payments.firstWhere((e) => e.method == 'cash');
    expect(cash.orders, 2);
    expect(cash.total, closeTo(1400, 0.01));
    final card = d.payments.firstWhere((e) => e.method == 'card');
    expect(card.total, closeTo(1200, 0.01));
    // Refunded mobile sale is not in the payment breakdown.
    expect(d.payments.where((e) => e.method == 'mobile'), isEmpty);

    // Staff: Alice (user 1) = 1400 across 2 orders, Bob (user 2) = 1200 across 1.
    final staff1 = d.staff.firstWhere((e) => e.name == 'Alice');
    expect(staff1.orders, 2);
    expect(staff1.revenue, closeTo(1400, 0.01));

    // Best sellers by units: Tee 3, Dress 2 (refund excluded).
    expect(d.topItems.first.name, 'Tee');
    expect(d.topItems.first.units, 3);
  });

  test('day boundaries exclude neighbouring days', () async {
    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(days: 1));
    final db = await DB.instance();

    // A sale yesterday at 23:59 and one today at 00:01 local time.
    final yLate = DateTime(yesterday.year, yesterday.month, yesterday.day, 23, 59)
            .millisecondsSinceEpoch ~/
        1000;
    final tEarly =
        DateTime(now.year, now.month, now.day, 0, 1).millisecondsSinceEpoch ~/ 1000;
    await db.insert('sales', {
      'receipt_no': 'R-Y1', 'user_id': 1, 'subtotal': 100, 'discount': 0,
      'tax': 0, 'total': 100, 'payment_method': 'cash', 'amount_paid': 100,
      'change_due': 0, 'status': 'completed', 'created_at': yLate,
    });
    await db.insert('sales', {
      'receipt_no': 'R-T5', 'user_id': 1, 'subtotal': 200, 'discount': 0,
      'tax': 0, 'total': 200, 'payment_method': 'cash', 'amount_paid': 200,
      'change_due': 0, 'status': 'completed', 'created_at': tEarly,
    });

    final dToday = await ZReportService.buildData(now);
    expect(dToday.orders, 1);
    expect(dToday.gross, closeTo(200, 0.01));

    final dYesterday = await ZReportService.buildData(yesterday);
    expect(dYesterday.orders, 1);
    expect(dYesterday.gross, closeTo(100, 0.01));
  });

  test('close / reopen day roundtrip persists the snapshot', () async {
    final now = DateTime.now();

    expect(await ZReportService.closedRecord(now), isNull);

    await ZReportService.closeDay(
        now, ZCloseRecord(closedAt: 12345, closedBy: 'Mana Ger', net: 2300, orders: 3));

    final rec = await ZReportService.closedRecord(now);
    expect(rec, isNotNull);
    expect(rec!.closedBy, 'Mana Ger');
    expect(rec.net, closeTo(2300, 0.01));
    expect(rec.orders, 3);

    // Closing a second day keeps both records.
    final other = now.subtract(const Duration(days: 2));
    await ZReportService.closeDay(
        other, ZCloseRecord(closedAt: 6789, closedBy: 'Mana Ger', net: 10, orders: 1));
    expect((await ZReportService.closedDays()).length, 2);

    // Re-open removes exactly the one day.
    await ZReportService.reopenDay(now);
    expect(await ZReportService.closedRecord(now), isNull);
    expect(await ZReportService.closedRecord(other), isNotNull);
  });

  test('backup reminder due logic', () {
    final s = AppSettings();
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // Never backed up -> due.
    expect(s.backupReminderDue, isTrue);

    // Backed up 2 days ago -> not due (weekly cadence).
    s.lastBackupAt = nowSec - 2 * 86400;
    expect(s.backupReminderDue, isFalse);

    // Backed up 8 days ago -> due.
    s.lastBackupAt = nowSec - 8 * 86400;
    expect(s.backupReminderDue, isTrue);

    // ...unless snoozed into the future.
    s.backupSnoozeUntil = nowSec + 3600;
    expect(s.backupReminderDue, isFalse);

    // Expired snooze -> due again.
    s.backupSnoozeUntil = nowSec - 10;
    expect(s.backupReminderDue, isTrue);
  });
}
