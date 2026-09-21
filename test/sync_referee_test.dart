import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:stylepos/data/database.dart';
import 'package:stylepos/services/sync_service.dart';

/// v1.24.2 sync upgrade contract tests:
///  * P0-1 paginated pulls (consumer side: every row merges, cursor moves)
///  * P0-2 stock referee (delta-only stock, seed/base handling, scoped
///    snapshot guards, own-device guard)
///  * P1-3 scoped remote pulls (realtime-named tables only)
///  * small wins (keep-alive phase jitter bounds, sync health counters)
class FakeGateway implements CloudGateway {
  final tables = <String, Map<String, Map<String, dynamic>>>{};
  final pulledTables = <String>[];

  /// Raw outgoing payloads (pre-merge) per table — push-contract tests
  /// assert against these, not against the stored (merged) rows.
  final payloads = <String, List<Map<String, dynamic>>>{};

  int _seq = 0;

  Map<String, Map<String, dynamic>> _t(String table) =>
      tables.putIfAbsent(table, () => {});

  @override
  Future<List<Map<String, dynamic>>> fetchUpdated(
      String table, DateTime since) async {
    pulledTables.add(table);
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
    payloads.putIfAbsent(table, () => []).addAll(
        [for (final r in rows) Map<String, dynamic>.from(r)]);
    for (final r in rows) {
      // real PostgREST upserts MERGE the payload into the stored row —
      // columns absent from the payload keep their stored values (the
      // stock-less variant push must not erase the cloud stock column).
      final existing = _t(table)[r['id'] as String];
      final merged = {...?existing, ...r};
      _t(table)[r['id'] as String] = merged;
      // the v1.24.2 cloud: NEW movements get a ledger_seq (column default)
      // and the AFTER INSERT trigger applies their delta to the cloud
      // variant's stock ('seed' rows are the base — position only).
      if (table == 'stock_movements' && existing == null) {
        if (merged['ledger_seq'] == null) {
          merged['ledger_seq'] = ++_seq;
        } else {
          _seq = max(_seq, (merged['ledger_seq'] as num).toInt());
        }
        final reason = merged['reason'] as String? ?? '';
        final qty = (merged['qty'] as num?)?.toInt() ?? 0;
        final v = _t('variants')[merged['variant_id'] as String];
        if (v != null) {
          if (reason == 'seed') {
            v['stock_upto'] = merged['ledger_seq'];
          } else if (qty != 0) {
            v['stock'] =
                (((v['stock'] as num?)?.toInt() ?? 0) + qty).clamp(0, 1 << 30);
            v['stock_upto'] = merged['ledger_seq'];
          }
        }
      }
    }
  }

  @override
  Future<String?> uploadProductPhoto(String cloudId, dynamic bytes) async =>
      null;

  @override
  Future<List<int>?> downloadProductPhoto(String storagePath) async => null;

  @override
  Future<String?> fetchSetting(String key) async => null;

  @override
  Future<void> upsertSetting(String key, String value) async {}

  @override
  Future<List<Map<String, dynamic>>> fetchAppUsersByIds(
          List<String> ids) async =>
      const [];
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
    tmp = await Directory.systemTemp.createTemp('stylepos_referee_test');
    DB.useDirectory(tmp.path);
    DB.closeAndReset();
    cloud = FakeGateway();
    sync = SyncService(gateway: cloud, signedInCheck: () => true);
    await db();
  });

  tearDown(() async {
    DB.closeAndReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Seeds one local product + variant (already cloud-adopted) and the
  /// matching cloud rows. [stock] is the local count, [cloudStock] the
  /// cloud's, [cloudUpto] the cloud variant's ledger position. Local
  /// device code becomes DEVA so movement ownership is testable.
  Future<int> seedVariant(
      {required int stock, required int cloudStock, int cloudUpto = 0}) async {
    final dbh = await db();
    final now = _now();
    await dbh.insert('settings',
        {'key': 'device_code', 'value': 'DEVA'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await dbh.insert('categories', {
      'name': 'Cat',
      'cloud_id': 'cat-1',
      'dirty': 0,
      'deleted': 0,
      'updated_at': now,
    });
    await dbh.insert('products', {
      'name': 'Tee',
      'barcode': 'TEE-1',
      'low_stock': 5,
      'archived': 0,
      'deleted': 0,
      'created_at': now,
      'cloud_id': 'prod-1',
      'dirty': 0,
      'updated_at': now,
    });
    final vid = await dbh.insert('variants', {
      'product_id': 1,
      'size': 'M',
      'sku': 'TEE-1-M',
      'barcode': 'TEE-1-M1',
      'price': 100.0,
      'cost': 40.0,
      'stock': stock,
      'archived': 0,
      'deleted': 0,
      'cloud_id': 'var-1',
      'dirty': 0,
      'updated_at': now,
    });
    cloud.tables['variants'] ??= {};
    cloud.tables['variants']!['var-1'] = {
      'id': 'var-1',
      'product_id': 'prod-1',
      'size': 'M',
      'sku': 'TEE-1-M',
      'barcode': 'TEE-1-M1',
      'price': 100.0,
      'cost': 40.0,
      'stock': cloudStock,
      'stock_upto': cloudUpto,
      'archived': false,
      'deleted': false,
      'updated_at': iso(now),
    };
    return vid;
  }

  /// Adds a movement row to the CLOUD ledger (as another device would
  /// have pushed it). [seq] pins its ledger position.
  void cloudMovement(String id,
      {required int qty, required int createdAt, String device = 'DEVB',
      String reason = 'sale', int? seq}) {
    cloud.tables['stock_movements'] ??= {};
    cloud.tables['stock_movements']![id] = {
      'id': id,
      'variant_id': 'var-1',
      'qty': qty,
      'reason': reason,
      'device_id': device,
      'created_at': iso(createdAt),
      'updated_at': iso(createdAt),
      'ledger_seq': ?seq,
    };
  }

  Future<int> localStock() async {
    final dbh = await db();
    // by cloud id: a re-inserted (bootstrap) variant gets a new local id
    final rows = await dbh.query('variants', where: "cloud_id = 'var-1'");
    return rows.first['stock'] as int;
  }

  int cloudStock() =>
      (cloud.tables['variants']!['var-1']!['stock'] as num).toInt();

  group('P0-2 stock referee', () {
    test('variant pushes carry NO absolute stock (deltas are the carrier)',
        () async {
      await seedVariant(stock: 10, cloudStock: 10);
      final dbh = await db();
      await dbh.update('variants',
          {'dirty': 1, 'price': 120.0, 'updated_at': _now() + 1},
          where: 'id = 1');
      await sync.run();
      expect(sync.phase, SyncPhase.idle);
      final pushedVariants = cloud.payloads['variants']!;
      expect(pushedVariants, isNotEmpty);
      for (final p in pushedVariants) {
        expect(p.containsKey('stock'), isFalse,
            reason: 'absolute stock in a variant push is the lost-update '
                'race this protocol removed');
      }
      expect(cloud.payloads['variants']!.first['price'], 120.0);
    });

    test('concurrent sales on two tills converge (deltas commute)', () async {
      // Cloud truth: 10 in stock; DEVB already sold 1 (movement present,
      // ledger seq 1, cloud variant stock = 9, stock_upto = 1). Device A
      // adopted the variant BEFORE that movement (base seq 0, stale 10)
      // and sells 1 concurrently.
      final now = _now();
      await seedVariant(stock: 10, cloudStock: 9, cloudUpto: 1);
      cloudMovement('mv-devb-1', qty: -1, createdAt: now - 5, seq: 1);
      final dbh = await db();
      await dbh.update('variants', {'dirty': 1, 'stock': 9, 'updated_at': now + 1},
          where: 'id = 1');
      await dbh.insert('stock_movements', {
        'variant_id': 1,
        'qty': -1,
        'reason': 'sale',
        'device_id': 'DEVA',
        'created_at': now + 1,
        'dirty': 1,
        'updated_at': now + 1,
      });

      await sync.run();

      // A pushes its -1 movement → referee: cloud 9 → 8 (truth).
      expect(cloudStock(), 8,
          reason: 'the cloud must apply deltas server-side, not accept '
              'last-writer absolute values');
      // A pulls DEVB's -1 onto its locally-dirty variant → 9 - 1 = 8.
      expect(await localStock(), 8);
    });

    test('a fresh device bootstraps from the cloud snapshot without '
        'replaying the ledger (no seed double-count)', () async {
      // No local rows yet beyond the seed helper — simulate a NEW device:
      // wipe the local variant so the pull has to insert it.
      await seedVariant(stock: 0, cloudStock: 8, cloudUpto: 3);
      final dbh = await db();
      await dbh.delete('variants');
      // Cloud ledger: base seed +10 (seq 1), then two sales -1 (seq 2, 3)
      // → 8. The cloud variant row's stock_upto = 3 covers all of them.
      cloudMovement('mv-seed', qty: 10, createdAt: _now() - 30,
          device: 'DEVA', reason: 'seed', seq: 1);
      cloudMovement('mv-old-1', qty: -1, createdAt: _now() - 20, seq: 2);
      cloudMovement('mv-old-2', qty: -1, createdAt: _now() - 10, seq: 3);

      await sync.run();

      // INSERT seeded from the cloud snapshot (8, upto=3); every ledger
      // row at or before the base is already inside that number.
      expect(await localStock(), 8,
          reason: 'snapshot(8) is right; replaying the ledger on top '
              'would double-count history (the v1.24.1 bootstrap bug)');
    });

    test('a remote delta NEWER than the local snapshot applies to a clean '
        'variant', () async {
      final now = _now();
      await seedVariant(stock: 10, cloudStock: 10);
      // variant is clean with base seq 0; the movement is ledger seq 1 —
      // after the snapshot, so it applies
      cloudMovement('mv-new', qty: -2, createdAt: now + 50, seq: 1);
      await sync.run();
      expect(await localStock(), 8);
    });

    test('a movement AT the snapshot position is already inside it and '
        'never applies twice', () async {
      final now = _now();
      await seedVariant(stock: 9, cloudStock: 9, cloudUpto: 1);
      final dbh = await db();
      // this device adopted the variant when the ledger stood at seq 1
      // (that is what stock_upto=1 means) — its local base reflects that
      await dbh.update('variants', {'stock_base_seq': 1}, where: 'id = 1');
      // the snapshot (9) already includes ledger seq 1 — a replay of that
      // same row (e.g. pull cursor rewind) must not decrement again
      cloudMovement('mv-inside', qty: -1, createdAt: now - 1, seq: 1);
      await sync.run();
      expect(await localStock(), 9);
    });

    test('a remote delta applies to a locally-DIRTY variant even when the '
        'movement predates the local edit', () async {
      final now = _now();
      await seedVariant(stock: 9, cloudStock: 10);
      final dbh = await db();
      // local unsynced sale: variant dirty, newer than everything
      await dbh.update('variants',
          {'dirty': 1, 'updated_at': now + 200}, where: 'id = 1');
      cloudMovement('mv-devb-2', qty: -1, createdAt: now + 5, seq: 1);
      await sync.run();
      expect(await localStock(), 8,
          reason: 'the movement is after the local snapshot position, so '
              'it stacks even on a locally-edited variant (concurrent-sale '
              'convergence)');
    });

    test('own-device movements coming back down never re-apply', () async {
      final now = _now();
      await seedVariant(stock: 10, cloudStock: 10);
      // movement carries THIS device's tag but the local row is gone
      // (reinstall scenario) — the tag must prevent a double-apply.
      cloudMovement('mv-own', qty: -1, createdAt: now + 50, device: 'DEVA',
          seq: 1);
      await sync.run();
      expect(await localStock(), 10);
    });

    test('the referee skips seed rows AND the patch base keeps the ledger '
        'consistent', () async {
      final now = _now();
      await seedVariant(stock: 10, cloudStock: 10);
      // a cloud-side seed (base row) must not change local stock even
      // though its ledger position is after the local snapshot
      cloudMovement('mv-seed-2', qty: 10, createdAt: now + 50,
          reason: 'seed', seq: 1);
      await sync.run();
      expect(await localStock(), 10);
      // and the fake referee ignored it too:
      expect(cloudStock(), 10);
    });
  });

  group('P0-1 paginated pull (consumer contract)', () {
    test('a pull larger than one page merges fully and advances the cursor',
        () async {
      final now = _now();
      final t = cloud.tables.putIfAbsent('customers', () => {});
      for (var i = 0; i < 1100; i++) {
        t['cust-$i'] = {
          'id': 'cust-$i',
          'name': 'Customer $i',
          'phone': null,
          'points': 0,
          'deleted': false,
          'created_at': iso(now),
          'updated_at': iso(now + 1),
        };
      }
      await sync.run();
      final dbh = await db();
      final n = (await dbh.rawQuery(
              "SELECT COUNT(*) AS n FROM customers "
              "WHERE cloud_id LIKE 'cust-%'"))
          .first['n'] as int;
      expect(n, 1100, reason: 'no row may be silently dropped past the '
          'PostgREST page size');
      final cursor = int.parse((await dbh.query('settings',
              where: 'key = ?',
              whereArgs: ['sync_last_pull_customers']))
          .first['value'] as String);
      expect(cursor, now - 1, reason: 'cursor = max(updated_at) - 2s rewind');
      expect(sync.rowsPulledToday, greaterThanOrEqualTo(1100));
    });
  });

  group('P1-3 scoped remote pulls', () {
    test('a remote realtime event pulls ONLY the table that changed',
        () async {
      await seedVariant(stock: 5, cloudStock: 5);
      sync.scheduleRemoteSync('sales');
      addTearDown(sync.dispose); // cancels the armed debounce timer
      await sync.run();
      expect(cloud.pulledTables, ['sales'],
          reason: 'one sale on another till must not re-fetch 17 tables');
    });

    test('a local edit promotes the pending cycle back to a full pull',
        () async {
      await seedVariant(stock: 5, cloudStock: 5);
      sync.scheduleRemoteSync('sales');
      sync.scheduleSync(); // local edit lands while the debounce is armed
      addTearDown(sync.dispose);
      await sync.run();
      expect(cloud.pulledTables, containsAll(
          ['categories', 'products', 'variants', 'sales']));
    });

    test('a manual sync always pulls everything', () async {
      await seedVariant(stock: 5, cloudStock: 5);
      sync.scheduleRemoteSync('sales');
      addTearDown(sync.dispose);
      await sync.run(manual: true);
      expect(cloud.pulledTables, containsAll(
          ['categories', 'products', 'variants', 'customers',
            'sale_items', 'stock_movements']));
    });
  });

  group('small wins', () {
    test('keep-alive phase jitter stays inside 30-60s', () {
      final r1 = Random(7);
      for (var i = 0; i < 200; i++) {
        final d = keepAlivePhaseOffset(r1);
        expect(d.inSeconds, inInclusiveRange(30, 60));
      }
      // two generators diverge (lockstep tills impossible)
      var allSame = true;
      final a = keepAlivePhaseOffset(Random(1)).inSeconds;
      for (var i = 0; i < 20; i++) {
        if (keepAlivePhaseOffset(Random(i + 2)).inSeconds != a) allSame = false;
      }
      expect(allSame, isFalse);
    });

    test('sync health counters count a real cycle and persist', () async {
      await seedVariant(stock: 10, cloudStock: 10);
      final dbh = await db();
      await dbh.update('variants', {'dirty': 1, 'price': 130.0},
          where: 'id = 1');
      await sync.run();
      expect(sync.cyclesToday, 1);
      expect(sync.cloudCallsToday, greaterThanOrEqualTo(1));
      expect(sync.rowsPushedToday, greaterThanOrEqualTo(1));
      expect(sync.healthLine, contains('1 syncs'));
      final saved = (await dbh.query('settings',
              where: 'key = ?', whereArgs: ['sync_stats_v1']))
          .first['value'] as String;
      expect(saved, contains('"cycles":1'));
      // a NEW engine instance on the same device resumes today's counters
      final fresh = SyncService(gateway: cloud, signedInCheck: () => true);
      await fresh.run();
      expect(fresh.cyclesToday, 2);
    });
  });
}
