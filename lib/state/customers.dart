import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/database.dart';
import '../models/customer.dart';
import '../services/sync_service.dart';

const _uuid = Uuid();

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

class CustomersProvider extends ChangeNotifier {
  List<Customer> customers = [];
  bool loading = false;

  Future<void> reload() async {
    loading = true;
    notifyListeners();
    try {
      final db = await DB.instance();
      final rows = await db.query('customers',
          where: 'deleted = 0', orderBy: 'name');
      customers = rows.map(Customer.fromMap).toList();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> save(Customer c) async {
    final db = await DB.instance();
    if (c.id == null) {
      final m = c.toMap();
      m['cloud_id'] = _uuid.v4();
      m['dirty'] = 1;
      m['updated_at'] = _now();
      await db.insert('customers', m);
    } else {
      await db.update('customers', {
        ...c.toMap(),
        'dirty': 1,
        'updated_at': _now(),
      }, where: 'id = ?', whereArgs: [c.id]);
    }
    await reload();
    SyncService.I.scheduleSync();
  }

  /// Soft-deletes the customer (tombstone) so sales history joins stay
  /// intact and the deletion propagates to the other devices on sync.
  Future<String?> delete(Customer c) async {
    final db = await DB.instance();
    await db.update('customers', {'deleted': 1, 'dirty': 1, 'updated_at': _now()},
        where: 'id = ?', whereArgs: [c.id]);
    await reload();
    SyncService.I.scheduleSync();
    return null;
  }

  List<Customer> search(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return customers;
    return customers
        .where((c) =>
            c.name.toLowerCase().contains(q) ||
            (c.phone ?? '').contains(q) ||
            (c.email ?? '').toLowerCase().contains(q))
        .toList();
  }
}
