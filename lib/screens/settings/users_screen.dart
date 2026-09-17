import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/user.dart';
import '../../state/auth.dart';
import '../../widgets/ui.dart';

/// Staff account management (admin only).
class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  List<AppUser>? _users;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final users = await context.read<AuthProvider>().listUsers();
    if (mounted) setState(() => _users = users);
  }

  Future<void> _edit([AppUser? existing]) async {
    await showDialog(
      context: context,
      builder: (_) => _UserEditDialog(user: existing),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('Staff accounts')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.person_add_alt_rounded, size: 20),
        label: const Text('Add staff'),
      ),
      body: _users == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 660),
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _users!.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final u = _users![i];
                    final isSelf = u.id == auth.user?.id;
                    return Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        leading: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: u.isAdmin ? AppColors.primarySoft : AppColors.infoSoft,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            u.isAdmin
                                ? Icons.admin_panel_settings_outlined
                                : Icons.badge_outlined,
                            color: u.isAdmin ? AppColors.primary : AppColors.info,
                            size: 22,
                          ),
                        ),
                        title: Row(
                          children: [
                            Text(
                              u.name,
                              style: TextStyle(
                                  fontFamily: 'Carlito',
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14.5,
                                  color: u.active ? AppColors.ink : AppColors.faint),
                            ),
                            if (isSelf) ...[
                              const SizedBox(width: 7),
                              StatusPill.build(context,
                                  label: 'You',
                                  foreground: AppColors.primary,
                                  background: AppColors.primarySoft),
                            ],
                            if (!u.active) ...[
                              const SizedBox(width: 7),
                              StatusPill.build(context,
                                  label: 'Inactive',
                                  foreground: AppColors.danger,
                                  background: AppColors.dangerSoft),
                            ],
                          ],
                        ),
                        subtitle: Text(
                            '${u.email} · ${u.isAdmin ? "Admin" : "Cashier"}',
                            style: const TextStyle(fontFamily: 'Carlito', fontSize: 12.5)),
                        trailing: PopupMenuButton<String>(
                          icon: const Icon(Icons.more_vert_rounded, size: 20, color: AppColors.muted),
                          onSelected: (v) async {
                            final a = context.read<AuthProvider>();
                            if (v == 'edit') {
                              _edit(u);
                            } else if (v == 'reset') {
                              _resetPassword(u);
                            } else if (v == 'toggle') {
                              if (isSelf) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text(
                                            'You cannot deactivate your own account')));
                                return;
                              }
                              await a.updateUser(u, active: !u.active);
                              _load();
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(value: 'edit', child: Text('Edit')),
                            const PopupMenuItem(
                                value: 'reset', child: Text('Reset password')),
                            PopupMenuItem(
                                value: 'toggle',
                                child: Text(u.active
                                    ? 'Deactivate'
                                    : 'Reactivate')),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
    );
  }

  Future<void> _resetPassword(AppUser u) async {
    final ctrl = TextEditingController();
    final err = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Reset password for ${u.name}'),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
              labelText: 'New password (min 6 chars)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, 'ok'), child: const Text('Reset')),
        ],
      ),
    );
    if (err == null || ctrl.text.isEmpty || !mounted) return;
    final result = await context.read<AuthProvider>().resetPassword(u.id!, ctrl.text);
    if (mounted && result != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
    } else if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Password reset for ${u.name}')));
    }
  }
}

class _UserEditDialog extends StatefulWidget {
  final AppUser? user;
  const _UserEditDialog({this.user});

  @override
  State<_UserEditDialog> createState() => _UserEditDialogState();
}

class _UserEditDialogState extends State<_UserEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _email;
  late final TextEditingController _password;
  late String _role;
  String? _error;

  bool get _isNew => widget.user == null;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.user?.name ?? '');
    _email = TextEditingController(text: widget.user?.email ?? '');
    _password = TextEditingController();
    _role = widget.user?.role ?? 'cashier';
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
    String? err;
    if (_isNew) {
      err = await auth.createUser(
        name: _name.text,
        email: _email.text,
        role: _role,
        password: _password.text,
      );
    } else {
      err = await auth.updateUser(
        widget.user!.copyWith(name: _name.text.trim(), role: _role),
      );
    }
    if (!mounted) return;
    if (err != null) {
      setState(() => _error = err);
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      title: Row(children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            _isNew ? Icons.person_add_alt_rounded : Icons.manage_accounts_outlined,
            size: 19,
            color: AppColors.primary,
          ),
        ),
        const SizedBox(width: 11),
        Text(_isNew ? 'Add staff account' : 'Edit staff account'),
      ]),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                  labelText: 'Full name *',
                  prefixIcon: Icon(Icons.person_outline_rounded, size: 20)),
            ),
            const SizedBox(height: 13),
            TextField(
              controller: _email,
              enabled: _isNew,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: 'Email (login) *',
                helperText: _isNew ? null : 'Email cannot be changed',
                prefixIcon: const Icon(Icons.alternate_email_rounded, size: 20),
              ),
            ),
            const SizedBox(height: 13),
            DropdownButtonFormField<String>(
              initialValue: _role,
              icon: const Icon(Icons.expand_more_rounded, size: 19),
              decoration: const InputDecoration(labelText: 'Role'),
              items: const [
                DropdownMenuItem(value: 'cashier', child: Text('Cashier — sell & customers')),
                DropdownMenuItem(value: 'admin', child: Text('Admin — full access')),
              ],
              onChanged: (v) => setState(() => _role = v ?? 'cashier'),
            ),
            if (_isNew) ...[
              const SizedBox(height: 13),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'Password * (min 6 chars)',
                    prefixIcon: Icon(Icons.lock_outline_rounded, size: 20)),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: AppColors.dangerSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline_rounded, size: 17, color: AppColors.danger),
                    const SizedBox(width: 8),
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
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
