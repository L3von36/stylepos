import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/sale.dart';
import '../../state/sales.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';
import 'sale_detail_screen.dart';

/// Sales history with time filters and search by receipt / customer / cashier.
class SalesScreen extends StatefulWidget {
  const SalesScreen({super.key});

  @override
  State<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends State<SalesScreen> {
  int _days = 1; // 1 = today
  final _search = TextEditingController();
  String _query = '';
  List<Sale>? _sales;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final sales = await context.read<SalesProvider>().listSales(
          days: _days,
          query: _query,
        );
    if (mounted) setState(() => _sales = sales);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final totalRevenue =
        _sales?.where((s) => !s.isRefunded).fold(0.0, (sum, s) => sum + s.total) ?? 0.0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      child: Column(
        children: [
          PageHeader(
            title: 'Sales',
            subtitle: _sales == null
                ? 'Loading…'
                : '${_sales!.length} receipt${_sales!.length == 1 ? '' : 's'}'
                    ' · ${settings.money(totalRevenue)} revenue',
          ),
          Row(
            children: [
              Expanded(
                child: SearchField(
                  controller: _search,
                  hint: 'Search receipt no, customer or cashier…',
                  onChanged: (v) {
                    _query = v;
                    _load();
                  },
                  onClear: () {
                    _search.clear();
                    _query = '';
                    _load();
                  },
                ),
              ),
              const SizedBox(width: 12),
              SegmentedButton<int>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 1, label: Text('Today')),
                  ButtonSegment(value: 7, label: Text('7 days')),
                  ButtonSegment(value: 30, label: Text('30 days')),
                  ButtonSegment(value: 0, label: Text('All')),
                ],
                selected: {_days},
                onSelectionChanged: (s) {
                  setState(() => _days = s.first);
                  _load();
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: _sales == null
                ? const Center(child: CircularProgressIndicator())
                : _sales!.isEmpty
                    ? EmptyState(
                        icon: Icons.receipt_long_outlined,
                        title: 'No sales in this period',
                        message: 'Completed checkouts will appear here as receipts.',
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          itemCount: _sales!.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, i) =>
                              _SaleTile(sale: _sales![i], settings: settings),
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

class _SaleTile extends StatelessWidget {
  final Sale sale;
  final AppSettings settings;
  const _SaleTile({required this.sale, required this.settings});

  @override
  Widget build(BuildContext context) {
    final dt = DateTime.fromMillisecondsSinceEpoch(sale.createdAt * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    final when =
        '${two(dt.day)}/${two(dt.month)} ${two(dt.hour)}:${two(dt.minute)}';

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () async {
          await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SaleDetailScreen(saleId: sale.id!)));
          // refresh totals/stock if a refund happened in the detail screen
          if (context.mounted) {
            _reloadSales(context);
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: sale.isRefunded ? AppColors.dangerSoft : AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  switch (sale.paymentMethod) {
                    'card' => Icons.credit_card_rounded,
                    'mobile' => Icons.smartphone_rounded,
                    _ => Icons.payments_outlined,
                  },
                  size: 21,
                  color: sale.isRefunded ? AppColors.danger : AppColors.primary,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(sale.receiptNo,
                            style: const TextStyle(
                                fontFamily: 'Carlito',
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                                color: AppColors.ink)),
                        if (sale.isRefunded) ...[
                          const SizedBox(width: 8),
                          StatusPill.build(context,
                              label: 'Refunded',
                              foreground: AppColors.danger,
                              background: AppColors.dangerSoft,
                              icon: Icons.undo_rounded),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$when · ${sale.customerName ?? 'Walk-in'} · ${sale.cashierName ?? ''}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: 'Carlito', fontSize: 12.5, color: AppColors.muted),
                    ),
                  ],
                ),
              ),
              Text(
                settings.money(sale.total),
                style: TextStyle(
                  fontFamily: 'Carlito',
                  fontWeight: FontWeight.w700,
                  fontSize: 15.5,
                  color: sale.isRefunded ? AppColors.faint : AppColors.ink,
                  decoration: sale.isRefunded ? TextDecoration.lineThrough : null,
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.faint),
            ],
          ),
        ),
      ),
    );
  }
}

void _reloadSales(BuildContext context) {
  final state = context.findAncestorStateOfType<_SalesScreenState>();
  state?._load();
}
