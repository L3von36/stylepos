import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/database.dart';
import '../../models/user.dart';
import '../../services/cloud_auth.dart';
import '../../services/sync_service.dart';
import '../../state/auth.dart';
import '../../widgets/ui.dart';

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

  const _StaffEntry({
    this.cloudId,
    this.localId,
    required this.name,
    required this.email,
    required this.role,
    required this.active,
    this.isSelf = false,
  });

  bool get isCloud => cloudId != null;
  bool get isManager => role == 'admin';
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
  }

  Future<void> _toggleActive(_StaffEntry u) async {
    if (u.isSelf) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('You cannot deactivate your own account')));
      return;
    }
    if (u.isCloud) {
      final err = await CloudAuth.setStaffActive(u.cloudId!, !u.active);
      if (!mounted) return;
      if (err != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err)));
        return;
      }
      _syncLocalCopy(u, active: !u.active);
    } else {
      final a = context.read<AuthProvider>();
      final local = await a.listUsers();
      final match = local.where((x) => x.id == u.localId).toList();
      if (match.isEmpty) return;
      await a.updateUser(match.first, active: !u.active);
    }
    _load();
  }

  /// Keeps the device-local copy of a cloud staff member in step so the
  /// local login gate and report names agree with the cloud.
  Future<void> _syncLocalCopy(_StaffEntry u,
      {String? name, String? role, bool? active}) async {
    try {
      if (u.localId == null) return;
      final db = await DB.instance();
      await db.update(
          'users',
          {
            'name': ?(name?.trim().isNotEmpty ?? false ? name!.trim() : null),
            'role': ?role,
            'active': ?(active != null ? (active ? 1 : 0) : null),
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
      appBar: AppBar(title: const Text('Staff accounts')),
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
            '${u.isManager ? "Manager" : "Sales"}',
            style: const TextStyle(fontFamily: 'Carlito', fontSize: 12.5)),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert_rounded, size: 20, color: AppColors.muted),
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
                    style: const TextStyle(
                        fontFamily: 'Carlito',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                        color: AppColors.muted)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: const TextStyle(
                        fontFamily: 'Carlito',
                        fontSize: 11.5,
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
            const Icon(Icons.group_add_rounded, size: 22, color: AppColors.primary),
            const SizedBox(width: AppSpace.s3),
            Expanded(
              child: Text(
                'No staff yet — tap "Add staff" to create a cloud account. '
                'Your staff signs in with that email and password on any '
                'device, and every sale is attributed to them.',
                style: const TextStyle(
                    fontFamily: 'Carlito', fontSize: 12.5, height: 1.4,
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
        leading: const Icon(Icons.error_outline_rounded, size: 18, color: AppColors.danger),
        title: Text(text,
            style: const TextStyle(
                fontFamily: 'Carlito', fontSize: 12.5, color: AppColors.danger)),
        trailing: IconButton(
          icon: const Icon(Icons.close_rounded, size: 16, color: AppColors.danger),
          onPressed: onClose,
        ),
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
  late String _role;
  String? _error;
  bool _busy = false;

  bool get _isNew => widget.entry == null;
  bool get _cloudTarget => widget.cloudMode && (widget.entry == null || widget.entry!.isCloud);

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.entry?.name ?? '');
    _email = TextEditingController(text: widget.entry?.email ?? '');
    _password = TextEditingController();
    _role = widget.entry?.role ?? 'cashier';
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final auth = context.read<AuthProvider>();
    // Capture before any await — context must not be used across async gaps.
    final screen = context.findAncestorStateOfType<_UsersScreenState>();
    final messenger = ScaffoldMessenger.of(context);
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
      } else {
        err = await auth.createUser(
          name: _name.text,
          email: _email.text,
          role: _role,
          password: _password.text,
        );
      }
    } else {
      // ---- edit ----
      final e = widget.entry!;
      if (e.isCloud) {
        err = await CloudAuth.updateStaff(e.cloudId!, name: _name.text, role: _role);
        if (err == null) {
          await screen?._syncLocalCopy(e, name: _name.text, role: _role);
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
      messenger.showSnackBar(const SnackBar(
          content: Text('Saved')));
      Navigator.pop(context);
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
                      const Icon(Icons.cloud_done_outlined,
                          size: 16, color: AppColors.primary),
                      const SizedBox(width: AppSpace.s2),
                      Expanded(
                        child: Text(
                          'Cloud account — works on every device. Staff signs '
                          'in with this email and password.',
                          style: const TextStyle(
                              fontFamily: 'Carlito', fontSize: 11.5,
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
                    const Icon(Icons.error_outline_rounded, size: 17, color: AppColors.danger),
                    const SizedBox(width: AppSpace.s2),
                    Expanded(
                      child: Text(_error!,
                          style: const TextStyle(
                              fontFamily: 'Carlito', fontSize: 12.5, color: AppColors.danger)),
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
