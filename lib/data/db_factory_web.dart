import 'package:sqflite/sqflite.dart' show databaseFactory;
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

/// Web: SQLite runs as a WASM worker; the database lives in the browser
/// (IndexedDB/OPFS). web/sqlite3.wasm + web/sqflite_sw.js are produced by
/// `dart run sqflite_common_ffi_web:setup` and shipped with the build.
void configureDatabaseFactory() {
  databaseFactory = databaseFactoryFfiWeb;
}
