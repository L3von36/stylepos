import 'dart:io' show Platform;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Android uses the bundled sqflite platform code; desktop uses FFI.
void configureDatabaseFactory() {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
}
