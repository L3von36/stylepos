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

  test('v1 database is upgraded to v4 and gains sync columns', () async {
    // -- arrange: build a minimal version-1 database by hand --
    final v1 = await databaseFactory.openDatabase(
      p.join(tempDir.path, 'stylepos.db'),
      options: OpenDatabaseOptions(version: 1, onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE categories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE
          )
        ''');
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
        await db.execute('''
          CREATE TABLE variants (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            product_id INTEGER NOT NULL,
            size TEXT NOT NULL DEFAULT '',
            color TEXT NOT NULL DEFAULT '',
            sku TEXT NOT NULL,
            barcode TEXT,
            price REAL NOT NULL DEFAULT 0,
            cost REAL NOT NULL DEFAULT 0,
            stock INTEGER NOT NULL DEFAULT 0,
            archived INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE customers (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            phone TEXT,
            email TEXT,
            notes TEXT,
            points INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            email TEXT NOT NULL UNIQUE,
            pass_hash TEXT NOT NULL,
            salt TEXT NOT NULL,
            role TEXT NOT NULL DEFAULT 'cashier',
            active INTEGER NOT NULL DEFAULT 1,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE sales (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            receipt_no TEXT NOT NULL UNIQUE,
            customer_id INTEGER,
            user_id INTEGER NOT NULL,
            subtotal REAL NOT NULL DEFAULT 0,
            discount REAL NOT NULL DEFAULT 0,
            tax REAL NOT NULL DEFAULT 0,
            total REAL NOT NULL DEFAULT 0,
            payment_method TEXT NOT NULL DEFAULT 'cash',
            amount_paid REAL NOT NULL DEFAULT 0,
            change_due REAL NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'completed',
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE sale_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sale_id INTEGER NOT NULL,
            variant_id INTEGER NOT NULL,
            product_name TEXT NOT NULL,
            variant_desc TEXT NOT NULL,
            unit_price REAL NOT NULL DEFAULT 0,
            qty INTEGER NOT NULL DEFAULT 0,
            line_total REAL NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE stock_movements (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            variant_id INTEGER NOT NULL,
            qty INTEGER NOT NULL,
            reason TEXT NOT NULL,
            note TEXT,
            user_id INTEGER,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT)
        ''');
        await db.insert('products', {
          'name': 'Legacy Tee',
          'low_stock': 5,
          'archived': 0,
          'created_at': 1700000000,
        });
        await db.insert('customers', {
          'name': 'Legacy Customer',
          'created_at': 1700000000,
        });
      }),
    );
    await v1.close();

    // -- act: open through the app (triggers onUpgrade 1 -> 4) --
    final db = await DB.instance();
    final version = await db.getVersion();
    final cols = await db.rawQuery('PRAGMA table_info(products)');
    final colNames = cols.map((c) => c['name']).toSet();

    // -- assert --
    expect(version, 4);
    expect(colNames, containsAll(['image', 'cloud_id', 'dirty', 'deleted']));
    // v4: sales tables gained their sync bookkeeping too
    final saleCols = (await db.rawQuery('PRAGMA table_info(sales)'))
        .map((c) => c['name'] as String)
        .toSet();
    expect(saleCols, containsAll(['cloud_id', 'dirty', 'updated_at']));
    final userCols = (await db.rawQuery('PRAGMA table_info(users)'))
        .map((c) => c['name'] as String)
        .toSet();
    expect(userCols, contains('cloud_id'));
    // pre-existing row survived
    final legacy = await db.query('products');
    expect(legacy.single['name'], 'Legacy Tee');
    expect(legacy.single['image'], isNull);
    // sync bookkeeping: timestamped, cloud identity left open for adoption
    expect(legacy.single['cloud_id'], isNull);
    expect(legacy.single['updated_at'], greaterThan(0));
    final legacyCust = await db.query('customers');
    expect(legacyCust.single['name'], 'Legacy Customer');
    expect(legacyCust.single['cloud_id'], isNull);

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
