import 'package:flutter/foundation.dart';

import 'ui_prefs.dart';

/// Identifiers for the app's main destinations.
enum NavId { pos, products, sales, customers, purchasing, reports }

NavId? _navIdFromName(String? name) {
  for (final id in NavId.values) {
    if (id.name == name) return id;
  }
  return null;
}

/// Single source of truth for WHERE the user is in the app shell — the
/// bottom nav bar (phones) and the sidebar (desktop) are both pure
/// projections of [id]; neither keeps its own selected index.
///
/// The active tab is persisted device-local and restored at boot, so the
/// app reopens where the shift left off (a cashier parked on Products at
/// closing time lands back on Products at opening).
class NavProvider extends ChangeNotifier {
  static const _prefKey = 'ui_last_tab';

  NavId _id = NavId.pos;

  /// Current destination (read-only — change it through [goTo]).
  NavId get id => _id;

  /// Restores the persisted tab. Awaited once from `main()` before the
  /// first frame, so the shell never flashes the wrong tab.
  Future<void> restore() async {
    final name = await readUiPref(_prefKey);
    final restored = _navIdFromName(name);
    if (restored != null) _id = restored;
  }

  /// Jumps to [id] and remembers it. Same-id calls are no-ops (the bottom
  /// bar fires onTap even when the user re-taps the active tab).
  void goTo(NavId id) {
    if (id == _id) return;
    _id = id;
    notifyListeners();
    // Persist without awaiting: navigation must never wait on storage.
    writeUiPref(_prefKey, id.name);
  }
}
