import 'package:flutter/foundation.dart';

import '../data/database.dart';

/// One shift: a clock-in, and (eventually) a clock-out.
class Shift {
  final int? id;
  final int userId;
  final int clockIn;
  final int? clockOut;

  const Shift({this.id, required this.userId, required this.clockIn, this.clockOut});

  bool get isOpen => clockOut == null;

  /// Shift length in minutes (open shifts count up to now).
  int get minutes {
    final end = (clockOut ?? DateTime.now().millisecondsSinceEpoch ~/ 1000);
    return ((end - clockIn) / 60).floor();
  }

  String get durationLabel {
    final m = minutes;
    final h = m ~/ 60;
    if (h <= 0) return '${m}m';
    return '${h}h ${m % 60}m';
  }

  factory Shift.fromMap(Map<String, Object?> m) => Shift(
        id: m['id'] as int?,
        userId: m['user_id'] as int,
        clockIn: m['clock_in'] as int,
        clockOut: m['clock_out'] as int?,
      );
}

/// Staff shift logs (clock in / clock out). Local to the device by design:
/// the punch happens on the till the staff member is actually standing at,
/// and the manager reviews the log there (Staff → shift-log icon).
class AttendanceProvider extends ChangeNotifier {
  /// Bumped whenever a punch lands so listeners (POS strip, shift screen)
  /// refresh.
  int revision = 0;

  /// The open (running) shift for [userId], or null when punched out.
  Future<Shift?> openShift(int userId) async {
    final db = await DB.instance();
    final rows = await db.query('attendance',
        where: 'user_id = ? AND clock_out IS NULL',
        whereArgs: [userId],
        orderBy: 'clock_in DESC',
        limit: 1);
    return rows.isEmpty ? null : Shift.fromMap(rows.first);
  }

  /// True when [userId] is currently clocked in on this device.
  Future<bool> isClockedIn(int userId) async => await openShift(userId) != null;

  Future<void> clockIn(int userId) async {
    final db = await DB.instance();
    // Safety: close any stale open shift (e.g. app killed mid-shift) before
    // starting a new one, so a user never carries two open shifts.
    final stale = await openShift(userId);
    if (stale != null) {
      await db.update(
        'attendance',
        {'clock_out': DateTime.now().millisecondsSinceEpoch ~/ 1000},
        where: 'id = ?',
        whereArgs: [stale.id],
      );
    }
    await db.insert('attendance', {
      'user_id': userId,
      'clock_in': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
    revision++;
    notifyListeners();
  }

  Future<void> clockOut(int userId) async {
    final db = await DB.instance();
    final open = await openShift(userId);
    if (open == null) return;
    await db.update(
      'attendance',
      {'clock_out': DateTime.now().millisecondsSinceEpoch ~/ 1000},
      where: 'id = ?',
      whereArgs: [open.id],
    );
    revision++;
    notifyListeners();
  }

  /// Shifts for the shift-log screen, joined with user names. Newest first.
  /// [days] limits the window (0 = everything).
  Future<List<({Shift shift, String userName})>> logs({int days = 0}) async {
    final db = await DB.instance();
    final cutoff = days <= 0
        ? 0
        : DateTime.now()
                .subtract(Duration(days: days))
                .millisecondsSinceEpoch ~/
            1000;
    final rows = await db.rawQuery('''
      SELECT a.*, u.name AS user_name
      FROM attendance a
      LEFT JOIN users u ON u.id = a.user_id
      ${cutoff > 0 ? 'WHERE a.clock_in >= ?' : ''}
      ORDER BY a.clock_in DESC
      LIMIT 500
    ''', cutoff > 0 ? [cutoff] : null);
    return [
      for (final r in rows)
        (
          shift: Shift.fromMap(r),
          userName: (r['user_name'] as String?) ?? 'Unknown',
        ),
    ];
  }
}
