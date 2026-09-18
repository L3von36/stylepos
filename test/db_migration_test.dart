import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:stylepos/data/database.dart';
import 'package:stylepos/models/product.dart';

/// Verifies schema upgrades. Since DB v5 the upgrade path also performs a
/// one-time purge of the hardcoded demo catalog + demo sales history, so
/// upgraded devices converge with the cleaned cloud.
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

  Future<Database> createLegacySchemaDb(String dir, int version) async {
    final db = await databaseFactory.openDatabase(
      p.join(dir, 'stylepos.db'),
      options: OpenDatabaseOptions(version: version, onCreate: (db, _) async {
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
      }),
    );
    return db;
  }

  test('v1 database is upgraded to v5 and gains all sync columns', () async {
    // -- arrange: build a minimal version-1 database by hand --
    final v1 = await createLegacySchemaDb(tempDir.path, 1);
    await v1.insert('products', {
      'name': 'Legacy Tee',
      'low_stock': 5,
      'archived': 0,
      'created_at': 1700000000,
    });
    await v1.insert('customers', {
      'name': 'Legacy Customer',
      'created_at': 1700000000,
    });
    await v1.close();

    // -- act: open through the app (triggers onUpgrade 1 -> 5) --
    final db = await DB.instance();
    final version = await db.getVersion();
    final cols = await db.rawQuery('PRAGMA table_info(products)');
    final colNames = cols.map((c) => c['name']).toSet();

    // -- assert --
    expect(version, 5);
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
    // v5 purge: the demo catalog is gone, the walk-in customer stays.
    final products = await db.query('products');
    expect(products, isEmpty);
    final legacyCust = await db.query('customers');
    expect(legacyCust.single['name'], 'Legacy Customer');

    // the migrated schema still accepts real products
    final id = await db.insert('products', Product(
      name: 'Fresh Tee',
      lowStock: 5,
      createdAt: 1700000001,
    ).toMap());
    expect(id, greaterThan(0));
  });

  test('v4 to v5 wipes the demo catalog, sales history and pull cursors',
      () async {
    final tempDir2 = await Directory.systemTemp.createTemp('stylepos_mig45');
    DB.useDirectory(tempDir2.path);
    DB.closeAndReset();
    addTearDown(() {
      DB.closeAndReset();
      tempDir2.deleteSync(recursive: true);
    });

    // -- arrange: a v4 database full of "demo" data + sync cursors --
    final v4 = await createLegacySchemaDb(tempDir2.path, 4);
    await v4.insert('users', {
      'name': 'Admin',
      'email': 'admin@stylepos.app',
      'pass_hash': 'x',
      'salt': 'y',
      'role': 'admin',
      'active': 1,
      'created_at': 1700000000,
    });
    final catId = await v4
        .insert('categories', {'name': 'T-Shirts'});
    final pid = await v4.insert('products', {
      'name': 'Classic Cotton Tee',
      'category_id': catId,
      'barcode': '600123400001',
      'low_stock': 5,
      'archived': 0,
      'created_at': 1700000000,
    });
    final vid = await v4.insert('variants', {
      'product_id': pid,
      'size': 'M',
      'color': 'Black',
      'sku': '600123400001-M-1',
      'price': 850,
      'cost': 400,
      'stock': 12,
      'archived': 0,
    });
    final sid = await v4.insert('sales', {
      'receipt_no': 'R-ABC123-000001',
      'user_id': 1,
      'subtotal': 850,
      'total': 850,
      'amount_paid': 1000,
      'change_due': 150,
      'status': 'completed',
      'created_at': 1700000000,
    });
    await v4.insert('sale_items', {
      'sale_id': sid,
      'variant_id': vid,
      'product_name': 'Classic Cotton Tee',
      'variant_desc': 'M / Black',
      'unit_price': 850,
      'qty': 1,
      'line_total': 850,
    });
    await v4.insert('stock_movements', {
      'variant_id': vid,
      'qty': -1,
      'reason': 'sale',
      'created_at': 1700000000,
    });
    await v4.insert('customers', {
      'name': 'Walk-in Customer',
      'created_at': 1700000000,
    });
    await v4.insert('settings', {'key': 'sync_last_pull_products', 'value': '99'});
    await v4.insert('settings', {'key': 'sync_last_pull_sales', 'value': '99'});
    await v4.close();

    // -- act: open through the app (triggers onUpgrade 4 -> 5) --
    final db = await DB.instance();
    expect(await db.getVersion(), 5);

    // -- assert: catalog + history wiped, cursors forgotten --
    for (final t in [
      'categories',
      'products',
      'variants',
      'sales',
      'sale_items',
      'stock_movements',
    ]) {
      final n = (await db.rawQuery('SELECT COUNT(*) AS n FROM $t'))
          .first['n'] as int? ?? 0;
      expect(n, 0, reason: '$t must be wiped by the v5 purge');
    }
    // functional data survives
    final cust = await db.query('customers');
    expect(cust.single['name'], 'Walk-in Customer');
    final users = await db.query('users');
    expect(users, hasLength(1));
    final cursors = await db.query('settings',
        where: "key LIKE 'sync_last_pull_%'");
    expect(cursors, isEmpty);
  });
}
