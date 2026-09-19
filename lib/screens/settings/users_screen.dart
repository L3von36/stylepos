import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/database.dart';
import '../../models/user.dart';
import '../../services/audit.dart';
import '../../services/cloud_auth.dart';
import '../../services/sync_service.dart';
import '../../state/auth.dart';
import '../../widgets/ui.dart';
import 'shift_logs_screen.dart';

/// One merged staff entry: a cloud account (signs in on ANY device) that
/// may also have a local row, or a legacy account on this device only.
class _StaffEntry {
  final String? cloudId;
  final int? localId;
  final String name;
  final String email;
  final String role;
  final bool active;
  final bool isSelf;

  /// JSON permissions object (see [AppUser.encodePermissions]); the cloud
  /// roster returns it as a jsonb map, local rows store the JSON string.
  final String? permissions;
  final double commissionRate;

  const _StaffEntry({
    this.cloudId,
    this.localId,
    required this.name,
    required this.email,
    required this.role,
    required this.active,
    this.isSelf = false,
    this.permissions,
    this.commissionRate = 0,
  });

  bool get isCloud => cloudId != null;
  bool get isManager => role == 'admin';

  /// Normalises the many shapes a permissions field can arrive in
  /// (jsonb map from PostgREST, JSON string from SQLite, null).
  static String? _permJson(dynamic p) {
    if (p == null) return null;
    if (p is String) return p.isEmpty ? null : p;
    if (p is Map) return jsonEncode(p);
    return null;
  }

  static double _rate(dynamic v) => (v as num?)?.toDouble() ?? 0;
}

/// Staff account management (admin only).
///
/// When the Manager is cloud-signed-in the roster is the CLOUD shop roster
/// (`app_users`): staff created here are real accounts that can sign in on
/// every device. Local-only (pre-cloud) accounts are listed in their own
/// section. The list refreshes live via the sync service (Realtime events
/// on app_users trigger a sync which notifies listeners).
class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  List<_StaffEntry>? _entries;
  bool _cloudMode = false; // true when the cloud roster is the source
  bool _loading = false;
  String? _banner;

  @override
  void initState() {
    super.initState();
    _load();
    // Realtime: app_users changes arrive via sync -> notifyListeners.
    SyncService.I.addListener(_onSync);
  }

  @override
  void dispose() {
    SyncService.I.removeListener(_onSync);
    super.dispose();
  }

  void _onSync() {
    if (!_loading) _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    try {
      final db = await DB.instance();
      final localRows = await db.query('users', orderBy: 'name');
      final cloudRows = await CloudAuth.fetchStaffRoster();
      final myUid = CloudAuth.currentUserId();

      final entries = <_StaffEntry>[];
      if (cloudRows != null) {
        // Cloud roster is the source of truth; merge local rows so edits
        // and password resets can also fix the device-local copy.
        final cloudEmails = <String>{};
        for (final c in cloudRows) {
          final cid = c['id'] as String;
          final email = (c['email'] as String? ?? '').toLowerCase();
          if (email.isNotEmpty) cloudEmails.add(email);
          Map<String, Object?>? local;
          for (final l in localRows) {
            if (l['cloud_id'] == cid ||
                (email.isNotEmpty &&
                    (l['email'] as String? ?? '').toLowerCase() == email)) {
              local = l;
              break;
            }
          }
          entries.add(_StaffEntry(
            cloudId: cid,
            localId: local?['id'] as int?,
            name: (c['name'] as String?)?.trim().isNotEmpty ?? false
                ? c['name'] as String
                : (local?['name'] as String? ?? 'Staff'),
            email: email.isNotEmpty
                ? email
                : (local?['email'] as String? ?? ''),
            role: c['role'] as String? ?? 'cashier',
            active: c['active'] as bool? ?? true,
            isSelf: cid == myUid,
            permissions: _StaffEntry._permJson(c['permissions']) ??
                (local?['permissions'] as String?),
            commissionRate: _StaffEntry._rate(c['commission_rate']) != 0
                ? _StaffEntry._rate(c['commission_rate'])
                : _StaffEntry._rate(local?['commission_rate']),
          ));
        }
        // Local-only accounts created before cloud staff existed.
        for (final l in localRows) {
          final email = (l['email'] as String? ?? '').toLowerCase();
          final matched = l['cloud_id'] != null ||
              cloudEmails.contains(email) ||
              entries.any((e) => e.localId == l['id']);
          if (!matched) {
            entries.add(_StaffEntry(
              localId: l['id'] as int?,
              name: l['name'] as String? ?? 'Staff',
              email: email,
              role: l['role'] as String? ?? 'cashier',
              active: (l['active'] as int? ?? 1) == 1,
              permissions: l['permissions'] as String?,
              commissionRate: _StaffEntry._rate(l['commission_rate']),
            ));
          }
        }
        entries.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        if (mounted) {
          setState(() {
            _entries = entries;
            _cloudMode = true;
          });
        }
        return;
      }

      // Not cloud-signed-in (or offline): plain local list, as before.
      final local = localRows
          .map((l) => _StaffEntry(
                cloudId: l['cloud_id'] as String?,
                localId: l['id'] as int?,
                name: l['name'] as String? ?? 'Staff',
                email: (l['email'] as String? ?? '').toLowerCase(),
                role: l['role'] as String? ?? 'cashier',
                active: (l['active'] as int? ?? 1) == 1,
                permissions: l['permissions'] as String?,
                commissionRate: _StaffEntry._rate(l['commission_rate']),
              ))
          .toList();
      if (mounted) {
        setState(() {
          _entries = local;
          _cloudMode = false;
        });
      }
    } finally {
      _loading = false;
    }
  }

  Future<void> _edit([_StaffEntry? existing]) async {
    final err = await showDialog<String>(
      context: context,
      builder: (_) => _UserEditDialog(entry: existing, cloudMode: _cloudMode),
    );
    if (err != null && mounted) {
      setState(() => _banner = err);
    }
    _load();
  }

  Future<void> _resetPassword(_StaffEntry u) async {
    final ctrl = TextEditingController();
    final err = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Reset password for ${u.name}'),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: ctrl,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(
                labelText: 'New password (min 6 chars)'),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, 'ok'), child: const Text('Reset')),
        ],
      ),
    );
    if (err == null || ctrl.text.isEmpty || !mounted) return;
    String? result;
    if (u.isCloud) {
      result = await CloudAuth.resetStaffPassword(u.cloudId!, ctrl.text);
    } else {
      result =
          await context.read<AuthProvider>().resetPassword(u.localId!, ctrl.text);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            result ?? 'Password reset for ${u.name} — it works on every device')));
    if (result == null) {
      final me = context.read<AuthProvider>().user;
      await Audit.add('password_reset', 'Password reset for ${u.name} (${u.email})',
          userId: me?.id, userName: me?.name);
    }
  }

  Future<void> _toggleActive(_StaffEntry u) async {
    if (u.isSelf) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('You cannot deactivate your own account')));
      return;
    }
    final me = context.read<AuthProvider>().user;
    if (u.isCloud) {
      final err = await CloudAuth.setStaffActive(u.cloudId!, !u.active);
      if (!mounted) return;
      if (err != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err)));
        return;
      }
      _syncLocalCopy(u, active: !u.active);
      await Audit.add(
          'staff_updated',
          '${u.name} ${u.active ? 'deactivated' : 'reactivated'}',
          userId: me?.id,
          userName: me?.name);
    } else {
      final a = context.read<AuthProvider>();
      final local = await a.listUsers();
      final match = local.where((x) => x.id == u.localId).toList();
      if (match.isEmpty) return;
      await a.updateUser(match.first, active: !u.active);
      await Audit.add(
          'staff_updated',
          '${u.name} ${u.active ? 'deactivated' : 'reactivated'}',
          userId: me?.id,
          userName: me?.name);
    }
    _load();
  }

  /// Keeps the device-local copy of a cloud staff member in step so the
  /// local login gate, permission gates and report names agree with the cloud.
  Future<void> _syncLocalCopy(_StaffEntry u,
      {String? name,
      String? role,
      bool? active,
      String? permissions,
      double? commissionRate}) async {
    try {
      if (u.localId == null) return;
      final db = await DB.instance();
      await db.update(
          'users',
          {
            'name': ?(name?.trim().isNotEmpty ?? false ? name!.trim() : null),
            'role': ?role,
            'active': ?(active != null ? (active ? 1 : 0) : null),
            'permissions': ?permissions,
            'commission_rate': ?commissionRate,
          },
          where: 'id = ?',
          whereArgs: [u.localId]);
    } catch (_) {// Local bookkeeping only — never block cloud actions.
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final entries = _entries;
    final cloudOnly = _cloudMode && entries != null
        ? entries.where((e) => e.isCloud).toList()
        : const <_StaffEntry>[];
    final deviceOnly = _cloudMode && entries != null
        ? entries.where((e) => !e.isCloud).toList()
        : entries ?? const <_StaffEntry>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Staff accounts'),
        actions: [
          IconButton(
            tooltip: 'Shift logs',
            icon: const Icon(Icons.badge_outlined, size: 22),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ShiftLogsScreen())),
          ),
          const SizedBox(width: AppSpace.s1),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.person_add_alt_rounded, size: 20),
        label: const Text('Add staff'),
      ),
      body: entries == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 660),
                  child: Builder(builder: (context) {
                    // Layout (cloud mode): [banner] [empty-cloud-hint?]
                    // [cloud cards] [device header + device cards?]
                    final hasEmptyCard = _cloudMode && cloudOnly.isEmpty;
                    final hasDeviceSection =
                        _cloudMode && deviceOnly.isNotEmpty;
                    final count =
                        (_banner != null ? 1 : 0) +
                            (hasEmptyCard ? 1 : 0) +
                            cloudOnly.length +
                            (hasDeviceSection ? 1 + deviceOnly.length : 0);
                    return ListView.separated(
                      padding: const EdgeInsets.all(AppSpace.s4),
                      itemCount: count,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: AppSpace.s2),
                      itemBuilder: (context, i) {
                        var idx = i;
                        if (_banner != null) {
                          if (idx == 0) {
                            return _BannerCard(
                                text: _banner!,
                                onClose: () => setState(() => _banner = null));
                          }
                          idx--;
                        }
                        if (hasEmptyCard) {
                          if (idx == 0) return const _EmptyCloudCard();
                          idx--;
                        }
                        if (idx < cloudOnly.length) {
                          return _staffCard(cloudOnly[idx], auth);
                        }
                        idx -= cloudOnly.length;
                        if (hasDeviceSection) {
                          if (idx == 0) {
                            return const _SectionHeader(
                              icon: Icons.phone_android_rounded,
                              title: 'On this device only',
                              subtitle:
                                  'Created before cloud staff — they can sign '
                                  'in on this device. Re-create them as cloud '
                                  'staff so they can sign in everywhere.',
                            );
                          }
                          idx--;
                          return _staffCard(deviceOnly[idx], auth);
                        }
                        // Not cloud mode: plain local list.
                        return _staffCard(entries[idx], auth);
                      },
                    );
                  }),
                ),
              ),
            ),
    );
  }

  /// Short " · can discount / can refund / 5% comm" tail for the card.
  static String _permSummary(_StaffEntry u) {
    if (u.isManager) return '';
    final bits = <String>[];
    final appUser = AppUser(
        name: u.name,
        email: u.email,
        role: u.role,
        createdAt: 0,
        permissions: u.permissions,
        commissionRate: u.commissionRate);
    if (appUser.canDiscount) {
      bits.add(appUser.discountCap > 0
          ? 'discounts ≤ ${appUser.discountCap.toStringAsFixed(0)}'
          : 'discounts');
    }
    if (appUser.canRefund) bits.add('refunds');
    if (appUser.earnsCommission) {
      final r = appUser.commissionRate;
      bits.add('${r == r.roundToDouble() ? r.toStringAsFixed(0) : r.toString()}% comm');
    }
    return bits.isEmpty ? '' : ' · ${bits.join(' · ')}';
  }

  Widget _staffCard(_StaffEntry u, AuthProvider auth) {
    return Card(
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: AppSpace.s4, vertical: AppSpace.s1),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: u.isManager ? AppColors.primarySoft : AppColors.infoSoft,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Icon(
            u.isManager
                ? Icons.admin_panel_settings_outlined
                : Icons.badge_outlined,
            color: u.isManager ? AppColors.primary : AppColors.info,
            size: 22,
          ),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                u.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: 'Carlito',
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: u.active ? AppColors.ink : AppColors.faint),
              ),
            ),
            if (u.isSelf) ...[
              const SizedBox(width: AppSpace.s2),
              StatusPill.build(context,
                  label: 'You',
                  foreground: AppColors.primary,
                  background: AppColors.primarySoft),
            ],
            const SizedBox(width: AppSpace.s2),
            StatusPill.build(context,
                label: u.isCloud ? 'Cloud' : 'This device',
                foreground:
                    u.isCloud ? AppColors.success : AppColors.muted,
                background: u.isCloud
                    ? AppColors.successSoft
                    : AppColors.surfaceTint),
            if (!u.active) ...[
              const SizedBox(width: AppSpace.s2),
              StatusPill.build(context,
                  label: 'Inactive',
                  foreground: AppColors.danger,
                  background: AppColors.dangerSoft),
            ],
          ],
        ),
        subtitle: Text(
            '${u.email.isEmpty ? "no email" : u.email} · '
            '${u.isManager ? "Manager" : "Sales"}'
            '${u.isManager ? "" : _permSummary(u)}',
            style: const TextStyle(fontFamily: 'Carlito', fontSize: 12)),
        trailing: PopupMenuButton<String>(
          icon: Icon(Icons.more_vert_rounded, size: 20, color: AppColors.muted),
          onSelected: (v) async {
            if (v == 'edit') {
              _edit(u);
            } else if (v == 'reset') {
              _resetPassword(u);
            } else if (v == 'toggle') {
              await _toggleActive(u);
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'edit', child: Text('Edit')),
            const PopupMenuItem(
                value: 'reset', child: Text('Reset password')),
            PopupMenuItem(
                value: 'toggle',
                enabled: !u.isSelf,
                child: Text(u.active ? 'Deactivate' : 'Reactivate')),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _SectionHeader(
      {required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.s3, left: AppSpace.s1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppColors.faint),
          const SizedBox(width: AppSpace.s2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontFamily: 'Carlito',
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                        color: AppColors.muted)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: TextStyle(
                        fontFamily: 'Carlito',
                        fontSize: 11,
                        height: 1.35,
                        color: AppColors.faint)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyCloudCard extends StatelessWidget {
  const _EmptyCloudCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.s4),
        child: Row(
          children: [
            Icon(Icons.group_add_rounded, size: 22, color: AppColors.primary),
            const SizedBox(width: AppSpace.s3),
            Expanded(
              child: Text(
                'No staff yet — tap "Add staff" to create a cloud account. '
                'Your staff signs in with that email and password on any '
                'device, and every sale is attributed to them.',
                style: TextStyle(
                    fontFamily: 'Carlito', fontSize: 12, height: 1.4,
                    color: AppColors.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BannerCard extends StatelessWidget {
  final String text;
  final VoidCallback onClose;

  const _BannerCard({required this.text, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.dangerSoft,
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: AppSpace.s4, vertical: AppSpace.s1),
        leading: Icon(Icons.error_outline_rounded, size: 18, color: AppColors.danger),
        title: Text(text,
            style: TextStyle(
                fontFamily: 'Carlito', fontSize: 12, color: AppColors.danger)),
        trailing: IconButton(
          icon: Icon(Icons.close_rounded, size: 16, color: AppColors.danger),
          onPressed: onClose,
        ),
      ),
    );
  }
}

class _PermSwitch extends StatelessWidget {
  final bool value;
  final String title;
  final String subtitle;
  final ValueChanged<bool> onChanged;

  const _PermSwitch({
    required this.value,
    required this.title,
    required this.subtitle,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        visualDensity: VisualDensity.compact,
        title: Text(title,
            style: TextStyle(
                fontFamily: 'Carlito',
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.ink)),
        subtitle: Text(subtitle,
            style: TextStyle(
                fontFamily: 'Carlito', fontSize: 11, color: AppColors.muted)),
        trailing: Switch(value: value, onChanged: onChanged),
      ),
    );
  }
}

class _UserEditDialog extends StatefulWidget {
  final _StaffEntry? entry;
  final bool cloudMode;

  const _UserEditDialog({this.entry, required this.cloudMode});

  @override
  State<_UserEditDialog> createState() => _UserEditDialogState();
}

class _UserEditDialogState extends State<_UserEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _email;
  late final TextEditingController _password;
  late final TextEditingController _cap;
  late final TextEditingController _rate;
  late String _role;
  late bool _canDiscount;
  late bool _canRefund;
  String? _error;
  bool _busy = false;

  bool get _isNew => widget.entry == null;
  bool get _cloudTarget => widget.cloudMode && (widget.entry == null || widget.entry!.isCloud);
  bool get _salesperson => _role == 'cashier';

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.entry?.name ?? '');
    _email = TextEditingController(text: widget.entry?.email ?? '');
    _password = TextEditingController();
    _role = widget.entry?.role ?? 'cashier';
    final perm = AppUser(
      name: '',
      email: '',
      role: 'cashier',
      createdAt: 0,
      permissions: widget.entry?.permissions,
      commissionRate: widget.entry?.commissionRate ?? 0,
    );
    _canDiscount = perm.canDiscount;
    _canRefund = perm.canRefund;
    _cap = TextEditingController(
        text: perm.discountCap.isFinite && perm.discountCap > 0
            ? perm.discountCap.toStringAsFixed(0)
            : '');
    _rate = TextEditingController(
        text: perm.commissionRate == perm.commissionRate.roundToDouble()
            ? (perm.commissionRate == 0
                ? ''
                : perm.commissionRate.toStringAsFixed(0))
            : perm.commissionRate.toString());
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _cap.dispose();
    _rate.dispose();
    super.dispose();
  }

  String get _permissionsJson => AppUser.encodePermissions(
        canDiscount: _canDiscount,
        discountCap: double.tryParse(_cap.text) ?? 0,
        canRefund: _canRefund,
      );

  double get _commissionRate => (double.tryParse(_rate.text) ?? 0)
      .clamp(0, 100)
      .toDouble();

  Future<void> _save() async {
    final auth = context.read<AuthProvider>();
    // Capture before any await — context must not be used across async gaps.
    final screen = context.findAncestorStateOfType<_UsersScreenState>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    String? err;
    setState(() => _busy = true);

    if (widget.entry == null) {
      // ---- create ----
      if (_cloudTarget) {
        err = await CloudAuth.createStaff(
          name: _name.text,
          email: _email.text,
          role: _role,
          password: _password.text,
        );
        if (err == null && _salesperson) {
          // create_staff_account does not take permissions — patch them
          // onto the freshly created app_users row (found by email).
          try {
            final roster = await CloudAuth.fetchStaffRoster();
            final row = roster?.firstWhere(
              (r) =>
                  (r['email'] as String? ?? '').toLowerCase() ==
                  _email.text.trim().toLowerCase(),
            );
            if (row != null) {
              err = await CloudAuth.updateStaff(
                row['id'] as String,
                permissionsJson: _permissionsJson,
                commissionRate: _commissionRate,
              );
            }
          } catch (_) {// Permissions can be added later via Edit.
          }
        }
      } else {
        err = await auth.createUser(
          name: _name.text,
          email: _email.text,
          role: _role,
          password: _password.text,
          permissions: _salesperson ? _permissionsJson : null,
          commissionRate: _salesperson ? _commissionRate : 0,
        );
      }
    } else {
      // ---- edit ----
      final e = widget.entry!;
      if (e.isCloud) {
        err = await CloudAuth.updateStaff(
          e.cloudId!,
          name: _name.text,
          role: _role,
          permissionsJson: _salesperson ? _permissionsJson : null,
          commissionRate: _salesperson ? _commissionRate : 0,
        );
        if (err == null) {
          await screen?._syncLocalCopy(
            e,
            name: _name.text,
            role: _role,
            permissions: _salesperson ? _permissionsJson : null,
            commissionRate: _salesperson ? _commissionRate : 0,
          );
        }
      } else {
        err = await auth.updateUser(
          AppUser(
            id: e.localId,
            name: _name.text.trim(),
            email: e.email,
            role: _role,
            active: e.active,
            createdAt: 0,
            permissions: _salesperson ? _permissionsJson : null,
            commissionRate: _salesperson ? _commissionRate : 0,
          ),
        );
      }
    }

    if (!mounted) return;
    if (err != null) {
      setState(() {
        _error = err;
        _busy = false;
      });
    } else {
      // Audit: who created/edited which staff account.
      final me = auth.user;
      final permsNote = _salesperson
          ? ' · ${_canDiscount ? 'discounts${(double.tryParse(_cap.text) ?? 0) > 0 ? '≤${double.tryParse(_cap.text)!.toStringAsFixed(0)}' : ''}' : 'no discounts'}'
              '${_canRefund ? ' · refunds' : ''}'
              '${_commissionRate > 0 ? ' · ${_commissionRate.toStringAsFixed(_commissionRate == _commissionRate.roundToDouble() ? 0 : 1)}% comm' : ''}'
          : '';
      await Audit.add(
        _isNew ? 'staff_created' : 'staff_updated',
        '${_name.text.trim()} · role: $_role'
            '${_cloudTarget ? ' · cloud account' : ' · device account'}'
            '$permsNote',
        userId: me?.id,
        userName: me?.name,
      );
      messenger.showSnackBar(const SnackBar(
          content: Text('Saved')));
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      title: Row(children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Icon(
            _isNew ? Icons.person_add_alt_rounded : Icons.manage_accounts_outlined,
            size: 19,
            color: AppColors.primary,
          ),
        ),
        const SizedBox(width: AppSpace.s3),
        Text(_isNew ? 'Add staff account' : 'Edit staff account'),
      ]),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_cloudTarget && _isNew)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.s3),
                child: Container(
                  padding: const EdgeInsets.all(AppSpace.s3),
                  decoration: BoxDecoration(
                    color: AppColors.primarySoft,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.cloud_done_outlined,
                          size: 16, color: AppColors.primary),
                      const SizedBox(width: AppSpace.s2),
                      Expanded(
                        child: Text(
                          'Cloud account — works on every device. Staff signs '
                          'in with this email and password.',
                          style: TextStyle(
                              fontFamily: 'Carlito', fontSize: 11,
                              height: 1.35, color: AppColors.primaryDark),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                  labelText: 'Full name *',
                  prefixIcon: Icon(Icons.person_outline_rounded, size: 20)),
            ),
            const SizedBox(height: AppSpace.s3),
            TextField(
              controller: _email,
              enabled: _isNew,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: 'Email (login) *',
                helperText: _isNew
                    ? null
                    : 'Email cannot be changed',
                prefixIcon: const Icon(Icons.alternate_email_rounded, size: 20),
              ),
            ),
            const SizedBox(height: 13),
            DropdownButtonFormField<String>(
              initialValue: _role,
              icon: const Icon(Icons.expand_more_rounded, size: 19),
              decoration: const InputDecoration(labelText: 'Role'),
              items: const [
                DropdownMenuItem(value: 'cashier', child: Text('Sales — sell, customers & own sales')),
                DropdownMenuItem(value: 'admin', child: Text('Manager — full access incl. reports')),
              ],
              onChanged: (v) => setState(() => _role = v ?? 'cashier'),
            ),
            if (_salesperson) ...[
              const SizedBox(height: AppSpace.s3),
              Container(
                padding: const EdgeInsets.all(AppSpace.s3),
                decoration: BoxDecoration(
                  color: AppColors.surfaceTint,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.verified_user_outlined,
                          size: 15, color: AppColors.primary),
                      const SizedBox(width: AppSpace.s2),
                      Text('PERMISSIONS & COMMISSION',
                          style: TextStyle(
                              fontFamily: 'Carlito',
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.4,
                              color: AppColors.muted)),
                    ]),
                    const SizedBox(height: AppSpace.s2),
                    _PermSwitch(
                      value: _canDiscount,
                      title: 'Give manual discounts',
                      subtitle: _canDiscount
                          ? 'No manager PIN needed up to the cap below'
                          : 'Every discount needs manager approval',
                      onChanged: (v) => setState(() => _canDiscount = v),
                    ),
                    if (_canDiscount)
                      Padding(
                        padding: const EdgeInsets.only(left: AppSpace.s6),
                        child: TextField(
                          controller: _cap,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Discount cap per sale (0 = no cap)',
                            isDense: true,
                          ),
                        ),
                      ),
                    _PermSwitch(
                      value: _canRefund,
                      title: 'Process refunds',
                      subtitle: _canRefund
                          ? 'Refunds without manager approval'
                          : 'Refunds need manager approval (PIN)',
                      onChanged: (v) => setState(() => _canRefund = v),
                    ),
                    TextField(
                      controller: _rate,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Commission rate (% of net sales, 0 = none)',
                        isDense: true,
                        prefixIcon: Icon(Icons.percent_rounded, size: 19),
                      ),
                    ),
                    const SizedBox(height: AppSpace.s1),
                    Text(
                      'Commission is earned automatically on every sale this '
                      'salesperson completes and shows in Reports.',
                      style: TextStyle(
                          fontFamily: 'Carlito',
                          fontSize: 11,
                          height: 1.35,
                          color: AppColors.faint),
                    ),
                  ],
                ),
              ),
            ],
            if (_isNew) ...[
              const SizedBox(height: AppSpace.s3),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'Password * (min 6 chars)',
                    prefixIcon: Icon(Icons.lock_outline_rounded, size: 20)),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: AppSpace.s3),
              Container(
                padding: const EdgeInsets.all(AppSpace.s3),
                decoration: BoxDecoration(
                  color: AppColors.dangerSoft,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline_rounded, size: 17, color: AppColors.danger),
                    const SizedBox(width: AppSpace.s2),
                    Expanded(
                      child: Text(_error!,
                          style: TextStyle(
                              fontFamily: 'Carlito', fontSize: 12, color: AppColors.danger)),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }
}
