import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/database.dart';
import '../models/user.dart';
import '../state/auth.dart';
import 'hash.dart';
import 'sync_service.dart';

/// Shared Supabase-auth flows used by BOTH the landing screen (Cloud tab)
/// and the settings card. After every successful auth we:
///   1. upsert the staff row in app_users (name for the cloud staff list)
///   2. let the first shop member claim the admin (Manager) role
///   3. map the cloud account onto a local staff account — same email and
///      password then work offline on the Staff tab
///   4. kick a sync so the device pulls the shared shop data
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
  }) async {
    try {
      final res = await _c.auth.signUp(email: email.trim(), password: password);
      if (res.session == null) return 'confirm';
      await _afterAuth(displayName: name, password: password);
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
      await _afterAuth(password: password);
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
    // 2) first shop member becomes the Manager
    try {
      await _c.rpc('claim_admin_if_first');
    } catch (_) {// Admin already claimed — fine.
    }

    // 3) map onto a local staff account so this device has a till identity
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

    // 4) pull the shop data
    SyncService.I.scheduleSync(const Duration(seconds: 1));
  }
}
