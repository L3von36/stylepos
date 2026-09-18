import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/cloud_auth.dart';
import '../../services/sync_service.dart';
import '../../widgets/ui.dart';
import 'users_screen.dart';

/// "Cloud sync" settings card: shop identity, status, manual sync,
/// manager reset tools and sign-out. Account creation / sign-in lives
/// on the landing screen's Manager tab.
class CloudSyncCard extends StatefulWidget {
  const CloudSyncCard({super.key});

  @override
  State<CloudSyncCard> createState() => _CloudSyncCardState();
}

class _CloudSyncCardState extends State<CloudSyncCard> {
  bool _busy = false;
  String? _role;
  Map<String, String> _shop = const {};

  @override
  void initState() {
    super.initState();
    _loadRole();
    _loadShop();
  }

  SupabaseClient get _c => Supabase.instance.client;

  Future<void> _loadRole() async {
    final role = await CloudAuth.currentRole();
    if (mounted) setState(() => _role = role);
  }

  Future<void> _loadShop() async {
    try {
      var shop = await CloudAuth.fetchMyShop();
      shop ??= await CloudAuth.rememberedShop();
      if (mounted) setState(() => _shop = shop!);
    } catch (_) {
      try {
        final remembered = await CloudAuth.rememberedShop();
        if (mounted) setState(() => _shop = remembered);
      } catch (_) {}
    }
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

  Future<void> _confirmEraseDevice() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Erase this device\'s data?'),
        content: const Text(
          'Everything on THIS device is deleted, then your shop\'s '
          'cloud data is pulled fresh. Other devices are not affected. '
          'Use this if this phone/PC shows old or wrong data.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppColors.danger,
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Erase & re-pull'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await CloudAuth.eraseLocalData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Device wiped — pulling your shop data…'),
      ));
      await SyncService.I.run();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmClearSales() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear sales history everywhere?'),
        content: const Text(
          'ALL sales, line items and stock movements are deleted from '
          'the cloud AND from every device signed into this shop. '
          'Products, customers and staff are kept. This cannot be undone.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppColors.danger,
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear sales history'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final err = await CloudAuth.clearSalesHistoryEverywhere();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(err ?? 'Sales history cleared on all devices'),
        backgroundColor: err == null ? null : AppColors.danger,
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sync = SyncService.I;
    final signedIn = sync.signedIn;
    final isAdmin = _role == 'admin';

    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) => SectionCard(
        icon: Icons.cloud_sync_outlined,
        title: 'Cloud sync',
        subtitle: 'Share products, stock, sales and reports between devices',
        children: [
          Text(
            'Your shop data lives on this device and syncs through your '
            'cloud when there is internet. Only YOUR shop\'s data is '
            'visible on devices signed into this shop.'
            '${sync.realtimeLive ? ' Live updates are on: sales from other '
                'devices appear here within seconds.' : ''}',
            style: TextStyle(
                fontSize: 12.5, color: AppColors.muted, height: 1.45),
          ),
          const SizedBox(height: AppSpace.s3),
          if (!signedIn) ...[
            Container(
              padding: const EdgeInsets.all(AppSpace.s3),
              decoration: BoxDecoration(
                color: AppColors.surfaceTint,
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: AppColors.borderSoft),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded,
                      size: 16, color: AppColors.faint),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Not connected. Sign out of the till, then use the '
                      'Manager tab on the login screen to open your shop '
                      'account.',
                      style: TextStyle(
                          fontFamily: 'Carlito',
                          fontSize: 12,
                          color: AppColors.muted,
                          height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
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
                        '${_role == null ? "" : "  ·  ${_role == "admin" ? "Manager" : "Sales"}"}'
                        '${sync.realtimeLive ? "  ·  Live" : ""}',
                        style: TextStyle(
                            fontSize: 12,
                            color: sync.lastError != null
                                ? AppColors.danger
                                : AppColors.muted),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if ((_shop['name'] ?? '').isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          '${_shop['name']}'
                          '${(_shop['code'] ?? '').isNotEmpty ? "  ·  shop code ${_shop['code']}" : ""}',
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.faint),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
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
                    onPressed: _busy
                        ? null
                        : () async {
                            setState(() => _busy = true);
                            await CloudAuth.signOut();
                            if (mounted) {
                              setState(() {
                                _busy = false;
                                _role = null;
                              });
                            }
                          },
                    icon: const Icon(Icons.logout, size: 18),
                    label: const Text('Sign out'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.s3),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 46)),
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const UsersScreen())),
              icon: const Icon(Icons.manage_accounts_outlined, size: 18),
              label: const Text('Staff accounts (add cashiers)'),
            ),
            if (isAdmin) ...[
              const SizedBox(height: AppSpace.s4),
              Text(
                'Manager tools',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: AppColors.faint),
              ),
              const SizedBox(height: AppSpace.s2),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 46),
                        foregroundColor: AppColors.danger,
                      ),
                      onPressed:
                          _busy ? null : () => _confirmEraseDevice(),
                      icon: const Icon(Icons.restart_alt_rounded, size: 18),
                      label: const Text('Erase this device & re-pull'),
                    ),
                  ),
                  const SizedBox(width: AppSpace.s3),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 46),
                        foregroundColor: AppColors.danger,
                      ),
                      onPressed:
                          _busy ? null : () => _confirmClearSales(),
                      icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                      label: const Text('Clear sales history everywhere'),
                    ),
                  ),
                ],
              ),
            ],
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
