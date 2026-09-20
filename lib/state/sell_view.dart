import 'package:flutter/foundation.dart';

import 'ui_prefs.dart';

/// Sell-tab view state: the search/scan query and the selected category
/// chip. Lifting this out of the widget (it used to live in a setState)
/// makes the shell's state management uniform — every screen's filters are
/// provider-owned, testable without pumping widgets, and the category the
/// cashier was browsing survives app restarts.
///
/// The raw text is deliberately NOT persisted (a stale filter string is
/// more confusing than helpful after a restart); the category chip is.
class SellViewState extends ChangeNotifier {
  static const _categoryKey = 'ui_sell_category';

  String _query = '';
  int _categoryFilter = -1; // -1 = all categories

  String get query => _query;
  int get categoryFilter => _categoryFilter;

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

  /// Restores the persisted category chip. Awaited once from `main()`.
  Future<void> restore() async {
    final v = int.tryParse(await readUiPref(_categoryKey) ?? '');
    if (v != null) _categoryFilter = v;
  }
}
