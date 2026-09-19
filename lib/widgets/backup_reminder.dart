import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/auth.dart';
import '../state/settings.dart';
import 'ui.dart';

/// Gentle, dismissible nudge for managers: "export a backup" when this
/// device has never been backed up or the last one is over a week old.
/// Non-web only (file backups do not exist in the browser).
///
/// Lives at the top of the content area on every tab until dismissed
/// (snoozed) or a fresh backup is made — a lost phone with no backup is
/// the one unrecoverable failure mode this app has.
class BackupReminderBanner extends StatelessWidget {
  final VoidCallback onBackup;

  const BackupReminderBanner({super.key, required this.onBackup});

  /// Builds the banner only when it should currently be visible.
  static Widget? maybe(BuildContext context, {required VoidCallback onBackup}) {
    if (kIsWeb) return null;
    final auth = context.watch<AuthProvider>();
    final settings = context.watch<AppSettings>();
    if (!(auth.user?.isAdmin ?? false)) return null;
    if (!settings.backupReminderDue) return null;
    return BackupReminderBanner(onBackup: onBackup);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>();
    final last = s.lastBackupAt;
    final String detail;
    if (last == null || last <= 0) {
      detail = 'This device has never been backed up. If it is lost or '
          'replaced, your shop history goes with it.';
    } else {
      final days =
          ((DateTime.now().millisecondsSinceEpoch ~/ 1000 - last) / 86400)
              .floor();
      detail = 'Last backup was $days day${days == 1 ? '' : 's'} ago. '
          'Export a fresh file and keep it away from this device.';
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(AppSpace.s4, AppSpace.s3, AppSpace.s4, 0),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.s3 + 2, vertical: AppSpace.s2 + 2),
      decoration: BoxDecoration(
        color: AppColors.warningSoft,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.backup_outlined, size: 20, color: AppColors.warning),
          const SizedBox(width: AppSpace.s2 + 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Time for a backup',
                  style: TextStyle(
                      fontFamily: 'Carlito',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink),
                ),
                const SizedBox(height: 1),
                Text(
                  detail,
                  style: TextStyle(
                      fontFamily: 'Carlito',
                      fontSize: 12,
                      height: 1.35,
                      color: AppColors.body),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.s2),
          TextButton(
            onPressed: () async {
              await context
                  .read<AppSettings>()
                  .snoozeBackupReminder(days: 3);
            },
            child: const Text('Not now'),
          ),
          const SizedBox(width: AppSpace.s1),
          FilledButton.tonalIcon(
            onPressed: onBackup,
            icon: const Icon(Icons.file_upload_outlined, size: 17),
            label: const Text('Back up now'),
          ),
        ],
      ),
    );
  }
}
