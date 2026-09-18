import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../data/database.dart';
import '../widgets/ui.dart';
import 'hash.dart';

/// Who approved a sensitive action (refund / big discount / stock edit).
class Approval {
  final int userId;
  final String userName;

  /// 'pin' (manager PIN) or 'password' (a manager account password).
  final String method;
  const Approval({required this.userId, required this.userName, required this.method});

  String get methodLabel => method == 'pin' ? 'manager PIN' : 'manager password';
}

/// Manager approval for sensitive actions.
///
/// The manager can set a short numeric PIN (Settings → Approvals & security)
/// that cashiers type to authorize e.g. a manual discount or a refund.
/// When no PIN is configured the dialog falls back to "any active manager
/// account email + password", so the shop is never locked out of its own
/// approvals. Every approval is written to the audit log by the caller.
class Approvals {
  Approvals._();

  static const _pinHashKey = 'manager_pin_hash';
  static const _pinSaltKey = 'manager_pin_salt';

  // ------------------------------------------------------------ PIN store

  static Future<bool> hasPin() async {
    final db = await DB.instance();
    final rows = await db.query('settings',
        where: 'key = ?', whereArgs: [_pinHashKey]);
    final h = rows.isEmpty ? null : rows.first['value'] as String?;
    return h != null && h.isNotEmpty;
  }

  /// Stores (or replaces) the manager PIN. Returns null on success.
  static Future<String?> setPin(String pin) async {
    final clean = pin.trim();
    if (clean.length < 4 || clean.length > 8) {
      return 'PIN must be 4–8 digits.';
    }
    if (int.tryParse(clean) == null) return 'PIN must contain only digits.';
    final db = await DB.instance();
    final salt = newSalt();
    await db.insert('settings', {'key': _pinSaltKey, 'value': salt},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert(
        'settings',
        {'key': _pinHashKey, 'value': hashPassword(clean, salt)},
        conflictAlgorithm: ConflictAlgorithm.replace);
    return null;
  }

  static Future<void> clearPin() async {
    final db = await DB.instance();
    await db.insert('settings', {'key': _pinHashKey, 'value': ''},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<bool> _verifyPin(String pin) async {
    final db = await DB.instance();
    final rows = await db.query('settings',
        where: 'key IN (?, ?)', whereArgs: [_pinHashKey, _pinSaltKey]);
    String? hash;
    String? salt;
    for (final r in rows) {
      if (r['key'] == _pinHashKey) hash = r['value'] as String?;
      if (r['key'] == _pinSaltKey) salt = r['value'] as String?;
    }
    if (hash == null || hash.isEmpty || salt == null || salt.isEmpty) {
      return false;
    }
    return hashPassword(pin.trim(), salt) == hash;
  }

  /// Password fallback: verifies against ANY active manager (admin) account.
  /// Used by the approval dialog when no PIN is configured (or via the
  /// "use manager password instead" switch).
  static Future<Approval?> verifyManagerPassword(
      String email, String password) async {
    final db = await DB.instance();
    final rows = await db.query('users',
        where: 'role = ? AND active = 1', whereArgs: ['admin']);
    for (final r in rows) {
      if ((r['email'] as String).toLowerCase().trim() != email.toLowerCase().trim()) {
        continue;
      }
      if (hashPassword(password, r['salt'] as String) == r['pass_hash']) {
        return Approval(
          userId: r['id'] as int,
          userName: r['name'] as String,
          method: 'password',
        );
      }
    }
    return null;
  }

  // -------------------------------------------------------------- dialog

  /// Shows the approval dialog. Returns the approval when authorized, null
  /// when cancelled or the credential check failed. [context] must carry an
  /// [AuthProvider]. The result should be written to the audit log together
  /// with the action it approved.
  static Future<Approval?> request(
    BuildContext context, {
    required String title,
    required String reason,
  }) async {
    return showDialog<Approval>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ApprovalDialog(title: title, reason: reason),
    );
  }
}

class _ApprovalDialog extends StatefulWidget {
  final String title;
  final String reason;
  const _ApprovalDialog({required this.title, required this.reason});

  @override
  State<_ApprovalDialog> createState() => _ApprovalDialogState();
}

class _ApprovalDialogState extends State<_ApprovalDialog> {
  final _pin = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _pinMode = true; // false = manager email + password fallback
  bool _hasPin = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    Approvals.hasPin().then((v) {
      if (mounted) setState(() => _hasPin = v);
    });
  }

  @override
  void dispose() {
    _pin.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    Approval? ok;
    if (_pinMode && _hasPin) {
      if (await Approvals._verifyPin(_pin.text)) {
        // PIN approval attributes to "the manager" — the acting user stays
        // the current one; the audit note records the method.
        ok = const Approval(userId: 0, userName: 'Manager', method: 'pin');
      } else {
        _setErr('Incorrect PIN.');
        return;
      }
    } else {
      ok = await Approvals.verifyManagerPassword(_email.text, _password.text);
      if (ok == null) {
        _setErr('No active manager account matches those credentials.');
        return;
      }
    }
    if (!mounted) return;
    Navigator.of(context).pop(ok);
  }

  void _setErr(String msg) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = msg;
    });
  }

  @override
  Widget build(BuildContext context) {
    final usePin = _pinMode && _hasPin;
    return AlertDialog(
      title: Row(children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: AppColors.warningSoft,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Icon(Icons.verified_user_outlined,
              size: 19, color: AppColors.warning),
        ),
        const SizedBox(width: AppSpace.s3),
        Expanded(child: Text(widget.title)),
      ]),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.reason,
                style: TextStyle(
                    fontFamily: 'Carlito', fontSize: 13, color: AppColors.body)),
            const SizedBox(height: AppSpace.s4),
            if (usePin) ...[
              TextField(
                controller: _pin,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 8,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Manager PIN',
                  counterText: '',
                  prefixIcon: Icon(Icons.password_rounded, size: 20),
                ),
                onSubmitted: (_) => _submit(),
              ),
            ] else ...[
              TextField(
                controller: _email,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Manager email',
                  prefixIcon: Icon(Icons.alternate_email_rounded, size: 20),
                ),
              ),
              const SizedBox(height: AppSpace.s3),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Manager password',
                  prefixIcon: Icon(Icons.lock_outline_rounded, size: 20),
                ),
                onSubmitted: (_) => _submit(),
              ),
            ],
            if (!_hasPin)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.s2),
                child: Text(
                  'No PIN is configured — approve with a manager account '
                  '(set a PIN in Settings → Approvals & security).',
                  style: TextStyle(
                      fontFamily: 'Carlito',
                      fontSize: 12,
                      color: AppColors.warning),
                ),
              ),
            if (_hasPin)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => setState(() {
                    _pinMode = !_pinMode;
                    _error = null;
                  }),
                  child: Text(_pinMode
                      ? 'Use manager password instead'
                      : 'Use PIN instead'),
                ),
              ),
            if (_error != null)
              Container(
                margin: const EdgeInsets.only(top: AppSpace.s2),
                padding: const EdgeInsets.all(AppSpace.s3),
                decoration: BoxDecoration(
                  color: AppColors.dangerSoft,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Row(children: [
                  Icon(Icons.error_outline_rounded,
                      size: 17, color: AppColors.danger),
                  const SizedBox(width: AppSpace.s2),
                  Expanded(
                    child: Text(_error!,
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 12.5,
                            color: AppColors.danger)),
                  ),
                ]),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary),
          onPressed: _busy ? null : _submit,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.check_rounded, size: 18),
          label: const Text('Approve'),
        ),
      ],
    );
  }
}

/// True when a non-manager user's [discount] must be approved first.
bool discountNeedsApproval({
  required bool isAdmin,
  required double discount,
  required double threshold,
}) {
  if (isAdmin || discount <= 0) return false;
  return discount >= threshold;
}
