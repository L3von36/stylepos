import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/cloud_auth.dart';
import '../../services/sync_service.dart';
import '../../widgets/ui.dart';
import 'users_screen.dart';

/// "Cloud sync" settings card: shop identity, status, manual sync and the
/// staff-accounts shortcut. Sign-out lives in the account sheet (phone) and
/// the sidebar (desktop); account creation / sign-in lives on the landing
/// screen's Manager tab.
class CloudSyncCard extends StatefulWidget {
  const CloudSyncCard({super.key});

  @override
  State<CloudSyncCard> createState() => _CloudSyncCardState();
}

class _CloudSyncCardState extends State<CloudSyncCard> {
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

  @override
  Widget build(BuildContext context) {
    final sync = SyncService.I;
    final signedIn = sync.signedIn;

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
                fontSize: 12, color: AppColors.muted, height: 1.45),
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
                  Icon(Icons.info_outline_rounded,
                      size: 16, color: AppColors.faint),
                  const SizedBox(width: 8),
                  Expanded(
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
                        style: TextStyle(
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
                          style: TextStyle(
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
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
              onPressed: sync.isBusy ? null : () => SyncService.I.run(),
              icon: const Icon(Icons.sync_rounded, size: 18),
              label: const Text('Sync now'),
            ),
            const SizedBox(height: AppSpace.s3),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 46)),
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const UsersScreen())),
              icon: const Icon(Icons.manage_accounts_outlined, size: 18),
              label: const Text('Staff accounts (add cashiers)'),
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
