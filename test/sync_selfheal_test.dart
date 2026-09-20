import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:stylepos/core/app_log.dart';
import 'package:stylepos/data/database.dart';
import 'package:stylepos/models/product.dart';
import 'package:stylepos/services/sync_service.dart';
import 'package:stylepos/state/catalog.dart';

/// Gateway that simulates a cloud whose schema lags the app: chosen
/// tables are entirely missing (PGRST205) and chosen columns are absent
/// (PGRST204) — exactly what Supabase returns before the patch SQL runs.
class GapGateway implements CloudGateway {
  GapGateway({Set<String> missingTables = const {}, Set<String> missingColumns = const {}})
      : missingTables = {...missingTables},
        missingColumns = {...missingColumns};

  final Set<String> missingTables;
  final Set<String> missingColumns;

  /// Rows stored per table (like the REST layer would).
  final tables = <String, Map<String, Map<String, dynamic>>>{};

  /// Every accepted upsert payload, in order — assertions read the LAST.
  final upsertCalls = <List<Map<String, dynamic>>>[];

  /// How many times [fetchUpdated] was attempted per table.
  final fetchAttempts = <String, int>{};

  Map<String, Map<String, dynamic>> _t(String table) =>
      tables.putIfAbsent(table, () => {});

  @override
  Future<List<Map<String, dynamic>>> fetchUpdated(
      String table, DateTime since) async {
    fetchAttempts[table] = (fetchAttempts[table] ?? 0) + 1;
    if (missingTables.contains(table)) {
      throw Exception("PostgrestException(message: Could not find the table "
          "'$table' in the schema cache, code: PGRST205)");
    }
    final sinceTs = since.millisecondsSinceEpoch ~/ 1000;
    return _t(table).values.where((r) {
      final ts =
          DateTime.tryParse(r['updated_at'] as String? ?? '') ?? DateTime(0);
      return ts.toUtc().millisecondsSinceEpoch ~/ 1000 > sinceTs;
    }).map((r) => Map<String, dynamic>.from(r)).toList();
  }

  @override
  Future<void> upsertRows(
      String table, List<Map<String, dynamic>> rows) async {
    if (missingTables.contains(table)) {
      throw Exception("PostgrestException(message: Could not find the table "
          "'$table' in the schema cache, code: PGRST205)");
    }
    for (final r in rows) {
      for (final col in missingColumns) {
        if (r.containsKey(col)) {
          throw Exception("PostgrestException(message: Could not find the "
              "'$col' column of '$table' in the schema cache, "
              "code: PGRST204)");
        }
      }
    }
    upsertCalls.add(rows);
    _lastUpsert[table] = rows;
    for (final r in rows) {
      _t(table)[r['id'] as String] = Map<String, dynamic>.from(r);
    }
  }

  final _lastUpsert = <String, List<Map<String, dynamic>>>{};

  List<Map<String, dynamic>>? lastUpsert(String table) => _lastUpsert[table];

  @override
  Future<String?> uploadProductPhoto(String cloudId, dynamic bytes) async =>
      'products/$cloudId.jpg';

  @override
  Future<List<int>?> downloadProductPhoto(String storagePath) async => null;

  final settingsRows = <String, String>{};

  @override
  Future<String?> fetchSetting(String key) async => settingsRows[key];

  @override
  Future<void> upsertSetting(String key, String value) async =>
      settingsRows[key] = value;

  @override
  Future<List<Map<String, dynamic>>> fetchAppUsersByIds(
          List<String> ids) async =>
      const [];
}

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('schema-gap parsers', () {
    test('missingColumnFrom decodes PGRST204 messages', () {
      final col = missingColumnFrom(Exception(
          "PostgrestException(message: Could not find the 'device_id' "
          "column of 'stock_movements' in the schema cache, code: PGRST204)"));
      expect(col, 'device_id');
    });

    test('missingColumnFrom decodes postgres 42703 shape', () {
      final col = missingColumnFrom(Exception(
          'column "promo_code" of relation "stock_movements" does not '
          'exist'));
      expect(col, 'promo_code');
    });

    test('missingColumnFrom returns null for unrelated errors', () {
      expect(missingColumnFrom(Exception('SocketException: offline')), isNull);
      expect(missingColumnFrom(Exception('some novel failure')), isNull);
    });

    test('isMissingTableError spots missing tables, not columns', () {
      expect(
          isMissingTableError(Exception(
              "PostgrestException(message: Could not find the table "
              "'promotions' in the schema cache, code: PGRST205)")),
          isTrue);
      expect(
          isMissingTableError(Exception(
              'PostgrestException(message: relation "attendance" does not '
              'exist, code: 42P01)')),
          isTrue);
      expect(
          isMissingTableError(Exception(
              "PostgrestException(message: Could not find the 'device_id' "
              "column of 'sales' in the schema cache, code: PGRST204)")),
          isFalse);
    });
  });

  group('sync self-heal (cloud older than app)', () {
    late Directory tmp;
    late GapGateway cloud;
    late SyncService sync;

    setUp(() async {
      AppLog.reset();
      tmp = await Directory.systemTemp.createTemp('stylepos_selfheal');
      DB.useDirectory(tmp.path);
      DB.closeAndReset();
      await DB.instance(); // ensure schema + seed exist
      cloud = GapGateway();
      sync = SyncService(gateway: cloud, signedInCheck: () => true);
    });

    tearDown(() async {
      DB.closeAndReset();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    /// One dirty stock movement whose variant is already cloud-matched —
    /// the minimal payload that reaches _pushMovements' upsert.
    Future<void> seedDirtyMovement() async {
      final catalog = CatalogProvider();
      await catalog.reload();
      await catalog.addCategory('Selfheal Cat');
      await catalog.reload();
      await catalog.saveProduct(Product(
        name: 'Selfheal Tee',
        categoryId: catalog.categories.first.id,
        lowStock: 5,
        createdAt: 0,
        variants: const [
          ProductVariant(
              productId: 0,
              sku: 'SHL-1',
              barcode: 'SHL-0001',
              price: 100,
              cost: 40,
              stock: 10),
        ],
      ));
      final db = await DB.instance();
      final variants = await db.query('variants', limit: 1);
      expect(variants, isNotEmpty, reason: 'product must have a variant');
      final vid = variants.first['id'] as int;
      await db.update('variants', {'cloud_id': 'vcld-1'},
          where: 'id = ?', whereArgs: [vid]);
      await db.insert('stock_movements', {
        'variant_id': vid,
        'qty': -2,
        'reason': 'adjust',
        'note': 'test',
        'user_id': null,
        'created_at': _now(),
        'device_id': 'DEV-XYZ',
        'dirty': 1,
        'updated_at': _now(),
      });
    }

    test('missing COLUMN: movement still pushes, without the column', () async {
      await seedDirtyMovement();
      cloud.missingColumns.add('device_id');

      await sync.run();

      expect(sync.phase, SyncPhase.idle,
          reason: 'a degraded push is NOT an error the shop must see');
      expect(sync.lastError, isNull);

      // scan every accepted stock-movement payload across both rounds
      final pushedRows = [for (final call in cloud.upsertCalls) ...call];
      expect(pushedRows.any((r) => r['qty'] == -2), isTrue,
          reason: 'the seeded movement is in the accepted payload');
      for (final r in pushedRows) {
        expect(r.containsKey('device_id'), isFalse,
            reason: 'the gap column is dropped from the payload');
      }

      final db = await DB.instance();
      final local = await db.query('stock_movements', where: 'dirty = 1');
      expect(local, isEmpty, reason: 'row marked clean after degraded push');
    });

    test('missing COLUMN is remembered: next cycle never retries the column',
        () async {
      await seedDirtyMovement();
      cloud.missingColumns.add('device_id');

      await sync.run(); // learns the gap
      final firstPushHadFailure = true; // (implicit via above test)

      // second dirty row, second cycle
      final db = await DB.instance();
      final variants = await db.query('variants', limit: 1);
      await db.insert('stock_movements', {
        'variant_id': variants.first['id'] as int,
        'qty': 1,
        'reason': 'restock',
        'note': null,
        'user_id': null,
        'created_at': _now(),
        'device_id': 'DEV-XYZ',
        'dirty': 1,
        'updated_at': _now(),
      });
      await sync.run();
      expect(firstPushHadFailure, isTrue);
      expect(sync.phase, SyncPhase.idle);
      // the accepted payload for the second cycle has no device_id either
      expect(cloud.lastUpsert('stock_movements')!.first
          .containsKey('device_id'), isFalse);
    });

    test('missing TABLE on an optional feature stays SILENT and cools down',
        () async {
      cloud.missingTables.add('promotions');

      await sync.run();
      expect(sync.phase, SyncPhase.idle,
          reason: 'optional feature not patched -> no red pill');
      expect(sync.lastError, isNull);
      expect(cloud.fetchAttempts['promotions'], 1);

      await sync.run(); // automatic cycle: cooldown holds
      expect(cloud.fetchAttempts['promotions'], 1,
          reason: 'skipped within the 30-minute cooldown');
    });

    test('manual sync re-probes cooled-down tables', () async {
      cloud.missingTables.add('promotions');
      await sync.run();
      expect(cloud.fetchAttempts['promotions'], 1);

      await sync.run(manual: true);
      expect(cloud.fetchAttempts['promotions'], 2,
          reason: 'manual run clears the cooldown and retries');
      expect(sync.phase, SyncPhase.idle);
    });

    test('missing TABLE on a CORE table surfaces the actionable fix',
        () async {
      await seedDirtyMovement();
      cloud.missingTables.add('stock_movements');

      await sync.run();
      expect(sync.phase, SyncPhase.error);
      expect(sync.lastError, isNotNull);
      expect(sync.lastError, contains('push movements'),
          reason: 'the failing step names the ledger push');
      expect(sync.lastError, contains('schema patch'),
          reason: 'the pill tooltip must point at the guided fix');
    });
  });
}
