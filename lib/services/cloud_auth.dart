import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../data/database.dart';
import '../models/user.dart';
import '../state/auth.dart';
import 'hash.dart';
import 'sync_service.dart';

/// How the device's old (pre-cloud) local data should be resolved the
/// first time it is linked to a cloud shop.
class LegacyDataInfo {
  final int sales;
  final int unsyncedProducts;

  /// True when this device was previously linked to a DIFFERENT shop.
  final bool shopMismatch;

  const LegacyDataInfo({
    required this.sales,
    required this.unsyncedProducts,
    required this.shopMismatch,
  });

  bool get hasAnything => sales > 0 || unsyncedProducts > 0 || shopMismatch;
}

/// Shared Supabase-auth flows used by the landing screen (Manager tab)
/// and the settings card. The cloud account IS the Manager account:
///
///   * "Create shop account" signs up + creates the shop (creator = Manager).
///   * "Sign in" opens the same shop on an additional device.
///   * Staff accounts are created INSIDE the app by the Manager
///     (Settings -> Staff accounts) and live on the device.
///
/// After every successful auth we:
///   1. upsert the staff row in app_users
///   2. let the first shop member claim the admin (Manager) role
///   3. remember the shop (id/code/name) on this device
///   4. map the cloud account onto a local staff account — same email and
///      password then work offline on the Staff tab
///   5. kick a sync so the device pulls the shared shop data
class CloudAuth {
  CloudAuth._();

  /// The app-wide AuthProvider, attached once in main().
  static AuthProvider? auth;

  static SupabaseClient get _c => Supabase.instance.client;

  /// Returns null on success, the literal 'confirm' when the account was
  /// created but the email must be confirmed first, or an error message.
  static Future<String?> signUp({
    required String email,
    required String password,
    String? name,
    String? shopName,
  }) async {
    try {
      final res = await _c.auth.signUp(email: email.trim(), password: password);
      if (res.session == null) return 'confirm';
      // New shop account: create the shop boundary + become its Manager.
      if (shopName != null && shopName.trim().isNotEmpty) {
        try {
          await _c.rpc('create_shop',
              params: {'p_name': shopName.trim()});
        } catch (_) {// Idempotent — may already belong to a shop.
        }
      }
      await _afterAuth(displayName: name ?? shopName, password: password);
      return null;
    } on AuthException catch (e) {
      return e.message;
    } catch (_) {
      return 'Sign up failed — check your connection.';
    }
  }

  /// Returns null on success or an error message.
  static Future<String?> signIn({
    required String email,
    required String password,
  }) async {
    try {
      await _c.auth
          .signInWithPassword(email: email.trim(), password: password);
      await _afterAuth();
      return null;
    } on AuthException catch (e) {
      if (e.message.toLowerCase().contains('not confirmed')) {
        return 'Email not confirmed yet — click the link we sent you. '
            '(Or disable "Confirm email" in the Supabase dashboard.)';
      }
      return e.message;
    } catch (_) {
      return 'Sign in failed — check your connection.';
    }
  }

  static Future<void> signOut() async {
    try {
      await _c.auth.signOut();
    } catch (_) {// Session may already be gone.
    }
  }

  /// Cloud role of the signed-in account ('admin' / 'cashier'), or null.
  static Future<String?> currentRole() async {
    try {
      final uid = _c.auth.currentSession?.user.id;
      if (uid == null) return null;
      final row = await _c
          .from('app_users')
          .select('role')
          .eq('id', uid)
          .maybeSingle();
      return row?['role'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// The signed-in user's shop, straight from the cloud (RLS returns only
  /// their own shop). Null when not signed in / offline / no shop yet.
  static Future<Map<String, String>?> fetchMyShop() async {
    try {
      final row = await _c
          .from('shops')
          .select('id,code,name')
          .maybeSingle();
      if (row == null) return null;
      return {
        'id': row['id'] as String,
        'code': (row['code'] as String?) ?? '',
        'name': (row['name'] as String?) ?? 'My Shop',
      };
    } catch (_) {
      return null;
    }
  }

  /// Shop remembered on this device at the last successful sign-in.
  static Future<Map<String, String>> rememberedShop() async {
    final db = await DB.instance();
    final rows = await db.query('settings',
        where: 'key IN (?, ?, ?)',
        whereArgs: ['cloud_shop_id', 'cloud_shop_code', 'cloud_shop_name']);
    final kv = {for (final r in rows) r['key'] as String: r['value'] as String?};
    return {
      'id': kv['cloud_shop_id'] ?? '',
      'code': kv['cloud_shop_code'] ?? '',
      'name': kv['cloud_shop_name'] ?? '',
    };
  }

  /// Detects old local data that does not (yet) belong to the signed-in
  /// shop: pre-cloud sales/products, or a device switching shops.
  /// Returns null when there is nothing to resolve.
  static Future<LegacyDataInfo?> legacyDataInfo() async {
    final db = await DB.instance();
    final salesRows =
        await db.rawQuery('SELECT COUNT(*) AS n FROM sales');
    final sales = (salesRows.first['n'] as int?) ?? 0;
    final prodRows = await db.rawQuery(
        "SELECT COUNT(*) AS n FROM products "
        "WHERE cloud_id IS NULL AND dirty = 1 AND deleted = 0");
    final unsynced = (prodRows.first['n'] as int?) ?? 0;

    final remembered = await rememberedShop();
    final shop = await fetchMyShop();
    final mismatch = shop != null &&
        remembered['id']!.isNotEmpty &&
        remembered['id'] != shop['id'];

    // The legacy question only makes sense for cloud shop members.
    // A local-only device (Staff-tab till, offline mode, no Manager
    // account yet) must NEVER be asked to "start fresh" — that would
    // just wipe a perfectly good local shop.
    final hasCloudShop = shop != null || remembered['id']!.isNotEmpty;
    if (!hasCloudShop) return null;
    if (remembered['id']!.isEmpty && (sales > 0 || unsynced > 0)) {
      return LegacyDataInfo(
          sales: sales, unsyncedProducts: unsynced, shopMismatch: false);
    }
    if (mismatch) {
      return LegacyDataInfo(
          sales: sales, unsyncedProducts: unsynced, shopMismatch: true);
    }
    return null;
  }

  /// Resolves the legacy-data question: [upload] keeps the old data and
  /// pushes it into the shop; otherwise the device is wiped and the shop's
  /// cloud data is pulled fresh.
  static Future<void> resolveLegacyData({required bool upload}) async {
    final db = await DB.instance();
    if (!upload) {
      await DB.wipeAllData();
    }
    // Remember the shop so the question never comes back for it.
    final shop = await fetchMyShop();
    if (shop != null) {
      await db.insert('settings',
          {'key': 'cloud_shop_id', 'value': shop['id'] ?? ''},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await db.insert('settings',
          {'key': 'cloud_shop_code', 'value': shop['code'] ?? ''},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await db.insert('settings',
          {'key': 'cloud_shop_name', 'value': shop['name'] ?? ''},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    // A full sync pulls the shop data (and pushes kept rows).
    SyncService.I.scheduleSync(const Duration(seconds: 1));
  }

  /// Manager tool: erase everything on THIS device, then re-pull the
  /// shop's cloud data. Fixes a device showing stale/foreign data.
  static Future<void> eraseLocalData() async {
    await DB.wipeAllData();
    // Remember the shop again after the wipe.
    await resolveLegacyData(upload: true);
  }

  /// Manager tool: purge the whole shop's sales history in the cloud AND
  /// on every device (the cloud marker propagates via Realtime + sync).
  static Future<String?> clearSalesHistoryEverywhere() async {
    try {
      final db = await DB.instance();
      // 1) wipe local history first so nothing can re-push the old rows
      await SyncService.I.wipeLocalSales(db);
      // 2) purge the cloud (sales cascades to sale_items)
      final zero = '00000000-0000-0000-0000-000000000000';
      await _c.from('stock_movements').delete().neq('id', zero);
      await _c.from('sales').delete().neq('id', zero);
      // 3) tell the other devices (they wipe themselves on next sync)
      final marker = DateTime.now().toUtc().toIso8601String();
      await SyncService.I.gateway.upsertSetting('sales_cleared_at', marker);
      // 4) ack locally + refresh
      await db.insert('settings',
          {'key': 'sales_cleared_ack', 'value': marker},
          conflictAlgorithm: ConflictAlgorithm.replace);
      return null;
    } catch (e) {
      return 'Could not clear cloud sales: ${e.toString().split('\n').first}';
    }
  }

  static Future<void> _afterAuth({String? displayName, String? password}) async {
    final user = _c.auth.currentUser;
    if (user == null) return;

    // 1) make sure a staff row exists in the cloud
    final fallbackName = user.email?.split('@').first ?? 'Staff';
    final name = (displayName?.trim().isNotEmpty ?? false)
        ? displayName!.trim()
        : fallbackName;
    try {
      await _c.from('app_users').upsert(
        {'id': user.id, 'name': name},
        onConflict: 'id',
        ignoreDuplicates: true,
      );
    } catch (_) {// Row may already exist — fine.
    }
    // 2) first shop member becomes the Manager (create_shop already does
    //    this for brand-new shops; this covers legacy accounts).
    try {
      await _c.rpc('claim_admin_if_first');
    } catch (_) {// Admin already claimed — fine.
    }

    // 3) remember the shop on this device
    try {
      final shop = await fetchMyShop();
      if (shop != null) {
        final db = await DB.instance();
        await db.insert('settings',
            {'key': 'cloud_shop_id', 'value': shop['id'] ?? ''},
            conflictAlgorithm: ConflictAlgorithm.replace);
        await db.insert('settings',
            {'key': 'cloud_shop_code', 'value': shop['code'] ?? ''},
            conflictAlgorithm: ConflictAlgorithm.replace);
        await db.insert('settings',
            {'key': 'cloud_shop_name', 'value': shop['name'] ?? ''},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    } catch (_) {// Offline — rememberedShop() stays as it was.
    }

    // 4) map onto a local staff account so this device has a till identity
    String? cloudRole;
    String? cloudName;
    try {
      final row = await _c
          .from('app_users')
          .select('name,role')
          .eq('id', user.id)
          .maybeSingle();
      cloudRole = row?['role'] as String?;
      cloudName = row?['name'] as String?;
    } catch (_) {// Offline-ish; defaults below still work.
    }
    final localRole = cloudRole == 'admin' ? 'admin' : 'cashier';

    try {
      final db = await DB.instance();
      final email = (user.email ?? '').trim().toLowerCase();
      var rows = email.isEmpty
          ? <Map<String, Object?>>[]
          : await db.query('users',
              where: 'email = ?', whereArgs: [email], limit: 1);
      // The device may already be signed in locally under a different email
      // (e.g. admin@stylepos.app) — treat that same person as the owner.
      if (rows.isEmpty && CloudAuth.auth?.user != null) {
        rows = await db.query('users',
            where: 'id = ?', whereArgs: [CloudAuth.auth!.user!.id], limit: 1);
      }

      if (rows.isNotEmpty) {
        final u = AppUser.fromMap(rows.first);
        await db.update('users', {'cloud_id': user.id, 'role': localRole},
            where: 'id = ?', whereArgs: [u.id]);
        await auth?.sessionAs(u.copyWith(role: localRole));
      } else {
        // Brand-new shop account: create the matching local staff row.
        final salt = newSalt();
        final id = await db.insert('users', {
          'name': (cloudName?.trim().isNotEmpty ?? false) ? cloudName! : name,
          'email': email.isEmpty ? 'cloud-${user.id}@cloud.local' : email,
          'pass_hash': password == null ? '' : hashPassword(password, salt),
          'salt': password == null ? '' : salt,
          'role': localRole,
          'active': 1,
          'created_at':
              DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'cloud_id': user.id,
        });
        final created = await db
            .query('users', where: 'id = ?', whereArgs: [id], limit: 1);
        if (created.isNotEmpty) await auth?.sessionAs(AppUser.fromMap(created.first));
      }
    } catch (_) {// Never block the cloud session on local bookkeeping.
    }

    // 5) pull the shop data
    SyncService.I.scheduleSync(const Duration(seconds: 1));
  }
}
