import 'package:flutter/material.dart';

import '../../services/audit.dart';
import '../../widgets/ui.dart';

/// Manager view of the audit trail: who did what, when (refunds,
/// approvals, stock adjustments, day closes, staff changes, backups).
/// Local to this device.
class AuditLogScreen extends StatefulWidget {
  const AuditLogScreen({super.key});

  @override
  State<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends State<AuditLogScreen> {
  List<AuditEntry>? _entries;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await Audit.list(limit: 300);
    if (mounted) setState(() => _entries = entries);
  }

  String _when(int epoch) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    final now = DateTime.now();
    final day = '${two(dt.day)}/${two(dt.month)}';
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return 'Today ${two(dt.hour)}:${two(dt.minute)}';
    }
    return '$day ${two(dt.hour)}:${two(dt.minute)}';
  }

  (IconData, Color) _visual(String action) => switch (action) {
        'refund' => (Icons.undo_rounded, AppColors.danger),
        'discount_approved' => (Icons.percent_rounded, AppColors.warning),
        'stock_adjust' => (Icons.inventory_rounded, AppColors.info),
        'day_close' => (Icons.event_available_rounded, AppColors.success),
        'day_reopen' => (Icons.event_busy_rounded, AppColors.warning),
        'staff_created' => (Icons.person_add_alt_rounded, AppColors.primary),
        'staff_updated' => (Icons.manage_accounts_outlined, AppColors.primary),
        'password_reset' => (Icons.lock_reset_outlined, AppColors.primary),
        'pin_changed' => (Icons.password_rounded, AppColors.primary),
        'backup_exported' => (Icons.backup_outlined, AppColors.success),
        'restore' => (Icons.restore_outlined, AppColors.warning),
        'sales_cleared' => (Icons.delete_sweep_outlined, AppColors.danger),
        'csv_import' => (Icons.upload_file_outlined, AppColors.info),
        _ => (Icons.history_rounded, AppColors.muted),
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Audit log'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, size: 22),
            onPressed: _load,
          ),
          const SizedBox(width: AppSpace.s1),
        ],
      ),
      body: _entries == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(AppSpace.s4),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 660),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_entries!.isEmpty)
                            const EmptyState(
                              icon: Icons.history_rounded,
                              title: 'Nothing recorded yet',
                              message:
                                  'Refunds, approvals, stock adjustments, day '
                                  'closes and staff changes are logged here '
                                  'as they happen.',
                            )
                          else
                            for (final e in _entries!)
                              Container(
                                margin:
                                    const EdgeInsets.only(bottom: AppSpace.s2),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpace.s3,
                                    vertical: AppSpace.s2 + 2),
                                decoration: BoxDecoration(
                                  color: AppColors.surface,
                                  borderRadius:
                                      BorderRadius.circular(AppRadius.md),
                                  border:
                                      Border.all(color: AppColors.borderSoft),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      width: 34,
                                      height: 34,
                                      decoration: BoxDecoration(
                                        color: AppColors.surfaceTint,
                                        borderRadius: BorderRadius.circular(
                                            AppRadius.sm),
                                      ),
                                      child: Icon(_visual(e.action).$1,
                                          size: 18,
                                          color: _visual(e.action).$2),
                                    ),
                                    const SizedBox(width: AppSpace.s3),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  AuditEntry.actionLabels[
                                                          e.action] ??
                                                      e.action,
                                                  style: TextStyle(
                                                      fontFamily: 'Carlito',
                                                      fontSize: 13.5,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      color: AppColors.ink),
                                                ),
                                              ),
                                              Text(_when(e.createdAt),
                                                  style: TextStyle(
                                                      fontFamily: 'Carlito',
                                                      fontSize: 11.5,
                                                      color: AppColors.faint)),
                                            ],
                                          ),
                                          if (e.details != null &&
                                              e.details!.isNotEmpty)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                  top: 2),
                                              child: Text(e.details!,
                                                  style: TextStyle(
                                                      fontFamily: 'Carlito',
                                                      fontSize: 12.5,
                                                      color: AppColors.muted)),
                                            ),
                                          if (e.userName != null &&
                                              e.userName!.isNotEmpty)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                  top: 2),
                                              child: Text(
                                                  'by ${e.userName}',
                                                  style: TextStyle(
                                                      fontFamily: 'Carlito',
                                                      fontSize: 11.5,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      color: AppColors.faint)),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          if (_entries!.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: AppSpace.s2),
                              child: Text(
                                'The audit log is stored on this device and '
                                'covers actions taken here.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontFamily: 'Carlito',
                                    fontSize: 11.5,
                                    color: AppColors.faint),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
