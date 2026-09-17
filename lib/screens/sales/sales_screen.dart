import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/sale.dart';
import '../../state/sales.dart';
import '../../state/settings.dart';
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

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          TextField(
            controller: _search,
            onChanged: (v) {
              _query = v;
              _load();
            },
            decoration: InputDecoration(
              hintText: 'Search receipt no, customer or cashier…',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _search.clear();
                        _query = '';
                        _load();
                      },
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            children: [
              for (final (label, days) in const [
                ('Today', 1), ('7 days', 7), ('30 days', 30), ('All', 0),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: _days == days,
                  onSelected: (_) {
                    setState(() => _days = days);
                    _load();
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _sales == null
                ? const Center(child: CircularProgressIndicator())
                : _sales!.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.receipt_long_outlined,
                                size: 48, color: Colors.grey.shade400),
                            const SizedBox(height: 8),
                            const Text('No sales in this period yet'),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          itemCount: _sales!.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 6),
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
    final theme = Theme.of(context);
    final dt = DateTime.fromMillisecondsSinceEpoch(sale.createdAt * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    final when =
        '${two(dt.day)}/${two(dt.month)} ${two(dt.hour)}:${two(dt.minute)}';

    return Card(
      child: ListTile(
        onTap: () async {
          await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SaleDetailScreen(saleId: sale.id!)));
          // refresh totals/stock if a refund happened in the detail screen
          if (context.mounted) {
            // ignore: use_build_context_synchronously
            _reloadSales(context);
          }
        },
        leading: CircleAvatar(
          backgroundColor: sale.isRefunded
              ? theme.colorScheme.errorContainer
              : theme.colorScheme.primaryContainer,
          child: Icon(
            switch (sale.paymentMethod) {
              'card' => Icons.credit_card,
              'mobile' => Icons.smartphone,
              _ => Icons.payments_outlined,
            },
            size: 20,
            color: sale.isRefunded ? theme.colorScheme.error : theme.colorScheme.primary,
          ),
        ),
        title: Row(
          children: [
            Text(sale.receiptNo, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            if (sale.isRefunded)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('Refunded',
                    style: TextStyle(fontSize: 10, color: theme.colorScheme.error)),
              ),
          ],
        ),
        subtitle: Text(
          '$when · ${sale.customerName ?? 'Walk-in'} · ${sale.cashierName ?? ''}',
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Text(
          settings.money(sale.total),
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            decoration: sale.isRefunded ? TextDecoration.lineThrough : null,
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
