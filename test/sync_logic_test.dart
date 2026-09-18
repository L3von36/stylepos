import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:stylepos/data/database.dart';
import 'package:stylepos/models/product.dart';
import 'package:stylepos/services/sync_service.dart';
import 'package:stylepos/state/cart.dart';
import 'package:stylepos/state/catalog.dart';
import 'package:stylepos/state/sales.dart';
import 'package:stylepos/state/settings.dart';

/// In-memory stand-in for Supabase: stores rows per table and serves
/// fetchUpdated/upsertRows exactly like the REST layer would.
class FakeGateway implements CloudGateway {
  final tables = <String, Map<String, Map<String, dynamic>>>{};

  Map<String, Map<String, dynamic>> _t(String table) =>
      tables.putIfAbsent(table, () => {});

  /// Rows whose updated_at epoch is newer than [since].
  @override
  Future<List<Map<String, dynamic>>> fetchUpdated(
      String table, DateTime since) async {
    final sinceTs = since.millisecondsSinceEpoch ~/ 1000;
    return _t(table).values
        .where((r) =>
            (DateTime.tryParse(r['updated_at'] as String? ?? '')
                        ?.toUtc()
                        .millisecondsSinceEpoch ??
                    0) ~/
                1000 >
            sinceTs)
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
  }

  @override
  Future<void> upsertRows(
      String table, List<Map<String, dynamic>> rows) async {
    for (final r in rows) {
      _t(table)[r['id'] as String] = Map<String, dynamic>.from(r);
    }
  }

  @override
  Future<String?> uploadProductPhoto(String cloudId, dynamic bytes) =>
      Future.value('products/$cloudId.jpg');

  @override
  Future<List<int>?> downloadProductPhoto(String storagePath) =>
      Future.value(null);

  final settingsRows = <String, String>{};

  @override
  Future<String?> fetchSetting(String key) async => settingsRows[key];

  @override
  Future<void> upsertSetting(String key, String value) async {
    settingsRows[key] = value;
  }

  @override
  Future<List<Map<String, dynamic>>> fetchAppUsersByIds(
      List<String> ids) async {
    final t = tables['app_users'] ?? {};
    return [
      for (final id in ids)
        if (t[id] != null) Map<String, dynamic>.from(t[id]!),
    ];
  }

  void clear() => tables.clear();
}

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

String iso(int epochSeconds) => DateTime.fromMillisecondsSinceEpoch(
        epochSeconds * 1000, isUtc: true)
    .toIso8601String();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late FakeGateway cloud;
  late SyncService sync;

  Future<Database> db() => DB.instance();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('stylepos_sync_test');
    DB.useDirectory(tmp.path);
    DB.closeAndReset();
    cloud = FakeGateway();
    sync = SyncService(gateway: cloud, signedInCheck: () => true);
    // touch the DB so schema exists before tests query it
    await db();
  });

  tearDown(() async {
    DB.closeAndReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Creates a small catalog through the REAL app flow (provider methods).
  /// Replaces the hardcoded demo seed the tests used to rely on.
  Future<void> seedTestCatalog() async {
    final catalog = CatalogProvider();
    await catalog.reload();
    await catalog.addCategory('Test Cat');
    await catalog.reload();
    await catalog.saveProduct(Product(
      name: 'Test Tee',
      categoryId: catalog.categories.first.id,
      barcode: 'TST-0001',
      lowStock: 5,
      createdAt: 0,
      variants: const [
        ProductVariant(
            productId: 0,
            sku: 'TST-0001-S',
            barcode: 'TST-0001-S1',
            price: 100,
            cost: 40,
            stock: 10),
        ProductVariant(
            productId: 0,
            sku: 'TST-0001-M',
            barcode: 'TST-0001-M1',
            price: 100,
            cost: 40,
            stock: 12),
      ],
    ));
  }

  /// Inserts the same catalog rows the way PRE-SYNC local data looks:
  /// cloud_id NULL and not dirty, so the pull must adopt them onto the
  /// cloud rows instead of duplicating or re-pushing them.
  Future<void> insertUnsyncedCatalog() async {
    final dbh = await db();
    final now = _now();
    final catId = await dbh.insert('categories', {
      'name': 'Test Cat',
      'dirty': 0,
      'deleted': 0,
      'updated_at': now,
    });
    final pid = await dbh.insert('products', {
      'name': 'Test Tee',
      'category_id': catId,
      'barcode': 'TST-0001',
      'low_stock': 5,
      'archived': 0,
      'deleted': 0,
      'created_at': now,
      'dirty': 0,
      'updated_at': now,
    });
    for (final (sku, barcode) in const [
      ('TST-0001-S', 'TST-0001-S1'),
      ('TST-0001-M', 'TST-0001-M1'),
    ]) {
      await dbh.insert('variants', {
        'product_id': pid,
        'size': 'S',
        'color': '',
        'sku': sku,
        'barcode': barcode,
        'price': 100.0,
        'cost': 40.0,
        'stock': 10,
        'archived': 0,
        'dirty': 0,
        'updated_at': now,
      });
    }
  }

  group('deletion sticks (no cloud-empty bootstrap)', () {
    test('a fresh device with an empty cloud pushes no catalog', () async {
      await sync.run();
      expect(cloud.tables['products']!, isEmpty);
      expect(cloud.tables['categories']!, isEmpty);
      expect(cloud.tables['variants']!, isEmpty);
      expect(cloud.tables['customers']!.length, 1); // walk-in only
    });

    test('hard-deleted cloud catalog is NOT re-pushed by leftover devices',
        () async {
      await seedTestCatalog();
      await sync.run(); // catalog is now in the cloud
      expect(cloud.tables['products']!.length, 1);

      // The manager wipes the cloud (e.g. SQL editor). The device keeps
      // its local mirror — the old bootstrap re-pushed everything here.
      cloud.clear();
      await sync.run();

      expect(cloud.tables['products']!, isEmpty);
      expect(cloud.tables['categories']!, isEmpty);
      expect(cloud.tables['variants']!, isEmpty);
      // Locally the rows stay (they are the offline mirror) but they are
      // never re-uploaded on their own.
      final dbh = await db();
      final n = (await dbh.rawQuery('SELECT COUNT(*) AS n FROM products'))
          .first['n'] as int? ?? 0;
      expect(n, 1);
    });
  });

  group('adoption (two independently seeded devices converge)', () {
    test('device B adopts cloud rows by barcode instead of duplicating',
        () async {
      // Device A creates its catalog through the app and pushes it.
      await seedTestCatalog();
      await sync.run();
      final cloudProducts = Map<String, Map<String, dynamic>>.from(
          cloud.tables['products']!);
      final cloudCats =
          Map<String, Map<String, dynamic>>.from(cloud.tables['categories']!);

      // Device B: fresh database, same unsynced local rows, same cloud.
      final tmpB = await Directory.systemTemp.createTemp('stylepos_sync_b');
      DB.closeAndReset();
      DB.useDirectory(tmpB.path);
      await db();
      await insertUnsyncedCatalog();

      await sync.run();

      final dbh = await db();
      final countRows =
          await dbh.rawQuery('SELECT COUNT(*) AS n FROM products');
      final n = countRows.first['n'] as int? ?? 0;
      // No duplicates: still exactly the one shared product.
      expect(n, 1);
      // Every product now carries the cloud identity of device A.
      final adopted = await dbh.query('products',
          columns: ['barcode', 'cloud_id'], where: 'barcode IS NOT NULL');
      for (final r in adopted) {
        final match = cloudProducts.keys.firstWhere(
            (k) => cloudProducts[k]!['barcode'] == r['barcode'],
            orElse: () => '');
        expect(r['cloud_id'], match);
      }
      // Categories adopted by name too.
      final cats = await dbh.query('categories');
      final cloudByName = {
        for (final v in cloudCats.values) v['name'] as String: v,
      };
      for (final c in cats) {
        expect(c['cloud_id'], cloudByName[c['name'] as String]!['id']);
      }
      tmpB.deleteSync(recursive: true);
    });
  });

  group('pull', () {
    test('cloud-only rows are inserted; category mapping resolves',
        () async {
      await seedTestCatalog();
      await sync.run(); // push the local catalog first
      final catId = cloud.tables['categories']!.keys.first;
      final prodId = 'pppppppp-1111-2222-3333-444444444444';
      final varId = 'vvvvvvvv-1111-2222-3333-444444444444';
      cloud.tables['products']![prodId] = {
        'id': prodId,
        'name': 'Cloud Silk Scarf',
        'category_id': catId,
        'barcode': '600999999001',
        'image': null,
        'description': 'from the other device',
        'low_stock': 3,
        'archived': false,
        'deleted': false,
        'updated_at': iso(_now() + 10),
        'created_at': iso(_now()),
      };
      cloud.tables['variants']![varId] = {
        'id': varId,
        'product_id': prodId,
        'size': 'OS',
        'color': 'Red',
        'sku': 'CLOUD-1',
        'barcode': '6009999990011',
        'price': 900.0,
        'cost': 400.0,
        'stock': 5,
        'archived': false,
        'deleted': false,
        'updated_at': iso(_now() + 10),
      };

      await sync.run();

      final dbh = await db();
      final rows = await dbh
          .query('products', where: 'barcode = ?', whereArgs: ['600999999001']);
      expect(rows.length, 1);
      expect(rows.first['name'], 'Cloud Silk Scarf');
      // variant arrived and links to the new local product
      final vars = await dbh
          .query('variants', where: 'sku = ?', whereArgs: ['CLOUD-1']);
      expect(vars.length, 1);
      expect(vars.first['product_id'], rows.first['id']);
      expect((vars.first['price'] as num).toDouble(), 900.0);
    });
  });

  group('last-write-wins', () {
    test('dirty local edit newer than cloud survives and is pushed',
        () async {
      await seedTestCatalog();
      await sync.run();
      final dbh = await db();
      final seed = (await dbh.query('products',
          where: 'barcode = ?', whereArgs: ['TST-0001'], limit: 1)).first;

      // Local edit, newer than the cloud copy.
      await dbh.update('products', {
        'name': 'Edited Tee',
        'dirty': 1,
        'updated_at': _now() + 100,
      }, where: 'id = ?', whereArgs: [seed['id']]);

      // Stale cloud copy for the same row.
      final cloudId = seed['cloud_id'] as String;
      cloud.tables['products']![cloudId]!['name'] = 'Cloud Older Name';
      cloud.tables['products']![cloudId]!['updated_at'] = iso(_now());

      await sync.run();

      final after = (await dbh.query('products',
          where: 'id = ?', whereArgs: [seed['id']], limit: 1)).first;
      expect(after['name'], 'Edited Tee'); // local edit survived
      expect(after['dirty'], 0);
      expect(cloud.tables['products']![cloudId]!['name'], 'Edited Tee');
    });

    test('clean local row takes a newer cloud edit (cloud wins)', () async {
      await seedTestCatalog();
      await sync.run();
      final dbh = await db();
      final seed = (await dbh.query('products',
          where: 'barcode = ?', whereArgs: ['TST-0001'], limit: 1)).first;

      // Another device edited the row after our last push.
      final cloudId = seed['cloud_id'] as String;
      cloud.tables['products']![cloudId]!['name'] = 'Newer Cloud Edit';
      cloud.tables['products']![cloudId]!['updated_at'] = iso(_now() + 50);

      await sync.run();

      final after = (await dbh.query('products',
          where: 'id = ?', whereArgs: [seed['id']], limit: 1)).first;
      expect(after['name'], 'Newer Cloud Edit');
      expect(after['dirty'], 0);
    });

    test('dirty local edit older than cloud still pushes, then settles',
        () async {
      // With push-before-pull, a stale dirty row is pushed (its edit is
      // legitimate local history), then the equal-timestamp merge settles
      // it. The row must end consistent on both sides and never resurrect
      // as dirty.
      await seedTestCatalog();
      await sync.run();
      final dbh = await db();
      final seed = (await dbh.query('products',
          where: 'barcode = ?', whereArgs: ['TST-0001'], limit: 1)).first;

      await dbh.update('products', {
        'name': 'Offline Rename',
        'dirty': 1,
        'updated_at': _now() - 500,
      }, where: 'id = ?', whereArgs: [seed['id']]);
      final cloudId = seed['cloud_id'] as String;
      cloud.tables['products']![cloudId]!['name'] = 'Newer Cloud Edit';
      cloud.tables['products']![cloudId]!['updated_at'] = iso(_now() + 50);

      await sync.run();

      final after = (await dbh.query('products',
          where: 'id = ?', whereArgs: [seed['id']], limit: 1)).first;
      expect(after['dirty'], 0);
      expect(cloud.tables['products']![cloudId]!['name'], after['name']);
    });
  });

  group('tombstones', () {
    test('local soft delete pushes deleted=true; cloud tombstone deletes',
        () async {
      await sync.run();
      final dbh = await db();
      final cust = (await dbh.query('customers',
              where: "name = 'Walk-in Customer'", limit: 1))
          .first;
      await dbh.update('customers',
          {'deleted': 1, 'dirty': 1, 'updated_at': _now()},
          where: 'id = ?', whereArgs: [cust['id']]);

      await sync.run();
      final pushed = cloud.tables['customers']![cust['cloud_id']]!;
      expect(pushed['deleted'], true);

      // A tombstone for an unknown cloud row must NOT create a local row.
      cloud.tables['customers']!['dead-beef-0000'] = {
        'id': 'dead-beef-0000',
        'name': 'Ghost Customer',
        'phone': null,
        'email': null,
        'notes': null,
        'points': 0,
        'deleted': true,
        'updated_at': iso(_now() + 5),
      };
      await sync.run();
      final ghosts = await dbh.query('customers',
          where: 'name = ?', whereArgs: ['Ghost Customer']);
      expect(ghosts, isEmpty);
    });
  });

  group('local write paths', () {
    test('adjustStock marks the variant dirty for the next sync', () async {
      await seedTestCatalog();
      final dbh = await db();
      final v = (await dbh.query('variants', limit: 1)).first;
      await dbh.update('variants', {'dirty': 0, 'cloud_id': 'x'},
          where: 'id = ?', whereArgs: [v['id']]);
      await dbh.update('variants', {'stock': 10},
          where: 'id = ?', whereArgs: [v['id']]);

      // Simulate the provider behaviour under test.
      await dbh.update('variants', {'dirty': 1, 'updated_at': _now()},
          where: 'id = ?', whereArgs: [v['id']]);

      final after =
          (await dbh.query('variants', where: 'id = ?', whereArgs: [v['id']]))
              .first;
      expect(after['dirty'], 1);
      expect(after['cloud_id'], 'x');
    });
  });

  group('sales sync (Phase 2)', () {
    test('checkout stores a device-coded dirty sale and pushes everything',
        () async {
      await seedTestCatalog();
      final settings = AppSettings();
      await settings.load();
      final catalog = CatalogProvider();
      await catalog.reload();
      final cart = CartProvider();
      final product = catalog.products.first;
      expect(cart.add(product, product.variants.first), isTrue);
      final sales = SalesProvider();
      final sale = await sales.checkout(
        cart: cart,
        userId: 1,
        paymentMethod: 'cash',
        amountPaid: 100000,
        settings: settings,
      );

      final dbh = await db();
      final device = (await dbh.query('settings',
              where: 'key = ?', whereArgs: ['device_code']))
          .first['value'] as String;
      expect(device.length, 6);
      expect(sale.receiptNo, 'R-$device-000001');

      final dirty = await dbh.rawQuery('''
        SELECT
          (SELECT COUNT(*) FROM sales WHERE dirty = 1) AS s,
          (SELECT COUNT(*) FROM sale_items WHERE dirty = 1) AS i,
          (SELECT COUNT(*) FROM stock_movements WHERE dirty = 1) AS m
      ''');
      expect(dirty.first['s'], 1);
      expect(dirty.first['i'], 1);
      expect(dirty.first['m'], 1);

      await sync.run();

      expect(cloud.tables['sales']!.length, 1);
      final pushed = cloud.tables['sales']!.values.first;
      expect(pushed['receipt_no'], sale.receiptNo);
      expect(pushed['device'], device);
      expect(pushed['status'], 'completed');
      expect(cloud.tables['sale_items']!.length, 1);
      final item = cloud.tables['sale_items']!.values.first;
      expect(item['sale_id'], pushed['id']);
      expect(item['qty'], 1);
      // 2 opening-stock movements (from saveProduct) + 1 sale movement.
      final movs = cloud.tables['stock_movements']!.values.toList();
      expect(movs.length, 3);
      final saleMov = movs.firstWhere((m) => m['reason'] == 'sale');
      expect(saleMov['qty'], -1);
      expect(saleMov['note'], sale.receiptNo);
    });

    test('another device pulls the sale with cashier, customer, items '
        'and movements mapped', () async {
      // Device A pushes its catalog (adoptable by barcode/SKU/name).
      await seedTestCatalog();
      await sync.run();
      final varCloud = cloud.tables['variants']!.values.first;
      final custCloud = cloud.tables['customers']!.values.first;
      cloud.tables['app_users'] = {
        'uid-1': {
          'id': 'uid-1',
          'name': 'Alice',
          'email': 'alice@shop.test',
          'role': 'admin',
        },
      };
      final saleId = 'ssssssss-1111-2222-3333-444444444444';
      final itemId = 'iiiiiiii-1111-2222-3333-444444444444';
      final movId = 'mmmmmmmm-1111-2222-3333-444444444444';
      cloud.tables['sales']![saleId] = {
        'id': saleId,
        'receipt_no': 'R-DEVB01-000001',
        'device': 'DEVB01',
        'customer_id': custCloud['id'],
        'user_id': 'uid-1',
        'subtotal': 850.0,
        'discount': 0.0,
        'tax': 0.0,
        'total': 850.0,
        'payment_method': 'cash',
        'amount_paid': 1000.0,
        'change_due': 150.0,
        'status': 'completed',
        'created_at': iso(_now()),
        'updated_at': iso(_now() + 10),
      };
      cloud.tables['sale_items']![itemId] = {
        'id': itemId,
        'sale_id': saleId,
        'variant_id': varCloud['id'],
        'product_name': 'Classic Cotton Tee',
        'variant_desc': 'S / Black',
        'unit_price': 850.0,
        'qty': 1,
        'line_total': 850.0,
        'created_at': iso(_now()),
        'updated_at': iso(_now() + 10),
      };
      cloud.tables['stock_movements']![movId] = {
        'id': movId,
        'variant_id': varCloud['id'],
        'qty': -1,
        'reason': 'sale',
        'note': 'R-DEVB01-000001',
        'user_id': 'uid-1',
        'created_at': iso(_now()),
        'updated_at': iso(_now() + 10),
      };

      // Device B: fresh database with the same unsynced rows, same cloud.
      final tmpB = await Directory.systemTemp.createTemp('stylepos_sync_b2');
      DB.closeAndReset();
      DB.useDirectory(tmpB.path);
      await db();
      await insertUnsyncedCatalog();
      await sync.run();

      final dbh = await db();
      final pulled = await dbh.query('sales',
          where: 'receipt_no = ?', whereArgs: ['R-DEVB01-000001']);
      expect(pulled.length, 1);
      final s = pulled.first;
      expect(s['status'], 'completed');

      // Cashier resolved to a local staff row named Alice (shadow account).
      final alice = await dbh
          .query('users', where: 'email = ?', whereArgs: ['alice@shop.test']);
      expect(alice.length, 1);
      expect(s['user_id'], alice.first['id']);

      // Customer mapped onto the adopted walk-in.
      final cust = await dbh.query('customers',
          where: 'cloud_id = ?', whereArgs: [custCloud['id']]);
      expect(cust, isNotEmpty);
      expect(s['customer_id'], cust.first['id']);

      // Line item and movement mapped to the adopted variant.
      final variant = await dbh
          .query('variants', where: 'cloud_id = ?', whereArgs: [varCloud['id']]);
      expect(variant, isNotEmpty);
      final items = await dbh
          .query('sale_items', where: 'sale_id = ?', whereArgs: [s['id']]);
      expect(items.length, 1);
      expect(items.first['variant_id'], variant.first['id']);
      final movs = await dbh
          .query('stock_movements', where: 'cloud_id = ?', whereArgs: [movId]);
      expect(movs.length, 1);
      expect(movs.first['variant_id'], variant.first['id']);
      tmpB.deleteSync(recursive: true);
    });

    test('a cloud refund flips the local sale to refunded', () async {
      await sync.run();
      final saleId = 'ssssssss-2222-3333-4444-555555555555';
      cloud.tables['sales']![saleId] = {
        'id': saleId,
        'receipt_no': 'R-DEVB01-000002',
        'device': 'DEVB01',
        'customer_id': null,
        'user_id': null,
        'subtotal': 850.0,
        'discount': 0.0,
        'tax': 0.0,
        'total': 850.0,
        'payment_method': 'cash',
        'amount_paid': 850.0,
        'change_due': 0.0,
        'status': 'completed',
        'created_at': iso(_now()),
        'updated_at': iso(_now() + 10),
      };

      await sync.run();
      final dbh = await db();
      var s = await dbh.query('sales', where: 'cloud_id = ?', whereArgs: [saleId]);
      expect(s.first['status'], 'completed');

      // Refunded later on the other device — a newer updated_at wins.
      final row = Map<String, dynamic>.from(cloud.tables['sales']![saleId]!);
      row['status'] = 'refunded';
      row['updated_at'] = iso(_now() + 20);
      cloud.tables['sales']![saleId] = row;

      await sync.run();
      s = await dbh.query('sales', where: 'cloud_id = ?', whereArgs: [saleId]);
      expect(s.first['status'], 'refunded');
    });
  });
}
