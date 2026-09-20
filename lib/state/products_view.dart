import 'package:flutter/foundation.dart';

import 'ui_prefs.dart';

/// Products (inventory) tab view state: search text, category filter and
/// the low-stock chip. Provider-owned like every other screen's state —
/// the widget stays a dumb projection, and the two toggles a manager uses
/// daily (category + low stock) survive app restarts. The search string
/// stays session-only on purpose (stale filters confuse on relaunch).
class ProductsViewState extends ChangeNotifier {
  static const _categoryKey = 'ui_products_category';
  static const _lowKey = 'ui_products_low';

  String _query = '';
  int _categoryFilter = -1; // -1 = all categories
  bool _lowOnly = false;

  String get query => _query;
  int get categoryFilter => _categoryFilter;
  bool get lowOnly => _lowOnly;

  void setQuery(String q) {
    if (q == _query) return;
    _query = q;
    notifyListeners();
  }

  void setCategoryFilter(int id) {
    if (id == _categoryFilter) return;
    _categoryFilter = id;
    notifyListeners();
    writeUiPref(_categoryKey, '$id');
  }

  void setLowOnly(bool v) {
    if (v == _lowOnly) return;
    _lowOnly = v;
    notifyListeners();
    writeUiPref(_lowKey, v ? '1' : '0');
  }

  /// Restores the persisted category + low-stock toggles. Awaited once
  /// from `main()`.
  Future<void> restore() async {
    final cat = int.tryParse(await readUiPref(_categoryKey) ?? '');
    if (cat != null) _categoryFilter = cat;
    _lowOnly = (await readUiPref(_lowKey)) == '1';
  }
}
