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
      // IMPORTANT: the shop is created INSIDE _afterAuth, AFTER the
      // caller's app_users row exists — create_shop links the shop by
      // UPDATING that row, so the order decides whether the account ever
      // joins its own shop (v1.9.0 had it reversed and orphaned shops).
      return await _afterAuth(
          displayName: name ?? shopName,
          password: password,
          newShopName: shopName);
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
      return await _afterAuth(password: password);
    } on AuthException catch (e) {
      if (e.message.toLowerCase().contains('not confirmed')) {
        return 'Email not confirmed yet — click the link we sent you. '
            '(Or disable "Confirm email" in the Supabase dashboard.)';
      }
      if (e.message.toLowerCase().contains('banned') ||
          e.message.toLowerCase().contains('disabled')) {
        return 'This account has been deactivated. Ask your Manager to '
            'reactivate it.';
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

  // ---- staff management (Manager, cloud-backed) ----

  /// The signed-in Manager's whole staff roster (RLS scopes it to their
  /// shop automatically). Null when not signed in, not the Manager, or
  /// the shop does not exist yet.
  static Future<List<Map<String, dynamic>>?> fetchStaffRoster() async {
    try {
      if (_c.auth.currentSession?.user.id == null) return null;
      if (await currentRole() != 'admin') return null;
      if (await fetchMyShop() == null) return null;
      final rows = await _c
          .from('app_users')
          .select('id,name,role,active,email')
          .order('name');
      return List<Map<String, dynamic>>.from(rows);
    } catch (_) {
      return null;
    }
  }

  /// Creates a real cloud staff account (Supabase auth user + app_users
  /// row in the caller's shop). Returns null on success or the message
  /// from the server (duplicate email, weak password, not the Manager…).
  static Future<String?> createStaff({
    required String email,
    required String password,
    required String name,
    required String role,
  }) async {
    try {
      await _c.rpc('create_staff_account', params: {
        'p_email': email.trim(),
        'p_password': password,
        'p_name': name.trim(),
        'p_role': role,
      });
      return null;
    } on AuthException catch (e) {
      return e.message;
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('already exists')) {
        return msg.contains('your shop')
            ? 'A staff account with that email already exists in your shop.'
            : 'An account with that email already exists.';
      }
      if (msg.contains('Manager')) return msg.split('\n').first;
      if (msg.contains('valid email')) return 'Enter a valid email address.';
      if (msg.contains('6 characters')) {
        return 'Password must be at least 6 characters.';
      }
      return 'Could not create the staff account — check your connection.';
    }
  }

  /// Resets a cloud staff member's password (they sign in with the new
  /// one on any device). Returns null on success or an error message.
  static Future<String?> resetStaffPassword(String cloudId, String pw) async {
    try {
      await _c.rpc('reset_staff_password',
          params: {'p_uid': cloudId, 'p_password': pw});
      return null;
    } catch (_) {
      return 'Could not reset the cloud password — check your connection.';
    }
  }

  /// Deactivates (bans) or reactivates a cloud staff member everywhere.
  static Future<String?> setStaffActive(String cloudId, bool active) async {
    try {
      await _c.rpc('set_staff_active',
          params: {'p_uid': cloudId, 'p_active': active});
      return null;
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('your own')) return 'You cannot change your own access.';
      return 'Could not update the staff member — check your connection.';
    }
  }

  /// Edits a cloud staff member's name / role. Returns null on success.
  static Future<String?> updateStaff(String cloudId,
      {String? name, String? role}) async {
    try {
      final data = <String, Object?>{
        'name': ?(name != null && name.trim().isNotEmpty ? name.trim() : null),
        'role': ?role,
      };
      if (data.isEmpty) return null;
      await _c.from('app_users').update(data).eq('id', cloudId);
      return null;
    } catch (_) {
      return 'Could not update the staff member — check your connection.';
    }
  }

  /// The signed-in cloud user id, or null when offline / signed out.
  static String? currentUserId() => _c.auth.currentSession?.user.id;

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

  static Future<String?> _afterAuth(
      {String? displayName, String? password, String? newShopName}) async {
    final user = _c.auth.currentUser;
    if (user == null) return null;

    // 1) make sure a staff row exists in the cloud
    final fallbackName = user.email?.split('@').first ?? 'Staff';
    final name = (displayName?.trim().isNotEmpty ?? false)
        ? displayName!.trim()
        : fallbackName;
    try {
      await _c.from('app_users').upsert(
        {'id': user.id, 'name': name, 'email': user.email},
        onConflict: 'id',
        ignoreDuplicates: true,
      );
    } catch (_) {// Row may already exist — fine.
    }

    // 2) create the shop AFTER the app_users row exists (see signUp).
    var pendingShopId = '';
    if (newShopName != null && newShopName.trim().isNotEmpty) {
      try {
        final sid = await _c.rpc('create_shop',
            params: {'p_name': newShopName.trim()});
        pendingShopId = sid?.toString() ?? '';
      } catch (_) {// Idempotent — may already belong to a shop.
      }
    }

    // 3) first shop member becomes the Manager (create_shop already does
    //    this for brand-new shops; this covers legacy accounts).
    try {
      await _c.rpc('claim_admin_if_first');
    } catch (_) {// Admin already claimed — fine.
    }

    // 3b) self-heal accounts whose shop was orphaned by the v1.9.0
    //     signup-order bug: the shop id was remembered at creation but
    //     the account was never linked. link_orphan_shop refuses unless
    //     the shop has no members at all, so this cannot steal shops.
    var shop = await fetchMyShop();
    if (shop == null) {
      try {
        final db = await DB.instance();
        final rows = await db.query('settings',
            where: 'key = ?', whereArgs: ['pending_shop_id']);
        final pid = rows.isEmpty ? '' : (rows.first['value'] ?? '') as String;
        if (pid.isNotEmpty) {
          try {
            await _c.rpc('link_orphan_shop', params: {'p_shop_id': pid});
          } catch (_) {// Already linked / not an orphan — drop the hint.
          }
          shop = await fetchMyShop();
        }
      } catch (_) {// Local settings unavailable — skip healing.
      }
    } else {
      pendingShopId = shop['id'] ?? '';
    }

    // 4) remember the shop on this device (and the healing hint)
    try {
      final db = await DB.instance();
      if (pendingShopId.isNotEmpty) {
        await db.insert('settings',
            {'key': 'pending_shop_id', 'value': pendingShopId},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
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
    } catch (_) {// Offline — rememberedShop() stays as it was.
    }

    // 4) map onto a local staff account so this device has a till identity
    String? cloudRole;
    String? cloudName;
    bool deactivated = false;
    try {
      final row = await _c
          .from('app_users')
          .select('name,role,active')
          .eq('id', user.id)
          .maybeSingle();
      cloudRole = row?['role'] as String?;
      cloudName = row?['name'] as String?;
      deactivated = row != null && row['active'] == false;
    } catch (_) {// Offline-ish; defaults below still work.
    }
    if (deactivated) {
      // The Manager has switched this staff member off — refuse the
      // session instead of opening a till for them.
      try {
        await _c.auth.signOut();
      } catch (_) {// Session may already be gone.
      }
      return 'This account has been deactivated. Ask your Manager to '
          'reactivate it.';
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
        final update = <String, Object?>{
          'cloud_id': user.id,
          'role': localRole,
        };
        // A shadow row (created by sync for sale attribution) has no local
        // password — seed it from this sign-in so the staff member can log
        // in on the Staff tab even when this device is OFFLINE.
        if (password != null &&
            (rows.first['pass_hash'] as String? ?? '').isEmpty) {
          final salt = newSalt();
          update['salt'] = salt;
          update['pass_hash'] = hashPassword(password, salt);
        }
        await db.update('users', update, where: 'id = ?', whereArgs: [u.id]);
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
    return null;
  }
}
