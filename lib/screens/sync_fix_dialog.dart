import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/cloud_patch.dart';
import '../services/sync_service.dart';
import '../widgets/ui.dart';

/// Opened from the red "Sync issue" pill when the failure is a cloud
/// schema gap ("this app is newer than the cloud database").
///
/// Gives the Manager the two-step fix in plain language:
///  1. copy the fix SQL (pre-formatted, complete, idempotent),
///  2. paste it into the Supabase SQL Editor and run it,
/// then "Retry now" re-probes everything immediately.
///
/// Until the SQL is run, the app KEEPS SYNCING everything it can — the
/// engine degrades gracefully — so this dialog is a fix, not a blocker.
class SyncFixDialog extends StatefulWidget {
  final SyncService sync;
  const SyncFixDialog({super.key, required this.sync});

  /// True when [lastError] describes a cloud schema gap and tapping the
  /// pill should open this dialog instead of just re-running the sync.
  static bool isSchemaGapError(String? lastError) {
    if (lastError == null) return false;
    final l = lastError.toLowerCase();
    return l.contains('schema patch') ||
        l.contains('cloud database') ||
        l.contains('copy the cloud fix sql');
  }

  @override
  State<SyncFixDialog> createState() => _SyncFixDialogState();
}

class _SyncFixDialogState extends State<SyncFixDialog> {
  bool _copied = false;

  Future<void> _copySql() async {
    await Clipboard.setData(ClipboardData(text: kCloudFixSql));
    if (!mounted) return;
    setState(() => _copied = true);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Fix SQL copied — paste it into the Supabase SQL Editor '
          'and press Run'),
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: 4),
    ));
  }

  Future<void> _retry() async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    navigator.pop();
    widget.sync.forgetSchemaGaps();
    await widget.sync.run(manual: true);
    messenger.showSnackBar(const SnackBar(
      content: Text('Re-synced — if the SQL ran, everything is up to date '
          'now'),
      behavior: SnackBarBehavior.floating,
    ));
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
          child: Icon(Icons.cloud_sync_outlined,
              size: 19, color: AppColors.primary),
        ),
        const SizedBox(width: AppSpace.s3),
        const Expanded(child: Text('Fix cloud sync')),
      ]),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment:
            CrossAxisAlignment.start, children: [
          Text(
            'Your shop keeps working — sales are saved on this device and '
            'everything that CAN sync is syncing. One part of the cloud '
            'database is older than this app, so a few fields are waiting.',
            style: TextStyle(
                fontSize: 13, color: AppColors.muted, height: 1.45),
          ),
          const SizedBox(height: AppSpace.s3),
          Container(
            padding: const EdgeInsets.all(AppSpace.s3),
            decoration: BoxDecoration(
              color: AppColors.surfaceTint,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: AppColors.borderSoft),
            ),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('The 60-second fix',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.ink)),
                  const SizedBox(height: AppSpace.s2),
                  _step('1', 'Tap "Copy fix SQL" below.'),
                  _step('2',
                      'Open your Supabase project → SQL Editor → New query.'),
                  _step('3', 'Paste and press Run.'),
                  _step('4', 'Come back here and tap "Retry now".'),
                ]),
          ),
          const SizedBox(height: AppSpace.s3),
          Text(
            'The fix SQL is safe to run any number of times and never '
            'deletes data — it only adds what is missing.',
            style: TextStyle(fontSize: 12, color: AppColors.faint,
                height: 1.4),
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Later')),
        OutlinedButton.icon(
          onPressed: _copySql,
          icon: Icon(_copied ? Icons.check_rounded : Icons.copy_rounded,
              size: 18),
          label: Text(_copied ? 'Copied' : 'Copy fix SQL'),
        ),
        FilledButton.icon(
          onPressed: _retry,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('Retry now'),
        ),
      ],
    );
  }

  Widget _step(String n, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 18,
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: AppColors.primary, shape: BoxShape.circle),
          child: Text(n,
              style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  color: Colors.white)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              style: TextStyle(
                  fontSize: 12.5, color: AppColors.ink, height: 1.35)),
        ),
      ]),
    );
  }
}
