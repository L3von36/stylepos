import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../data/database.dart';
import '../models/user.dart';
import '../services/hash.dart';

/// Handles login / session persistence / staff account management.
class AuthProvider extends ChangeNotifier {
  AppUser? user;
  bool ready = false;

  /// Reads a persisted session (if any) at startup.
  Future<void> init() async {
    try {
      final db = await DB.instance();
      final rows = await db.query('settings',
          where: 'key = ?', whereArgs: ['session_user_id']);
      final idStr = rows.isEmpty ? null : rows.first['value'] as String?;
      final id = int.tryParse(idStr ?? '');
      if (id != null) {
        final found = await db.query('users',
            where: 'id = ? AND active = 1', whereArgs: [id]);
        if (found.isNotEmpty) {
          user = AppUser.fromMap(found.first);
        }
      }
    } catch (_) {
      // Fresh DB or read failure -> force login.
      user = null;
    }
    ready = true;
    notifyListeners();
  }

  /// Returns null on success, or an error message.
  Future<String?> login(String email, String password) async {
    final db = await DB.instance();
    final rows = await db.query('users',
        where: 'email = ?', whereArgs: [email.trim().toLowerCase()]);
    if (rows.isEmpty) return 'No account found for that email.';
    final u = AppUser.fromMap(rows.first);
    if (!u.active) return 'This account has been deactivated.';
    final hash = hashPassword(password, rows.first['salt'] as String);
    if (hash != rows.first['pass_hash']) return 'Incorrect password.';

    user = u;
    final db2 = await DB.instance();
    await db2.insert('settings', {'key': 'session_user_id', 'value': '${u.id}'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
    return null;
  }

  /// Opens a local session for [u] (used when a cloud sign-in maps onto a
  /// staff account, e.g. from the landing screen's Cloud tab).
  Future<void> sessionAs(AppUser u) async {
    user = u;
    final db = await DB.instance();
    await db.insert('settings', {'key': 'session_user_id', 'value': '${u.id}'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
  }

  Future<void> logout() async {
    final db = await DB.instance();
    await db.insert('settings', {'key': 'session_user_id', 'value': ''},
        conflictAlgorithm: ConflictAlgorithm.replace);
    user = null;
    notifyListeners();
  }

  /// Changes the password of the currently logged-in user.
  /// Returns null on success, or an error message.
  Future<String?> changePassword(String oldPw, String newPw) async {
    if (user == null) return 'Not logged in.';
    final db = await DB.instance();
    final rows =
        await db.query('users', where: 'id = ?', whereArgs: [user!.id]);
    if (rows.isEmpty) return 'Account not found.';
    final hash = hashPassword(oldPw, rows.first['salt'] as String);
    if (hash != rows.first['pass_hash']) return 'Current password is incorrect.';
    if (newPw.length < 6) return 'New password must be at least 6 characters.';
    final salt = newSalt();
    await db.update(
      'users',
      {'salt': salt, 'pass_hash': hashPassword(newPw, salt)},
      where: 'id = ?',
      whereArgs: [user!.id],
    );
    return null;
  }

  // ---- staff management (admin) ----

  Future<List<AppUser>> listUsers() async {
    final db = await DB.instance();
    final rows = await db.query('users', orderBy: 'name');
    return rows.map(AppUser.fromMap).toList();
  }

  /// Returns null on success, or an error message.
  Future<String?> createUser({
    required String name,
    required String email,
    required String role,
    required String password,
    String? permissions,
    double commissionRate = 0,
  }) async {
    if (name.trim().isEmpty) return 'Name is required.';
    if (password.length < 6) return 'Password must be at least 6 characters.';
    if (!email.contains('@')) return 'Enter a valid email address.';
    final db = await DB.instance();
    final exists = await db.query('users',
        where: 'email = ?', whereArgs: [email.trim().toLowerCase()]);
    if (exists.isNotEmpty) return 'An account with that email already exists.';
    final salt = newSalt();
    await db.insert('users', AppUser(
      name: name.trim(),
      email: email,
      role: role,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      permissions: permissions,
      commissionRate: commissionRate,
    ).toMap()
      ..['salt'] = salt
      ..['pass_hash'] = hashPassword(password, salt));
    notifyListeners();
    return null;
  }

  /// Updates name / role / active flag / permissions / commission rate.
  /// Returns null on success, or an error.
  Future<String?> updateUser(AppUser u, {bool? active}) async {
    final db = await DB.instance();
    await db.update('users', u.copyWith(active: active ?? u.active).toMap(),
        where: 'id = ?', whereArgs: [u.id]);
    if (u.id == user?.id) {
      user = u.copyWith(active: active ?? u.active);
    }
    notifyListeners();
    return null;
  }

  Future<String?> resetPassword(int userId, String newPassword) async {
    if (newPassword.length < 6) return 'Password must be at least 6 characters.';
    final db = await DB.instance();
    final salt = newSalt();
    await db.update('users', {
      'salt': salt,
      'pass_hash': hashPassword(newPassword, salt),
    }, where: 'id = ?', whereArgs: [userId]);
    return null;
  }
}
