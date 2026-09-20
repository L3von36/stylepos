import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/branches.dart';
import '../../services/sync_service.dart';
import '../../state/auth.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';
import '../sync_fix_dialog.dart';

/// Manager-only: sales totals for every shop in the manager's branch tree
/// (root shop + branches) via the `branch_sales_overview` cloud RPC — the
/// owner's answer to "which branch sold what" without hopping workspaces.
///
/// If the cloud predates the RPC, the card offers the guided fix-SQL flow
/// (same two-step as the sync pill) instead of an error.
class BranchesOverviewCard extends StatefulWidget {
  const BranchesOverviewCard({super.key});

  @override
  State<BranchesOverviewCard> createState() => _BranchesOverviewCardState();
}

class _BranchesOverviewCardState extends State<BranchesOverviewCard> {
  List<BranchSales>? _rows;
  bool _needsCloudFix = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final (rows, needsFix) = await Branches.overview();
    if (mounted) {
      setState(() {
        _rows = rows;
        _needsCloudFix = needsFix;
      });
    }
  }

  Future<void> _openFixDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) => SyncFixDialog(sync: SyncService.I),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = context.watch<AuthProvider>().user?.isAdmin ?? false;
    if (!isAdmin) return const SizedBox.shrink();

    final settings = context.watch<AppSettings>();
    final rows = _rows;

    // Signed out / offline / transient cloud hiccup: stay out of the way.
    if (!_needsCloudFix && (rows == null || rows.isEmpty)) {
      return const SizedBox.shrink();
    }

    return SectionCard(
      icon: Icons.account_tree_rounded,
      title: 'Branch sales',
      subtitle: _needsCloudFix
          ? 'One-time cloud update needed'
          : 'Every shop in your branch tree, at a glance',
      children: [
        if (_needsCloudFix) ...[
          Text(
            'Your cloud database predates the branch-totals function, so '
            'cross-branch numbers can\'t be fetched yet. Everything else '
            'keeps working — run the one-time fix SQL to unlock this card.',
            style: TextStyle(fontSize: 12.5, color: AppColors.muted,
                height: 1.45),
          ),
          const SizedBox(height: AppSpace.s3),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: _openFixDialog,
              icon: const Icon(Icons.cloud_sync_outlined, size: 18),
              label: const Text('Fix cloud sync'),
            ),
          ),
        ] else ...[
          for (final b in rows!) _BranchTile(branch: b, settings: settings),
          if (rows.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.s2),
              child: Text(
                'Switch this device to another branch from Settings → '
                'Branches to see its full catalog, staff and reports.',
                style: TextStyle(
                    fontSize: 11.5,
                    color: AppColors.faint,
                    fontStyle: FontStyle.italic,
                    height: 1.4),
              ),
            ),
        ],
      ],
    );
  }
}

class _BranchTile extends StatelessWidget {
  final BranchSales branch;
  final AppSettings settings;
  const _BranchTile({required this.branch, required this.settings});

  @override
  Widget build(BuildContext context) {
    final b = branch;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.s2),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.s3, vertical: AppSpace.s2),
      decoration: BoxDecoration(
        color: AppColors.surfaceTint,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(
            color: b.isCurrent ? AppColors.primary : AppColors.borderSoft,
            width: b.isCurrent ? 1.2 : 1),
      ),
      child: Row(
        children: [
          Icon(
            b.isCurrent ? Icons.storefront_rounded : Icons.store_outlined,
            size: 20,
            color: b.isCurrent ? AppColors.primary : AppColors.muted,
          ),
          const SizedBox(width: AppSpace.s2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(b.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontFamily: 'Carlito',
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: AppColors.ink)),
                    ),
                    if (b.isCurrent) ...[
                      const SizedBox(width: AppSpace.s2),
                      StatusPill.build(context,
                          label: 'This device',
                          foreground: AppColors.primary,
                          background: AppColors.primarySoft),
                    ],
                  ],
                ),
                Text(
                  'code ${b.code} · All time: ${settings.money(b.revenue)}'
                  ' (${b.orders} order${b.orders == 1 ? '' : 's'})',
                  style: TextStyle(
                      fontFamily: 'Carlito', fontSize: 11.5,
                      color: AppColors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.s2),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('TODAY',
                  style: TextStyle(
                      fontFamily: 'Carlito',
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                      color: AppColors.faint)),
              Text(settings.money(b.todayRevenue),
                  style: TextStyle(
                      fontFamily: 'Carlito',
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: b.todayRevenue > 0
                          ? AppColors.primary
                          : AppColors.muted)),
              Text('${b.todayOrders} sale${b.todayOrders == 1 ? '' : 's'}',
                  style: TextStyle(
                      fontFamily: 'Carlito', fontSize: 11,
                      color: AppColors.muted)),
            ],
          ),
        ],
      ),
    );
  }
}
