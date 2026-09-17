import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../data/database.dart';
import 'images.dart';

const _uuid = Uuid();

/// The four catalog tables mirrored to the cloud since Phase 1.
const kSyncTables = ['categories', 'products', 'variants', 'customers'];

/// Sales history tables mirrored to the cloud (Phase 2). Append-only:
/// refunds are a status change, so no tombstone column is needed.
const kSalesTables = ['sales', 'sale_items', 'stock_movements'];

/// How the sync engine talks to the cloud. The real implementation uses
/// Supabase (PostgREST + Storage); tests plug in an in-memory fake.
abstract class CloudGateway {
  /// Rows in [table] whose `updated_at` is newer than [since].
  Future<List<Map<String, dynamic>>> fetchUpdated(String table, DateTime since);

  /// Insert-or-update rows by primary key `id`.
  Future<void> upsertRows(String table, List<Map<String, dynamic>> rows);

  /// Uploads a product photo; returns the storage path it was stored at.
  Future<String?> uploadProductPhoto(String cloudId, String filePath);

  /// Downloads a product photo; null when unavailable.
  Future<List<int>?> downloadProductPhoto(String storagePath);

  /// Cloud staff profiles (app_users) for the given auth ids — used to
  /// attribute pulled sales to the right cashier name on this device.
  Future<List<Map<String, dynamic>>> fetchAppUsersByIds(List<String> ids);
}

/// Supabase-backed gateway (REST + Storage).
class SupabaseGateway implements CloudGateway {
  SupabaseClient get _c => Supabase.instance.client;

  @override
  Future<List<Map<String, dynamic>>> fetchUpdated(
      String table, DateTime since) async {
    final rows = await _c
        .from(table)
        .select()
        .gt('updated_at', since.toUtc().toIso8601String())
        .order('updated_at');
    return [
      for (final r in (rows as List)) Map<String, dynamic>.from(r as Map),
    ];
  }

  @override
  Future<void> upsertRows(String table, List<Map<String, dynamic>> rows) async {
    for (var i = 0; i < rows.length; i += 60) {
      final end = (i + 60 > rows.length) ? rows.length : i + 60;
      await _c.from(table).upsert(rows.sublist(i, end), onConflict: 'id');
    }
  }

  @override
  Future<String?> uploadProductPhoto(String cloudId, String filePath) async {
    try {
      const path = 'products'; // objects go to products/<cloudId>.jpg
      final object = '$path/$cloudId.jpg';
      await _c.storage.from('product-images').upload(
            object,
            File(filePath),
            fileOptions: const FileOptions(
                upsert: true, contentType: 'image/jpeg'),
          );
      return object;
    } catch (e) {
      debugPrint('photo upload failed: $e');
      return null;
    }
  }

  @override
  Future<List<int>?> downloadProductPhoto(String storagePath) async {
    try {
      return await _c.storage.from('product-images').download(storagePath);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> fetchAppUsersByIds(
      List<String> ids) async {
    if (ids.isEmpty) return [];
    try {
      return await _c
          .from('app_users')
          .select('id,name,email,role')
          .inFilter('id', ids);
    } catch (_) {
      return [];
    }
  }
}

enum SyncPhase { idle, syncing, error }

/// Offline-first sync engine: local SQLite stays the brain, the cloud is a
/// mirror for the other devices.
///
/// Rules
///  * Local edits mark rows dirty; sync pushes dirty rows (upsert by UUID).
///  * Pull fetches rows newer than the last pull and merges them.
///  * Conflicts resolve last-write-wins on `updated_at`. A dirty local row
///    newer than the cloud copy stays and is pushed back; an older dirty
///    row loses its edits and takes the cloud version.
///  * Deletes are soft (tombstones) so every device learns about them.
///  * Rows created independently on two devices are matched by natural key
///    (category name / product barcode / variant SKU / customer name+phone)
///    so both devices converge on one cloud identity.
///  * If the cloud is empty but this device has data, the whole catalog is
///    pushed once (bootstrap).
class SyncService extends ChangeNotifier {
  SyncService({CloudGateway? gateway, this.signedInCheck})
      : _gateway = gateway ?? SupabaseGateway();

  /// App-wide instance (uses Supabase).
  static final SyncService I = SyncService();

  final CloudGateway _gateway;

  /// Overridable sign-in probe (tests pass `() => true`).
  final bool Function()? signedInCheck;
  StreamSubscription<AuthState>? _authSub;
  Timer? _debounce;
  bool _running = false;
  bool _queued = false;
  bool _started = false;

  SyncPhase phase = SyncPhase.idle;
  DateTime? lastSyncAt;
  String? lastError;

  /// True while a Supabase Realtime subscription is attached — the Manager
  /// sees sales from other devices land within seconds.
  bool realtimeLive = false;

  RealtimeChannel? _channel;

  /// Called after a successful sync so providers reload from SQLite.
  Future<void> Function()? onSynced;

  bool get isBusy => _running;

  bool get signedIn {
    if (signedInCheck != null) return signedInCheck!();
    try {
      return Supabase.instance.client.auth.currentSession != null;
    } catch (_) {
      return false;
    }
  }

  /// Attach cloud-auth listeners; call once at app startup.
  void start() {
    if (_started) return;
    _started = true;
    try {
      _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((s) {
        if (s.event == AuthChangeEvent.signedIn ||
            s.event == AuthChangeEvent.initialSession) {
          scheduleSync(const Duration(seconds: 2));
          _startRealtime();
        } else if (s.event == AuthChangeEvent.signedOut) {
          _stopRealtime();
        }
        notifyListeners();
      });
    } catch (_) {
      // Supabase not initialised (unit tests) — manual runs still work.
    }
    if (signedIn) {
      scheduleSync(const Duration(seconds: 2));
      _startRealtime();
    }
  }

  /// Listens for cloud row changes (sales made on another device, catalog
  /// edits, refunds) and schedules a pull a moment later.
  void _startRealtime() {
    if (_channel != null) return;
    try {
      final client = Supabase.instance.client;
      final ch = client.channel('stylepos-live');
      for (final table in [...kSyncTables, ...kSalesTables, 'settings']) {
        ch.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: table,
          callback: (_) => scheduleSync(const Duration(seconds: 2)),
        );
      }
      ch.subscribe();
      _channel = ch;
      realtimeLive = true;
      notifyListeners();
    } catch (_) {
      // Supabase not initialised or offline — pull-on-demand still works.
    }
  }

  Future<void> _stopRealtime() async {
    final ch = _channel;
    _channel = null;
    realtimeLive = false;
    if (ch != null) {
      try {
        await Supabase.instance.client.removeChannel(ch);
      } catch (_) {// Already gone.
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _debounce?.cancel();
    super.dispose();
  }

  /// Coalesces bursts of local edits into one sync ~4s later.
  void scheduleSync([Duration delay = const Duration(seconds: 4)]) {
    if (!signedIn) return;
    _debounce?.cancel();
    _debounce = Timer(delay, () => run());
  }

  /// Runs a full push+pull cycle now (no-op when signed out).
  Future<void> run() async {
    if (!signedIn) return;
    if (_running) {
      _queued = true;
      return;
    }
    _running = true;
    phase = SyncPhase.syncing;
    lastError = null;
    notifyListeners();
    try {
      await _bootstrapIfNeeded();
      // Push order respects foreign keys: parents before children.
      await _pushCategories();
      await _pushProducts();
      await _pushVariants();
      await _pushCustomers();
      await _pushSales();
      await _pushSaleItems();
      await _pushMovements();
      // Pull order likewise: parents first so ids resolve.
      await _pullCategories();
      await _pullProducts();
      await _pullVariants();
      await _pullCustomers();
      await _pullSales();
      await _pullSaleItems();
      await _pullMovements();

      // Rows that never matched anything in the cloud (created before this
      // device first synced, e.g. seed catalog) get pushed as new rows.
      // The second push round is a no-op when nothing was marked.
      final db = await _db;
      for (final t in [...kSyncTables, ...kSalesTables]) {
        await db.execute('UPDATE $t SET dirty = 1 WHERE cloud_id IS NULL');
      }
      await _pushCategories();
      await _pushProducts();
      await _pushVariants();
      await _pushCustomers();
      await _pushSales();
      await _pushSaleItems();
      await _pushMovements();

      lastSyncAt = DateTime.now();
      phase = SyncPhase.idle;
      await onSynced?.call();
    } catch (e) {
      phase = SyncPhase.error;
      lastError = e.toString();
    } finally {
      _running = false;
      notifyListeners();
    }
    if (_queued) {
      _queued = false;
      scheduleSync(const Duration(seconds: 1));
    }
  }

  // ------------------------------------------------------------ helpers

  Future<Database> get _db => DB.instance();

  int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  String _iso(int epochSeconds) => DateTime.fromMillisecondsSinceEpoch(
          (epochSeconds <= 0 ? _now() : epochSeconds) * 1000,
          isUtc: true)
      .toIso8601String();

  int _epoch(dynamic cloudTs) {
    final t = DateTime.tryParse(cloudTs?.toString() ?? '');
    return (t?.toUtc().millisecondsSinceEpoch ?? 0) ~/ 1000;
  }

  bool _b(dynamic v) => v == true || v == 1;

  String? get _cloudUid {
    try {
      return Supabase.instance.client.auth.currentSession?.user.id;
    } catch (_) {
      return null;
    }
  }

  /// The per-device receipt prefix stored in settings (mirrors state/sales).
  Future<String> _deviceCode() async {
    final db = await _db;
    final rows =
        await db.query('settings', where: 'key = ?', whereArgs: ['device_code']);
    return rows.isEmpty ? '' : (rows.first['value'] as String? ?? '');
  }

  Future<int> _getLastPull(String table) async {
    final db = await _db;
    final rows = await db.query('settings',
        where: 'key = ?', whereArgs: ['sync_last_pull_$table']);
    if (rows.isEmpty) return 0; // first sync: fetch everything
    return int.tryParse(rows.first['value'] as String? ?? '') ?? 0;
  }

  Future<void> _setLastPull(String table, int epoch) async {
    final db = await _db;
    await db.insert(
        'settings',
        {'key': 'sync_last_pull_$table', 'value': '$epoch'},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, Object?>>> _byCloudId(String table, Object id) async {
    final db = await _db;
    return db.query(table, where: 'cloud_id = ?', whereArgs: [id], limit: 1);
  }

  /// First sync against an empty cloud pushes the whole local catalog once.
  Future<void> _bootstrapIfNeeded() async {
    final cloudRows =
        await _gateway.fetchUpdated('products', DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
    if (cloudRows.isNotEmpty) return;
    final db = await _db;
    final countRows = await db.rawQuery(
        'SELECT COUNT(*) AS n FROM products WHERE deleted = 0');
    final n = countRows.first['n'] as int? ?? 0;
    if (n == 0) return;
    for (final t in kSyncTables) {
      await db.execute('UPDATE $t SET dirty = 1 WHERE deleted = 0');
    }
    for (final t in kSalesTables) {
      await db.execute('UPDATE $t SET dirty = 1');
    }
    await _pushCategories();
    await _pushProducts();
    await _pushVariants();
    await _pushCustomers();
  }

  Future<void> _pushCategories() async {
    final db = await _db;
    final rows = await db.query('categories', where: 'dirty = 1');
    if (rows.isEmpty) return;
    final payload = <Map<String, dynamic>>[];
    final ids = <int, String>{};
    for (final r in rows) {
      final cloudId = (r['cloud_id'] as String?) ?? _uuid.v4();
      ids[r['id'] as int] = cloudId;
      payload.add({
        'id': cloudId,
        'name': r['name'],
        'deleted': (r['deleted'] as int? ?? 0) == 1,
        'updated_at': _iso(r['updated_at'] as int? ?? 0),
      });
    }
    await _gateway.upsertRows('categories', payload);
    for (final e in ids.entries) {
      await db.update('categories', {'dirty': 0, 'cloud_id': e.value},
          where: 'id = ?', whereArgs: [e.key]);
    }
  }

  Future<void> _pushProducts() async {
    final db = await _db;
    final rows = await db.query('products', where: 'dirty = 1');
    if (rows.isEmpty) return;

    final catCloud = <int, String>{};
    for (final c in await db.query('categories', columns: ['id', 'cloud_id'])) {
      final cid = c['cloud_id'] as String?;
      if (cid != null) catCloud[c['id'] as int] = cid;
    }

    final payload = <Map<String, dynamic>>[];
    for (final r in rows) {
      final cloudId = (r['cloud_id'] as String?) ?? _uuid.v4();
      await db.update('products', {'cloud_id': cloudId},
          where: 'id = ?', whereArgs: [r['id']]);

      // Photo: push the local file, then reference the storage path.
      String? cloudImage;
      final localImage = r['image'] as String?;
      if (localImage != null) {
        final f = File(ProductImages.path(localImage));
        if (f.existsSync()) {
          cloudImage = await _gateway.uploadProductPhoto(cloudId, f.path);
        }
      }

      final entry = <String, dynamic>{
        'id': cloudId,
        'name': r['name'],
        'category_id': catCloud[r['category_id'] as int?],
        'barcode': r['barcode'],
        'description': r['description'],
        'low_stock': r['low_stock'],
        'archived': (r['archived'] as int? ?? 0) == 1,
        'deleted': (r['deleted'] as int? ?? 0) == 1,
        'updated_at': _iso(r['updated_at'] as int? ?? 0),
      };
      if (cloudImage != null) {
        entry['image'] = cloudImage; // fresh upload succeeded
      } else if (localImage == null) {
        entry['image'] = null; // user removed the photo
      } // else: upload failed — omit so the cloud photo survives
      payload.add(entry);
      await db.update('products',
          {'dirty': 0, 'cloud_image': cloudImage},
          where: 'id = ?', whereArgs: [r['id']]);
    }
    await _gateway.upsertRows('products', payload);
  }

  Future<void> _pushVariants() async {
    final db = await _db;
    final rows = await db.query('variants', where: 'dirty = 1');
    if (rows.isEmpty) return;

    final prodCloud = <int, String?>{};
    for (final pr in await db.query('products', columns: ['id', 'cloud_id'])) {
      prodCloud[pr['id'] as int] = pr['cloud_id'] as String?;
    }

    final payload = <Map<String, dynamic>>[];
    final ids = <int, String>{};
    for (final r in rows) {
      final productCloudId = prodCloud[r['product_id'] as int];
      if (productCloudId == null) continue; // parent not synced yet; next round
      final cloudId = (r['cloud_id'] as String?) ?? _uuid.v4();
      ids[r['id'] as int] = cloudId;
      payload.add({
        'id': cloudId,
        'product_id': productCloudId,
        'size': r['size'],
        'color': r['color'],
        'sku': r['sku'],
        'barcode': r['barcode'],
        'price': (r['price'] as num? ?? 0).toDouble(),
        'cost': (r['cost'] as num? ?? 0).toDouble(),
        'stock': r['stock'],
        'archived': (r['archived'] as int? ?? 0) == 1,
        'deleted': (r['deleted'] as int? ?? 0) == 1,
        'updated_at': _iso(r['updated_at'] as int? ?? 0),
      });
    }
    if (payload.isNotEmpty) {
      await _gateway.upsertRows('variants', payload);
    }
    for (final e in ids.entries) {
      await db.update('variants', {'dirty': 0, 'cloud_id': e.value},
          where: 'id = ?', whereArgs: [e.key]);
    }
  }

  Future<void> _pushCustomers() async {
    final db = await _db;
    final rows = await db.query('customers', where: 'dirty = 1');
    if (rows.isEmpty) return;
    final payload = <Map<String, dynamic>>[];
    final ids = <int, String>{};
    for (final r in rows) {
      final cloudId = (r['cloud_id'] as String?) ?? _uuid.v4();
      ids[r['id'] as int] = cloudId;
      payload.add({
        'id': cloudId,
        'name': r['name'],
        'phone': r['phone'],
        'email': r['email'],
        'notes': r['notes'],
        'points': r['points'],
        'deleted': (r['deleted'] as int? ?? 0) == 1,
        'updated_at': _iso(r['updated_at'] as int? ?? 0),
      });
    }
    await _gateway.upsertRows('customers', payload);
    for (final e in ids.entries) {
      await db.update('customers', {'dirty': 0, 'cloud_id': e.value},
          where: 'id = ?', whereArgs: [e.key]);
    }
  }

  Future<void> _pushSales() async {
    final db = await _db;
    final rows = await db.query('sales', where: 'dirty = 1');
    if (rows.isEmpty) return;

    final custCloud = <int, String?>{};
    for (final c in await db.query('customers', columns: ['id', 'cloud_id'])) {
      custCloud[c['id'] as int] = c['cloud_id'] as String?;
    }
    final uid = _cloudUid;
    final device = await _deviceCode();

    final payload = <Map<String, dynamic>>[];
    final ids = <int, String>{};
    for (final r in rows) {
      final cloudId = (r['cloud_id'] as String?) ?? _uuid.v4();
      ids[r['id'] as int] = cloudId;
      payload.add({
        'id': cloudId,
        'receipt_no': r['receipt_no'],
        'device': device,
        'customer_id': custCloud[r['customer_id'] as int?],
        'user_id': uid,
        'subtotal': (r['subtotal'] as num? ?? 0).toDouble(),
        'discount': (r['discount'] as num? ?? 0).toDouble(),
        'tax': (r['tax'] as num? ?? 0).toDouble(),
        'total': (r['total'] as num? ?? 0).toDouble(),
        'payment_method': r['payment_method'],
        'amount_paid': (r['amount_paid'] as num? ?? 0).toDouble(),
        'change_due': (r['change_due'] as num? ?? 0).toDouble(),
        'status': r['status'],
        'created_at': _iso(r['created_at'] as int? ?? 0),
        'updated_at': _iso(r['updated_at'] as int? ?? 0),
      });
    }
    await _gateway.upsertRows('sales', payload);
    for (final e in ids.entries) {
      await db.update('sales', {'dirty': 0, 'cloud_id': e.value},
          where: 'id = ?', whereArgs: [e.key]);
    }
  }

  Future<void> _pushSaleItems() async {
    final db = await _db;
    final rows = await db.query('sale_items', where: 'dirty = 1');
    if (rows.isEmpty) return;

    final saleCloud = <int, String?>{};
    for (final s in await db.query('sales', columns: ['id', 'cloud_id'])) {
      saleCloud[s['id'] as int] = s['cloud_id'] as String?;
    }
    final varCloud = <int, String?>{};
    for (final v in await db.query('variants', columns: ['id', 'cloud_id'])) {
      varCloud[v['id'] as int] = v['cloud_id'] as String?;
    }

    final payload = <Map<String, dynamic>>[];
    final ids = <int, String>{};
    for (final r in rows) {
      final saleCloudId = saleCloud[r['sale_id'] as int];
      if (saleCloudId == null) continue; // parent sale not synced yet
      final cloudId = (r['cloud_id'] as String?) ?? _uuid.v4();
      ids[r['id'] as int] = cloudId;
      payload.add({
        'id': cloudId,
        'sale_id': saleCloudId,
        'variant_id': varCloud[r['variant_id'] as int?],
        'product_name': r['product_name'],
        'variant_desc': r['variant_desc'],
        'unit_price': (r['unit_price'] as num? ?? 0).toDouble(),
        'qty': r['qty'],
        'line_total': (r['line_total'] as num? ?? 0).toDouble(),
        'created_at': _iso(r['updated_at'] as int? ?? 0),
        'updated_at': _iso(r['updated_at'] as int? ?? 0),
      });
    }
    if (payload.isNotEmpty) await _gateway.upsertRows('sale_items', payload);
    for (final e in ids.entries) {
      await db.update('sale_items', {'dirty': 0, 'cloud_id': e.value},
          where: 'id = ?', whereArgs: [e.key]);
    }
  }

  Future<void> _pushMovements() async {
    final db = await _db;
    final rows = await db.query('stock_movements', where: 'dirty = 1');
    if (rows.isEmpty) return;

    final varCloud = <int, String?>{};
    for (final v in await db.query('variants', columns: ['id', 'cloud_id'])) {
      varCloud[v['id'] as int] = v['cloud_id'] as String?;
    }
    final uid = _cloudUid;

    final payload = <Map<String, dynamic>>[];
    final ids = <int, String>{};
    for (final r in rows) {
      final varCloudId = varCloud[r['variant_id'] as int?];
      if (varCloudId == null) continue; // variant unknown in the cloud
      final cloudId = (r['cloud_id'] as String?) ?? _uuid.v4();
      ids[r['id'] as int] = cloudId;
      payload.add({
        'id': cloudId,
        'variant_id': varCloudId,
        'qty': r['qty'],
        'reason': r['reason'],
        'note': r['note'],
        'user_id': uid,
        'created_at': _iso(r['created_at'] as int? ?? 0),
        'updated_at': _iso(r['updated_at'] as int? ?? 0),
      });
    }
    if (payload.isNotEmpty) {
      await _gateway.upsertRows('stock_movements', payload);
    }
    for (final e in ids.entries) {
      await db.update('stock_movements', {'dirty': 0, 'cloud_id': e.value},
          where: 'id = ?', whereArgs: [e.key]);
    }
  }

  // ------------------------------------------------------------ PULL

  Future<void> _pullTable(
      String table,
      Future<void> Function(Map<String, dynamic>, int) merge) async {
    final since = await _getLastPull(table);
    final rows = await _gateway.fetchUpdated(
        table, DateTime.fromMillisecondsSinceEpoch(since * 1000, isUtc: true));
    var maxTs = since;
    for (final r in rows) {
      final ts = _epoch(r['updated_at']);
      if (ts > maxTs) maxTs = ts;
      if (ts <= since) continue; // overlap guard (2s rewind window)
      try {
        await merge(r, ts);
      } catch (e) {
        debugPrint('merge $table failed: $e');
      }
    }
    // Small rewind so border rows are re-fetched next time (merge is
    // idempotent), never moving backwards.
    await _setLastPull(table, maxTs > since ? maxTs - 2 : since);
  }

  Future<void> _pullCategories() async {
    await _pullTable('categories', (r, ts) => _mergeCategory(r, ts));
  }

  Future<void> _pullProducts() async {
    await _pullTable('products', (r, ts) => _mergeProduct(r, ts));
  }

  Future<void> _pullVariants() async {
    await _pullTable('variants', (r, ts) => _mergeVariant(r, ts));
  }

  Future<void> _pullCustomers() async {
    await _pullTable('customers', (r, ts) => _mergeCustomer(r, ts));
  }

  Future<void> _pullSales() async {
    await _pullTable('sales', (r, ts) => _mergeSale(r, ts));
  }

  Future<void> _pullSaleItems() async {
    await _pullTable('sale_items', (r, ts) => _mergeSaleItem(r, ts));
  }

  Future<void> _pullMovements() async {
    await _pullTable('stock_movements', (r, ts) => _mergeMovement(r, ts));
  }

  Future<void> _mergeCategory(Map<String, dynamic> r, int cloudTs) async {
    final db = await _db;
    var rows = await _byCloudId('categories', r['id']);
    if (rows.isEmpty) {
      // Natural-key adoption: same name seeded independently on 2 devices.
      rows = await db.query('categories',
          where: 'name = ? AND cloud_id IS NULL',
          whereArgs: [r['name']],
          limit: 1);
      if (rows.isNotEmpty) {
        await db.update('categories', {'cloud_id': r['id']},
            where: 'id = ?', whereArgs: [rows.first['id']]);
      }
    }
    if (rows.isEmpty) {
      if (_b(r['deleted'])) return; // tombstone for an unknown row
      await db.insert('categories', {
        'name': r['name'],
        'cloud_id': r['id'],
        'dirty': 0,
        'deleted': _b(r['deleted']) ? 1 : 0,
        'updated_at': cloudTs,
      });
      return;
    }
    final local = rows.first;
    final localTs = local['updated_at'] as int? ?? 0;
    if ((local['dirty'] as int? ?? 0) == 1 && localTs >= cloudTs) {
      return; // local edit is newer; it will be pushed
    }
    try {
      await db.update('categories', {
        'name': r['name'],
        'deleted': _b(r['deleted']) ? 1 : 0,
        'updated_at': cloudTs,
        'dirty': 0,
      }, where: 'id = ?', whereArgs: [local['id']]);
    } catch (_) {
      // UNIQUE(name) collision with another local category — keep local.
    }
  }

  Future<void> _mergeProduct(Map<String, dynamic> r, int cloudTs) async {
    final db = await _db;
    final cloudId = r['id'] as String;
    var rows = await _byCloudId('products', cloudId);
    if (rows.isEmpty && r['barcode'] != null) {
      rows = await db.query('products',
          where: 'barcode = ? AND cloud_id IS NULL',
          whereArgs: [r['barcode']],
          limit: 1);
      if (rows.isNotEmpty) {
        await db.update('products', {'cloud_id': cloudId},
            where: 'id = ?', whereArgs: [rows.first['id']]);
      }
    }

    if (rows.isEmpty) {
      if (_b(r['deleted'])) return;
      int? catId;
      if (r['category_id'] != null) {
        final c = await _byCloudId('categories', r['category_id']);
        if (c.isNotEmpty) catId = c.first['id'] as int?;
      }
      final img = await _takeCloudPhoto(cloudId, r['image'] as String?, null);
      await db.insert('products', {
        'name': r['name'],
        'category_id': catId,
        'barcode': r['barcode'],
        'image': img?.localName,
        'description': r['description'],
        'low_stock': r['low_stock'] as int? ?? 5,
        'archived': _b(r['archived']) ? 1 : 0,
        'created_at': _epoch(r['created_at']),
        'cloud_id': cloudId,
        'cloud_image': r['image'],
        'dirty': 0,
        'deleted': _b(r['deleted']) ? 1 : 0,
        'updated_at': cloudTs,
      });
      return;
    }

    final local = rows.first;
    final localTs = local['updated_at'] as int? ?? 0;
    if ((local['dirty'] as int? ?? 0) == 1 && localTs >= cloudTs) return;

    int? catId = local['category_id'] as int?;
    if (r['category_id'] != null) {
      final c = await _byCloudId('categories', r['category_id']);
      catId = c.isNotEmpty ? c.first['id'] as int? : null;
    } else {
      catId = null;
    }
    final photo = await _photoAfterCloudWins(
      cloudId: cloudId,
      cloudImage: r['image'] as String?,
      localImage: local['image'] as String?,
      lastCloudImage: local['cloud_image'] as String?,
    );
    await db.update('products', {
      'name': r['name'],
      'category_id': catId,
      'barcode': r['barcode'],
      'image': photo?.localName,
      'cloud_image': r['image'],
      'description': r['description'],
      'low_stock': r['low_stock'] as int? ?? 5,
      'archived': _b(r['archived']) ? 1 : 0,
      'deleted': _b(r['deleted']) ? 1 : 0,
      'updated_at': cloudTs,
      'dirty': 0,
    }, where: 'id = ?', whereArgs: [local['id']]);
  }

  Future<void> _mergeVariant(Map<String, dynamic> r, int cloudTs) async {
    final db = await _db;
    var rows = await _byCloudId('variants', r['id']);
    if (rows.isEmpty && (r['sku'] as String? ?? '').isNotEmpty) {
      // Adopt by SKU within the same (mapped) product.
      final candidates = await db.query('variants',
          where: 'sku = ? AND cloud_id IS NULL', whereArgs: [r['sku']]);
      for (final cand in candidates) {
        final prod = await db.query('products',
            where: 'id = ?', whereArgs: [cand['product_id']], limit: 1);
        if (prod.isNotEmpty &&
            prod.first['cloud_id'] == r['product_id']) {
          await db.update('variants', {'cloud_id': r['id']},
              where: 'id = ?', whereArgs: [cand['id']]);
          rows = [cand];
          break;
        }
      }
    }

    if (rows.isEmpty) {
      if (_b(r['deleted'])) return;
      final prod = await _byCloudId('products', r['product_id']);
      if (prod.isEmpty) return; // parent unknown on this device yet
      await db.insert('variants', {
        'product_id': prod.first['id'],
        'size': r['size'] ?? '',
        'color': r['color'] ?? '',
        'sku': r['sku'] ?? '',
        'barcode': r['barcode'],
        'price': (r['price'] as num? ?? 0).toDouble(),
        'cost': (r['cost'] as num? ?? 0).toDouble(),
        'stock': r['stock'] as int? ?? 0,
        'archived': _b(r['archived']) ? 1 : 0,
        'cloud_id': r['id'],
        'dirty': 0,
        'deleted': _b(r['deleted']) ? 1 : 0,
        'updated_at': cloudTs,
      });
      return;
    }

    final local = rows.first;
    final localTs = local['updated_at'] as int? ?? 0;
    if ((local['dirty'] as int? ?? 0) == 1 && localTs >= cloudTs) return;
    await db.update('variants', {
      'size': r['size'] ?? '',
      'color': r['color'] ?? '',
      'sku': r['sku'] ?? '',
      'barcode': r['barcode'],
      'price': (r['price'] as num? ?? 0).toDouble(),
      'cost': (r['cost'] as num? ?? 0).toDouble(),
      'stock': r['stock'] as int? ?? 0,
      'archived': _b(r['archived']) ? 1 : 0,
      'deleted': _b(r['deleted']) ? 1 : 0,
      'updated_at': cloudTs,
      'dirty': 0,
    }, where: 'id = ?', whereArgs: [local['id']]);
  }

  Future<void> _mergeCustomer(Map<String, dynamic> r, int cloudTs) async {
    final db = await _db;
    var rows = await _byCloudId('customers', r['id']);
    if (rows.isEmpty) {
      // Natural-key adoption: same name + same phone (or both null).
      rows = await db.query('customers',
          where: 'name = ? COLLATE NOCASE AND cloud_id IS NULL '
              'AND ((phone IS NULL AND ? IS NULL) OR phone = ?)',
          whereArgs: [r['name'], r['phone'], r['phone']],
          limit: 1);
      if (rows.isNotEmpty) {
        await db.update('customers', {'cloud_id': r['id']},
            where: 'id = ?', whereArgs: [rows.first['id']]);
      }
    }

    if (rows.isEmpty) {
      if (_b(r['deleted'])) return;
      await db.insert('customers', {
        'name': r['name'],
        'phone': r['phone'],
        'email': r['email'],
        'notes': r['notes'],
        'points': r['points'] as int? ?? 0,
        'created_at': _epoch(r['created_at']),
        'cloud_id': r['id'],
        'dirty': 0,
        'deleted': _b(r['deleted']) ? 1 : 0,
        'updated_at': cloudTs,
      });
      return;
    }

    final local = rows.first;
    final localTs = local['updated_at'] as int? ?? 0;
    if ((local['dirty'] as int? ?? 0) == 1 && localTs >= cloudTs) return;
    await db.update('customers', {
      'name': r['name'],
      'phone': r['phone'],
      'email': r['email'],
      'notes': r['notes'],
      'points': r['points'] as int? ?? 0,
      'deleted': _b(r['deleted']) ? 1 : 0,
      'updated_at': cloudTs,
      'dirty': 0,
    }, where: 'id = ?', whereArgs: [local['id']]);
  }

  // ------------------------------------------------------------ sales merge

  /// Maps a cloud user id (app_users / auth uuid) to a local staff row,
  /// creating a shadow account (that cannot log in locally) when this is
  /// the first sale seen from that colleague — so reports show their name.
  Future<int> _localUserIdFor(String? cloudUid) async {
    if (cloudUid == null || cloudUid.isEmpty) return 0;
    final db = await _db;
    final rows = await db.query('users',
        where: 'cloud_id = ?', whereArgs: [cloudUid], limit: 1);
    if (rows.isNotEmpty) return rows.first['id'] as int;

    final prof = await _gateway.fetchAppUsersByIds([cloudUid]);
    final name =
        prof.isNotEmpty ? (prof.first['name'] as String? ?? 'Staff') : 'Staff';
    final email = prof.isNotEmpty ? prof.first['email'] as String? : null;
    final role = prof.isNotEmpty
        ? (prof.first['role'] as String? ?? 'cashier')
        : 'cashier';

    if (email != null && email.isNotEmpty) {
      final byEmail = await db.query('users',
          where: 'email = ?', whereArgs: [email], limit: 1);
      if (byEmail.isNotEmpty) {
        await db.update('users', {'cloud_id': cloudUid},
            where: 'id = ?', whereArgs: [byEmail.first['id']]);
        return byEmail.first['id'] as int;
      }
    }
    // Shadow user: empty salt/hash means no local password can ever match.
    final id = await db.insert('users', {
      'name': name,
      'email': email ?? 'staff-$cloudUid@cloud.local',
      'pass_hash': '',
      'salt': '',
      'role': role == 'admin' ? 'admin' : 'cashier',
      'active': 1,
      'created_at': _now(),
      'cloud_id': cloudUid,
    });
    return id;
  }

  Future<void> _mergeSale(Map<String, dynamic> r, int cloudTs) async {
    final db = await _db;
    var rows = await _byCloudId('sales', r['id']);

    if (rows.isEmpty) {
      int? customerId;
      if (r['customer_id'] != null) {
        final c = await _byCloudId('customers', r['customer_id']);
        if (c.isNotEmpty) customerId = c.first['id'] as int?;
      }
      final userId = await _localUserIdFor(r['user_id'] as String?);
      try {
        await db.insert('sales', {
          'receipt_no': r['receipt_no'],
          'customer_id': customerId,
          'user_id': userId,
          'subtotal': (r['subtotal'] as num? ?? 0).toDouble(),
          'discount': (r['discount'] as num? ?? 0).toDouble(),
          'tax': (r['tax'] as num? ?? 0).toDouble(),
          'total': (r['total'] as num? ?? 0).toDouble(),
          'payment_method': r['payment_method'] ?? 'cash',
          'amount_paid': (r['amount_paid'] as num? ?? 0).toDouble(),
          'change_due': (r['change_due'] as num? ?? 0).toDouble(),
          'status': r['status'] ?? 'completed',
          'created_at': _epoch(r['created_at']),
          'cloud_id': r['id'],
          'dirty': 0,
          'updated_at': cloudTs,
        });
      } catch (_) {
        // receipt_no UNIQUE collision (should not happen with device codes)
      }
      return;
    }

    final local = rows.first;
    final localTs = local['updated_at'] as int? ?? 0;
    if ((local['dirty'] as int? ?? 0) == 1 && localTs >= cloudTs) return;
    if (local['status'] == r['status']) {
      await db.update('sales', {'updated_at': cloudTs, 'dirty': 0},
          where: 'id = ?', whereArgs: [local['id']]);
      return;
    }
    // Status changed elsewhere (refund) — adopt it.
    await db.update('sales', {
      'status': r['status'] ?? 'completed',
      'updated_at': cloudTs,
      'dirty': 0,
    }, where: 'id = ?', whereArgs: [local['id']]);
  }

  Future<void> _mergeSaleItem(Map<String, dynamic> r, int cloudTs) async {
    final db = await _db;
    final existing = await _byCloudId('sale_items', r['id']);
    if (existing.isNotEmpty) return; // line items are immutable

    final sale = await _byCloudId('sales', r['sale_id']);
    if (sale.isEmpty) return; // parent sale not pulled yet; next round

    int variantId = 0;
    if (r['variant_id'] != null) {
      final v = await _byCloudId('variants', r['variant_id']);
      if (v.isNotEmpty) variantId = v.first['id'] as int;
    }
    await db.insert('sale_items', {
      'sale_id': sale.first['id'],
      'variant_id': variantId,
      'product_name': r['product_name'] ?? '',
      'variant_desc': r['variant_desc'] ?? '',
      'unit_price': (r['unit_price'] as num? ?? 0).toDouble(),
      'qty': r['qty'] as int? ?? 0,
      'line_total': (r['line_total'] as num? ?? 0).toDouble(),
      'cloud_id': r['id'],
      'dirty': 0,
      'updated_at': cloudTs,
    });
  }

  Future<void> _mergeMovement(Map<String, dynamic> r, int cloudTs) async {
    final db = await _db;
    final existing = await _byCloudId('stock_movements', r['id']);
    if (existing.isNotEmpty) return; // ledger rows are immutable

    if (r['variant_id'] == null) return;
    final v = await _byCloudId('variants', r['variant_id']);
    if (v.isEmpty) return; // variant unknown here yet
    final userId = await _localUserIdFor(r['user_id'] as String?);
    await db.insert('stock_movements', {
      'variant_id': v.first['id'],
      'qty': r['qty'] as int? ?? 0,
      'reason': r['reason'] ?? 'adjust',
      'note': r['note'],
      'user_id': userId,
      'created_at': _epoch(r['created_at']),
      'cloud_id': r['id'],
      'dirty': 0,
      'updated_at': cloudTs,
    });
  }

  // ------------------------------------------------------------ photos

  /// Downloads a cloud photo for a brand-new local product.
  Future<({String localName})?> _takeCloudPhoto(
      String cloudId, String? cloudImage, String? currentLocal) async {
    if (cloudImage == null) return null;
    if (currentLocal != null &&
        File(ProductImages.path(currentLocal)).existsSync()) {
      return (localName: currentLocal);
    }
    final bytes = await _gateway.downloadProductPhoto(cloudImage);
    if (bytes == null || bytes.isEmpty) return null;
    final name = '$cloudId.jpg';
    try {
      await File(ProductImages.path(name)).writeAsBytes(bytes, flush: true);
      return (localName: name);
    } catch (_) {
      return null;
    }
  }

  /// Photo decision when the cloud copy wins the merge:
  ///  * cloud path changed (or local file vanished) -> download fresh
  ///  * cloud removed the photo -> remove locally
  ///  * otherwise keep the local copy (no re-download)
  Future<({String? localName})?> _photoAfterCloudWins({
    required String cloudId,
    required String? cloudImage,
    required String? localImage,
    required String? lastCloudImage,
  }) async {
    if (cloudImage == null) {
      return (localName: null);
    }
    final changed = cloudImage != lastCloudImage;
    final fileMissing =
        localImage == null || !File(ProductImages.path(localImage)).existsSync();
    if (!changed && !fileMissing) {
      return (localName: localImage);
    }
    final res = await _takeCloudPhoto(cloudId, cloudImage, localImage);
    return (localName: res?.localName);
  }
}
