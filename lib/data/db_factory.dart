/// Picks the SQLite factory for the current platform.
///   IO (Android/desktop) -> db_factory_io.dart
///   Web (js)             -> db_factory_web.dart
library;

export 'db_factory_io.dart'
    if (dart.library.js_interop) 'db_factory_web.dart';
