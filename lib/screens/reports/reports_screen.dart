import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/product.dart';
import '../../services/csv_util.dart';
import '../../state/catalog.dart';
import '../../state/nav.dart';
import '../../state/sales.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';
import 'manager_tools_card.dart';
import 'ops_cards.dart';
import 'z_report_card.dart';

/// Reports: KPI cards + revenue line chart + top products + category share.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  int _range = 7;
  Map<String, ({double revenue, int orders, int itemsSold})>? _summaries;
  List<(DateTime, double)>? _revenue;
  List<(String, int, double)>? _top;
  List<(String, double)>? _categories;
  List<({String name, int orders, double revenue})>? _staff;
  List<({String method, int orders, double total})>? _payments;
  double? _cogs;
  List<({String name, int units, double revenue, double cost})>? _catMargins;
  List<({String name, String variantDesc, int stock, int unitsSold})>? _slow;
  List<(DateTime, double)>? _months;
  List<({DateTime month, double taxable, double taxCollected, double refundedTax})>? _tax;
  int _lastRevision = 0;

  @override
  void initState() {
    super.initState();
    _lastRevision = context.read<SalesProvider>().revision;
    _load();
  }

  Future<void> _load() async {
    final sales = context.read<SalesProvider>();
    final now = DateTime.now();
    final weekStart = DateTime(now.year, now.month, now.day - now.weekday + 1);
    final monthStart = DateTime(now.year, now.month, 1);
    final results = await Future.wait([
      sales.summary(0), // today
      sales.summarySince(weekStart.millisecondsSinceEpoch ~/ 1000),
      sales.summarySince(monthStart.millisecondsSinceEpoch ~/ 1000),
      sales.summary(30),
      sales.revenueByDay(_range),
      sales.topProducts(_range, limit: 5),
      sales.categoryShare(_range),
      sales.staffPerformance(_range),
      sales.cogs(_range),
      sales.paymentBreakdown(_range),
      sales.categoryMargins(_range, limit: 6),
      sales.slowMovers(_range, limit: 6),
      sales.revenueByMonth(12),
      sales.taxByMonth(6),
    ]);
    if (!mounted) return;
    setState(() {
      _summaries = {
        'today': results[0] as ({double revenue, int orders, int itemsSold}),
        'week': results[1] as ({double revenue, int orders, int itemsSold}),
        'month': results[2] as ({double revenue, int orders, int itemsSold}),
        '30d': results[3] as ({double revenue, int orders, int itemsSold}),
      };
      _revenue = results[4] as List<(DateTime, double)>;
      _top = results[5] as List<(String, int, double)>;
      _categories = results[6] as List<(String, double)>;
      _staff = results[7]
          as List<({String name, int orders, double revenue})>;
      _cogs = results[8] as double;
      _payments = results[9]
          as List<({String method, int orders, double total})>;
      _catMargins = results[10]
          as List<({String name, int units, double revenue, double cost})>;
      _slow = results[11]
          as List<({String name, String variantDesc, int stock, int unitsSold})>;
      _months = results[12] as List<(DateTime, double)>;
      _tax = results[13]
          as List<({DateTime month, double taxable, double taxCollected, double refundedTax})>;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    // Live catalog so the low-stock KPI matches the sidebar badge exactly.
    final liveLow = context.watch<CatalogProvider>().lowStockItems().length;
    // Realtime: when sync lands sales from other devices, revision bumps
    // and the whole report reloads after this frame.
    final salesRev = context.watch<SalesProvider>().revision;
    if (salesRev != _lastRevision) {
      _lastRevision = salesRev;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
    final today = _summaries?['today'];
    final week = _summaries?['week'];
    final month = _summaries?['month'];
    final d30 = _summaries?['30d'];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(AppSpace.s4, AppSpace.s4, AppSpace.s4, AppSpace.s6),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const PageHeader(
                title: 'Reports',
                subtitle: 'Revenue, best sellers and inventory health at a glance',
              ),

              // KPI cards
              LayoutBuilder(builder: (context, c) {
                const gap = 12.0;
                // Six KPI cards must fill rows evenly — 3-across on
                // desktop/tablet, 2-across on phones, 1 on very narrow
                // screens — never 5+1 with an orphan card on the last row.
                final cols = c.maxWidth >= 3 * 200 + 2 * gap
                    ? 3
                    : c.maxWidth >= 2 * 184 + gap
                        ? 2
                        : 1;
                final w = (c.maxWidth - gap * (cols - 1)) / cols;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    SizedBox(
                      width: w,
                      child: KpiCard(
                        label: 'Revenue today',
                        value: settings.money(today?.revenue ?? 0),
                        icon: Icons.today_rounded,
                      ),
                    ),
                    SizedBox(
                      width: w,
                      child: KpiCard(
                        label: 'Orders today',
                        value: '${today?.orders ?? 0}',
                        icon: Icons.receipt_long_rounded,
                        color: AppColors.info,
                        soft: AppColors.infoSoft,
                      ),
                    ),
                    SizedBox(
                      width: w,
                      child: KpiCard(
                        label: 'Revenue this week',
                        value: settings.money(week?.revenue ?? 0),
                        icon: Icons.date_range_rounded,
                        color: AppColors.success,
                        soft: AppColors.successSoft,
                      ),
                    ),
                    SizedBox(
                      width: w,
                      child: KpiCard(
                        label: 'Revenue this month',
                        value: settings.money(month?.revenue ?? 0),
                        icon: Icons.calendar_month_rounded,
                        color: AppColors.isDark ? const Color(0xFFA78BFA) : const Color(0xFF7C3AED),
                        soft: AppColors.isDark ? const Color(0xFF3B2A6E) : const Color(0xFFEDE9FE),
                      ),
                    ),
                    SizedBox(
                      width: w,
                      child: KpiCard(
                        label: 'Avg basket (30d)',
                        value: settings.money(
                            d30 != null && d30.orders > 0 ? d30.revenue / d30.orders : 0),
                        icon: Icons.shopping_basket_rounded,
                        color: AppColors.isDark ? const Color(0xFF2DD4BF) : const Color(0xFF0D9488),
                        soft: AppColors.isDark ? const Color(0xFF0B3B34) : const Color(0xFFCCFBF1),
                      ),
                    ),
                    SizedBox(
                      width: w,
                      child: KpiCard(
                        label: 'Low stock items',
                        value: '$liveLow',
                        icon: Icons.warning_amber_rounded,
                        color: liveLow > 0 ? AppColors.danger : AppColors.success,
                        soft: liveLow > 0 ? AppColors.dangerSoft : AppColors.successSoft,
                      ),
                    ),
                  ],
                );
              }),
              const SizedBox(height: AppSpace.s4),

              // Day close (Z-report): pick a business day, print the
              // A4 report, close the day with a signed snapshot.
              const ZReportCard(),
              const SizedBox(height: AppSpace.s4),

              // range selector (Wrap: the segmented control can be wider
              // than the label row on small phones)
              Wrap(
                spacing: AppSpace.s2,
                runSpacing: AppSpace.s2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('Period',
                      style: TextStyle(
                          fontFamily: 'Carlito',
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.muted)),
                  SegmentedButton<int>(
                    showSelectedIcon: false,
                    style: primarySegmentStyle(),
                    segments: const [
                      ButtonSegment(value: 7, label: Text('7 days')),
                      ButtonSegment(value: 30, label: Text('30 days')),
                      ButtonSegment(value: 90, label: Text('90 days')),
                    ],
                    selected: {_range},
                    onSelectionChanged: (s) {
                      setState(() => _range = s.first);
                      _load();
                    },
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.s4),

              // revenue chart
              SectionCard(
                icon: Icons.show_chart_rounded,
                title: 'Revenue trend',
                subtitle: 'Daily revenue over the selected period',
                children: [
                  SizedBox(
                    height: 230,
                    child: _revenue == null
                        ? const Center(child: CircularProgressIndicator())
                        : _RevenueLineChart(data: _revenue!, settings: settings),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.s4),
              // Charts side-by-side only when each gets enough width —
              // 160px-wide charts are unreadable on phones.
              LayoutBuilder(builder: (context, cc) {
                final top = SectionCard(
                  icon: Icons.leaderboard_rounded,
                  title: 'Top products',
                  subtitle: 'Units sold in the selected period',
                  children: [
                    SizedBox(
                      height: 230,
                      child: _top == null || _top!.isEmpty
                          ? const EmptyState(
                              icon: Icons.leaderboard_outlined,
                              title: 'No sales yet',
                              message: 'Best sellers will appear here.',
                            )
                          : _TopProductsBarChart(data: _top!),
                    ),
                  ],
                );
                final categories = SectionCard(
                  icon: Icons.pie_chart_outline_rounded,
                  title: 'Category share',
                  subtitle: 'Share of revenue by category',
                  children: [
                    SizedBox(
                      height: 230,
                      child: _categories == null || _categories!.isEmpty
                          ? const EmptyState(
                              icon: Icons.pie_chart_outline_rounded,
                              title: 'No sales yet',
                              message: 'Category split will appear here.',
                            )
                          : _CategoryPie(data: _categories!),
                    ),
                  ],
                );
                if (cc.maxWidth < 640) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      top,
                      const SizedBox(height: AppSpace.s4),
                      categories,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: top),
                    const SizedBox(width: AppSpace.s4),
                    Expanded(child: categories),
                  ],
                );
              }),
              const SizedBox(height: AppSpace.s4),

              // manager insights: estimated profit + staff + payment methods
              _ManagerInsightsCard(
                settings: settings,
                staff: _staff,
                payments: _payments,
                cogs: _cogs,
                revenue: _revenue == null
                    ? 0.0
                    : _revenue!.fold<double>(0.0, (s, d) => s + d.$2),
                rangeDays: _range,
              ),
              const SizedBox(height: AppSpace.s4),

              // stock health: value of goods on hand + low-stock alerts
              const _StockHealthCard(),
              const SizedBox(height: AppSpace.s4),

              // profit & margins: revenue vs cost of goods + top earners
              MarginCard(days: _range),
              const SizedBox(height: AppSpace.s4),

              // margin per category: which product families actually pay
              _CategoryMarginCard(data: _catMargins),
              const SizedBox(height: AppSpace.s4),

              // slow-moving stock: capital sitting on the shelf
              _SlowMoversCard(data: _slow),
              const SizedBox(height: AppSpace.s4),

              // seasonal trends: revenue by month, last 12 months
              _SeasonalCard(data: _months),
              const SizedBox(height: AppSpace.s4),

              // tax / VAT report: monthly taxable base + tax collected
              _TaxReportCard(data: _tax),
              const SizedBox(height: AppSpace.s4),

              // who sold what, how much, what they earned
              StaffPerformanceCard(days: _range),
              const SizedBox(height: AppSpace.s4),

              // commission ledger: pending payouts, mark paid, adjustments
              const CommissionsCard(),
              const SizedBox(height: AppSpace.s4),

              // manager tools: approval PIN + discount gate + audit trail
              // (moved out of Settings — Reports is the manager workspace)
              const ManagerToolsCard(),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

/// Manager-only section: estimated profit for the period, who is selling,
/// and how customers are paying.
class _ManagerInsightsCard extends StatelessWidget {
  final AppSettings settings;
  final List<({String name, int orders, double revenue})>? staff;
  final List<({String method, int orders, double total})>? payments;
  final double? cogs;
  final double revenue;
  final int rangeDays;

  const _ManagerInsightsCard({
    required this.settings,
    required this.staff,
    required this.payments,
    required this.cogs,
    required this.revenue,
    required this.rangeDays,
  });

  String _methodLabel(String m) =>
      m == 'cash' ? 'Cash' : m == 'card' ? 'Card' : 'Mobile money';

  IconData _methodIcon(String m) => m == 'cash'
      ? Icons.payments_outlined
      : m == 'card'
          ? Icons.credit_card_rounded
          : Icons.smartphone_rounded;

  @override
  Widget build(BuildContext context) {
    final profit = revenue - (cogs ?? 0);
    final margin = revenue > 0 ? (profit / revenue * 100) : 0.0;

    return SectionCard(
      icon: Icons.manage_accounts_rounded,
      title: 'Manager insights',
      subtitle: 'Profit estimate, staff performance and payment mix',
      children: [
        // profit strip
        Container(
          padding: const EdgeInsets.all(AppSpace.s3),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF4F46E5), Color(0xFF6D28D9)],
            ),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            children: [
              _profitCell('Revenue ($rangeDays d)', settings.money(revenue)),
              const SizedBox(width: AppSpace.s3),
              _profitCell('Est. cost of goods', settings.money(cogs ?? 0)),
              const SizedBox(width: AppSpace.s3),
              _profitCell(
                  'Est. profit', settings.money(profit),
                  trailing: '${margin.toStringAsFixed(0)}% margin'),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.s4),
        LayoutBuilder(builder: (context, c) {
          final twoCols = c.maxWidth >= 640;
          final staffList = _buildStaff();
          final payList = _buildPayments();
          if (!twoCols) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                staffList,
                const SizedBox(height: AppSpace.s4),
                payList,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: staffList),
              const SizedBox(width: AppSpace.s4),
              Expanded(child: payList),
            ],
          );
        }),
      ],
    );
  }

  Widget _profitCell(String label, String value, {String? trailing}) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontFamily: 'Carlito',
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: Colors.white.withValues(alpha: 0.75))),
          const SizedBox(height: 2),
          // FittedBox: long money strings shrink instead of butting into
          // (or visually clipping against) the neighbouring cell on phones.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value,
                style: TextStyle(
                    fontFamily: 'Carlito',
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
          ),
          if (trailing != null)
            Text(trailing,
                style: TextStyle(
                    fontFamily: 'Carlito',
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.75))),
        ],
      ),
    );
  }

  Widget _buildStaff() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Staff performance',
            style: TextStyle(
                fontFamily: 'Carlito',
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.ink)),
        const SizedBox(height: AppSpace.s2),
        if (staff == null || staff!.isEmpty)
          const EmptyState(
            icon: Icons.badge_outlined,
            title: 'No sales in this period',
            message: 'Staff revenue will appear here.',
          )
        else
          for (final s in staff!)
            Container(
              margin: const EdgeInsets.only(bottom: AppSpace.s2),
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.s3, vertical: AppSpace.s2),
              decoration: BoxDecoration(
                color: AppColors.surfaceTint,
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: AppColors.borderSoft),
              ),
              child: Row(
                children: [
                  InitialsAvatar(s.name, size: 32),
                  const SizedBox(width: AppSpace.s2),
                  Expanded(
                    child: Text(s.name,
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppColors.ink)),
                  ),
                  Text('${s.orders} sale${s.orders == 1 ? '' : 's'}',
                      style: TextStyle(
                          fontFamily: 'Carlito', fontSize: 12, color: AppColors.muted)),
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
      ],
    );
  }

  Widget _buildPayments() {
    final total = payments?.fold(0.0, (s, p) => s + p.total) ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Payment methods',
            style: TextStyle(
                fontFamily: 'Carlito',
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.ink)),
        const SizedBox(height: AppSpace.s2),
        if (payments == null || payments!.isEmpty)
          const EmptyState(
            icon: Icons.credit_card_off_outlined,
            title: 'No payments in this period',
            message: 'Cash / card / mobile money split will appear here.',
          )
        else
          for (final p in payments!)
            Container(
              margin: const EdgeInsets.only(bottom: AppSpace.s2),
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.s3, vertical: AppSpace.s2),
              decoration: BoxDecoration(
                color: AppColors.surfaceTint,
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: AppColors.borderSoft),
              ),
              child: Row(
                children: [
                  Icon(_methodIcon(p.method), size: 18, color: AppColors.primary),
                  const SizedBox(width: AppSpace.s2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_methodLabel(p.method),
                            style: TextStyle(
                                fontFamily: 'Carlito',
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppColors.ink)),
                        Text(
                            '${p.orders} sale${p.orders == 1 ? '' : 's'} · '
                            '${total > 0 ? (p.total / total * 100).toStringAsFixed(0) : 0}% of revenue',
                            style: TextStyle(
                                fontFamily: 'Carlito',
                                fontSize: 11,
                                color: AppColors.muted)),
                      ],
                    ),
                  ),
                  Text(settings.money(p.total),
                      style: TextStyle(
                          fontFamily: 'Carlito',
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.body)),
                ],
              ),
            ),
      ],
    );
  }
}

// ---------- stock health (valuation + low-stock alerts) ----------

/// Inventory valuation tiles plus the itemized low-stock alert list.
/// Reads the live catalog, so sales/adjustments/sync update it instantly.
class _StockHealthCard extends StatelessWidget {
  const _StockHealthCard();

  @override
  Widget build(BuildContext context) {
    final catalog = context.watch<CatalogProvider>();
    final settings = context.watch<AppSettings>();
    final nav = context.read<NavProvider>();

    var units = 0;
    var costValue = 0.0;
    var retailValue = 0.0;
    for (final p in catalog.products) {
      for (final v in p.variants) {
        units += v.stock;
        costValue += v.stock * v.cost;
        retailValue += v.stock * v.price;
      }
    }
    final low = catalog.lowStockItems();

    final tiles = [
      (Icons.scale_rounded, 'Units on hand', '$units', AppColors.info, AppColors.infoSoft),
      (
        Icons.payments_rounded,
        'Value at cost',
        settings.money(costValue),
        AppColors.primary,
        AppColors.primarySoft,
      ),
      (
        Icons.storefront_rounded,
        'Value at retail',
        settings.money(retailValue),
        AppColors.success,
        AppColors.successSoft,
      ),
    ];

    return SectionCard(
      icon: Icons.inventory_rounded,
      title: 'Stock health',
      subtitle: 'Value of goods on hand and items running low',
      children: [
        LayoutBuilder(builder: (context, c) {
          const gap = 12.0;
          final cols = c.maxWidth >= 3 * 190 + 2 * gap
              ? 3
              : c.maxWidth >= 2 * 170 + gap
                  ? 2
                  : 1;
          final w = (c.maxWidth - gap * (cols - 1)) / cols;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final t in tiles)
                SizedBox(
                  width: w,
                  child: Container(
                    padding: const EdgeInsets.all(AppSpace.s3),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceTint,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      border: Border.all(color: AppColors.borderSoft),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: t.$5,
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                          ),
                          child: Icon(t.$1, size: 18, color: t.$4),
                        ),
                        const SizedBox(width: AppSpace.s2),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(t.$2.toUpperCase(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontFamily: 'Carlito',
                                      fontSize: 11,
                                      letterSpacing: 0.4,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.muted)),
                              Text(t.$3,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontFamily: 'Carlito',
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.ink)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        }),
        const SizedBox(height: AppSpace.s3),
        const Divider(),
        Row(
          children: [
            Expanded(
              child: Text(
                low.isEmpty
                    ? 'Nothing is running low'
                    : 'Running low (${low.length})',
                style: TextStyle(
                    fontFamily: 'Carlito',
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: low.isEmpty ? AppColors.success : AppColors.ink),
              ),
            ),
            if (low.length > 5)
              TextButton(
                onPressed: () => nav.goTo(NavId.products),
                child: const Text('View all in Products'),
              ),
          ],
        ),
        if (low.isEmpty)
          Row(
            children: [
              Icon(Icons.check_circle_outline_rounded,
                  size: 16, color: AppColors.success),
              const SizedBox(width: AppSpace.s2),
              Expanded(
                child: Text(
                  'Every product is above its low-stock threshold. '
                  'Adjust thresholds per product in the product editor.',
                  style: TextStyle(
                      fontFamily: 'Carlito',
                      fontSize: 12,
                      color: AppColors.muted,
                      height: 1.4),
                ),
              ),
            ],
          )
        else
          for (final (Product, ProductVariant) item in low.take(5))
            Container(
              margin: const EdgeInsets.only(bottom: AppSpace.s2),
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.s3, vertical: AppSpace.s2),
              decoration: BoxDecoration(
                color: AppColors.surfaceTint,
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: AppColors.borderSoft),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.$1.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontFamily: 'Carlito',
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppColors.ink)),
                        if (item.$2.descriptor.isNotEmpty)
                          Text(item.$2.descriptor,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontFamily: 'Carlito',
                                  fontSize: 11,
                                  color: AppColors.muted)),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpace.s2),
                  StatusPill.stock(context, item.$2.stock,
                      lowThreshold: item.$1.lowStock),
                ],
              ),
            ),
      ],
    );
  }
}

// ---------- chart widgets ----------

class _RevenueLineChart extends StatelessWidget {
  final List<(DateTime, double)> data;
  final AppSettings settings;
  const _RevenueLineChart({required this.data, required this.settings});

  @override
  Widget build(BuildContext context) {
    final spots = <FlSpot>[
      for (var i = 0; i < data.length; i++) FlSpot(i.toDouble(), data[i].$2),
    ];
    final maxY = spots.map((s) => s.y).fold(1.0, (a, b) => b > a ? b : a);

    return LineChart(
      LineChartData(
        minY: 0,
        maxY: maxY * 1.15,
        gridData: FlGridData(
          drawVerticalLine: false,
          getDrawingHorizontalLine: (v) => FlLine(
            color: AppColors.borderSoft,
            strokeWidth: 1,
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 26,
              interval: (data.length / 6).clamp(1, 100).toDouble(),
              getTitlesWidget: (v, meta) {
                final idx = v.toInt();
                if (idx < 0 || idx >= data.length) return const SizedBox.shrink();
                final d = data[idx].$1;
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('${d.day}/${d.month}',
                      style: TextStyle(
                          fontFamily: 'Carlito', fontSize: 11, color: AppColors.muted)),
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            barWidth: 3,
            color: AppColors.primary,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppColors.primary.withValues(alpha: 0.18),
                  AppColors.primary.withValues(alpha: 0.02),
                ],
              ),
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (spots) => [
              for (final s in spots)
                LineTooltipItem(
                  settings.money(s.y),
                  const TextStyle(
                      fontFamily: 'Carlito',
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Colors.white),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopProductsBarChart extends StatelessWidget {
  final List<(String, int, double)> data;
  const _TopProductsBarChart({required this.data});

  @override
  Widget build(BuildContext context) {
    final maxY = data.map((d) => d.$2).fold(1, (a, b) => b > a ? b : a).toDouble();

    return BarChart(
      BarChartData(
        maxY: maxY * 1.2,
        alignment: BarChartAlignment.spaceAround,
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              getTitlesWidget: (v, meta) {
                final idx = v.toInt();
                if (idx < 0 || idx >= data.length) return const SizedBox.shrink();
                final name = data[idx].$1;
                final short = name.length > 10 ? '${name.substring(0, 10)}…' : name;
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(short,
                      style: TextStyle(
                          fontFamily: 'Carlito', fontSize: 10, color: AppColors.muted)),
                );
              },
            ),
          ),
        ),
        barGroups: [
          for (var i = 0; i < data.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: data[i].$2.toDouble(),
                  width: 24,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                  gradient: const LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0xFF6366F1), Color(0xFF4F46E5)],
                  ),
                ),
              ],
              showingTooltipIndicators: [0],
            ),
        ],
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, groupIndex, rod, rodIndex) =>
                BarTooltipItem(
                  '${data[group.x].$1}\n${data[group.x].$2} sold',
                  const TextStyle(
                      fontFamily: 'Carlito',
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Colors.white),
                  textAlign: TextAlign.center,
                ),
          ),
        ),
      ),
    );
  }
}

class _CategoryPie extends StatelessWidget {
  final List<(String, double)> data;
  const _CategoryPie({required this.data});

  @override
  Widget build(BuildContext context) {
    final total = data.fold(0.0, (s, d) => s + d.$2);

    return Column(
      children: [
        Expanded(
          child: PieChart(
            PieChartData(
              sectionsSpace: 3,
              centerSpaceRadius: 40,
              sections: [
                for (var i = 0; i < data.length; i++)
                  PieChartSectionData(
                    value: data[i].$2,
                    title: total > 0 && data[i].$2 / total >= 0.04
                        ? '${(data[i].$2 / total * 100).round()}%'
                        : '',
                    titleStyle: const TextStyle(
                        fontFamily: 'Carlito',
                        fontSize: 11,
                        color: Colors.white,
                        fontWeight: FontWeight.w700),
                    radius: 56,
                    color: AppColors.chart[i % AppColors.chart.length],
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpace.s2),
        Wrap(
          spacing: AppSpace.s3,
          runSpacing: AppSpace.s1,
          children: [
            for (var i = 0; i < data.length; i++)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: AppColors.chart[i % AppColors.chart.length],
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: AppSpace.s1),
                  Text(data[i].$1,
                      style: TextStyle(fontFamily: 'Carlito', fontSize: 11, color: AppColors.body)),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

// ---------- category margin ----------

/// Margin per product family: revenue vs cost of goods per category, so
/// the manager sees which lines actually pay (and which just move units).
class _CategoryMarginCard extends StatelessWidget {
  final List<({String name, int units, double revenue, double cost})>? data;
  const _CategoryMarginCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    return SectionCard(
      icon: Icons.donut_small_rounded,
      title: 'Margin by category',
      subtitle: 'Revenue vs cost of goods per product family',
      children: [
        if (data == null)
          const Center(child: CircularProgressIndicator())
        else if (data!.isEmpty)
          const EmptyState(
            icon: Icons.donut_small_outlined,
            title: 'No sales in this period',
            message: 'Category margins will appear here.',
          )
        else
          Column(
            children: [
              for (final row in data!)
                Container(
                  margin: const EdgeInsets.only(bottom: AppSpace.s2),
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.s3, vertical: AppSpace.s2),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceTint,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    border: Border.all(color: AppColors.borderSoft),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(row.name,
                                style: TextStyle(
                                    fontFamily: 'Carlito',
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.ink)),
                            Text(
                                '${row.units} sold · cost ${settings.money(row.cost)}',
                                style: TextStyle(
                                    fontFamily: 'Carlito',
                                    fontSize: 11,
                                    color: AppColors.muted)),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(settings.money(row.revenue - row.cost),
                              style: TextStyle(
                                  fontFamily: 'Carlito',
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: row.revenue - row.cost >= 0
                                      ? AppColors.success
                                      : AppColors.danger)),
                          Text(
                              '${row.revenue > 0 ? ((row.revenue - row.cost) / row.revenue * 100).toStringAsFixed(0) : 0}% margin',
                              style: TextStyle(
                                  fontFamily: 'Carlito',
                                  fontSize: 11,
                                  color: AppColors.muted)),
                        ],
                      ),
                      const SizedBox(width: AppSpace.s3),
                      SizedBox(
                        width: 90,
                        child: Text(settings.money(row.revenue),
                            textAlign: TextAlign.right,
                            style: TextStyle(
                                fontFamily: 'Carlito',
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppColors.primary)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

// ---------- slow-moving stock ----------

/// Capital sitting on the shelf: items with stock that barely (or never)
/// sold in the period. The manager's markdown/reorder signal.
class _SlowMoversCard extends StatelessWidget {
  final List<({String name, String variantDesc, int stock, int unitsSold})>? data;
  const _SlowMoversCard({required this.data});

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      icon: Icons.hourglass_bottom_rounded,
      title: 'Slow-moving stock',
      subtitle: 'Shelf stock that barely sold — consider a promotion',
      children: [
        if (data == null)
          const Center(child: CircularProgressIndicator())
        else if (data!.isEmpty)
          const EmptyState(
            icon: Icons.hourglass_empty_rounded,
            title: 'Nothing on the shelf',
            message: 'Slow movers will appear when stock sits unsold.',
          )
        else
          Column(
            children: [
              for (final row in data!)
                Container(
                  margin: const EdgeInsets.only(bottom: AppSpace.s2),
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.s3, vertical: AppSpace.s2),
                  decoration: BoxDecoration(
                    color: row.unitsSold == 0
                        ? AppColors.warningSoft
                        : AppColors.surfaceTint,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    border: Border.all(
                        color: row.unitsSold == 0
                            ? AppColors.warning.withValues(alpha: 0.3)
                            : AppColors.borderSoft),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        row.unitsSold == 0
                            ? Icons.priority_high_rounded
                            : Icons.hourglass_bottom_rounded,
                        size: 16,
                        color: row.unitsSold == 0
                            ? AppColors.warning
                            : AppColors.muted,
                      ),
                      const SizedBox(width: AppSpace.s2),
                      Expanded(
                        child: Text(
                          row.variantDesc.isEmpty
                              ? row.name
                              : '${row.name} · ${row.variantDesc}',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontFamily: 'Carlito',
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: AppColors.ink),
                        ),
                      ),
                      Text('${row.stock} in stock',
                          style: TextStyle(
                              fontFamily: 'Carlito',
                              fontSize: 12,
                              color: AppColors.muted)),
                      const SizedBox(width: AppSpace.s3),
                      Text(
                          '${row.unitsSold} sold',
                          style: TextStyle(
                              fontFamily: 'Carlito',
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: row.unitsSold == 0
                                  ? AppColors.warning
                                  : AppColors.body)),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

// ---------- seasonal trends ----------

/// Revenue by month for the last 12 months — the seasonal pattern
/// (December spikes, back-to-school, holidays) at one glance.
class _SeasonalCard extends StatelessWidget {
  final List<(DateTime, double)>? data;
  const _SeasonalCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    return SectionCard(
      icon: Icons.wb_sunny_outlined,
      title: 'Seasonal trends',
      subtitle: 'Revenue by month — last 12 months',
      children: [
        SizedBox(
          height: 220,
          child: data == null
              ? const Center(child: CircularProgressIndicator())
              : data!.every((m) => m.$2 == 0)
                  ? const EmptyState(
                      icon: Icons.wb_sunny_outlined,
                      title: 'No sales yet',
                      message: 'Monthly revenue will appear here.',
                    )
                  : _MonthBarChart(data: data!, settings: settings),
        ),
      ],
    );
  }
}

class _MonthBarChart extends StatelessWidget {
  final List<(DateTime, double)> data;
  final AppSettings settings;
  const _MonthBarChart({required this.data, required this.settings});

  static const _monthLabels = [
    'J', 'F', 'M', 'A', 'M', 'J', 'J', 'A', 'S', 'O', 'N', 'D'
  ];

  @override
  Widget build(BuildContext context) {
    final maxV = data.fold(0.0, (s, d) => d.$2 > s ? d.$2 : s);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final (i, m) in data.indexed)
          Expanded(
            child: Tooltip(
              message:
                  '${m.$1.year}-${m.$1.month.toString().padLeft(2, '0')} · ${settings.money(m.$2)}',
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Container(
                      height: maxV > 0 ? 150 * (m.$2 / maxV) : 2,
                      decoration: BoxDecoration(
                        color: m.$2 > 0
                            ? AppColors.chart[i % AppColors.chart.length]
                            : AppColors.borderSoft,
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(4)),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(_monthLabels[m.$1.month - 1],
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: AppColors.muted)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ---------- tax / VAT report ----------

/// Tax/VAT report: taxable base and tax collected per month, with a CSV
/// export for the accountant. Refunds reduce what was effectively collected.
class _TaxReportCard extends StatelessWidget {
  final List<
          ({
            DateTime month,
            double taxable,
            double taxCollected,
            double refundedTax,
          })>? data;
  const _TaxReportCard({required this.data});

  Future<void> _exportCsv(BuildContext context) async {
    final rows = data;
    if (rows == null) return;
    final b = StringBuffer()
      ..writeln('month,taxable_sales,tax_collected,tax_on_refunds,net_tax');
    for (final r in rows) {
      b.writeln([
        '${r.month.year}-${r.month.month.toString().padLeft(2, '0')}',
        (r.taxable).toStringAsFixed(2),
        (r.taxCollected).toStringAsFixed(2),
        (r.refundedTax).toStringAsFixed(2),
        (r.taxCollected - r.refundedTax).toStringAsFixed(2),
      ].map(CsvUtil.escape).join(','));
    }
    final result = await CsvUtil.saveFile(
      name: 'tax-report-${DateTime.now().toIso8601String().substring(0, 10)}.csv',
      data: CsvUtil.encodeUtf8(b.toString()),
    );
    if (context.mounted && result != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Tax report CSV $result'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final rows = data;
    final totalTaxable =
        rows?.fold(0.0, (s, r) => s + r.taxable) ?? 0;
    final totalTax = rows?.fold(0.0, (s, r) => s + r.taxCollected) ?? 0;
    final totalRefunded = rows?.fold(0.0, (s, r) => s + r.refundedTax) ?? 0;

    return SectionCard(
      icon: Icons.receipt_long_outlined,
      title: 'Tax / VAT report',
      subtitle:
          'Tax rate ${settings.taxRate.toStringAsFixed(0)}% — collected per month (last 6)',
      action: IconButton(
        tooltip: 'Export CSV',
        icon: const Icon(Icons.file_download_outlined, size: 20),
        onPressed: rows == null || rows.isEmpty ? null : () => _exportCsv(context),
      ),
      children: [
        if (rows == null)
          const Center(child: CircularProgressIndicator())
        else ...[
          Container(
            padding: const EdgeInsets.all(AppSpace.s3),
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: LayoutBuilder(builder: (context, lc) {
              // 4-up fits wide screens; on phones the labels truncated
              // ("TAXABLE S…") — switch to a 2x2 grid below 420dp.
              final cells = [
                _taxCell('Taxable sales', settings.money(totalTaxable)),
                _taxCell('Tax collected', settings.money(totalTax)),
                _taxCell('Tax on refunds', '- ${settings.money(totalRefunded)}'),
                _taxCell('Net tax due', settings.money(totalTax - totalRefunded),
                    bold: true),
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
          ),
          const SizedBox(height: AppSpace.s3),
          for (final r in rows.reversed)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.s1),
              child: Row(
                children: [
                  SizedBox(
                    width: 92,
                    child: Text(
                        '${r.month.year}-${r.month.month.toString().padLeft(2, '0')}',
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppColors.body)),
                  ),
                  Expanded(
                    child: Text(settings.money(r.taxable),
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 12,
                            color: AppColors.muted)),
                  ),
                  Text(settings.money(r.taxCollected),
                      style: TextStyle(
                          fontFamily: 'Carlito',
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.ink)),
                  const SizedBox(width: AppSpace.s2),
                  SizedBox(
                    width: 64,
                    child: Text(
                        r.refundedTax > 0
                            ? '-${settings.moneyPlain(r.refundedTax)}'
                            : '—',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 12,
                            color: AppColors.danger)),
                  ),
                ],
              ),
            ),
          if (settings.taxRate <= 0)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.s2),
              child: Text(
                'Tax is off — set your rate in Settings to start '
                'collecting VAT on receipts.',
                style: TextStyle(
                    fontFamily: 'Carlito', fontSize: 11, color: AppColors.faint),
              ),
            ),
        ],
      ],
    );
  }

  Widget _taxCell(String label, String value, {bool bold = false}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
          Text(label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontFamily: 'Carlito',
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: AppColors.primaryDark.withValues(alpha: 0.7))),
          // FittedBox: the money value shrinks on phones instead of
          // wrapping to two lines inside the cramped 4-up strip.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value,
                style: TextStyle(
                    fontFamily: 'Carlito',
                    fontSize: bold ? 14 : 13,
                    fontWeight: bold ? FontWeight.w800 : FontWeight.w700,
                    color: AppColors.primaryDark)),
        ),
      ],
    );
  }
}
