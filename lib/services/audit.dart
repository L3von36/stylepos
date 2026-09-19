import '../data/database.dart';

/// One immutable audit-trail row: WHO did WHAT, WHEN.
class AuditEntry {
  final int? id;
  final int? userId;
  final String? userName;
  final String action;
  final String? details;
  final int createdAt;

  const AuditEntry({
    this.id,
    this.userId,
    this.userName,
    required this.action,
    this.details,
    required this.createdAt,
  });

  factory AuditEntry.fromMap(Map<String, Object?> m) => AuditEntry(
        id: m['id'] as int?,
        userId: m['user_id'] as int?,
        userName: m['user_name'] as String?,
        action: m['action'] as String? ?? '',
        details: m['details'] as String?,
        createdAt: m['created_at'] as int? ?? 0,
      );

  /// Human-readable action label + icon key (kept in the UI layer).
  static const actionLabels = {
    'refund': 'Sale refunded',
    'partial_refund': 'Items refunded',
    'exchange_return': 'Exchange return',
    'discount_approved': 'Discount approved',
    'stock_adjust': 'Stock adjusted',
    'day_close': 'Day closed (Z-report)',
    'day_reopen': 'Day re-opened',
    'staff_created': 'Staff account created',
    'staff_updated': 'Staff account updated',
    'password_reset': 'Staff password reset',
    'pin_changed': 'Manager PIN changed',
    'backup_exported': 'Backup exported',
    'restore': 'Backup restored',
    'sales_cleared': 'Sales history cleared',
    'csv_import': 'Products imported (CSV)',
    'promo_created': 'Promotion created',
    'promo_updated': 'Promotion updated',
    'promo_deleted': 'Promotion deleted',
    'bulk_price_update': 'Bulk price update',
    'branch_created': 'Branch created',
    'branch_switched': 'Switched branch',
    'receipt_emailed': 'Receipt emailed',
    'receipt_sms': 'Receipt sent by SMS',
  };
}

/// Append-only audit trail (local table `audit_log`).
///
/// Writes are fire-and-forget best-effort: accountability must never block
/// or crash the action it is recording. The log is device-local by design —
/// it captures what happened on THIS till (refunds, approvals, day closes,
/// staff edits, backups).
class Audit {
  Audit._();

  /// Records an action. [userId]/[userName] describe the acting user;
  /// approval details go into [details] as free text.
  static Future<void> add(
    String action,
    String? details, {
    int? userId,
    String? userName,
  }) async {
    try {
      final db = await DB.instance();
      await db.insert('audit_log', {
        'user_id': userId,
        'user_name': userName,
        'action': action,
        'details': details,
        'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      });
    } catch (_) {
      // Never let the audit write break the shop floor.
    }
  }

  /// Newest-first audit entries, optionally filtered by action.
  static Future<List<AuditEntry>> list({int limit = 300, String? action}) async {
    final db = await DB.instance();
    final rows = await db.query(
      'audit_log',
      where: action == null ? null : 'action = ?',
      whereArgs: action == null ? null : [action],
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.map(AuditEntry.fromMap).toList();
  }

  /// Convenience used by tests.
  static Future<void> clearAll() async {
    final db = await DB.instance();
    await db.delete('audit_log');
  }
}
