import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm, Database;
import 'package:uuid/uuid.dart';

import '../data/database.dart';
import '../models/sale.dart';
import '../services/sync_service.dart';
import 'cart.dart';
import 'settings.dart';

const _uuid = Uuid();

/// Per-device receipt prefix (e.g. `K3XQ2F`) so receipts from different
/// devices never collide in the cloud (`R-<code>-000123`).
Future<String> _deviceCode(Database db) async {
  final rows = await db.query('settings',
      where: 'key = ?', whereArgs: ['device_code']);
  final existing = rows.isEmpty ? '' : (rows.first['value'] as String? ?? '');
  if (existing.isNotEmpty) return existing;
  final code =
      _uuid.v4().replaceAll('-', '').substring(0, 6).toUpperCase();
  await db.insert('settings', {'key': 'device_code', 'value': code},
      conflictAlgorithm: ConflictAlgorithm.replace);
  return code;
}

/// Sales history, checkout transaction and report queries.
class SalesProvider extends ChangeNotifier {
  /// Bumped whenever a sale completes or is refunded so listeners
  /// (e.g. the POS "my sales today" strip) know to refresh.
  int revision = 0;

  /// Completes a sale inside a single DB transaction:
  /// inserts the sale + items, decrements stock, records movements and
  /// awards loyalty points. Returns the persisted [Sale] (with id).
  Future<Sale> checkout({
    required CartProvider cart,
    required int userId,
    required String paymentMethod,
    required double amountPaid,
    required AppSettings settings,
  }) async {
    assert(cart.isNotEmpty, 'Cannot checkout an empty cart');

    final db = await DB.instance();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final totals = cart.totalsWith(settings);
    final change = paymentMethod == 'cash'
        ? (amountPaid - totals.total).clamp(0.0, double.maxFinite)
        : 0.0;

    late Sale sale;
    final deviceCode = await _deviceCode(db);
    await db.transaction((txn) async {
      // sequential receipt number (unique per device via the code prefix)
      final seqRows = await txn.query('settings',
          where: 'key = ?', whereArgs: ['receipt_seq']);
      final seq = int.tryParse(seqRows.first['value'] as String? ?? '') ?? 0;
      final receiptNo = 'R-$deviceCode-${(seq + 1).toString().padLeft(6, '0')}';
      await txn.update('settings', {'value': '${seq + 1}'},
          where: 'key = ?', whereArgs: ['receipt_seq']);

      final saleId = await txn.insert('sales', {
        'receipt_no': receiptNo,
        'customer_id': cart.customer?.id,
        'user_id': userId,
        'subtotal': totals.subtotal,
        'discount': totals.discount,
        'tax': totals.tax,
        'total': totals.total,
        'payment_method': paymentMethod,
        'amount_paid': amountPaid,
        'change_due': change,
        'status': 'completed',
        'created_at': now,
        'cloud_id': null,
        'dirty': 1,
        'updated_at': now,
      });

      for (final item in cart.items) {
        await txn.insert('sale_items', {
          'sale_id': saleId,
          'variant_id': item.variant.id,
          'product_name': item.product.name,
          'variant_desc': item.variant.descriptor,
          'unit_price': item.variant.price,
          'unit_cost': item.variant.cost,
          'qty': item.qty,
          'line_total': item.lineTotal,
          'cloud_id': null,
          'dirty': 1,
          'updated_at': now,
        });
        await txn.rawUpdate(
          'UPDATE variants SET stock = MAX(stock - ?, 0), dirty = 1, updated_at = ? WHERE id = ?',
          [item.qty, now, item.variant.id],
        );
        await txn.insert('stock_movements', {
          'variant_id': item.variant.id,
          'qty': -item.qty,
          'reason': 'sale',
          'note': receiptNo,
          'user_id': userId,
          'created_at': now,
          'cloud_id': null,
          'dirty': 1,
          'updated_at': now,
        });
      }

      // loyalty: 1 point per loyalty_step spent (0 disables)
      if (cart.customer?.id != null && settings.loyaltyStep > 0) {
        final earned = (totals.total / settings.loyaltyStep).floor();
        if (earned > 0) {
          await txn.rawUpdate(
            'UPDATE customers SET points = points + ?, dirty = 1, updated_at = ? WHERE id = ?',
            [earned, now, cart.customer!.id],
          );
        }
      }

      // commission: rate% of net revenue (total minus tax) for the seller
      if (userId > 0) {
        final seller = await txn
            .query('users',
                columns: ['commission_rate'],
                where: 'id = ?',
                whereArgs: [userId],
                limit: 1)
            .then((r) =>
                (r.isEmpty ? 0.0 : (r.first['commission_rate'] as num? ?? 0))
                    .toDouble());
        if (seller > 0) {
          final net = (totals.total - totals.tax).clamp(0.0, double.maxFinite);
          await txn.insert('commissions', {
            'user_id': userId,
            'sale_id': saleId,
            'amount': net * seller / 100.0,
            'basis': 'sale',
            'status': 'pending',
            'note': receiptNo,
            'period':
                '${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}',
            'paid_at': null,
            'created_at': now,
            'cloud_id': null,
            'dirty': 1,
            'updated_at': now,
          });
        }
      }

      sale = Sale(
        id: saleId,
        receiptNo: receiptNo,
        customerId: cart.customer?.id,
        customerName: cart.customer?.name,
        userId: userId,
        subtotal: totals.subtotal,
        discount: totals.discount,
        tax: totals.tax,
        total: totals.total,
        paymentMethod: paymentMethod,
        amountPaid: amountPaid,
        changeDue: change,
        createdAt: now,
      );
    });

    revision++;
    notifyListeners();
    SyncService.I.scheduleSync();
    return sale;
  }

  /// Lists sales with optional filters. `days` = 0 means all time.
  /// [userId] scopes the list to one cashier — salespeople only ever see
  /// their own receipts (the manager sees the whole shop).
  Future<List<Sale>> listSales({int days = 0, String? query, int? customerId, int? userId}) async {
    final db = await DB.instance();
    final where = <String>[];
    final args = <Object?>[];

    if (days > 0) {
      final cutoff =
          DateTime.now().subtract(Duration(days: days)).millisecondsSinceEpoch ~/ 1000;
      where.add('s.created_at >= ?');
      args.add(cutoff);
    }
    if (userId != null) {
      where.add('s.user_id = ?');
      args.add(userId);
    }
    if (customerId != null) {
      where.add('s.customer_id = ?');
      args.add(customerId);
    }
    if (query != null && query.trim().isNotEmpty) {
      final q = '%${query.trim().toLowerCase()}%';
      where.add(
          '(LOWER(s.receipt_no) LIKE ? OR LOWER(IFNULL(c.name, "")) LIKE ? OR LOWER(IFNULL(u.name, "")) LIKE ?)');
      args.addAll([q, q, q]);
    }

    final rows = await db.rawQuery('''
      SELECT s.*, c.name AS customer_name, u.name AS cashier_name
      FROM sales s
      LEFT JOIN customers c ON c.id = s.customer_id
      LEFT JOIN users u ON u.id = s.user_id
      ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
      ORDER BY s.created_at DESC
      LIMIT 500
    ''', args);
    return rows.map(Sale.fromMap).toList();
  }

  Future<List<SaleItem>> itemsForSale(int saleId) async {
    final db = await DB.instance();
    final rows = await db.query('sale_items',
        where: 'sale_id = ?', whereArgs: [saleId], orderBy: 'id');
    return rows.map(SaleItem.fromMap).toList();
  }

  /// Bumps the revision so listeners (reports, POS strip) reload — used by
  /// the sync engine when cloud sales arrive in realtime.
  void bump() {
    revision++;
    notifyListeners();
  }

  /// Marks a sale refunded and restores stock. Admin-only; caller enforces.
  Future<void> refund(Sale sale, int adminId) async {
    final db = await DB.instance();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await db.transaction((txn) async {
      await txn.rawUpdate(
          'UPDATE sales SET status = ?, dirty = 1, updated_at = ? WHERE id = ?',
          ['refunded', now, sale.id]);
      final items = await txn.query('sale_items',
          where: 'sale_id = ?', whereArgs: [sale.id]);
      for (final r in items) {
        final qty = r['qty'] as int;
        final variantId = r['variant_id'] as int;
        await txn.rawUpdate(
            'UPDATE variants SET stock = stock + ?, dirty = 1, updated_at = ? WHERE id = ?',
            [qty, now, variantId]);
        await txn.insert('stock_movements', {
          'variant_id': variantId,
          'qty': qty,
          'reason': 'refund',
          'note': sale.receiptNo,
          'user_id': adminId,
          'created_at': now,
          'cloud_id': null,
          'dirty': 1,
          'updated_at': now,
        });
      }
    });
    revision++;
    notifyListeners();
    SyncService.I.scheduleSync();
  }

  // ---- report queries (completed sales only) ----

  Future<int> lowStockCount() async {
    final db = await DB.instance();
    final rows = await db.rawQuery('''
      SELECT COUNT(*) AS n
      FROM variants v
      JOIN products p ON p.id = v.product_id
      WHERE p.archived = 0 AND v.archived = 0 AND v.stock <= p.low_stock
    ''');
    return rows.first['n'] as int? ?? 0;
  }

  /// Aggregate sales numbers for a time window (in days).
  Future<({double revenue, int orders, int itemsSold})> summary(int days) async {
    final db = await DB.instance();
    final cutoff = days > 0
        ? DateTime.now()
                .subtract(Duration(days: days))
                .millisecondsSinceEpoch ~/
            1000
        : 0;
    final rows = await db.rawQuery('''
      SELECT COUNT(*) AS orders,
             COALESCE(SUM(total), 0) AS revenue
      FROM sales
      WHERE status = 'completed' AND created_at >= ?
    ''', [cutoff]);
    final itemRows = await db.rawQuery('''
      SELECT COALESCE(SUM(si.qty), 0) AS items
      FROM sale_items si
      JOIN sales s ON s.id = si.sale_id
      WHERE s.status = 'completed' AND s.created_at >= ?
    ''', [cutoff]);
    return (
      revenue: (rows.first['revenue'] as num?)?.toDouble() ?? 0,
      orders: rows.first['orders'] as int? ?? 0,
      itemsSold: itemRows.first['items'] as int? ?? 0,
    );
  }

  /// Daily revenue for the last `days` days, local-time grouped.
  Future<List<(DateTime, double)>> revenueByDay(int days) async {
    final db = await DB.instance();
    final cutoff = DateTime.now()
            .subtract(Duration(days: days))
            .millisecondsSinceEpoch ~/
        1000;
    final rows = await db.rawQuery('''
      SELECT date(created_at, 'unixepoch', 'localtime') AS day,
             SUM(total) AS revenue
      FROM sales
      WHERE status = 'completed' AND created_at >= ?
      GROUP BY day
      ORDER BY day
    ''', [cutoff]);

    final byDay = <String, double>{
      for (final r in rows) r['day'] as String: (r['revenue'] as num).toDouble(),
    };
    final out = <(DateTime, double)>[];
    for (var i = days - 1; i >= 0; i--) {
      final d = DateTime.now().subtract(Duration(days: i));
      final key = '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      out.add((d, byDay[key] ?? 0));
    }
    return out;
  }

  /// Top products by units sold in the last `days` days.
  Future<List<(String, int, double)>> topProducts(int days, {int limit = 5}) async {
    final db = await DB.instance();
    final cutoff = DateTime.now()
            .subtract(Duration(days: days))
            .millisecondsSinceEpoch ~/
        1000;
    final rows = await db.rawQuery('''
      SELECT si.product_name AS name,
             SUM(si.qty) AS units,
             SUM(si.line_total) AS revenue
      FROM sale_items si
      JOIN sales s ON s.id = si.sale_id
      WHERE s.status = 'completed' AND s.created_at >= ?
      GROUP BY si.product_name
      ORDER BY units DESC
      LIMIT ?
    ''', [cutoff, limit]);
    return rows
        .map((r) => (
              r['name'] as String,
              r['units'] as int? ?? 0,
              (r['revenue'] as num?)?.toDouble() ?? 0,
            ))
        .toList();
  }

  /// Revenue share per category in the last `days` days.
  Future<List<(String, double)>> categoryShare(int days) async {
    final db = await DB.instance();
    final cutoff = DateTime.now()
            .subtract(Duration(days: days))
            .millisecondsSinceEpoch ~/
        1000;
    final rows = await db.rawQuery('''
      SELECT IFNULL(cat.name, 'Uncategorized') AS name,
             SUM(si.line_total) AS revenue
      FROM sale_items si
      JOIN sales s ON s.id = si.sale_id
      LEFT JOIN variants v ON v.id = si.variant_id
      LEFT JOIN products p ON p.id = v.product_id
      LEFT JOIN categories cat ON cat.id = p.category_id
      WHERE s.status = 'completed' AND s.created_at >= ?
      GROUP BY IFNULL(cat.name, 'Uncategorized')
      ORDER BY revenue DESC
      LIMIT 8
    ''', [cutoff]);
    return rows
        .map((r) => (r['name'] as String, (r['revenue'] as num).toDouble()))
        .toList();
  }

  /// "My sales today" strip on the POS screen: orders + revenue + items
  /// sold by one staff member since local midnight.
  Future<({int orders, double revenue, int itemsSold})> todaySummaryForUser(
      int userId) async {
    final db = await DB.instance();
    final now = DateTime.now();
    final midnight = DateTime(now.year, now.month, now.day)
        .millisecondsSinceEpoch ~/
        1000;
    final rows = await db.rawQuery('''
      SELECT COUNT(*) AS orders, COALESCE(SUM(total), 0) AS revenue
      FROM sales
      WHERE status = 'completed' AND user_id = ? AND created_at >= ?
    ''', [userId, midnight]);
    final itemRows = await db.rawQuery('''
      SELECT COALESCE(SUM(si.qty), 0) AS items
      FROM sale_items si
      JOIN sales s ON s.id = si.sale_id
      WHERE s.status = 'completed' AND s.user_id = ? AND s.created_at >= ?
    ''', [userId, midnight]);
    return (
      orders: rows.first['orders'] as int? ?? 0,
      revenue: (rows.first['revenue'] as num?)?.toDouble() ?? 0,
      itemsSold: itemRows.first['items'] as int? ?? 0,
    );
  }

  /// Revenue and order count per staff member (manager feature).
  Future<List<({String name, int orders, double revenue})>> staffPerformance(
      int days) async {
    final db = await DB.instance();
    final cutoff = days > 0
        ? DateTime.now()
                .subtract(Duration(days: days))
                .millisecondsSinceEpoch ~/
            1000
        : 0;
    final rows = await db.rawQuery('''
      SELECT u.name AS name,
             COUNT(*) AS orders,
             COALESCE(SUM(s.total), 0) AS revenue
      FROM sales s
      JOIN users u ON u.id = s.user_id
      WHERE s.status = 'completed' AND s.created_at >= ?
      GROUP BY u.id, u.name
      ORDER BY revenue DESC
    ''', [cutoff]);
    return rows
        .map((r) => (
              name: r['name'] as String? ?? 'Unknown',
              orders: r['orders'] as int? ?? 0,
              revenue: (r['revenue'] as num?)?.toDouble() ?? 0,
            ))
        .toList();
  }

  /// Margin per product for the window: what each item earned vs what it
  /// cost. Uses the per-sale cost snapshot (sale_items.unit_cost) when the
  /// sale carries one, falling back to the variant's current cost for
  /// older history.
  Future<List<({String name, int units, double revenue, double cost})>>
      productMargins(int days, {int limit = 8}) async {
    final db = await DB.instance();
    final cutoff = days > 0
        ? DateTime.now()
                .subtract(Duration(days: days))
                .millisecondsSinceEpoch ~/
            1000
        : 0;
    final rows = await db.rawQuery('''
      SELECT si.product_name AS name,
             SUM(si.qty) AS units,
             SUM(si.line_total) AS revenue,
             SUM(si.qty * CASE WHEN si.unit_cost > 0 THEN si.unit_cost
                               ELSE COALESCE(v.cost, 0) END) AS cost
      FROM sale_items si
      JOIN sales s ON s.id = si.sale_id
      LEFT JOIN variants v ON v.id = si.variant_id
      WHERE s.status = 'completed' AND s.created_at >= ?
      GROUP BY si.product_name
      HAVING revenue > 0
      ORDER BY revenue DESC
      LIMIT ?
    ''', [cutoff, limit]);
    return rows
        .map((r) => (
              name: r['name'] as String? ?? 'Unknown',
              units: r['units'] as int? ?? 0,
              revenue: (r['revenue'] as num?)?.toDouble() ?? 0,
              cost: (r['cost'] as num?)?.toDouble() ?? 0,
            ))
        .toList();
  }

  /// Detailed per-staff performance for the window: who sold what, how
  /// much, and how much discount they handed out (manager feature).
  Future<List<
          ({
            int userId,
            String name,
            int orders,
            int items,
            double revenue,
            double discount
          })>> staffPerformanceDetailed(int days) async {
    final db = await DB.instance();
    final cutoff = days > 0
        ? DateTime.now()
                .subtract(Duration(days: days))
                .millisecondsSinceEpoch ~/
            1000
        : 0;
    final rows = await db.rawQuery('''
      SELECT u.id AS user_id, u.name AS name,
             COUNT(DISTINCT s.id) AS orders,
             COALESCE(SUM(si.qty), 0) AS items,
             COALESCE(SUM(s.total), 0) AS revenue,
             COALESCE(SUM(s.discount), 0) AS discount
      FROM sales s
      JOIN users u ON u.id = s.user_id
      LEFT JOIN sale_items si ON si.sale_id = s.id
      WHERE s.status = 'completed' AND s.created_at >= ?
      GROUP BY u.id, u.name
      ORDER BY revenue DESC
    ''', [cutoff]);
    return rows
        .map((r) => (
              userId: r['user_id'] as int? ?? 0,
              name: r['name'] as String? ?? 'Unknown',
              orders: r['orders'] as int? ?? 0,
              items: r['items'] as int? ?? 0,
              revenue: (r['revenue'] as num?)?.toDouble() ?? 0,
              discount: (r['discount'] as num?)?.toDouble() ?? 0,
            ))
        .toList();
  }

  /// Cost of goods sold for the window, from variant cost prices.
  /// Lets the manager see an estimated profit next to revenue.
  Future<double> cogs(int days) async {
    final db = await DB.instance();
    final cutoff = days > 0
        ? DateTime.now()
                .subtract(Duration(days: days))
                .millisecondsSinceEpoch ~/
            1000
        : 0;
    final rows = await db.rawQuery('''
      SELECT COALESCE(SUM(si.qty * COALESCE(v.cost, 0)), 0) AS cost
      FROM sale_items si
      JOIN sales s ON s.id = si.sale_id
      LEFT JOIN variants v ON v.id = si.variant_id
      WHERE s.status = 'completed' AND s.created_at >= ?
    ''', [cutoff]);
    return (rows.first['cost'] as num?)?.toDouble() ?? 0;
  }

  /// Totals per payment method in the window (manager feature).
  Future<List<({String method, int orders, double total})>> paymentBreakdown(
      int days) async {
    final db = await DB.instance();
    final cutoff = days > 0
        ? DateTime.now()
                .subtract(Duration(days: days))
                .millisecondsSinceEpoch ~/
            1000
        : 0;
    final rows = await db.rawQuery('''
      SELECT payment_method AS method,
             COUNT(*) AS orders,
             COALESCE(SUM(total), 0) AS total
      FROM sales
      WHERE status = 'completed' AND created_at >= ?
      GROUP BY payment_method
      ORDER BY total DESC
    ''', [cutoff]);
    return rows
        .map((r) => (
              method: r['method'] as String? ?? 'cash',
              orders: r['orders'] as int? ?? 0,
              total: (r['total'] as num?)?.toDouble() ?? 0,
            ))
        .toList();
  }
}
