import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/sale.dart';
import '../../services/receipt_service.dart';
import '../../state/auth.dart';
import '../../state/catalog.dart';
import '../../state/sales.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';

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
        title: Row(children: [
          Icon(Icons.undo_rounded, size: 21, color: AppColors.danger),
          SizedBox(width: AppSpace.s3),
          Text('Refund this sale?'),
        ]),
        content: const SizedBox(
            width: 380,
            child: Text(
                'All items will be returned to stock and the sale marked as refunded. This cannot be undone.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppColors.danger),
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
              icon: const Icon(Icons.undo_rounded),
              onPressed: _refund,
            ),
          const SizedBox(width: AppSpace.s2),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpace.s4),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 580),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // header
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpace.s4 + 2),
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: sale.isRefunded ? AppColors.dangerSoft : AppColors.primarySoft,
                            borderRadius: BorderRadius.circular(AppRadius.md),
                          ),
                          child: Icon(
                            sale.isRefunded ? Icons.undo_rounded : Icons.receipt_long_rounded,
                            size: 23,
                            color: sale.isRefunded ? AppColors.danger : AppColors.primary,
                          ),
                        ),
                        const SizedBox(width: AppSpace.s4),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text('Receipt ${sale.receiptNo}',
                                      style: TextStyle(
                                          fontFamily: 'Carlito',
                                          fontSize: 17,
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.ink)),
                                  if (sale.isRefunded) ...[
                                    const SizedBox(width: AppSpace.s2),
                                    StatusPill.build(context,
                                        label: 'REFUNDED',
                                        foreground: AppColors.danger,
                                        background: AppColors.dangerSoft),
                                  ],
                                ],
                              ),
                              const SizedBox(height: AppSpace.s1),
                              Text('$when · Cashier: ${sale.cashierName ?? '-'}'
                                  ' · Customer: ${sale.customerName ?? 'Walk-in'}',
                                  style: TextStyle(
                                      fontFamily: 'Carlito', fontSize: 12.5, color: AppColors.muted)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: AppSpace.s3),

                // items
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, AppSpace.s3, 16, AppSpace.s2),
                        child: Row(
                          children: [
                            Text('Items',
                                style: TextStyle(
                                    fontFamily: 'Carlito',
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.ink)),
                            const Spacer(),
                            Text('${_items.length} line${_items.length == 1 ? '' : 's'}',
                                style: TextStyle(fontFamily: 'Carlito', fontSize: 12, color: AppColors.muted)),
                          ],
                        ),
                      ),
                      const Divider(indent: 16, endIndent: 16),
                      for (final it in _items)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: AppSpace.s2),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(it.productName,
                                        style: TextStyle(
                                            fontFamily: 'Carlito',
                                            fontSize: 14,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.ink)),
                                    Text(
                                        '${it.variantDesc} · ${settings.money(it.unitPrice)} × ${it.qty}',
                                        style: TextStyle(
                                            fontFamily: 'Carlito', fontSize: 12.5, color: AppColors.muted)),
                                  ],
                                ),
                              ),
                              Text(settings.money(it.lineTotal),
                                  style: TextStyle(
                                      fontFamily: 'Carlito',
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.body)),
                            ],
                          ),
                        ),
                      const SizedBox(height: AppSpace.s1),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpace.s3),

                // totals
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpace.s4 + 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _row('Subtotal', settings.money(sale.subtotal)),
                        if (sale.discount > 0)
                          _row('Discount', '- ${settings.money(sale.discount)}',
                              color: AppColors.danger),
                        if (sale.tax > 0) _row('Tax', settings.money(sale.tax)),
                        const Divider(height: AppSpace.s5),
                        Row(
                          children: [
                            Text('TOTAL',
                                style: TextStyle(
                                    fontFamily: 'Carlito',
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.4,
                                    color: AppColors.muted)),
                            const Spacer(),
                            Text(settings.money(sale.total),
                                style: TextStyle(
                                    fontFamily: 'Carlito',
                                    fontSize: 22,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.primaryDark)),
                          ],
                        ),
                        const SizedBox(height: AppSpace.s3),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: AppSpace.s4, vertical: AppSpace.s3),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceTint,
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                          ),
                          child: Column(
                            children: [
                              _row('Payment', _methodLabel(sale.paymentMethod)),
                              if (sale.paymentMethod == 'cash') ...[
                                _row('Tendered', settings.money(sale.amountPaid)),
                                if (sale.changeDue > 0)
                                  _row('Change', settings.money(sale.changeDue),
                                      color: AppColors.success),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: AppSpace.s4),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _saveOrPrint(printIt: false),
                        icon: const Icon(Icons.save_outlined, size: 18),
                        label: const Text('Save PDF'),
                      ),
                    ),
                    const SizedBox(width: AppSpace.s3),
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

  String _methodLabel(String m) =>
      m == 'cash' ? 'Cash' : m == 'card' ? 'Card' : 'Mobile money';

  Widget _row(String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(label, style: TextStyle(fontFamily: 'Carlito', fontSize: 13, color: AppColors.muted)),
          const Spacer(),
          Text(value, style: TextStyle(
              fontFamily: 'Carlito', fontSize: 13, fontWeight: FontWeight.w700,
              color: color ?? AppColors.body)),
        ],
      ),
    );
  }
}
