import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/sales.dart';
import '../../state/settings.dart';

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
  int _lowStock = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sales = context.read<SalesProvider>();
    final results = await Future.wait([
      sales.summary(0), // today
      sales.summary(1), // yesterday-ish window (unused, keep simple)
      sales.summary(7),
      sales.summary(30),
      sales.revenueByDay(_range),
      sales.topProducts(_range, limit: 5),
      sales.categoryShare(_range),
      sales.lowStockCount(),
    ]);
    if (!mounted) return;
    setState(() {
      _summaries = {
        'today': results[0] as ({double revenue, int orders, int itemsSold}),
        '7d': results[2] as ({double revenue, int orders, int itemsSold}),
        '30d': results[3] as ({double revenue, int orders, int itemsSold}),
      };
      _revenue = results[4] as List<(DateTime, double)>;
      _top = results[5] as List<(String, int, double)>;
      _categories = results[6] as List<(String, double)>;
      _lowStock = results[7] as int;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final theme = Theme.of(context);
    final today = _summaries?['today'];
    final d7 = _summaries?['7d'];
    final d30 = _summaries?['30d'];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // KPI cards
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  StatCard(
                    label: 'Revenue today',
                    value: settings.money(today?.revenue ?? 0),
                    icon: Icons.today_outlined,
                  ),
                  StatCard(
                    label: 'Orders today',
                    value: '${today?.orders ?? 0}',
                    icon: Icons.receipt_long_outlined,
                  ),
                  StatCard(
                    label: 'Revenue 7 days',
                    value: settings.money(d7?.revenue ?? 0),
                    icon: Icons.date_range_outlined,
                  ),
                  StatCard(
                    label: 'Revenue 30 days',
                    value: settings.money(d30?.revenue ?? 0),
                    icon: Icons.calendar_month_outlined,
                  ),
                  StatCard(
                    label: 'Avg basket (30d)',
                    value: settings.money(
                        d30 != null && d30.orders > 0 ? d30.revenue / d30.orders : 0),
                    icon: Icons.shopping_basket_outlined,
                  ),
                  StatCard(
                    label: 'Low stock items',
                    value: '$_lowStock',
                    icon: Icons.warning_amber_outlined,
                    highlight: _lowStock > 0,
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // range selector
              Row(
                children: [
                  Text('Period:', style: theme.textTheme.bodyMedium),
                  const SizedBox(width: 8),
                  SegmentedButton<int>(
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
              const SizedBox(height: 12),

              // revenue chart
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Revenue trend',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 16),
                      SizedBox(
                        height: 220,
                        child: _revenue == null
                            ? const Center(child: CircularProgressIndicator())
                            : _RevenueLineChart(data: _revenue!),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Top products (units sold)',
                                style: theme.textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 16),
                            SizedBox(
                              height: 220,
                              child: _top == null || _top!.isEmpty
                                  ? Center(
                                      child: Text('No sales yet',
                                          style: TextStyle(
                                              color: Colors.grey.shade500)))
                                  : _TopProductsBarChart(data: _top!),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Category share (revenue)',
                                style: theme.textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 16),
                            SizedBox(
                              height: 220,
                              child: _categories == null || _categories!.isEmpty
                                  ? Center(
                                      child: Text('No sales yet',
                                          style: TextStyle(
                                              color: Colors.grey.shade500)))
                                  : _CategoryPie(data: _categories!),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------- chart widgets ----------

class _RevenueLineChart extends StatelessWidget {
  final List<(DateTime, double)> data;
  const _RevenueLineChart({required this.data});

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
          getDrawingHorizontalLine: (v) => const FlLine(
            color: Color(0x22000000),
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
              interval: (data.length / 6).clamp(1, 100).toDouble(),
              getTitlesWidget: (v, meta) {
                final idx = v.toInt();
                if (idx < 0 || idx >= data.length) return const SizedBox.shrink();
                final d = data[idx].$1;
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${d.day}/${d.month}',
                      style: const TextStyle(fontSize: 10)),
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
            color: Theme.of(context).colorScheme.primary,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(),
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
              getTitlesWidget: (v, meta) {
                final idx = v.toInt();
                if (idx < 0 || idx >= data.length) return const SizedBox.shrink();
                final name = data[idx].$1;
                final short = name.length > 10 ? '${name.substring(0, 10)}…' : name;
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(short, style: const TextStyle(fontSize: 9)),
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
                  width: 22,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                  color: Theme.of(context).colorScheme.primary,
                ),
              ],
            ),
        ],
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(),
        ),
      ),
    );
  }
}

class _CategoryPie extends StatelessWidget {
  final List<(String, double)> data;
  const _CategoryPie({required this.data});

  static const palette = [
    Color(0xFF3F51B5), Color(0xFF009688), Color(0xFFFF9800), Color(0xFFE91E63),
    Color(0xFF795548), Color(0xFF607D8B), Color(0xFF9C27B0), Color(0xFF8BC34A),
  ];

  @override
  Widget build(BuildContext context) {
    final total = data.fold(0.0, (s, d) => s + d.$2);

    return Column(
      children: [
        Expanded(
          child: PieChart(
            PieChartData(
              sectionsSpace: 2,
              centerSpaceRadius: 34,
              sections: [
                for (var i = 0; i < data.length; i++)
                  PieChartSectionData(
                    value: data[i].$2,
                    title: total > 0
                        ? '${(data[i].$2 / total * 100).round()}%'
                        : '',
                    titleStyle: const TextStyle(
                        fontSize: 10,
                        color: Colors.white,
                        fontWeight: FontWeight.bold),
                    radius: 52,
                    color: palette[i % palette.length],
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 4,
          children: [
            for (var i = 0; i < data.length; i++)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: palette[i % palette.length],
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(data[i].$1, style: const TextStyle(fontSize: 11)),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

// ---------- shared KPI card ----------

class StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final bool highlight;

  const StatCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Container(
        width: 172,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon,
                    size: 18,
                    color: highlight ? theme.colorScheme.error : theme.colorScheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(value,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: highlight ? theme.colorScheme.error : null,
                )),
          ],
        ),
      ),
    );
  }
}