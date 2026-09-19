import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/database.dart';
import '../../services/audit.dart';
import '../../state/auth.dart';
import '../../state/commissions.dart';
import '../../state/sales.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';

/// Profit & margins for the selected period: revenue vs cost of goods,
/// gross profit, margin %, and the best-earning products.
class MarginCard extends StatefulWidget {
  final int days;
  const MarginCard({super.key, required this.days});

  @override
  State<MarginCard> createState() => _MarginCardState();
}

class _MarginCardState extends State<MarginCard> {
  double? _revenue;
  double? _cogs;
  List<({String name, int units, double revenue, double cost})>? _margins;
  int _lastRevision = -1;

  @override
  void initState() {
    super.initState();
    _lastRevision = context.read<SalesProvider>().revision;
    _load();
  }

  @override
  void didUpdateWidget(covariant MarginCard old) {
    super.didUpdateWidget(old);
    if (old.days != widget.days) _load();
  }

  Future<void> _load() async {
    final sales = context.read<SalesProvider>();
    final rev = await sales.summary(widget.days);
    final cogs = await sales.cogs(widget.days);
    final margins = await sales.productMargins(widget.days, limit: 6);
    if (!mounted) return;
    setState(() {
      _revenue = rev.revenue;
      _cogs = cogs;
      _margins = margins;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Realtime: reload when sales land from other devices.
    final rev = context.watch<SalesProvider>().revision;
    if (rev != _lastRevision) {
      _lastRevision = rev;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
    final settings = context.watch<AppSettings>();
    final money = settings.money;
    final revenue = _revenue ?? 0;
    final cogs = _cogs ?? 0;
    final profit = revenue - cogs;
    final pct = revenue > 0 ? (profit / revenue * 100) : 0.0;
    final margins = _margins ?? const [];

    return SectionCard(
      icon: Icons.trending_up_rounded,
      title: 'Profit & margins',
      subtitle: 'Revenue vs cost of goods in the selected period',
      children: [
        LayoutBuilder(builder: (context, lc) {
          // 4-up fits wide screens; on phones the labels truncated
          // ("COST OF GO…") — switch to a 2x2 grid below 420dp.
          final cells = [
            _figure(context, 'Revenue', money(revenue), AppColors.ink),
            _figure(context, 'Cost of goods', money(cogs), AppColors.muted),
            _figure(context, 'Gross profit', money(profit),
                profit >= 0 ? AppColors.success : AppColors.danger),
            _figure(
                context,
                'Margin',
                '${pct.toStringAsFixed(pct.abs() >= 100 ? 0 : 1)}%',
                AppColors.primary),
          ];
          if (lc.maxWidth < 420) {
            return Wrap(
              spacing: AppSpace.s3,
              runSpacing: AppSpace.s3,
              children: [
                for (final cell in cells)
                  SizedBox(width: (lc.maxWidth - AppSpace.s3) / 2, child: cell),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: cells[0]),
              const SizedBox(width: AppSpace.s3),
              Expanded(child: cells[1]),
              const SizedBox(width: AppSpace.s3),
              Expanded(child: cells[2]),
              const SizedBox(width: AppSpace.s3),
              Expanded(child: cells[3]),
            ],
          );
        }),
        const SizedBox(height: AppSpace.s4),
        if (margins.isEmpty)
          const EmptyState(
            icon: Icons.trending_up_outlined,
            title: 'No sales in this period',
            message: 'Per-product margins appear once sales are recorded.',
          )
        else ...[
          Text('TOP EARNERS · PROFIT PER PRODUCT',
              style: TextStyle(
                  fontFamily: 'Carlito',
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: AppColors.muted)),
          const SizedBox(height: AppSpace.s2),
          for (final m in margins) ...[
            _marginRow(context, m, money),
            const SizedBox(height: AppSpace.s2),
          ],
        ],
      ],
    );
  }

  Widget _figure(BuildContext context, String label, String value, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(),
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontFamily: 'Carlito',
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                color: AppColors.muted)),
        const SizedBox(height: 2),
        // FittedBox: full value stays readable (shrinks) instead of
        // being cut to "KSh 1,…" in the 4-up strip on phones.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value,
              style: TextStyle(
                  fontFamily: 'Carlito',
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: color)),
        ),
      ],
    );
  }

  Widget _marginRow(
      BuildContext context,
      ({String name, int units, double revenue, double cost}) m,
      String Function(double) money) {
    final profit = m.revenue - m.cost;
    final pct = m.revenue > 0 ? profit / m.revenue * 100 : 0.0;
    return Row(children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(m.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: 'Carlito',
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.ink)),
            Text('${m.units} sold · ${money(m.revenue)} revenue',
                style: TextStyle(
                    fontFamily: 'Carlito', fontSize: 12, color: AppColors.muted)),
          ],
        ),
      ),
      const SizedBox(width: AppSpace.s3),
      Text('${pct.toStringAsFixed(pct.abs() >= 100 ? 0 : 1)}%',
          style: TextStyle(
              fontFamily: 'Carlito',
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: profit >= 0 ? AppColors.success : AppColors.danger)),
      const SizedBox(width: AppSpace.s2),
      SizedBox(
        width: 88,
        child: Text(money(profit),
            textAlign: TextAlign.right,
            style: TextStyle(
                fontFamily: 'Carlito',
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.ink)),
      ),
    ]);
  }
}

/// Who sold what, how much — and what each salesperson earned in
/// commission so far (manager feature).
class StaffPerformanceCard extends StatefulWidget {
  final int days;
  const StaffPerformanceCard({super.key, required this.days});

  @override
  State<StaffPerformanceCard> createState() => _StaffPerformanceCardState();
}

class _StaffPerformanceCardState extends State<StaffPerformanceCard> {
  List<({int userId, String name, int orders, int items, double revenue, double discount})>? _rows;
  Map<int, double>? _pending;
  Map<int, double>? _rates;
  int _lastRevision = -1;

  @override
  void initState() {
    super.initState();
    _lastRevision = context.read<SalesProvider>().revision;
    _load();
  }

  @override
  void didUpdateWidget(covariant StaffPerformanceCard old) {
    super.didUpdateWidget(old);
    if (old.days != widget.days) _load();
  }

  Future<void> _load() async {
    final sales = context.read<SalesProvider>();
    final commissions = context.read<CommissionsProvider>();
    final db = await DB.instance();
    final rows = await sales.staffPerformanceDetailed(widget.days);
    final pending = await commissions.pendingByUser();
    final users = await db.query('users', columns: ['id', 'commission_rate']);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _pending = pending;
      _rates = {for (final u in users) u['id'] as int: (u['commission_rate'] as num? ?? 0).toDouble()};
    });
  }

  @override
  Widget build(BuildContext context) {
    final rev = context.watch<SalesProvider>().revision;
    if (rev != _lastRevision) {
      _lastRevision = rev;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
    final settings = context.watch<AppSettings>();
    final money = settings.money;
    final rows = _rows ?? const [];
    final header = TextStyle(
        fontFamily: 'Carlito',
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.3,
        color: AppColors.muted);

    return SectionCard(
      icon: Icons.groups_rounded,
      title: 'Staff performance',
      subtitle: 'Sales and commission earned in the selected period',
      children: [
        if (rows.isEmpty)
          const EmptyState(
            icon: Icons.groups_outlined,
            title: 'No sales in this period',
            message: 'Per-staff performance appears once sales are recorded.',
          )
        else ...[
          // Responsive: the 5-column table only fits wide screens. On
          // phones the headers wrapped and visually merged ("ORDERS ·
          // ITEMS" became "S… ITEMS") — below 560dp each staff member
          // gets a two-line card instead.
          LayoutBuilder(builder: (context, lc) {
            final wide = lc.maxWidth >= 560;
            return Column(
              children: [
                if (wide)
                  _wideTable(rows, header, money)
                else
                  for (final r in rows) ...[
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: AppSpace.s2),
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpace.s3, vertical: AppSpace.s2),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceTint,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        border: Border.all(color: AppColors.borderSoft),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(r.name,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontFamily: 'Carlito',
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.ink)),
                              ),
                              Text('${r.orders} · ${r.items}',
                                  style: TextStyle(
                                      fontFamily: 'Carlito',
                                      fontSize: 12,
                                      color: AppColors.muted)),
                            ],
                          ),
                          const SizedBox(height: AppSpace.s1),
                          // metrics line: FittedBox keeps long money
                          // strings from clipping on the smallest phones
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '${money(r.revenue)} revenue'
                              '${r.discount > 0 ? ' · -${money(r.discount)} disc.' : ''}'
                              ' · ${_pending?[r.userId] != null && _pending![r.userId]! > 0 ? '${money(_pending![r.userId]!)} pending' : ((_rates?[r.userId] ?? 0) > 0 ? 'nothing pending' : 'no commission')}',
                              style: TextStyle(
                                  fontFamily: 'Carlito',
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.primary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                const SizedBox(height: AppSpace.s1),
                Text(
                  'Commission = pending payouts in the ledger. A dash means '
                  'the staff member earns commission but nothing is pending.',
                  style: TextStyle(
                      fontFamily: 'Carlito', fontSize: 11, color: AppColors.faint),
                ),
              ],
            );
          }),
        ],
      ],
    );
  }

  /// The full 5-column table — wide screens only (the phone variant above
  /// stacks each staff member into its own card).
  Widget _wideTable(
      List<({int userId, String name, int orders, int items, double revenue, double discount})>
          rows,
      TextStyle header,
      String Function(double) money) {
    return Column(
      children: [
        Row(children: [
          Expanded(flex: 4, child: Text('STAFF', style: header)),
          Expanded(
              flex: 2,
              child: Text('ORDERS · ITEMS', textAlign: TextAlign.right, style: header)),
          Expanded(
              flex: 3,
              child: Text('REVENUE', textAlign: TextAlign.right, style: header)),
          Expanded(
              flex: 3,
              child: Text('DISCOUNTS', textAlign: TextAlign.right, style: header)),
          Expanded(
              flex: 3,
              child: Text('COMMISSION', textAlign: TextAlign.right, style: header)),
        ]),
        const SizedBox(height: AppSpace.s2),
        for (final r in rows) ...[
          Row(children: [
              Expanded(
                flex: 4,
                child: Text(r.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: 'Carlito',
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink)),
              ),
              Expanded(
                flex: 2,
                child: Text('${r.orders} · ${r.items}',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        fontFamily: 'Carlito', fontSize: 12, color: AppColors.body)),
              ),
              Expanded(
                flex: 3,
                child: Text(money(r.revenue),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        fontFamily: 'Carlito',
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink)),
              ),
              Expanded(
                flex: 3,
                child: Text(r.discount > 0 ? '-${money(r.discount)}' : '—',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        fontFamily: 'Carlito',
                        fontSize: 12,
                        color: r.discount > 0 ? AppColors.warning : AppColors.faint)),
              ),
              Expanded(
                flex: 3,
                child: Text(
                  _pending?[r.userId] != null && _pending![r.userId]! > 0
                      ? money(_pending![r.userId]!)
                      : ((_rates?[r.userId] ?? 0) > 0 ? '—' : '·'),
                  textAlign: TextAlign.right,
                  style: TextStyle(
                      fontFamily: 'Carlito',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.success),
                ),
              ),
            ]),
            const SizedBox(height: AppSpace.s2),
          ],
      ],
    );
  }
}

/// The commission ledger: pending payouts per salesperson, mark-paid, and
/// manual adjustments (bonuses / deductions).
class CommissionsCard extends StatefulWidget {
  const CommissionsCard({super.key});

  @override
  State<CommissionsCard> createState() => _CommissionsCardState();
}

class _CommissionsCardState extends State<CommissionsCard> {
  @override
  void initState() {
    super.initState();
    final commissions = context.read<CommissionsProvider>();
    Future.microtask(() => commissions.reload());
  }

  Future<(int, String)?> _pickStaff() async {
    final db = await DB.instance();
    final users = await db.query('users',
        columns: ['id', 'name', 'role'],
        where: 'active = 1',
        orderBy: 'name');
    if (!mounted) return null;
    return showDialog<(int, String)>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Adjust commission for…'),
        children: [
          for (final u in users)
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.pop(c, (u['id'] as int, u['name'] as String)),
              child: Text('${u['name']}${u['role'] == 'admin' ? ' (Manager)' : ''}',
                  style: TextStyle(fontFamily: 'Carlito', fontSize: 14)),
            ),
        ],
      ),
    );
  }

  Future<void> _addAdjustment() async {
    final staff = await _pickStaff();
    if (staff == null || !mounted) return;
    final amountCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Commission adjustment · ${staff.$2}'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: amountCtrl,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: 'Amount (negative for a deduction)'),
              ),
              const SizedBox(height: AppSpace.s3),
              TextField(
                controller: noteCtrl,
                decoration: const InputDecoration(
                    labelText: 'Note (bonus, cash advance…)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
        ],
      ),
    );
    final amount = double.tryParse(amountCtrl.text);
    if (ok != true || amount == null || amount == 0 || !mounted) return;
    final me = context.read<AuthProvider>().user;
    final moneyStr = settings.money(amount);
    final note = noteCtrl.text.trim();
    await context.read<CommissionsProvider>().addAdjustment(
        userId: staff.$1, amount: amount, note: note);
    await Audit.add('commission_adjustment',
        '${staff.$2} · $moneyStr${note.isEmpty ? '' : ' · $note'}',
        userId: me?.id, userName: me?.name);
  }

  AppSettings get settings => context.read<AppSettings>();

  @override
  Widget build(BuildContext context) {
    final c = context.watch<CommissionsProvider>();
    final settings = context.watch<AppSettings>();
    final money = settings.money;
    final period =
        '${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}';
    final pendingRows = c.rows.where((r) => !r.c.isPaid).toList();
    final paidThisMonth = c.rows
        .where((r) => r.c.isPaid && r.c.period == period)
        .fold<double>(0, (t, r) => t + r.c.amount);

    return SectionCard(
      icon: Icons.payments_rounded,
      title: 'Commissions',
      subtitle: 'What your salespeople have earned and been paid',
      action: Row(mainAxisSize: MainAxisSize.min, children: [
        TextButton.icon(
          onPressed: _addAdjustment,
          icon: const Icon(Icons.add_rounded, size: 16),
          label: const Text('Adjustment'),
        ),
      ]),
      children: [
        Row(children: [
          Expanded(
            child: _totalTile(context, 'Pending payouts', money(
                pendingRows.fold<double>(0, (t, r) => t + r.c.amount)),
                AppColors.warning),
          ),
          const SizedBox(width: AppSpace.s3),
          Expanded(
            child: _totalTile(context, 'Paid this month', money(paidThisMonth),
                AppColors.success),
          ),
        ]),
        const SizedBox(height: AppSpace.s3),
        if (pendingRows.isEmpty)
          const EmptyState(
            icon: Icons.payments_outlined,
            title: 'Nothing pending',
            message: 'Commission earned on sales appears here until you pay it out.',
          )
        else
          for (final r in pendingRows.take(8))
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.s2),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.userName,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontFamily: 'Carlito',
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: AppColors.ink)),
                      Text(
                        '${r.c.isAdjustment ? 'Adjustment' : 'Sale'}'
                        '${r.c.saleId != null ? '' : ''}'
                        '${r.c.period.isNotEmpty ? ' · ${r.c.period}' : ''}'
                        '${r.c.note?.isNotEmpty ?? false ? ' · ${r.c.note}' : ''}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 12,
                            color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
                Text(money(r.c.amount),
                    style: TextStyle(
                        fontFamily: 'Carlito',
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink)),
                const SizedBox(width: AppSpace.s2),
                if (!r.c.isAdjustment)
                  SizedBox(
                    height: 32,
                    child: FilledButton.tonal(
                      style: FilledButton.styleFrom(
                          backgroundColor: AppColors.successSoft,
                          foregroundColor: AppColors.success,
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppSpace.s3)),
                      onPressed: () async {
                        final me = context.read<AuthProvider>().user;
                        await context
                            .read<CommissionsProvider>()
                            .markPaid(r.c.userId, r.c.period);
                        await Audit.add('commission_paid',
                            '${r.userName} · ${money(r.c.amount)} (${r.c.period})',
                            userId: me?.id, userName: me?.name);
                      },
                      child: const Text('Paid',
                          style: TextStyle(fontSize: 12)),
                    ),
                  ),
              ]),
            ),
      ],
    );
  }

  Widget _totalTile(BuildContext context, String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(AppSpace.s3),
      decoration: BoxDecoration(
        color: AppColors.surfaceTint,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              style: TextStyle(
                  fontFamily: 'Carlito',
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                  color: AppColors.muted)),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(
                  fontFamily: 'Carlito',
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: color)),
        ],
      ),
    );
  }
}
