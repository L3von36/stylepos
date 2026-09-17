import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/sale.dart';
import '../../services/receipt_service.dart';
import '../../state/auth.dart';
import '../../state/catalog.dart';
import '../../state/sales.dart';
import '../../state/settings.dart';

/// Receipt view for one sale: items, totals, PDF actions and refund (admin).
class SaleDetailScreen extends StatefulWidget {
  final int saleId;
  const SaleDetailScreen({super.key, required this.saleId});

  @override
  State<SaleDetailScreen> createState() => _SaleDetailScreenState();
}

class _SaleDetailScreenState extends State<SaleDetailScreen> {
  Sale? _sale;
  List<SaleItem> _items = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sales = context.read<SalesProvider>();
    final all = await sales.listSales(days: 0);
    final sale = all.firstWhere((s) => s.id == widget.saleId,
        orElse: () => const Sale(
            receiptNo: '-',
            userId: 0,
            paymentMethod: 'cash',
            subtotal: 0,
            total: 0,
            createdAt: 0));
    final items = await sales.itemsForSale(widget.saleId);
    if (mounted) {
      setState(() {
        _sale = sale;
        _items = items;
        _loaded = true;
      });
    }
  }

  Future<void> _refund() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Refund this sale?'),
        content: const Text(
            'All items will be returned to stock and the sale marked as refunded. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(c).colorScheme.error),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Refund'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final sales = context.read<SalesProvider>();
    final catalog = context.read<CatalogProvider>();
    final user = context.read<AuthProvider>().user!;
    await sales.refund(_sale!, user.id!);
    await catalog.reload();
    await _load();
    if (mounted) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Sale refunded, stock restored')));
    }
  }

  Future<void> _saveOrPrint({required bool printIt}) async {
    try {
      final settings = context.read<AppSettings>();
      final bytes = await ReceiptService.buildPdf(
        sale: _sale!,
        items: _items,
        settings: settings,
        pointsEarned: 0,
      );
      if (printIt) {
        await ReceiptService.printPdf(bytes);
      } else {
        final file = await ReceiptService.savePdf(bytes, _sale!.receiptNo);
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('Saved to ${file.path}')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final auth = context.watch<AuthProvider>();
    final theme = Theme.of(context);

    if (!_loaded) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final sale = _sale!;
    final dt = DateTime.fromMillisecondsSinceEpoch(sale.createdAt * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    final when =
        '${two(dt.day)}/${two(dt.month)}/${dt.year} ${two(dt.hour)}:${two(dt.minute)}';

    return Scaffold(
      appBar: AppBar(
        title: Text(sale.receiptNo),
        actions: [
          if (auth.user?.isAdmin == true && !sale.isRefunded)
            IconButton(
              tooltip: 'Refund',
              icon: const Icon(Icons.undo),
              onPressed: _refund,
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // header
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text('Receipt ${sale.receiptNo}',
                                style: theme.textTheme.titleLarge
                                    ?.copyWith(fontWeight: FontWeight.bold)),
                            const Spacer(),
                            if (sale.isRefunded)
                              Chip(
                                label: const Text('REFUNDED'),
                                backgroundColor: theme.colorScheme.errorContainer,
                                labelStyle:
                                    TextStyle(color: theme.colorScheme.error, fontSize: 11),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text('$when · Cashier: ${sale.cashierName ?? '-'}'
                            ' · Customer: ${sale.customerName ?? 'Walk-in'}',
                            style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                // items
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      children: [
                        for (final it in _items)
                          ListTile(
                            dense: true,
                            title: Text(it.productName),
                            subtitle: Text(
                                '${it.variantDesc} · ${settings.money(it.unitPrice)} × ${it.qty}'),
                            trailing: Text(settings.money(it.lineTotal),
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                // totals
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _row('Subtotal', settings.money(sale.subtotal)),
                        if (sale.discount > 0)
                          _row('Discount', '- ${settings.money(sale.discount)}'),
                        if (sale.tax > 0) _row('Tax', settings.money(sale.tax)),
                        const Divider(height: 18),
                        Row(
                          children: [
                            Text('TOTAL',
                                style: theme.textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.bold)),
                            const Spacer(),
                            Text(settings.money(sale.total),
                                style: theme.textTheme.titleLarge
                                    ?.copyWith(fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        _row('Payment', sale.paymentMethod),
                        if (sale.paymentMethod == 'cash') ...[
                          _row('Tendered', settings.money(sale.amountPaid)),
                          if (sale.changeDue > 0)
                            _row('Change', settings.money(sale.changeDue)),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _saveOrPrint(printIt: false),
                        icon: const Icon(Icons.save_outlined, size: 18),
                        label: const Text('Save PDF'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => _saveOrPrint(printIt: true),
                        icon: const Icon(Icons.print_outlined, size: 18),
                        label: const Text('Print'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(label, style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
          const Spacer(),
          Text(value, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
}
