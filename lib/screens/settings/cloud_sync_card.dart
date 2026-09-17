import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/sync_service.dart';
import '../../widgets/ui.dart';

/// "Cloud sync" settings card: Supabase sign up / in / out plus a manual
/// sync trigger and status. The cloud account is what authorizes this
/// device to share the shop dataset (Row Level Security).
class CloudSyncCard extends StatefulWidget {
  const CloudSyncCard({super.key});

  @override
  State<CloudSyncCard> createState() => _CloudSyncCardState();
}

class _CloudSyncCardState extends State<CloudSyncCard> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _name = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _role;

  @override
  void initState() {
    super.initState();
    _loadRole();
  }

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    _name.dispose();
    super.dispose();
  }

  SupabaseClient get _c => Supabase.instance.client;

  Future<void> _loadRole() async {
    try {
      final uid = _c.auth.currentSession?.user.id;
      if (uid == null) return;
      final row = await _c.from('app_users').select('role').eq('id', uid).maybeSingle();
      if (mounted) setState(() => _role = row?['role'] as String?);
    } catch (_) {
      // Non-fatal; the role badge just stays empty.
    }
  }

  Future<void> _toast(String msg, {bool error = false}) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? AppColors.danger : null,
    ));
  }

  /// After auth: make sure a staff row exists for this login, let the very
  /// first shop member claim the admin role, then sync.
  Future<void> _afterAuth() async {
    final user = _c.auth.currentUser;
    if (user != null) {
      final name = _name.text.trim().isNotEmpty
          ? _name.text.trim()
          : (user.email?.split('@').first ?? 'Staff');
      try {
        await _c.from('app_users').upsert(
          {'id': user.id, 'name': name},
          onConflict: 'id',
          ignoreDuplicates: true,
        );
      } catch (_) {// Row may already exist — fine.
      }
      try {
        await _c.rpc('claim_admin_if_first');
      } catch (_) {// First admin already claimed — fine.
      }
    }
    await _loadRole();
    if (mounted) setState(() {});
    SyncService.I.scheduleSync(const Duration(seconds: 1));
  }

  Future<void> _signUp() async {
    setState(() => _busy = true);
    try {
      final res = await _c.auth.signUp(
        email: _email.text.trim(),
        password: _pass.text,
      );
      if (res.session == null) {
        await _toast('Account created! Check your email for a confirmation '
            'link, then sign in here.');
      } else {
        await _afterAuth();
        await _toast('Welcome to the cloud! This account is the shop admin.');
      }
    } on AuthException catch (e) {
      await _toast(e.message, error: true);
    } catch (_) {
      await _toast('Sign up failed — check your connection', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signIn() async {
    setState(() => _busy = true);
    try {
      await _c.auth.signInWithPassword(
        email: _email.text.trim(),
        password: _pass.text,
      );
      await _afterAuth();
      await _toast('Signed in — syncing…');
    } on AuthException catch (e) {
      if (e.message.toLowerCase().contains('not confirmed')) {
        await _toast('Email not confirmed yet — click the link we sent you. '
            '(Or disable "Confirm email" in the Supabase dashboard.)',
            error: true);
      } else {
        await _toast(e.message, error: true);
      }
    } catch (_) {
      await _toast('Sign in failed — check your connection', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    try {
      await _c.auth.signOut();
    } catch (_) {// Session may already be gone.
    }
    if (mounted) setState(() => _role = null);
  }

  String _statusLine(SyncService sync) {
    if (sync.isBusy) return 'Syncing…';
    if (sync.lastError != null) {
      return 'Sync problem: ${sync.lastError!.split('\n').first}';
    }
    final last = sync.lastSyncAt;
    if (last == null) return 'Signed in — waiting to sync';
    return 'Last sync ${_timeAgo(last)}';
  }

  String _timeAgo(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  @override
  Widget build(BuildContext context) {
    final sync = SyncService.I;
    final signedIn = sync.signedIn;

    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) => SectionCard(
        icon: Icons.cloud_sync_outlined,
        title: 'Cloud sync',
        subtitle: 'Share products, stock and customers between phone and PC',
        children: [
          Text(
            'Your shop data lives on this device and syncs through your '
            'Supabase cloud when there is internet. The till keeps working '
            'normally with no internet and catches up later.',
            style: TextStyle(
                fontSize: 12.5, color: AppColors.muted, height: 1.45),
          ),
          const SizedBox(height: AppSpace.s3),
          if (!signedIn) ...[
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                  labelText: 'Your name (used once, for the staff list)'),
            ),
            const SizedBox(height: AppSpace.s3),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration:
                  const InputDecoration(labelText: 'Cloud email'),
            ),
            const SizedBox(height: AppSpace.s3),
            TextField(
              controller: _pass,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Cloud password',
                suffixIcon: IconButton(
                  icon: Icon(_obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.s4),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 46)),
                    onPressed: _busy ? null : _signIn,
                    icon: const Icon(Icons.login, size: 18),
                    label: const Text('Sign in'),
                  ),
                ),
                const SizedBox(width: AppSpace.s3),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 46)),
                    onPressed: _busy ? null : _signUp,
                    icon: const Icon(Icons.person_add_alt_1, size: 18),
                    label: const Text('Create account'),
                  ),
                ),
              ],
            ),
            if (_busy) ...[
              const SizedBox(height: AppSpace.s3),
              const LinearProgressIndicator(),
            ],
          ] else ...[
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.primarySoft,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Icon(
                    sync.isBusy
                        ? Icons.sync_rounded
                        : (sync.phase == SyncPhase.error
                            ? Icons.cloud_off_outlined
                            : Icons.cloud_done_outlined),
                    color: sync.phase == SyncPhase.error
                        ? AppColors.danger
                        : AppColors.primary,
                    size: 22,
                  ),
                ),
                const SizedBox(width: AppSpace.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _c.auth.currentSession?.user.email ?? '',
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppColors.ink),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${_statusLine(sync)}'
                        '${_role == null ? "" : "  ·  ${_role == "admin" ? "Manager" : "Sales"}"}',
                        style: TextStyle(
                            fontSize: 12,
                            color: sync.lastError != null
                                ? AppColors.danger
                                : AppColors.muted),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.s3),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 46)),
                    onPressed: sync.isBusy ? null : () => SyncService.I.run(),
                    icon: const Icon(Icons.sync_rounded, size: 18),
                    label: const Text('Sync now'),
                  ),
                ),
                const SizedBox(width: AppSpace.s3),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 46)),
                    onPressed: _busy ? null : _signOut,
                    icon: const Icon(Icons.logout, size: 18),
                    label: const Text('Sign out'),
                  ),
                ),
              ],
            ),
            if (sync.isBusy) ...[
              const SizedBox(height: AppSpace.s3),
              const LinearProgressIndicator(),
            ],
          ],
        ],
      ),
    );
  }
}
