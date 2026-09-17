import 'package:flutter/foundation.dart';

import '../data/database.dart';
import '../models/customer.dart';

class CustomersProvider extends ChangeNotifier {
  List<Customer> customers = [];
  bool loading = false;

  Future<void> reload() async {
    loading = true;
    notifyListeners();
    try {
      final db = await DB.instance();
      final rows = await db.query('customers', orderBy: 'name');
      customers = rows.map(Customer.fromMap).toList();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> save(Customer c) async {
    final db = await DB.instance();
    if (c.id == null) {
      await db.insert('customers', c.toMap());
    } else {
      await db.update('customers', c.toMap(),
          where: 'id = ?', whereArgs: [c.id]);
    }
    await reload();
  }

  /// Returns null on success, or an error (e.g. customer has sales history).
  Future<String?> delete(Customer c) async {
    final db = await DB.instance();
    final used = await db.query('sales',
        where: 'customer_id = ?', whereArgs: [c.id], limit: 1);
    if (used.isNotEmpty) {
      return 'Cannot delete: this customer has sales history. Edit instead.';
    }
    await db.delete('customers', where: 'id = ?', whereArgs: [c.id]);
    await reload();
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
