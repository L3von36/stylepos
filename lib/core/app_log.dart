import 'package:flutter/foundation.dart';

/// Tiny structured logger with an in-memory ring of recent entries.
///
/// Every catch block that used to swallow errors silently now goes through
/// [w]/[e], so "the app felt broken but said nothing" becomes diagnosable:
/// the ring backs diagnostics (see [recent]) and debug builds still print
/// to the console verbatim. Keep messages short and prefixed by the
/// subsystem, e.g. `AppLog.e('sync/products', e, st)`.
class AppLog {
  static const int _maxEntries = 200;
  static final List<String> _ring = <String>[];

  /// Newest-first snapshot of the last log lines (bounded).
  static List<String> recent({int count = 40}) {
    final n = count < _ring.length ? count : _ring.length;
    return List.unmodifiable(_ring.take(n));
  }

  /// Clears the ring (used by tests).
  static void reset() => _ring.clear();

  static void d(String context, [Object? detail]) =>
      _add('DEBUG', context, detail, null);

  static void w(String context, [Object? error, StackTrace? stack]) =>
      _add('WARN ', context, error, stack);

  static void e(String context, [Object? error, StackTrace? stack]) =>
      _add('ERROR', context, error, stack);

  static void _add(
      String level, String context, Object? detail, StackTrace? stack) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    final line = '$ts $level $context${detail == null ? '' : ' :: $detail'}';
    _ring.insert(0, line);
    if (_ring.length > _maxEntries) _ring.removeLast();
    debugPrint(line);
    if (stack != null && kDebugMode) debugPrintStack(stackTrace: stack);
  }
}
