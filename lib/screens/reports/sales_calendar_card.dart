import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/sale.dart';
import '../../state/sales.dart';
import '../../state/settings.dart';
import '../../widgets/calendar.dart';
import '../../widgets/ui.dart';
import '../sales/sale_detail_screen.dart';

/// Reports: month-grid sales calendar. Every day cell carries that day's
/// compact revenue; tapping a day opens the drill-down sheet — the day's
/// receipts, its total and WHO sold what (per-cashier split).
class SalesCalendarCard extends StatefulWidget {
  const SalesCalendarCard({super.key});

  @override
  State<SalesCalendarCard> createState() => _SalesCalendarCardState();
}

class _SalesCalendarCardState extends State<SalesCalendarCard> {
  late DateTime _month =
      DateTime(DateTime.now().year, DateTime.now().month, 1);
  Map<String, ({int orders, double revenue})>? _totals;
  int _lastRevision = 0;

  @override
  void initState() {
    super.initState();
    _lastRevision = context.read<SalesProvider>().revision;
    _load();
  }

  Future<void> _load() async {
    final totals =
        await context.read<SalesProvider>().monthDayTotals(_month);
    if (mounted) setState(() => _totals = totals);
  }

  bool get _isCurrentMonth {
    final now = DateTime.now();
    return _month.year == now.year && _month.month == now.month;
  }

  Future<void> _openDay(DateTime day) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _DaySalesSheet(day: day),
    );
    // A receipt could have been refunded inside the detail screen.
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    // Realtime: cloud sales landing re-bucket the visible month.
    final rev = context.watch<SalesProvider>().revision;
    if (rev != _lastRevision) {
      _lastRevision = rev;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }

    return SectionCard(
      icon: Icons.calendar_month_rounded,
      title: 'Sales calendar',
      subtitle: 'Tap a day to see that day\'s sales and who sold them',
      children: [
        if (_totals == null)
          const Center(child: CircularProgressIndicator())
        else
          MonthCalendar(
            month: _month,
            totals: _totals!,
            selectedDay: null,
            onDayTap: _openDay,
            onPrevMonth: () {
              setState(() {
                _month = DateTime(_month.year, _month.month - 1, 1);
              });
              _load();
            },
            onNextMonth: _isCurrentMonth
                ? null
                : () {
                    setState(() {
                      _month = DateTime(_month.year, _month.month + 1, 1);
                    });
                    _load();
                  },
          ),
      ],
    );
  }
}

/// Bottom sheet for one calendar day: total + order count, the per-cashier
/// split (who sold), then the day's receipts (tap for full detail).
class _DaySalesSheet extends StatefulWidget {
  final DateTime day;
  const _DaySalesSheet({required this.day});

  @override
  State<_DaySalesSheet> createState() => _DaySalesSheetState();
}

class _DaySalesSheetState extends State<_DaySalesSheet> {
  List<Sale>? _sales;
  List<({String name, int orders, double revenue})>? _staff;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sales = context.read<SalesProvider>();
    final results = await Future.wait(
        [sales.salesOnDay(widget.day), sales.staffOnDay(widget.day)]);
    if (mounted) {
      setState(() {
        _sales = results[0] as List<Sale>;
        _staff = results[1]
            as List<({String name, int orders, double revenue})>;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final day = widget.day;

    final completed =
        _sales?.where((s) => !s.isRefunded).toList(growable: false) ??
            const <Sale>[];
    final revenue = completed.fold<double>(0, (s, x) => s + x.total);

    return ConstrainedBox(
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.82),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // grab handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10, bottom: 4),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.borderSoft,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: AppSpace.s4, vertical: AppSpace.s2),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(DateFormat('EEEE, d MMMM').format(day),
                          style: TextStyle(
                              fontFamily: 'Carlito',
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: AppColors.ink)),
                      Text(
                        _sales == null
                            ? 'Loading…'
                            : '${completed.length} sale${completed.length == 1 ? '' : 's'}'
                                ' · ${settings.money(revenue)}',
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 12.5,
                            color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: _sales == null
                ? const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(AppSpace.s4),
                    children: [
                      // ---- who sold that day ----
                      if (_staff!.isNotEmpty) ...[
                        Text('WHO SOLD',
                            style: TextStyle(
                                fontFamily: 'Carlito',
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.6,
                                color: AppColors.faint)),
                        const SizedBox(height: AppSpace.s2),
                        for (final s in _staff!)
                          Container(
                            margin: const EdgeInsets.only(bottom: AppSpace.s2),
                            padding: const EdgeInsets.symmetric(
                                horizontal: AppSpace.s3, vertical: AppSpace.s2),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceTint,
                              borderRadius:
                                  BorderRadius.circular(AppRadius.sm),
                              border:
                                  Border.all(color: AppColors.borderSoft),
                            ),
                            child: Row(
                              children: [
                                InitialsAvatar(s.name, size: 30),
                                const SizedBox(width: AppSpace.s2),
                                Expanded(
                                  child: Text(s.name,
                                      style: TextStyle(
                                          fontFamily: 'Carlito',
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.ink)),
                                ),
                                Text(
                                    '${s.orders} sale${s.orders == 1 ? '' : 's'}',
                                    style: TextStyle(
                                        fontFamily: 'Carlito',
                                        fontSize: 12,
                                        color: AppColors.muted)),
                                const SizedBox(width: AppSpace.s3),
                                Text(settings.money(s.revenue),
                                    style: TextStyle(
                                        fontFamily: 'Carlito',
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.primary)),
                              ],
                            ),
                          ),
                        const SizedBox(height: AppSpace.s3),
                      ],

                      // ---- the day's receipts ----
                      Text('RECEIPTS',
                          style: TextStyle(
                              fontFamily: 'Carlito',
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.6,
                              color: AppColors.faint)),
                      const SizedBox(height: AppSpace.s2),
                      if (_sales!.isEmpty)
                        const EmptyState(
                          icon: Icons.receipt_long_outlined,
                          title: 'No sales this day',
                          message:
                              'Receipts from this day will appear here.',
                        )
                      else
                        for (final s in _sales!)
                          _DayReceiptTile(sale: s, settings: settings),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _DayReceiptTile extends StatelessWidget {
  final Sale sale;
  final AppSettings settings;
  const _DayReceiptTile({required this.sale, required this.settings});

  @override
  Widget build(BuildContext context) {
    final dt = DateTime.fromMillisecondsSinceEpoch(sale.createdAt * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    final when = '${two(dt.hour)}:${two(dt.minute)}';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => SaleDetailScreen(saleId: sale.id!)));
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.s3, vertical: AppSpace.s2),
          child: Row(
            children: [
              Text(when,
                  style: TextStyle(
                      fontFamily: 'Carlito',
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.muted)),
              const SizedBox(width: AppSpace.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(sale.receiptNo,
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppColors.ink)),
                    Text(
                        '${sale.cashierName ?? '-'} · '
                        '${sale.customerName ?? 'Walk-in'}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 11.5,
                            color: AppColors.muted)),
                  ],
                ),
              ),
              Text(
                settings.money(sale.total),
                style: TextStyle(
                    fontFamily: 'Carlito',
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: sale.isRefunded ? AppColors.faint : AppColors.ink,
                    decoration:
                        sale.isRefunded ? TextDecoration.lineThrough : null),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
