import 'package:flutter/material.dart';

import '../services/sync_service.dart';
import '../widgets/ui.dart';

/// Compact cloud status pill for the app bar. Makes realtime visible:
///
///  * spinner + "Syncing"  — a push/pull cycle is running
///  * green pulse + "Live" — Supabase Realtime confirmed (SUBSCRIBED):
///    sales and edits from other devices land here within seconds
///  * red dot + "Sync issue" — the last sync failed (tap to retry)
///  * grey dot + "Cloud" — signed in, realtime not confirmed yet
///
/// Tapping the pill always triggers a manual sync.
class SyncStatusPill extends StatelessWidget {
  const SyncStatusPill({super.key});

  @override
  Widget build(BuildContext context) {
    final sync = SyncService.I;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        if (!sync.signedIn) return const SizedBox.shrink();

        Widget lead;
        Color color, soft;
        String label, tip;
        if (sync.isBusy) {
          lead = const SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(strokeWidth: 2),
          );
          color = AppColors.primary;
          soft = AppColors.primarySoft;
          label = 'Syncing';
          tip = 'Syncing with the cloud — tap to sync again';
        } else if (sync.phase == SyncPhase.error) {
          lead = _Dot(AppColors.danger);
          color = AppColors.danger;
          soft = AppColors.dangerSoft;
          label = 'Sync issue';
          tip =
              '${sync.lastError?.split('\n').first ?? 'Sync failed'} — tap to retry';
        } else if (sync.realtimeLive) {
          lead = _PulsingDot(color: AppColors.success);
          color = AppColors.success;
          soft = AppColors.successSoft;
          label = 'Live';
          tip = 'Live updates are on — changes from your other devices '
              'appear here within seconds. Tap to sync now.';
        } else {
          lead = _Dot(AppColors.faint);
          color = AppColors.muted;
          soft = AppColors.surfaceTint;
          label = 'Cloud';
          tip = 'Connected to the cloud — tap to sync now';
        }

        return Tooltip(
          message: tip,
          waitDuration: const Duration(milliseconds: 400),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            onTap: sync.isBusy ? null : () => sync.run(),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.s3, vertical: 5),
              decoration: BoxDecoration(
                color: soft,
                borderRadius: BorderRadius.circular(AppRadius.pill),
                border: Border.all(color: color.withValues(alpha: 0.35)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  lead,
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Static 7px status dot.
class _Dot extends StatelessWidget {
  const _Dot(this.color);
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
        ),
      );
}

/// Softly pulsing dot — a quiet heartbeat for the "Live" state.
class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color});
  final Color color;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.45, end: 1.0).animate(
        CurvedAnimation(parent: _c, curve: Curves.easeInOut),
      ),
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: widget.color.withValues(alpha: 0.55),
              blurRadius: 4,
              spreadRadius: 0.5,
            ),
          ],
        ),
      ),
    );
  }
}
