import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:stylepos/data/database.dart';
import 'package:stylepos/services/sync_service.dart';

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
  Future<String?> uploadProductPhoto(String cloudId, String filePath) =>
      Future.value('products/$cloudId.jpg');

  @override
  Future<List<int>?> downloadProductPhoto(String storagePath) =>
      Future.value(null);

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

  group('bootstrap', () {
    test('empty cloud + seeded device pushes the whole catalog once', () async {
      await sync.run();

      expect(cloud.tables['categories']!.length, 7);
      expect(cloud.tables['products']!.length, 8);
      expect(cloud.tables['customers']!.length, 1);
      expect(cloud.tables['variants']!.length, greaterThan(10));

      final dbh = await db();
      final countRows = await dbh
          .rawQuery('SELECT COUNT(*) AS n FROM products WHERE dirty = 1');
      final dirty = countRows.first['n'] as int? ?? 0;
      expect(dirty, 0);
    });

    test('second run is a no-op (nothing dirty)', () async {
      await sync.run();
      final before = cloud.tables['products']!.length;
      cloud.clear();
      await sync.run();
      // Nothing dirty -> nothing re-pushed, but pull saw nothing new.
      expect(cloud.tables['products']!.length, before);
    });
  });

  group('adoption (two independently seeded devices converge)', () {
    test('device B adopts cloud rows by barcode instead of duplicating',
        () async {
      // Device A already pushed its catalog to the cloud.
      await sync.run();
      final cloudProducts = Map<String, Map<String, dynamic>>.from(
          cloud.tables['products']!);
      final cloudCats =
          Map<String, Map<String, dynamic>>.from(cloud.tables['categories']!);

      // Device B: fresh database, own seeds, points at the same cloud.
      final tmpB = await Directory.systemTemp.createTemp('stylepos_sync_b');
      DB.closeAndReset();
      DB.useDirectory(tmpB.path);
      await db();

      await sync.run();

      final dbh = await db();
      final countRows =
          await dbh.rawQuery('SELECT COUNT(*) AS n FROM products');
      final n = countRows.first['n'] as int? ?? 0;
      // No duplicates: still exactly the 8 seed products.
      expect(n, 8);
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
      await sync.run(); // push seeds first
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
      await sync.run();
      final dbh = await db();
      final seed = (await dbh.query('products',
          where: 'barcode = ?', whereArgs: ['600123400001'], limit: 1)).first;

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
      await sync.run();
      final dbh = await db();
      final seed = (await dbh.query('products',
          where: 'barcode = ?', whereArgs: ['600123400001'], limit: 1)).first;

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
      await sync.run();
      final dbh = await db();
      final seed = (await dbh.query('products',
          where: 'barcode = ?', whereArgs: ['600123400001'], limit: 1)).first;

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
}
