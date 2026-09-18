import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stylepos/data/database.dart';
import 'package:stylepos/services/approvals.dart';
import 'package:stylepos/services/audit.dart';
import 'package:stylepos/services/csv_util.dart';
import 'package:stylepos/services/zreport_service.dart';
import 'package:stylepos/state/attendance.dart';
import 'package:stylepos/state/sales.dart';

/// Roles, approvals & accountability: manager PIN, discount approval rule,
/// shift logs, audit trail, cash reconciliation and the CSV toolkit.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('stylepos_roles');
    DB.useDirectory(tmp.path);
  });

  tearDown(() async {
    await DB.closeAndReset();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('manager PIN', () {
    test('set / verify / clear roundtrip', () async {
      expect(await Approvals.hasPin(), isFalse);

      expect(await Approvals.setPin('12'),
          'PIN must be 4–8 digits.'); // too short
      expect(await Approvals.setPin('abcd'), 'PIN must contain only digits.');
      expect(await Approvals.setPin('123456'), isNull);
      expect(await Approvals.hasPin(), isTrue);

      // The PIN is stored hashed, never in plaintext.
      final db = await DB.instance();
      final rows = await db.query('settings',
          where: 'key = ?', whereArgs: ['manager_pin_hash']);
      final stored = rows.first['value'] as String;
      expect(stored, isNot(contains('123456')));
      expect(stored.length, 64); // sha256 hex

      await Approvals.setPin('998877');
      await Approvals.clearPin();
      expect(await Approvals.hasPin(), isFalse);
    });

    test('manager password fallback verifies an active admin', () async {
      // Fresh DB seeds admin@stylepos.app / admin123 (active admin).
      final ok = await Approvals.verifyManagerPassword(
          'admin@stylepos.app', 'admin123');
      expect(ok, isNotNull);
      expect(ok!.userName, 'Admin');
      expect(ok.method, 'password');

      expect(
          await Approvals.verifyManagerPassword(
              'admin@stylepos.app', 'wrong'),
          isNull);
      expect(
          await Approvals.verifyManagerPassword('no@one.test', 'x'),
          isNull);

      // Deactivated managers must not authorize anything.
      final db = await DB.instance();
      await db.update('users', {'active': 0},
          where: 'email = ?', whereArgs: ['admin@stylepos.app']);
      expect(
          await Approvals.verifyManagerPassword(
              'admin@stylepos.app', 'admin123'),
          isNull);
    });
  });

  group('discount approval rule', () {
    test('threshold semantics', () {
      // Managers are never gated.
      expect(
        discountNeedsApproval(
            isAdmin: true, discount: 999, threshold: 0),
        isFalse,
      );
      // Zero discount is never gated.
      expect(
        discountNeedsApproval(isAdmin: false, discount: 0, threshold: 0),
        isFalse,
      );
      // Threshold 0 = every discount needs approval.
      expect(
        discountNeedsApproval(isAdmin: false, discount: 10, threshold: 0),
        isTrue,
      );
      // At/above threshold gated, below not.
      expect(
        discountNeedsApproval(isAdmin: false, discount: 500, threshold: 500),
        isTrue,
      );
      expect(
        discountNeedsApproval(isAdmin: false, discount: 499.99, threshold: 500),
        isFalse,
      );
    });
  });

  group('attendance (shift logs)', () {
    test('clock in / clock out roundtrip', () async {
      final attendance = AttendanceProvider();
      final db = await DB.instance();
      final uid = (await db.query('users', limit: 1)).first['id'] as int;

      expect(await attendance.openShift(uid), isNull);
      expect(await attendance.isClockedIn(uid), isFalse);

      await attendance.clockIn(uid);
      final open = await attendance.openShift(uid);
      expect(open, isNotNull);
      expect(open!.isOpen, isTrue);
      expect(open.clockIn, greaterThan(0));

      await attendance.clockOut(uid);
      final done = await attendance.openShift(uid);
      expect(done, isNull);

      // The closed shift is in the log with a duration.
      final logs = await attendance.logs();
      expect(logs.length, 1);
      expect(logs.first.shift.isOpen, isFalse);
      expect(logs.first.shift.clockOut, isNotNull);
    });

    test('clocking in twice closes the stale shift (never two open)', () async {
      final attendance = AttendanceProvider();
      final db = await DB.instance();
      final uid = (await db.query('users', limit: 1)).first['id'] as int;

      await attendance.clockIn(uid);
      // Simulate an app kill mid-shift: clock in again without clocking out.
      await attendance.clockIn(uid);

      final open = await attendance.openShift(uid);
      expect(open, isNotNull);
      final all = await db.query('attendance', where: 'user_id = ?', whereArgs: [uid]);
      expect(all.length, 2);
      final openCount =
          all.where((r) => r['clock_out'] == null).length;
      expect(openCount, 1);
    });
  });

  group('audit trail', () {
    test('add / list roundtrip preserves who, what, when', () async {
      await Audit.add('refund', 'R-AAA-000001 · KSh 500.00',
          userId: 1, userName: 'Admin');
      await Audit.add('discount_approved', 'KSh 200.00 via manager PIN');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await Audit.add('day_close', '2026-01-31 · net KSh 2,300.00',
          userId: 1, userName: 'Admin');

      final all = await Audit.list();
      expect(all.length, 3);
      // Newest first.
      expect(all.first.action, 'day_close');
      expect(all.last.action, 'refund');
      expect(all.last.userName, 'Admin');
      expect(all.last.userId, 1);
      expect(all.first.createdAt, greaterThanOrEqualTo(all.last.createdAt));

      // Filter by action.
      final refunds = await Audit.list(action: 'refund');
      expect(refunds.length, 1);
      expect(refunds.first.details, contains('R-AAA-000001'));
    });
  });

  group('cash reconciliation', () {
    test('expected cash = cash sales − cash refunds; variance on close',
        () async {
      final db = await DB.instance();
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final uid = (await db.query('users', limit: 1)).first['id'] as int;

      // Cash sale 1000, card sale 500, cash refund 300.
      await db.insert('sales', {
        'receipt_no': 'R-C1', 'user_id': uid, 'subtotal': 1000.0,
        'discount': 0, 'tax': 0, 'total': 1000.0,
        'payment_method': 'cash', 'amount_paid': 1000.0, 'change_due': 0,
        'status': 'completed', 'created_at': now,
      });
      await db.insert('sales', {
        'receipt_no': 'R-C2', 'user_id': uid, 'subtotal': 500.0,
        'discount': 0, 'tax': 0, 'total': 500.0,
        'payment_method': 'card', 'amount_paid': 500.0, 'change_due': 0,
        'status': 'completed', 'created_at': now,
      });
      await db.insert('sales', {
        'receipt_no': 'R-C3', 'user_id': uid, 'subtotal': 300.0,
        'discount': 0, 'tax': 0, 'total': 300.0,
        'payment_method': 'cash', 'amount_paid': 300.0, 'change_due': 0,
        'status': 'refunded', 'created_at': now,
      });

      final d = await ZReportService.buildData(DateTime.now());
      expect(d.cashIn, closeTo(1000, 0.01));
      expect(d.cashRefunds, closeTo(300, 0.01));
      expect(d.expectedCash, closeTo(700, 0.01));

      // Close with a count that is 50 over.
      final day = DateTime.now();
      await ZReportService.closeDay(
        day,
        ZCloseRecord(
          closedAt: now,
          closedBy: 'Admin',
          net: d.net,
          orders: d.orders,
          expectedCash: d.expectedCash,
          countedCash: 750,
        ),
      );
      final rec = await ZReportService.closedRecord(day);
      expect(rec, isNotNull);
      expect(rec!.variance, closeTo(50, 0.01));

      // Old snapshots without a count keep working (variance null).
      final legacy = ZCloseRecord.fromJson(
          {'at': 1, 'by': 'X', 'net': 10.0, 'orders': 1});
      expect(legacy.variance, isNull);
      expect(legacy.countedCash, isNull);
    });
  });

  group('CSV toolkit', () {
    test('escape quotes when needed', () {
      expect(CsvUtil.escape('plain'), 'plain');
      expect(CsvUtil.escape('a,b'), '"a,b"');
      expect(CsvUtil.escape('say "hi"'), '"say ""hi"""');
      expect(CsvUtil.escape('line\nbreak'), '"line\nbreak"');
    });

    test('parse handles quotes, CRLF and trailing newline', () {
      final rows = CsvUtil.parse(
          'name,price,note\r\nTee,"1,200","has ""quotes"", ok"\r\nDress,500,\r\n');
      expect(rows.length, 3);
      expect(rows[0], ['name', 'price', 'note']);
      expect(rows[1], ['Tee', '1,200', 'has "quotes", ok']);
      expect(rows[2], ['Dress', '500', '']);
    });

    test('headerIndex is case-insensitive and tolerant', () {
      final idx = CsvUtil.headerIndex(
          [' Name ', 'PRICE', 'unknown'], ['name', 'price', 'size']);
      expect(idx['name'], 0);
      expect(idx['price'], 1);
      expect(idx['size'], -1);
    });
  });

  group('salesperson scoping', () {
    test("listSales(userId:) returns only that cashier's sales", () async {
      final db = await DB.instance();
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final admin = (await db.query('users',
              where: 'email = ?', whereArgs: ['admin@stylepos.app']))
          .first['id'] as int;
      final bob = await db.insert('users', {
        'name': 'Bob', 'email': 'bob@roles.test', 'pass_hash': 'x',
        'salt': 'y', 'role': 'cashier', 'active': 1, 'created_at': 1,
      });

      for (final (i, uid) in [admin, bob, bob].indexed) {
        await db.insert('sales', {
          'receipt_no': 'R-S$i', 'user_id': uid, 'subtotal': 100.0 + i,
          'discount': 0, 'tax': 0, 'total': 100.0 + i,
          'payment_method': 'cash', 'amount_paid': 100.0 + i,
          'change_due': 0, 'status': 'completed', 'created_at': now,
        });
      }

      final sales = SalesProvider();
      final everything = await sales.listSales();
      expect(everything.length, 3);

      final bobsOnly = await sales.listSales(userId: bob);
      expect(bobsOnly.length, 2);
      expect(bobsOnly.every((s) => s.userId == bob), isTrue);

      final adminsOnly = await sales.listSales(userId: admin);
      expect(adminsOnly.length, 1);
      expect(adminsOnly.first.userId, admin);
    });
  });
}
