import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:stylepos/data/database.dart';
import 'package:stylepos/models/product.dart';

/// Verifies the v1 -> v2 migration: existing installations get the
/// products.image column added without losing any data.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDir = await Directory.systemTemp.createTemp('stylepos_mig');
    DB.useDirectory(tempDir.path);
  });

  tearDownAll(() async {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('v1 database is upgraded to v2 and gains products.image', () async {
    // -- arrange: build a minimal version-1 database by hand --
    final v1 = await databaseFactory.openDatabase(
      p.join(tempDir.path, 'stylepos.db'),
      options: OpenDatabaseOptions(version: 1, onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE products (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            category_id INTEGER,
            barcode TEXT,
            description TEXT,
            low_stock INTEGER NOT NULL DEFAULT 5,
            archived INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.insert('products', {
          'name': 'Legacy Tee',
          'low_stock': 5,
          'archived': 0,
          'created_at': 1700000000,
        });
      }),
    );
    await v1.close();

    // -- act: open through the app (triggers onUpgrade 1 -> 2) --
    final db = await DB.instance();
    final version = await db.getVersion();
    final cols = await db.rawQuery('PRAGMA table_info(products)');
    final colNames = cols.map((c) => c['name']).toSet();

    // -- assert --
    expect(version, 2);
    expect(colNames, contains('image'));
    // pre-existing row survived
    final legacy = await db.query('products');
    expect(legacy.single['name'], 'Legacy Tee');
    expect(legacy.single['image'], isNull);

    // image writes work on the migrated schema
    final updated = Product(
      id: legacy.single['id'] as int,
      name: 'Legacy Tee',
      image: 'img_test.jpg',
      createdAt: 1700000000,
    );
    await db.update('products', updated.toMap(),
        where: 'id = ?', whereArgs: [legacy.single['id']]);
    final after = await db.query('products');
    expect(after.single['image'], 'img_test.jpg');
  });
}
