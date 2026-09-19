import 'package:flutter/foundation.dart';

import '../data/database.dart';
import '../models/promotion.dart';
import '../services/audit.dart' as audit_svc;
import '../services/sync_service.dart';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Manager-created promotions (coupons + seasonal campaigns), local-first
/// and synced to every till. Cashiers only APPLY codes at checkout; all
/// editing happens here (manager UI), so this provider is intentionally
/// separate from the cart.
class PromotionsProvider extends ChangeNotifier {
  List<Promotion> promotions = [];
  bool loading = false;

  Future<void> reload() async {
    loading = true;
    notifyListeners();
    try {
      final db = await DB.instance();
      final rows = await db.query('promotions',
          where: 'deleted = 0', orderBy: 'created_at DESC');
      promotions = rows.map(Promotion.fromMap).toList();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Case-insensitive code lookup among live promotions.
  Promotion? findByCode(String code) {
    final c = code.trim().toUpperCase();
    if (c.isEmpty) return null;
    for (final p in promotions) {
      if (p.code.toUpperCase() == c) return p;
    }
    return null;
  }

  /// Creates or updates a promotion. Returns null on success or an error.
  Future<String?> save(Promotion p, {int? actorUserId, String? actorName}) async {
    if (p.name.trim().isEmpty) return 'Give the promotion a name.';
    final code = p.code.trim().toUpperCase();
    if (code.isEmpty) return 'A promo code is required (e.g. SUMMER25).';
    if (code.contains(' ')) return 'Codes cannot contain spaces.';
    if (p.value <= 0) return 'The discount value must be greater than zero.';
    if (p.isPercent && p.value > 100) return 'Percent cannot exceed 100.';
    if (p.endsAt != null && p.startsAt != null && p.endsAt! < p.startsAt!) {
      return 'The end date is before the start date.';
    }
    final db = await DB.instance();
    // Unique code among not-deleted promotions.
    final clash = await db.query('promotions',
        where: 'UPPER(code) = ? AND deleted = 0 AND id IS NOT ?',
        whereArgs: [code, p.id],
        limit: 1);
    if (clash.isNotEmpty) return 'Code $code is already in use.';

    final map = p.copyWith(code: code).toMap()
      ..['updated_at'] = _now()
      ..['dirty'] = 1;
    if (p.id == null) {
      await db.insert('promotions', map);
      await _logPromo('promo_created', p, actorUserId, actorName);
    } else {
      await db.update('promotions', map, where: 'id = ?', whereArgs: [p.id]);
      await _logPromo('promo_updated', p, actorUserId, actorName);
    }
    SyncService.I.scheduleSync();
    await reload();
    return null;
  }

  /// Soft-deletes (tombstone) so every till drops the code.
  Future<void> delete(Promotion p, {int? actorUserId, String? actorName}) async {
    final db = await DB.instance();
    await db.update('promotions',
        {'deleted': 1, 'dirty': 1, 'updated_at': _now()},
        where: 'id = ?', whereArgs: [p.id]);
    await audit_svc.Audit.add('promo_deleted',
        '${p.code} (${p.name})', userId: actorUserId, userName: actorName);
    SyncService.I.scheduleSync();
    await reload();
  }

  /// Counts how many times each promotion was actually used on completed
  /// sales (join through sales.promo_code) — usage tracking for reports.
  Future<Map<String, int>> usageByCode() async {
    final db = await DB.instance();
    final rows = await db.rawQuery('''
      SELECT UPPER(promo_code) AS code, COUNT(*) AS uses
      FROM sales
      WHERE promo_code IS NOT NULL AND status != 'refunded'
      GROUP BY UPPER(promo_code)
    ''');
    return {for (final r in rows) r['code'] as String: r['uses'] as int? ?? 0};
  }

  /// Bumps used_count after a sale used the code (called in the checkout
  /// transaction itself — see SalesProvider.checkout).
  Future<void> bumpLocalUsage(String code) async {
    final db = await DB.instance();
    await db.rawUpdate(
        'UPDATE promotions SET used_count = used_count + 1, dirty = 1, '
        'updated_at = ? WHERE UPPER(code) = ? AND deleted = 0',
        [_now(), code.toUpperCase()]);
  }

  Future<void> _logPromo(String action, Promotion p,
      int? userId, String? userName) async {
    final label =
        action == 'promo_created' ? 'Created promotion' : 'Updated promotion';
    await audit_svc.Audit.add(action,
        '$label ${p.code} — ${p.isPercent ? '${p.value}% off' : p.value} · ${p.kind}',
        userId: userId, userName: userName);
  }
}
