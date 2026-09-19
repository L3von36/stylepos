import 'package:flutter/foundation.dart';

import '../data/database.dart';
import '../models/commission.dart';
import '../services/sync_service.dart';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Commission ledger: what each salesperson has earned and what has been
/// paid out. Rows land automatically at checkout (seller's commission rate
/// applied to net sale revenue) and via manager adjustments. The manager
/// marks rows paid from Reports → Commissions.
class CommissionsProvider extends ChangeNotifier {
  /// Latest rows joined with staff names for the report card.
  List<({Commission c, String userName})> rows = [];
  bool loading = false;

  Future<void> reload() async {
    loading = true;
    notifyListeners();
    try {
      final db = await DB.instance();
      final res = await db.rawQuery('''
        SELECT c.*, IFNULL(u.name, 'Former staff') AS user_name
        FROM commissions c LEFT JOIN users u ON u.id = c.user_id
        ORDER BY c.created_at DESC, c.id DESC LIMIT 400
      ''');
      rows = [
        for (final r in res)
          (
            c: Commission.fromMap(r),
            userName: r['user_name'] as String? ?? 'Former staff',
          )
      ];
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Marks every pending row for [userId] in [period] as paid.
  Future<void> markPaid(int userId, String period) async {
    final db = await DB.instance();
    final now = _now();
    await db.update(
        'commissions',
        {'status': 'paid', 'paid_at': now, 'dirty': 1, 'updated_at': now},
        where: 'user_id = ? AND status = ? AND period = ?',
        whereArgs: [userId, 'pending', period]);
    SyncService.I.scheduleSync();
    await reload();
  }

  /// Manager-entered adjustment (bonus or deduction — pass a negative amount).
  Future<void> addAdjustment({
    required int userId,
    required double amount,
    String? note,
  }) async {
    final db = await DB.instance();
    final now = _now();
    await db.insert('commissions', {
      'user_id': userId,
      'sale_id': null,
      'amount': amount,
      'basis': 'adjustment',
      'status': 'pending',
      'note': note,
      'period':
          '${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}',
      'paid_at': null,
      'created_at': now,
      'cloud_id': null,
      'dirty': 1,
      'updated_at': now,
    });
    SyncService.I.scheduleSync();
    await reload();
  }

  /// Pending totals per user id (for the staff performance card).
  Future<Map<int, double>> pendingByUser() async {
    final db = await DB.instance();
    final res = await db.rawQuery('''
      SELECT user_id, SUM(amount) AS pending FROM commissions
      WHERE status = 'pending' GROUP BY user_id
    ''');
    return {
      for (final r in res)
        (r['user_id'] as int? ?? 0): (r['pending'] as num? ?? 0).toDouble()
    };
  }

  /// Own commission progress for [period] (YYYY-MM): pending vs paid —
  /// powers the salesperson's personal dashboard (they only ever see
  /// their own rows here).
  Future<({double pending, double paid})> myProgress(
      int userId, String period) async {
    final db = await DB.instance();
    final res = await db.rawQuery('''
      SELECT status, SUM(amount) AS total FROM commissions
      WHERE user_id = ? AND period = ? GROUP BY status
    ''', [userId, period]);
    var pending = 0.0;
    var paid = 0.0;
    for (final r in res) {
      if (r['status'] == 'paid') {
        paid = (r['total'] as num? ?? 0).toDouble();
      } else {
        pending = (r['total'] as num? ?? 0).toDouble();
      }
    }
    return (pending: pending, paid: paid);
  }
}
