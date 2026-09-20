import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../core/app_log.dart';
import '../data/database.dart';

/// Device-local UI preferences (active bottom-nav tab, per-screen filters)
/// stored in the settings key/value table.
///
/// NOT mirrored to the cloud by design — which tab a cashier left open on
/// this device is nobody else's business. Reads/writes never throw and
/// never notify listeners: UI-chrome state must not rebuild MaterialApp on
/// every tab tap (providers own their notification policy instead).
Future<String?> readUiPref(String key) async {
  try {
    final db = await DB.instance();
    final rows =
        await db.query('settings', where: 'key = ?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  } catch (e, s) {
    AppLog.w('ui-pref read failed ($key)', e, s);
    return null;
  }
}

Future<void> writeUiPref(String key, String value) async {
  try {
    final db = await DB.instance();
    await db.insert('settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  } catch (e, s) {
    AppLog.w('ui-pref write failed ($key)', e, s);
  }
}
