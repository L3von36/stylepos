import 'package:flutter/foundation.dart';

/// Identifiers for the app's main destinations.
enum NavId { pos, products, sales, customers, reports }

/// Tiny navigation notifier so any screen can jump to a tab
/// (e.g. customer detail -> "Start sale" -> POS tab).
class NavProvider extends ChangeNotifier {
  NavId id = NavId.pos;

  void goTo(NavId id) {
    this.id = id;
    notifyListeners();
  }
}
