import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm, Database;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../data/database.dart';
import 'photo_store.dart';

const _uuid = Uuid();

/// The four catalog tables mirrored to the cloud since Phase 1.
const kSyncTables = ['categories', 'products', 'variants', 'customers'];

/// Sales history tables mirrored to the cloud (Phase 2). Append-only:
/// refunds are a status change, so no tombstone column is needed.
const kSalesTables = ['sales', 'sale_items', 'stock_movements'];

/// Purchasing + commissions tables (Task 28). POs have tombstones;
/// PO items and commissions are append-or-status rows like sales.
const kOpsTables = [
  'suppliers',
  'purchase_orders',
  'purchase_order_items',
  'commissions'
];

/// Staff attendance table mirrored to the cloud (Phase 3).
const kAttendanceTables = ['attendance'];

/// Promotions (coupons + seasonal campaigns) — manager-created on any
/// device, applied at every till (Task 29). Tombstones like suppliers.
const kPromoTables = ['promotions'];

/// How the sync engine talks to the cloud. The real implementation uses
/// Supabase (PostgREST + Storage); tests plug in an in-memory fake.
abstract class CloudGateway {
  /// Rows in [table] whose `updated_at` is newer than [since].
  Future<List<Map<String, dynamic>>> fetchUpdated(String table, DateTime since);

  /// Insert-or-update rows by primary key `id`.
  Future<void> upsertRows(String table, List<Map<String, dynamic>> rows);

  /// Uploads a product photo; returns the storage path it was stored at.
  Future<String?> uploadProductPhoto(String cloudId, Uint8List bytes);

  /// Downloads a product photo; null when unavailable.
  Future<List<int>?> downloadProductPhoto(String storagePath);

  /// Reads one cloud settings row (shop-scoped by RLS); null when missing.
  Future<String?> fetchSetting(String key);

  /// Creates or updates one cloud settings row.
  Future<void> upsertSetting(String key, String value);

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
  Future<String?> uploadProductPhoto(String cloudId, Uint8List bytes) async {
    try {
      const path = 'products'; // objects go to products/<cloudId>.jpg
      final object = '$path/$cloudId.jpg';
      await _c.storage.from('product-images').uploadBinary(
            object,
            bytes,
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

  @override
  Future<String?> fetchSetting(String key) async {
    try {
      final rows = await _c.from('settings').select('value').eq('key', key);
      if (rows.isEmpty) return null;
      return rows.first['value'] as String?;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> upsertSetting(String key, String value) async {
    // shop_id is stamped by the column default (my_shop_id()); the touch
    // trigger keeps updated_at fresh so Realtime notifies other devices.
    await _c.from('settings').upsert(
          {'key': key, 'value': value},
          onConflict: 'shop_id,key',
        );
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
///  * An empty cloud never triggers a bulk re-push: deletions must stick.
///    Only dirty rows (and rows that never matched a cloud row) go up.
class SyncService extends ChangeNotifier {
  SyncService({CloudGateway? gateway, this.signedInCheck})
      : _gateway = gateway ?? SupabaseGateway();

  /// App-wide instance (uses Supabase).
  static final SyncService I = SyncService();

  final CloudGateway _gateway;

  /// Gateway access for services that need a direct cloud call
  /// (e.g. the clear-sales-history settings marker).
  CloudGateway get gateway => _gateway;

  /// Overridable sign-in probe (tests pass `() => true`).
  final bool Function()? signedInCheck;
  StreamSubscription<AuthState>? _authSub;
  Timer? _debounce;
  bool _running = false;
  bool _queued = false;
  bool _started = false;

  /// Safety-net so a missed realtime event (websocket blip, device asleep)
  /// still converges within a minute instead of waiting for a local edit.
  Timer? _keepAlive;

  /// Reconnects a dropped realtime channel with growing backoff.
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;

  /// Re-syncs when the app comes back to the foreground (mobile/web tab).
  AppLifecycleListener? _lifecycle;

  SyncPhase phase = SyncPhase.idle;
  DateTime? lastSyncAt;
  String? lastError;

  /// True while a Supabase Realtime subscription is attached AND confirmed
  /// by the server (SUBSCRIBED status) — the Manager sees sales from other
  /// devices land within seconds.
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
          _reconnectAttempt = 0;
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

    // Safety-net: pull every 45s even if no realtime event arrives.
    _keepAlive ??= Timer.periodic(const Duration(seconds: 45), (_) {
      if (signedIn) scheduleSync();
    });

    // Coming back to the foreground (phone app switch / browser tab):
    // catch up immediately and revive the realtime channel if it died.
    try {
      _lifecycle ??= AppLifecycleListener(onResume: () {
        if (!signedIn) return;
        scheduleSync(const Duration(seconds: 1));
        _startRealtime();
      });
    } catch (_) {// Tests / environments without a binding.
    }

    if (signedIn) {
      scheduleSync(const Duration(seconds: 2));
      _startRealtime();
    }
  }

  /// Listens for cloud row changes (sales made on another device, catalog
  /// edits, refunds, staff changes) and schedules a pull ~1s later. The
  /// SUBSCRIBED status drives the visible "Live" indicator; any error
  /// schedules an automatic reconnect with backoff.
  void _startRealtime() {
    if (_channel != null) {
      // Channel exists but never confirmed / died — reconnect it.
      if (!realtimeLive) _scheduleRealtimeReconnect();
      return;
    }
    try {
      final client = Supabase.instance.client;
      final ch = client.channel('stylepos-live');
      for (final table in [
        ...kSyncTables,
        ...kSalesTables,
        ...kOpsTables,
        ...kAttendanceTables,
        ...kPromoTables,
        'settings',
        'app_users'
      ]) {
        ch.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: table,
          callback: (_) => scheduleSync(const Duration(seconds: 1)),
        );
      }
      ch.subscribe((status, [error]) {
        debugPrint('realtime $status${error == null ? '' : ' ($error)'}');
        if (status == RealtimeSubscribeStatus.subscribed) {
          _reconnectAttempt = 0;
          _reconnectTimer?.cancel();
          if (!realtimeLive) {
            realtimeLive = true;
            notifyListeners();
          }
          return;
        }
        // A per-table config rejection (e.g. app_users before the user
        // runs patch5 SQL) arrives as channelError AFTER a successful
        // join. The channel itself is healthy — every published table
        // still streams — so do NOT reconnect-loop here. patch5 fixes it.
        final msg = error?.toString() ?? '';
        final configRejection = status == RealtimeSubscribeStatus.channelError &&
            (msg.contains('Unable to subscribe') ||
                msg.contains('Realtime is enabled'));
        if (configRejection) {
          if (!realtimeLive) {
            realtimeLive = true;
            notifyListeners();
          }
          return;
        }
        // WebSocket-level problem (timedOut / closed / real error).
        if (realtimeLive || identical(_channel, ch)) {
          realtimeLive = false;
          notifyListeners();
          _scheduleRealtimeReconnect();
        }
      });
      _channel = ch;
      notifyListeners();
    } catch (_) {
      // Supabase not initialised or offline — pull-on-demand still works.
    }
  }

  /// Tears down and re-joins the channel after a growing delay
  /// (3s, 10s, 30s, then every 60s; caps at 6 tries — the 45s keep-alive
  /// pull keeps data fresh even when realtime never comes back).
  void _scheduleRealtimeReconnect() {
    _reconnectTimer?.cancel();
    final attempt = _reconnectAttempt += 1;
    if (attempt > 6) return;
    final delay = attempt <= 1
        ? const Duration(seconds: 3)
        : attempt <= 2
            ? const Duration(seconds: 10)
            : attempt <= 4
                ? const Duration(seconds: 30)
                : const Duration(seconds: 60);
    _reconnectTimer = Timer(delay, () async {
      if (!signedIn) return;
      await _removeChannel();
      _startRealtime();
    });
  }

  Future<void> _removeChannel() async {
    final ch = _channel;
    _channel = null;
    realtimeLive = false;
    if (ch != null) {
      try {
        await Supabase.instance.client.removeChannel(ch);
      } catch (_) {// Already gone.
      }
    }
  }

  Future<void> _stopRealtime() async {
    _reconnectTimer?.cancel();
    _reconnectAttempt = 0;
    await _removeChannel();
    notifyListeners();
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _debounce?.cancel();
    _keepAlive?.cancel();
    _reconnectTimer?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  /// Coalesces bursts of local edits into one sync ~4s later.
  void scheduleSync([Duration delay = const Duration(seconds: 4)]) {
    if (!signedIn) return;
    _debounce?.cancel();
    _debounce = Timer(delay, () => run());
  }

  /// Human-friendly one-liner for sync failures. Raw exception text
  /// ("PostgrestException(message: …, code: 42501)") means nothing to a
  /// shop owner — decode the common Supabase/Postgres failure families and
  /// prefix the failing step so the Sync pill tooltip is actionable.
  static String friendlySyncError(String step, Object error) {
    final raw = error.toString();
    final code = RegExp(r'code:\s*([0-9A-Z]+)').firstMatch(raw)?.group(1);
    final lower = raw.toLowerCase();
    if (code == '42501' || lower.contains('row-level security')) {
      return '$step: the cloud blocked a change (permissions). Update the '
          'app, run the latest Supabase patch, then tap the pill to retry.';
    }
    if (code == '23505' || lower.contains('duplicate key')) {
      return '$step: an identical record already exists in the cloud — '
          'it will merge on the next sync.';
    }
    if (code == '23503' || lower.contains('foreign key')) {
      return '$step: waiting for a related record to upload — '
          'the next sync finishes it.';
    }
    if (code == '42P01' ||
        lower.contains('could not find the') ||
        lower.contains('schema cache') ||
        (code != null && code.startsWith('PGRST2'))) {
      return '$step: this app is newer than the cloud database — run the '
          'latest Supabase schema patch SQL, then retry.';
    }
    if (lower.contains('jwt') || lower.contains('unauthorized')) {
      return '$step: your cloud session expired — sign in again.';
    }
    if (lower.contains('socket') ||
        lower.contains('network') ||
        lower.contains('host lookup') ||
        lower.contains('connection') ||
        lower.contains('timed out') ||
        lower.contains('timeout')) {
      return '$step: network hiccup — retrying automatically.';
    }
    return '$step: ${raw.split('\n').first}';
  }

  /// Runs a full push+pull cycle now (no-op when signed out).
  ///
  /// Every step is isolated: one failing table (a row the cloud's RLS
  /// rejected, a transient network blip) must never starve the others.
  /// Before this, a cashier's rejected variant-stock push aborted the
  /// whole cycle — the device froze in a red "Sync issue" state AND
  /// stopped pulling, so sales made elsewhere never appeared.
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
    Object? firstError;
    String? firstErrorStep;
    Future<void> step(String name, Future<void> Function() action) async {
      try {
        await action();
      } catch (e) {
        firstError ??= e;
        firstErrorStep ??= name;
        debugPrint('sync step $name failed: $e');
      }
    }

    // Another device may have cleared the sales history — honour that
    // before anything else so old sales never resurrect here.
    await step('sales clear marker', _applySalesClearMarker);
    // Push order respects foreign keys: parents before children.
    await step('push categories', _pushCategories);
    await step('push products', _pushProducts);
    await step('push variants', _pushVariants);
    await step('push customers', _pushCustomers);
    await step('push sales', _pushSales);
    await step('push sale items', _pushSaleItems);
    await step('push suppliers', _pushSuppliers);
    await step('push purchase orders', _pushPOs);
    await step('push PO items', _pushPOItems);
    await step('push commissions', _pushCommissions);
    await step('push promotions', _pushPromotions);
    await step('push attendance', _pushAttendance);
    // Pull order likewise: parents first so ids resolve.
    await step('pull categories', _pullCategories);
    await step('pull products', _pullProducts);
    await step('pull variants', _pullVariants);
    await step('pull customers', _pullCustomers);
    await step('pull sales', _pullSales);
    await step('pull sale items', _pullSaleItems);
    await step('pull movements', _pullMovements);
    await step('pull suppliers', _pullSuppliers);
    await step('pull purchase orders', _pullPOs);
    await step('pull PO items', _pullPOItems);
    await step('pull commissions', _pullCommissions);
    await step('pull promotions', _pullPromotions);
    await step('pull attendance', _pullAttendance);

    // Rows that never matched anything in the cloud (created before this
    // device first synced, e.g. seed catalog) get pushed as new rows.
    // The second push round is a no-op when nothing was marked.
    await step('mark unsynced rows', () async {
      final db = await _db;
      for (final t in [
        ...kSyncTables,
        ...kSalesTables,
        ...kOpsTables,
        ...kAttendanceTables,
        ...kPromoTables,
      ]) {
        await db.execute('UPDATE $t SET dirty = 1 WHERE cloud_id IS NULL');
      }
    });
    await step('push categories 2', _pushCategories);
    await step('push products 2', _pushProducts);
    await step('push variants 2', _pushVariants);
    await step('push customers 2', _pushCustomers);
    await step('push sales 2', _pushSales);
    await step('push sale items 2', _pushSaleItems);
    await step('push movements 2', _pushMovements);
    await step('push suppliers 2', _pushSuppliers);
    await step('push purchase orders 2', _pushPOs);
    await step('push PO items 2', _pushPOItems);
    await step('push commissions 2', _pushCommissions);
    await step('push promotions 2', _pushPromotions);
    await step('push attendance 2', _pushAttendance);

    // Red "Sync issue" only when at least one step actually failed;
    // failed rows stay dirty and are retried on the next cycle.
    // lastError is the DECODED, human-readable line (step + plain-language
    // cause) — the pill tooltip shows it verbatim, so a shop owner sees
    // "push sales: the cloud blocked a change…" instead of
    // "PostgrestException(message: …, code: 42501)".
    if (firstError != null) {
      phase = SyncPhase.error;
      lastError = friendlySyncError(firstErrorStep ?? 'sync', firstError!);
    } else {
      phase = SyncPhase.idle;
      lastSyncAt = DateTime.now();
    }
    // Refresh the UI with whatever landed locally — even when a push
    // failed, pulled rows are already in SQLite and must be visible.
    try {
      await onSynced?.call();
    } catch (e) {
      debugPrint('onSynced listener failed: $e');
    }
    _running = false;
    notifyListeners();
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

  String? _isoOrNull(int? epochSeconds) =>
      epochSeconds == null || epochSeconds <= 0 ? null : _iso(epochSeconds);

  int? _epochOrNull(dynamic cloudTs) {
    final t = DateTime.tryParse(cloudTs?.toString() ?? '');
    return t == null
        ? null
        : t.toUtc().millisecondsSinceEpoch ~/ 1000;
  }

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

  // ------------------------------------------------- sales history clear

  /// Cloud marker timestamp of the last "clear sales history" action, or
  /// null when the shop never cleared.
  Future<String?> _salesClearedMarker() => _gateway.fetchSetting('sales_cleared_at');

  /// If the shop's sales history was cleared on ANOTHER device, wipe the
  /// local sales tables too (otherwise this device would keep — and later
  /// re-push — the old receipts the Manager just purged).
  Future<void> _applySalesClearMarker() async {
    final marker = await _salesClearedMarker();
    if (marker == null || marker.isEmpty) return;
    final db = await _db;
    final ackRows = await db.query('settings',
        where: 'key = ?', whereArgs: ['sales_cleared_ack']);
    final ack = ackRows.isEmpty ? '' : (ackRows.first['value'] as String? ?? '');
    if (ack == marker) return;
    await wipeLocalSales(db);
    await db.insert('settings',
        {'key': 'sales_cleared_ack', 'value': marker},
        conflictAlgorithm: ConflictAlgorithm.replace);
    debugPrint('sales history cleared in the cloud — local copy wiped');
  }

  /// Deletes all local sales history (children first). Cloud deletion is
  /// the caller's job; here we only clean the local mirror.
  Future<void> wipeLocalSales(Database db) async {
    await db.execute('DELETE FROM sale_items');
    await db.execute('DELETE FROM stock_movements');
    await db.execute('DELETE FROM sales');
    // Reset pull cursors so nothing stale is assumed about the cloud.
    for (final t in kSalesTables) {
      await _setLastPull(t, 0);
    }
  }

  Future<List<Map<String, Object?>>> _byCloudId(String table, Object id) async {
    final db = await _db;
    return db.query(table, where: 'cloud_id = ?', whereArgs: [id], limit: 1);
  }

  /// NOTE: there is deliberately NO "empty cloud ⇒ re-push the local
  /// catalog" bootstrap. That behavior resurrected deleted products: as
  /// soon as the cloud looked empty (right after a cleanup), every device
  /// with leftover local rows re-uploaded its whole catalog. Local rows
  /// reach the cloud only when they are dirty (created/edited in the app)
  /// or have no cloud_id yet (see the second push round in [run]).

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

      // Photo: push the local bytes, then reference the storage path.
      String? cloudImage;
      final localImage = r['image'] as String?;
      if (localImage != null) {
        final bytes =
            photoExists(localImage) ? photoReadBytes(localImage) : null;
        if (bytes != null) {
          cloudImage = await _gateway.uploadProductPhoto(cloudId, bytes);
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
        'promo_code': r['promo_code'],
        'promo_discount': (r['promo_discount'] as num? ?? 0).toDouble(),
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
        'unit_cost': (r['unit_cost'] as num? ?? 0).toDouble(),
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

  /// Cloud user id for a LOCAL staff row (commissions stay attributed to
  /// the salesperson even when the manager's device pushes the payout).
  Future<String?> _cloudUserIdFor(int? localUserId) async {
    if (localUserId == null || localUserId <= 0) return null;
    final db = await _db;
    final rows = await db.query('users',
        columns: ['cloud_id'],
        where: 'id = ?',
        whereArgs: [localUserId],
        limit: 1);
    return rows.first['cloud_id'] as String? ?? _cloudUid;
  }

  Future<void> _pushSuppliers() async {
    final db = await _db;
    final rows = await db.query('suppliers', where: 'dirty = 1');
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
        'address': r['address'],
        'notes': r['notes'],
        'created_at': _iso(r['created_at'] as int? ?? 0),
        'deleted': (r['deleted'] as int? ?? 0) == 1,
        'updated_at': _iso(r['updated_at'] as int? ?? 0),
      });
    }
    await _gateway.upsertRows('suppliers', payload);
    for (final e in ids.entries) {
      await db.update('suppliers', {'dirty': 0, 'cloud_id': e.value},
          where: 'id = ?', whereArgs: [e.key]);
    }
  }

  Future<void> _pushPOs() async {
    final db = await _db;
    final rows = await db.query('purchase_orders', where: 'dirty = 1');
    if (rows.isEmpty) return;

    final supCloud = <int, String?>{};
    for (final s in await db.query('suppliers', columns: ['id', 'cloud_id'])) {
      supCloud[s['id'] as int] = s['cloud_id'] as String?;
    }

    final payload = <Map<String, dynamic>>[];
    final ids = <int, String>{};
    for (final r in rows) {
      final cloudId = (r['cloud_id'] as String?) ?? _uuid.v4();
      ids[r['id'] as int] = cloudId;
      payload.add({
        'id': cloudId,
        'supplier_id': supCloud[r['supplier_id'] as int?],
        'status': r['status'],
        'order_date': _isoOrNull(r['order_date'] as int?),
        'expected_date': _isoOrNull(r['expected_date'] as int?),
        'received_date': _isoOrNull(r['received_date'] as int?),
        'notes': r['notes'],
        'created_by': await _cloudUserIdFor(r['created_by'] as int?),
        'created_at': _iso(r['created_at'] as int? ?? 0),
        'deleted': (r['deleted'] as int? ?? 0) == 1,
        'updated_at': _iso(r['updated_at'] as int? ?? 0),
      });
    }
    await _gateway.upsertRows('purchase_orders', payload);
    for (final e in ids.entries) {
      await db.update('purchase_orders', {'dirty': 0, 'cloud_id': e.value},
          where: 'id = ?', whereArgs: [e.key]);
    }
  }

  Future<void> _pushPOItems() async {
    final db = await _db;
    final rows = await db.query('purchase_order_items', where: 'dirty = 1');
    if (rows.isEmpty) return;

    final poCloud = <int, String?>{};
    for (final p in await db
        .query('purchase_orders', columns: ['id', 'cloud_id'])) {
      poCloud[p['id'] as int] = p['cloud_id'] as String?;
    }
    final varCloud = <int, String?>{};
    for (final v in await db.query('variants', columns: ['id', 'cloud_id'])) {
      varCloud[v['id'] as int] = v['cloud_id'] as String?;
    }

    final payload = <Map<String, dynamic>>[];
    final ids = <int, String>{};
    for (final r in rows) {
      final poCloudId = poCloud[r['po_id'] as int];
      if (poCloudId == null) continue; // parent PO not synced yet
      final cloudId = (r['cloud_id'] as String?) ?? _uuid.v4();
      ids[r['id'] as int] = cloudId;
      payload.add({
        'id': cloudId,
        'po_id': poCloudId,
        'variant_id': varCloud[r['variant_id'] as int?],
        'product_name': r['product_name'],
        'variant_desc': r['variant_desc'],
        'sku': r['sku'],
        'qty_ordered': r['qty_ordered'],
        'qty_received': r['qty_received'],
        'unit_cost': (r['unit_cost'] as num? ?? 0).toDouble(),
        'created_at': _iso(r['updated_at'] as int? ?? 0),
        'updated_at': _iso(r['updated_at'] as int? ?? 0),
      });
    }
    if (payload.isNotEmpty) {
      await _gateway.upsertRows('purchase_order_items', payload);
    }
    for (final e in ids.entries) {
      await db.update('purchase_order_items',
          {'dirty': 0, 'cloud_id': e.value},
          where: 'id = ?', whereArgs: [e.key]);
    }
  }

  Future<void> _pushCommissions() async {
    final db = await _db;
    final rows = await db.query('commissions', where: 'dirty = 1');
    if (rows.isEmpty) return;

    final saleCloud = <int, String?>{};
    for (final s in await db.query('sales', columns: ['id', 'cloud_id'])) {
      saleCloud[s['id'] as int] = s['cloud_id'] as String?;
    }

    final payload = <Map<String, dynamic>>[];
    final ids = <int, String>{};
    for (final r in rows) {
      final cloudId = (r['cloud_id'] as String?) ?? _uuid.v4();
      ids[r['id'] as int] = cloudId;
      payload.add({
        'id': cloudId,
        'user_id': await _cloudUserIdFor(r['user_id'] as int?),
        'sale_id': saleCloud[r['sale_id'] as int?],
        'amount': (r['amount'] as num? ?? 0).toDouble(),
        'basis': r['basis'],
        'status': r['status'],
        'note': r['note'],
        'period': r['period'],
        'paid_at': _isoOrNull(r['paid_at'] as int?),
        'created_at': _iso(r['created_at'] as int? ?? 0),
        'updated_at': _iso(r['updated_at'] as int? ?? 0),
      });
    }
    await _gateway.upsertRows('commissions', payload);
    for (final e in ids.entries) {
      await db.update('commissions', {'dirty': 0, 'cloud_id': e.value},
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
    final device = await _deviceCode();

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
        'device_id': r['device_id'] ?? device,
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

  /// Promotions: manager-created, applied on every till.
  Future<void> _pushPromotions() async {
    final db = await _db;
    final rows = await db.query('promotions', where: 'dirty = 1');
    if (rows.isEmpty) return;
    final payload = <Map<String, dynamic>>[];
    final ids = <int, String>{};
    for (final r in rows) {
      final cloudId = (r['cloud_id'] as String?) ?? _uuid.v4();
      ids[r['id'] as int] = cloudId;
      payload.add({
        'id': cloudId,
        'name': r['name'],
        'code': r['code'],
        'kind': r['kind'],
        'type': r['type'],
        'value': (r['value'] as num? ?? 0).toDouble(),
        'min_subtotal': (r['min_subtotal'] as num? ?? 0).toDouble(),
        'starts_at': _isoOrNull(r['starts_at'] as int?),
        'ends_at': _isoOrNull(r['ends_at'] as int?),
        'usage_limit': r['usage_limit'],
        'used_count': r['used_count'],
        'active': (r['active'] as int? ?? 1) == 1,
        'created_at': _iso(r['created_at'] as int? ?? 0),
        'deleted': (r['deleted'] as int? ?? 0) == 1,
        'updated_at': _iso(r['updated_at'] as int? ?? 0),
      });
    }
    await _gateway.upsertRows('promotions', payload);
    for (final e in ids.entries) {
      await db.update('promotions', {'dirty': 0, 'cloud_id': e.value},
          where: 'id = ?', whereArgs: [e.key]);
    }
  }

  Future<void> _pushAttendance() async {
    final db = await _db;
    final rows = await db.query('attendance', where: 'dirty = 1');
    if (rows.isEmpty) return;

    final userCloud = <int, String?>{};
    for (final u in await db.query('users', columns: ['id', 'cloud_id'])) {
      userCloud[u['id'] as int] = u['cloud_id'] as String?;
    }

    final payload = <Map<String, dynamic>>[];
    final ids = <int, String>{};
    for (final r in rows) {
      final userCloudId = userCloud[r['user_id'] as int?];
      if (userCloudId == null) continue; // user not cloud-mapped yet
      final cloudId = (r['cloud_id'] as String?) ?? _uuid.v4();
      ids[r['id'] as int] = cloudId;
      payload.add({
        'id': cloudId,
        'user_id': userCloudId,
        'clock_in': _iso(r['clock_in'] as int? ?? 0),
        'clock_out': r['clock_out'] != null ? _iso(r['clock_out'] as int) : null,
        'created_at': _iso(r['clock_in'] as int? ?? 0),
        'updated_at': _iso(r['updated_at'] as int? ?? 0),
      });
    }
    if (payload.isNotEmpty) {
      await _gateway.upsertRows('attendance', payload);
    }
    for (final e in ids.entries) {
      await db.update('attendance', {'dirty': 0, 'cloud_id': e.value},
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

  Future<void> _pullSuppliers() async {
    await _pullTable('suppliers', (r, ts) => _mergeSupplier(r, ts));
  }

  Future<void> _pullPOs() async {
    await _pullTable('purchase_orders', (r, ts) => _mergePO(r, ts));
  }

  Future<void> _pullPOItems() async {
    await _pullTable('purchase_order_items', (r, ts) => _mergePOItem(r, ts));
  }

  Future<void> _pullCommissions() async {
    await _pullTable('commissions', (r, ts) => _mergeCommission(r, ts));
  }

  Future<void> _pullPromotions() async {
    await _pullTable('promotions', (r, ts) => _mergePromotion(r, ts));
  }

  Future<void> _pullAttendance() async {
    await _pullTable('attendance', (r, ts) => _mergeAttendance(r, ts));
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
          'promo_code': r['promo_code'],
          'promo_discount': (r['promo_discount'] as num? ?? 0).toDouble(),
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
      'unit_cost': (r['unit_cost'] as num? ?? 0).toDouble(),
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
    final variantId = v.first['id'] as int;
    final delta = r['qty'] as int? ?? 0;
    await db.insert('stock_movements', {
      'variant_id': variantId,
      'qty': delta,
      'reason': r['reason'] ?? 'adjust',
      'note': r['note'],
      'user_id': userId,
      'created_at': _epoch(r['created_at']),
      'cloud_id': r['id'],
      'device_id': r['device_id'] as String?,
      'dirty': 0,
      'updated_at': cloudTs,
    });
    // Delta-based stock synchronization: apply this movement's delta to
    // the local variant so multi-device concurrent sales properly decrement
    // stock without losing deltas to last-write-wins collisions.
    if (delta != 0) {
      await db.rawUpdate('''
        UPDATE variants
        SET stock = MAX(stock + ?, 0), sync_version = sync_version + 1, updated_at = ?
        WHERE id = ?
      ''', [delta, cloudTs, variantId]);
    }
  }

  Future<void> _mergeAttendance(Map<String, dynamic> r, int cloudTs) async {
    final db = await _db;
    var rows = await _byCloudId('attendance', r['id']);

    final clockIn = _epoch(r['clock_in']);
    final clockOut = r['clock_out'] != null ? _epoch(r['clock_out']) : null;
    final userId = await _localUserIdFor(r['user_id'] as String?);

    if (rows.isEmpty) {
      // De-duplicate by user_id and clock_in
      rows = await db.query('attendance',
          where: 'user_id = ? AND clock_in = ? AND cloud_id IS NULL',
          whereArgs: [userId, clockIn],
          limit: 1);
      if (rows.isNotEmpty) {
        await db.update('attendance', {'cloud_id': r['id']},
            where: 'id = ?', whereArgs: [rows.first['id']]);
      }
    }

    if (rows.isEmpty) {
      await db.insert('attendance', {
        'user_id': userId,
        'clock_in': clockIn,
        'clock_out': clockOut,
        'cloud_id': r['id'],
        'dirty': 0,
        'updated_at': cloudTs,
      });
      return;
    }

    final local = rows.first;
    final localTs = local['updated_at'] as int? ?? 0;
    if ((local['dirty'] as int? ?? 0) == 1 && localTs >= cloudTs) return;

    await db.update('attendance', {
      'clock_out': clockOut,
      'updated_at': cloudTs,
      'dirty': 0,
    }, where: 'id = ?', whereArgs: [local['id']]);
  }

  // -------------------------------------------------- ops merges (Task 28)

  Future<void> _mergeSupplier(Map<String, dynamic> r, int cloudTs) async {
    final db = await _db;
    var rows = await _byCloudId('suppliers', r['id']);
    if (rows.isEmpty) {
      // Natural-key adoption: same name entered on two devices.
      rows = await db.query('suppliers',
          where: 'name = ? COLLATE NOCASE AND cloud_id IS NULL',
          whereArgs: [r['name']],
          limit: 1);
      if (rows.isNotEmpty) {
        await db.update('suppliers', {'cloud_id': r['id']},
            where: 'id = ?', whereArgs: [rows.first['id']]);
      }
    }
    if (rows.isEmpty) {
      if (_b(r['deleted'])) return;
      await db.insert('suppliers', {
        'name': r['name'],
        'phone': r['phone'],
        'email': r['email'],
        'address': r['address'],
        'notes': r['notes'],
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
    await db.update('suppliers', {
      'name': r['name'],
      'phone': r['phone'],
      'email': r['email'],
      'address': r['address'],
      'notes': r['notes'],
      'deleted': _b(r['deleted']) ? 1 : 0,
      'updated_at': cloudTs,
      'dirty': 0,
    }, where: 'id = ?', whereArgs: [local['id']]);
  }

  Future<void> _mergePO(Map<String, dynamic> r, int cloudTs) async {
    final db = await _db;
    var rows = await _byCloudId('purchase_orders', r['id']);
    if (rows.isEmpty) {
      if (_b(r['deleted'])) return;
      int? supplierId;
      if (r['supplier_id'] != null) {
        final s = await _byCloudId('suppliers', r['supplier_id']);
        if (s.isNotEmpty) supplierId = s.first['id'] as int?;
      }
      final createdBy = await _localUserIdFor(r['created_by'] as String?);
      await db.insert('purchase_orders', {
        'supplier_id': supplierId,
        'status': r['status'] ?? 'draft',
        'order_date': _epochOrNull(r['order_date']),
        'expected_date': _epochOrNull(r['expected_date']),
        'received_date': _epochOrNull(r['received_date']),
        'notes': r['notes'],
        'created_by': createdBy,
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
    int? supplierId = local['supplier_id'] as int?;
    if (r['supplier_id'] != null) {
      final s = await _byCloudId('suppliers', r['supplier_id']);
      supplierId = s.isNotEmpty ? s.first['id'] as int? : null;
    } else {
      supplierId = null;
    }
    await db.update('purchase_orders', {
      'supplier_id': supplierId,
      'status': r['status'] ?? 'draft',
      'order_date': _epochOrNull(r['order_date']),
      'expected_date': _epochOrNull(r['expected_date']),
      'received_date': _epochOrNull(r['received_date']),
      'notes': r['notes'],
      'deleted': _b(r['deleted']) ? 1 : 0,
      'updated_at': cloudTs,
      'dirty': 0,
    }, where: 'id = ?', whereArgs: [local['id']]);
  }

  Future<void> _mergePOItem(Map<String, dynamic> r, int cloudTs) async {
    final db = await _db;
    final existing = await _byCloudId('purchase_order_items', r['id']);

    if (existing.isNotEmpty) {
      // Lines move (receive) — adopt cloud quantity when it is newer.
      final local = existing.first;
      final localTs = local['updated_at'] as int? ?? 0;
      if ((local['dirty'] as int? ?? 0) == 1 && localTs >= cloudTs) return;
      await db.update('purchase_order_items', {
        'qty_received': r['qty_received'] as int? ?? 0,
        'unit_cost': (r['unit_cost'] as num? ?? 0).toDouble(),
        'updated_at': cloudTs,
        'dirty': 0,
      }, where: 'id = ?', whereArgs: [local['id']]);
      return;
    }

    final po = await _byCloudId('purchase_orders', r['po_id']);
    if (po.isEmpty) return; // parent PO not pulled yet; next round

    int? variantId;
    if (r['variant_id'] != null) {
      final v = await _byCloudId('variants', r['variant_id']);
      if (v.isNotEmpty) variantId = v.first['id'] as int?;
    }
    await db.insert('purchase_order_items', {
      'po_id': po.first['id'],
      'variant_id': variantId,
      'product_name': r['product_name'] ?? '',
      'variant_desc': r['variant_desc'] ?? '',
      'sku': r['sku'] ?? '',
      'qty_ordered': r['qty_ordered'] as int? ?? 0,
      'qty_received': r['qty_received'] as int? ?? 0,
      'unit_cost': (r['unit_cost'] as num? ?? 0).toDouble(),
      'cloud_id': r['id'],
      'dirty': 0,
      'updated_at': cloudTs,
    });
  }

  Future<void> _mergeCommission(Map<String, dynamic> r, int cloudTs) async {
    final db = await _db;
    final existing = await _byCloudId('commissions', r['id']);

    if (existing.isNotEmpty) {
      final local = existing.first;
      final localTs = local['updated_at'] as int? ?? 0;
      if ((local['dirty'] as int? ?? 0) == 1 && localTs >= cloudTs) return;
      await db.update('commissions', {
        'status': r['status'] ?? 'pending',
        'paid_at': _epochOrNull(r['paid_at']),
        'updated_at': cloudTs,
        'dirty': 0,
      }, where: 'id = ?', whereArgs: [local['id']]);
      return;
    }

    final userId = await _localUserIdFor(r['user_id'] as String?);
    int? saleId;
    if (r['sale_id'] != null) {
      final s = await _byCloudId('sales', r['sale_id']);
      if (s.isNotEmpty) saleId = s.first['id'] as int?;
    }
    await db.insert('commissions', {
      'user_id': userId,
      'sale_id': saleId,
      'amount': (r['amount'] as num? ?? 0).toDouble(),
      'basis': r['basis'] ?? 'sale',
      'status': r['status'] ?? 'pending',
      'note': r['note'],
      'period': r['period'] ?? '',
      'paid_at': _epochOrNull(r['paid_at']),
      'created_at': _epoch(r['created_at']),
      'cloud_id': r['id'],
      'dirty': 0,
      'updated_at': cloudTs,
    });
  }

  // -------------------------------------------------- promo merges (Task 29)

  Future<void> _mergePromotion(Map<String, dynamic> r, int cloudTs) async {
    final db = await _db;
    var rows = await _byCloudId('promotions', r['id']);
    if (rows.isEmpty) {
      // Natural-key adoption: same code created independently on two
      // devices (the manager may edit promotions from any till).
      final code = (r['code'] as String? ?? '').toUpperCase();
      if (code.isNotEmpty) {
        rows = await db.query('promotions',
            where: 'UPPER(code) = ? AND cloud_id IS NULL AND deleted = 0',
            whereArgs: [code],
            limit: 1);
        if (rows.isNotEmpty) {
          await db.update('promotions', {'cloud_id': r['id']},
              where: 'id = ?', whereArgs: [rows.first['id']]);
        }
      }
    }
    if (rows.isEmpty) {
      if (_b(r['deleted'])) return; // tombstone for an unknown row
      await db.insert('promotions', {
        'name': r['name'] ?? '',
        'code': (r['code'] as String? ?? '').toUpperCase(),
        'kind': r['kind'] ?? 'coupon',
        'type': r['type'] ?? 'percent',
        'value': (r['value'] as num? ?? 0).toDouble(),
        'min_subtotal': (r['min_subtotal'] as num? ?? 0).toDouble(),
        'starts_at': _epochOrNull(r['starts_at']),
        'ends_at': _epochOrNull(r['ends_at']),
        'usage_limit': r['usage_limit'] as int? ?? 0,
        'used_count': r['used_count'] as int? ?? 0,
        'active': _b(r['active']) || r['active'] == null ? 1 : 0,
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
    if ((local['dirty'] as int? ?? 0) == 1 && localTs >= cloudTs) {
      return; // local edit is newer; it will be pushed
    }
    await db.update('promotions', {
      'name': r['name'] ?? local['name'],
      'code': (r['code'] as String? ?? local['code']).toString().toUpperCase(),
      'kind': r['kind'] ?? local['kind'],
      'type': r['type'] ?? local['type'],
      'value': (r['value'] as num? ?? 0).toDouble(),
      'min_subtotal': (r['min_subtotal'] as num? ?? 0).toDouble(),
      'starts_at': _epochOrNull(r['starts_at']),
      'ends_at': _epochOrNull(r['ends_at']),
      'usage_limit': r['usage_limit'] as int? ?? 0,
      'used_count': r['used_count'] as int? ?? local['used_count'],
      'active': _b(r['active']) ? 1 : 0,
      'deleted': _b(r['deleted']) ? 1 : 0,
      'updated_at': cloudTs,
      'dirty': 0,
    }, where: 'id = ?', whereArgs: [local['id']]);
  }

  // ------------------------------------------------------------ photos

  /// Downloads a cloud photo for a brand-new local product.
  Future<({String? localName})?> _takeCloudPhoto(
      String cloudId, String? cloudImage, String? currentLocal) async {
    if (cloudImage == null) return null;
    if (currentLocal != null && photoExists(currentLocal)) {
      return (localName: currentLocal);
    }
    final bytes = await _gateway.downloadProductPhoto(cloudImage);
    if (bytes == null || bytes.isEmpty) return null;
    final name = '$cloudId.jpg';
    try {
      final ref = await photoSave(name, Uint8List.fromList(bytes));
      return (localName: ref);
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
    final fileMissing = localImage == null || !photoExists(localImage);
    if (!changed && !fileMissing) {
      return (localName: localImage);
    }
    final res = await _takeCloudPhoto(cloudId, cloudImage, localImage);
    return (localName: res?.localName);
  }
}
