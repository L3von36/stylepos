import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/cloud_auth.dart';
import '../../services/sync_service.dart';
import '../../widgets/ui.dart';

/// "Cloud sync" settings card: status, manual sync trigger and sign-out.
/// Account creation / sign-in lives on the landing screen's Cloud tab.
class CloudSyncCard extends StatefulWidget {
  const CloudSyncCard({super.key});

  @override
  State<CloudSyncCard> createState() => _CloudSyncCardState();
}

class _CloudSyncCardState extends State<CloudSyncCard> {
  bool _busy = false;
  String? _role;

  @override
  void initState() {
    super.initState();
    _loadRole();
  }

  SupabaseClient get _c => Supabase.instance.client;

  Future<void> _loadRole() async {
    final role = await CloudAuth.currentRole();
    if (mounted) setState(() => _role = role);
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
            'Supabase cloud when there is internet. The till keeps working '
            'normally with no internet and catches up later.'
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
                      'Cloud tab on the login screen to create or open '
                      'your shop account.',
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
