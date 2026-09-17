import 'package:flutter/foundation.dart';

/// Tiny navigation notifier so any screen can jump to a tab
/// (e.g. customer detail -> "Start sale" -> POS tab).
class NavProvider extends ChangeNotifier {
  int index = 0;

  void go(int i) {
    index = i;
    notifyListeners();
  }
}
