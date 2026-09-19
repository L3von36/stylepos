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
/// Shows as a slim, quiet strip at the top of the Sell tab only — loud
/// amber blocks on every tab read as an error, not a reminder.
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
    final never = last == null || last <= 0;
    final String detail;
    if (never) {
      detail = 'Never backed up on this device — export a file and keep '
          'it off this phone.';
    } else {
      final days =
          ((DateTime.now().millisecondsSinceEpoch ~/ 1000 - last) / 86400)
              .floor();
      detail = 'Last backup was $days day${days == 1 ? '' : 's'} ago — '
          'export a fresh file.';
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(AppSpace.s4, AppSpace.s3, AppSpace.s4, 0),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: AppColors.warningSoft,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.55),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.backup_outlined, size: 17, color: AppColors.warning),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  never ? 'No backup yet' : 'Backup due',
                  style: TextStyle(
                      fontFamily: 'Carlito',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink),
                ),
                const SizedBox(height: 1),
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: 'Carlito',
                      fontSize: 11.5,
                      height: 1.3,
                      color: AppColors.body),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          TextButton(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              textStyle: TextStyle(
                  fontFamily: 'Carlito',
                  fontSize: 12,
                  fontWeight: FontWeight.w600),
            ),
            onPressed: () async {
              await context.read<AppSettings>().snoozeBackupReminder(days: 3);
            },
            child: const Text('Later'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              backgroundColor: AppColors.warning,
              foregroundColor: AppColors.isDark
                  ? const Color(0xFF39300E)
                  : Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              textStyle: TextStyle(
                  fontFamily: 'Carlito',
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700),
            ),
            onPressed: onBackup,
            child: const Text('Back up'),
          ),
        ],
      ),
    );
  }
}
