import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/database.dart';

/// One-tap safety net: packs the whole shop (SQLite database + product
/// photos) into a single shareable `.stylepos` backup file, and restores
/// it back.
///
/// The archive layout is simple and future-proof:
///   meta.json     { app, schema, exportedAt }
///   stylepos.db   the complete database (WAL checkpointed first)
///   `images/<file>` every product photo (folder optional)
class BackupService {
  static const dbFileName = 'stylepos.db';
  static const imagesDirName = 'product_images';
  static const metaName = 'meta.json';

  /// Directory holding stylepos.db — mirrors DB.instance() resolution.
  static Future<String> _dbDir() async {
    if (Platform.isAndroid || Platform.isIOS) return await getDatabasesPath();
    return (await getApplicationSupportDirectory()).path;
  }

  static Future<String> _imagesDir() async {
    final support = await getApplicationSupportDirectory();
    return p.join(support.path, imagesDirName);
  }

  /// Packs DB + photos into `outPath` (or a timestamped temp file).
  /// Returns the backup file path.
  static Future<String> createBackup({
    String? outPath,
    String? dbDirOverride,
    String? imagesDirOverride,
  }) async {
    final dbDir = dbDirOverride ?? await _dbDir();
    final dbFile = File(p.join(dbDir, dbFileName));
    if (!dbFile.existsSync()) {
      throw const BackupException('No shop database found on this device yet.');
    }

    // Fold the write-ahead log into the main file so the copy is complete.
    final db = await DB.instance();
    try {
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (_) {/* desktop FFI may not use WAL — safe to continue */}
    final archive = Archive();
    final meta = {
      'app': 'StylePOS',
      'schema': 2,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
    };
    _addBytes(archive, metaName, utf8.encode(jsonEncode(meta)));
    _addBytes(archive, dbFileName, dbFile.readAsBytesSync());

    final imagesDir = Directory(imagesDirOverride ?? await _imagesDir());
    if (imagesDir.existsSync()) {
      for (final f in imagesDir.listSync().whereType<File>()) {
        if (f.path.endsWith('.tmp')) continue;
        _addBytes(archive, 'images/${p.basename(f.path)}', f.readAsBytesSync());
      }
    }

    final out = outPath ??
        p.join(
          (await getTemporaryDirectory()).path,
          'StylePOS-backup-${_stamp()}.stylepos',
        );
    final zip = ZipEncoder().encode(archive);
    File(out)
      ..createSync(recursive: true)
      ..writeAsBytesSync(zip);
    return out;
  }

  /// Restores `zipPath` over the current shop data. Closes the database,
  /// replaces the DB file and product photos, then reopens the DB.
  /// Caller should prompt for an app restart afterwards.
  static Future<int> restoreBackup(
    String zipPath, {
    String? dbDirOverride,
    String? imagesDirOverride,
  }) async {
    final bytes = File(zipPath).readAsBytesSync();
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const BackupException('That file is not a valid StylePOS backup.');
    }
    if (archive.findFile(dbFileName) == null ||
        archive.findFile(metaName) == null) {
      throw const BackupException('That file is missing shop data — not a StylePOS backup.');
    }

    final dbDir = dbDirOverride ?? await _dbDir();
    final imagesDirPath = imagesDirOverride ?? await _imagesDir();

    // Close the pool before touching files under it.
    await DB.closeAndReset();

    for (final entry in archive) {
      final name = entry.name;
      if (name.contains('..') || p.isAbsolute(name)) {
        throw const BackupException('Unsafe file path inside backup.');
      }
      if (name == dbFileName) {
        for (final stale in ['$dbFileName-wal', '$dbFileName-shm']) {
          final f = File(p.join(dbDir, stale));
          if (f.existsSync()) f.deleteSync();
        }
        File(p.join(dbDir, dbFileName))
          ..createSync(recursive: true)
          ..writeAsBytesSync(entry.content as List<int>);
      } else if (name.startsWith('images/')) {
        final target = File(p.join(imagesDirPath, p.basename(name)));
        target
          ..createSync(recursive: true)
          ..writeAsBytesSync(entry.content as List<int>);
      }
    }

    final db = await DB.instance();
    final row = await db.rawQuery('SELECT COUNT(*) AS n FROM sales');
    return (row.first['n'] as int?) ?? 0;
  }

  static void _addBytes(Archive archive, String name, List<int> data) {
    final entry = ArchiveFile(name, data.length, data);
    archive.addFile(entry);
  }

  static String _stamp() {
    final t = DateTime.now();
    final m = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    final h = t.hour.toString().padLeft(2, '0');
    final mi = t.minute.toString().padLeft(2, '0');
    return '${t.year}$m$d-$h$mi';
  }
}

class BackupException implements Exception {
  final String message;
  const BackupException(this.message);
  @override
  String toString() => message;
}
