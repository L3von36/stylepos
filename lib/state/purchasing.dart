import 'package:flutter/foundation.dart';

import '../data/database.dart';
import '../models/purchase_order.dart';
import '../models/supplier.dart';
import '../services/sync_service.dart';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Purchasing: the supplier database, purchase orders and goods-received.
///
/// Everything is local-first (SQLite) and pushed to the cloud by the sync
/// engine — suppliers/POs created here appear on every device. Receiving a
/// line tops the variant's stock up through a `purchase` stock movement and
/// re-points the variant's cost price, so margin reports use the latest buy
/// price from that supplier.
class PurchasingProvider extends ChangeNotifier {
  List<Supplier> suppliers = [];
  List<({PurchaseOrder po, String? supplierName, double total})> orders = [];
  bool loading = false;

  // ------------------------------------------------------------ suppliers

  Future<List<Supplier>> reloadSuppliers() async {
    final db = await DB.instance();
    final rows = await db.query('suppliers',
        where: 'deleted = 0', orderBy: 'name COLLATE NOCASE');
    suppliers = rows.map(Supplier.fromMap).toList();
    notifyListeners();
    return suppliers;
  }

  /// Creates or updates a supplier. Returns null on success.
  Future<String?> saveSupplier(Supplier s) async {
    if (s.name.trim().isEmpty) return 'Supplier name is required.';
    final db = await DB.instance();
    final map = s.toMap()..['updated_at'] = _now()..['dirty'] = 1;
    if (s.id == null) {
      await db.insert('suppliers', map);
    } else {
      await db.update('suppliers', map, where: 'id = ?', whereArgs: [s.id]);
    }
    SyncService.I.scheduleSync();
    await reloadSuppliers();
    return null;
  }

  /// Soft-deletes (tombstone) so every device learns about the removal.
  Future<void> deleteSupplier(Supplier s) async {
    final db = await DB.instance();
    await db.update(
        'suppliers',
        {'deleted': 1, 'dirty': 1, 'updated_at': _now()},
        where: 'id = ?',
        whereArgs: [s.id]);
    SyncService.I.scheduleSync();
    await reloadAll();
  }

  // -------------------------------------------------------- purchase orders

  Future<void> reloadOrders() async {
    final db = await DB.instance();
    final rows = await db.rawQuery('''
      SELECT po.*, s.name AS supplier_name,
             IFNULL((SELECT SUM(qty_ordered * unit_cost)
                     FROM purchase_order_items i WHERE i.po_id = po.id), 0)
               AS total_cost
      FROM purchase_orders po
      LEFT JOIN suppliers s ON s.id = po.supplier_id
      WHERE po.deleted = 0
      ORDER BY po.created_at DESC
    ''');
    orders = [
      for (final r in rows)
        (
          po: PurchaseOrder.fromMap(r),
          supplierName: r['supplier_name'] as String?,
          total: (r['total_cost'] as num? ?? 0).toDouble(),
        )
    ];
    notifyListeners();
  }

  Future<void> reloadAll() async {
    loading = true;
    notifyListeners();
    try {
      await reloadSuppliers();
      await reloadOrders();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Lines of one purchase order.
  Future<List<PurchaseOrderItem>> itemsFor(int poId) async {
    final db = await DB.instance();
    final rows = await db.query('purchase_order_items',
        where: 'po_id = ?', whereArgs: [poId], orderBy: 'id');
    return rows.map(PurchaseOrderItem.fromMap).toList();
  }

  /// Creates a draft PO (with lines) or edits an existing draft's lines.
  /// Returns the po id, or null when nothing to save.
  Future<int?> saveDraft({
    int? poId,
    required int? supplierId,
    required String? notes,
    required List<PurchaseOrderItem> lines,
  }) async {
    if (lines.isEmpty) return null;
    final db = await DB.instance();
    final now = _now();
    late int id;
    await db.transaction((txn) async {
      if (poId == null) {
        id = await txn.insert('purchase_orders', {
          'supplier_id': supplierId,
          'status': 'draft',
          'notes': notes,
          'created_by': 0,
          'created_at': now,
          'cloud_id': null,
          'dirty': 1,
          'updated_at': now,
        });
        for (final l in lines) {
          await txn.insert('purchase_order_items',
              l.copyWith(poId: id).toMap()..['dirty'] = 1
                ..['updated_at'] = now);
        }
      } else {
        id = poId;
        await txn.update(
            'purchase_orders',
            {
              'supplier_id': supplierId,
              'notes': notes,
              'dirty': 1,
              'updated_at': now,
            },
            where: 'id = ?',
            whereArgs: [poId]);
        await txn.delete('purchase_order_items',
            where: 'po_id = ?', whereArgs: [poId]);
        for (final l in lines) {
          await txn.insert('purchase_order_items',
              l.copyWith(poId: poId).toMap()..['dirty'] = 1
                ..['updated_at'] = now);
        }
      }
    });
    SyncService.I.scheduleSync();
    await reloadOrders();
    return id;
  }

  /// Marks the PO as sent to the supplier.
  Future<void> markOrdered(int poId, {int? expectedDate}) async {
    final db = await DB.instance();
    await db.update(
        'purchase_orders',
        {
          'status': 'ordered',
          'order_date': _now(),
          'expected_date': ?expectedDate,
          'dirty': 1,
          'updated_at': _now(),
        },
        where: 'id = ?',
        whereArgs: [poId]);
    SyncService.I.scheduleSync();
    await reloadOrders();
  }

  /// Cancels an open PO (no stock effect).
  Future<void> cancelOrder(int poId) async {
    final db = await DB.instance();
    await db.update(
        'purchase_orders',
        {'status': 'cancelled', 'dirty': 1, 'updated_at': _now()},
        where: 'id = ?',
        whereArgs: [poId]);
    SyncService.I.scheduleSync();
    await reloadOrders();
  }

  /// Soft-deletes a draft PO.
  Future<void> deleteDraft(int poId) async {
    final db = await DB.instance();
    await db.update(
        'purchase_orders',
        {'deleted': 1, 'dirty': 1, 'updated_at': _now()},
        where: 'id = ? AND status = ?',
        whereArgs: [poId, 'draft']);
    SyncService.I.scheduleSync();
    await reloadOrders();
  }

  /// Goods-received: records [qtys] per item id, tops stock up, re-points
  /// cost price, writes one `purchase` movement per line. A PO whose lines
  /// are all fully received flips to `received`.
  Future<void> receiveGoods(
      int poId, Map<int, int> qtyByItemId, Map<int, double> costByItemId,
      {int? actorUserId}) async {
    final db = await DB.instance();
    final now = _now();
    await db.transaction((txn) async {
      for (final e in qtyByItemId.entries) {
        if (e.value <= 0) continue;
        final rows = await txn.query('purchase_order_items',
            where: 'id = ?', whereArgs: [e.key], limit: 1);
        if (rows.isEmpty) continue;
        final item = PurchaseOrderItem.fromMap(rows.first);
        final newReceived = item.qtyReceived + e.value;
        final cost = costByItemId[e.key] ?? item.unitCost;

        await txn.update(
            'purchase_order_items',
            {
              'qty_received': newReceived,
              'unit_cost': cost,
              'dirty': 1,
              'updated_at': now,
            },
            where: 'id = ?',
            whereArgs: [e.key]);

        if (item.variantId != null && item.variantId! > 0) {
          await txn.rawUpdate(
              'UPDATE variants SET stock = stock + ?, cost = ?, dirty = 1, '
              'updated_at = ? WHERE id = ?',
              [e.value, cost, now, item.variantId]);
          await txn.insert('stock_movements', {
            'variant_id': item.variantId,
            'qty': e.value,
            'reason': 'purchase',
            'note': 'PO #$poId received',
            'user_id': actorUserId,
            'created_at': now,
            'cloud_id': null,
            'dirty': 1,
            'updated_at': now,
          });
        }
      }

      // PO fully received? (every line's received >= ordered)
      final items = await txn.query('purchase_order_items',
          where: 'po_id = ?', whereArgs: [poId]);
      final allIn = items.isNotEmpty &&
          items.every((r) =>
              (r['qty_received'] as int? ?? 0) >=
              (r['qty_ordered'] as int? ?? 0));
      await txn.update(
          'purchase_orders',
          {
            if (allIn) 'status': 'received',
            'received_date': allIn ? now : null,
            'dirty': 1,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [poId]);
    });
    SyncService.I.scheduleSync();
    await reloadAll();
  }

  /// Suppliers as a simple id→name map for pickers and reports.
  Map<int, String> supplierNameMap() =>
      {for (final s in suppliers) s.id!: s.name};
}
