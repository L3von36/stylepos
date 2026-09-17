import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/sale.dart';
import '../../services/receipt_service.dart';
import '../../state/auth.dart';
import '../../state/cart.dart';
import '../../state/catalog.dart';
import '../../state/customers.dart';
import '../../state/sales.dart';
import '../../state/settings.dart';

enum _Stage { payment, processing, done }

/// Payment dialog: choose method, enter tendered (cash), complete the sale,
/// then show the receipt actions (save PDF / print / share).
class CheckoutDialog extends StatefulWidget {
  const CheckoutDialog({super.key});

  @override
  State<CheckoutDialog> createState() => _CheckoutDialogState();
}

class _CheckoutDialogState extends State<CheckoutDialog> {
  _Stage _stage = _Stage.payment;
  String _method = 'cash';
  final _tendered = TextEditingController();
  String? _error;
  Sale? _sale;
  int _pointsEarned = 0;
  File? _savedPdf;

  @override
  void dispose() {
    _tendered.dispose();
    super.dispose();
  }

  double get _tenderedValue => double.tryParse(_tendered.text) ?? 0;

  Future<void> _completeSale() async {
    setState(() {
      _stage = _Stage.processing;
      _error = null;
    });
    try {
      final cart = context.read<CartProvider>();
      final sales = context.read<SalesProvider>();
      final settings = context.read<AppSettings>();
      final auth = context.read<AuthProvider>();
      final catalog = context.read<CatalogProvider>();
      final customers = context.read<CustomersProvider>();
      final user = auth.user!;

      // loyalty preview (mirrors sales.checkout logic)
      final total = cart.total(settings.taxRate);
      _pointsEarned = (cart.customer?.id != null && settings.loyaltyStep > 0)
          ? (total / settings.loyaltyStep).floor()
          : 0;

      final sale = await sales.checkout(
        cart: cart,
        userId: user.id!,
        paymentMethod: _method,
        amountPaid: _method == 'cash' ? _tenderedValue : total,
        settings: settings,
      );

      cart.clear();
      await catalog.reload();
      await customers.reload();

      setState(() {
        _sale = sale;
        _stage = _Stage.done;
      });
    } catch (e) {
      setState(() {
        _stage = _Stage.payment;
        _error = 'Sale failed: $e';
      });
    }
  }

  Future<void> _savePdf() async {
    try {
      final settings = context.read<AppSettings>();
      final sales = context.read<SalesProvider>();
      final sale = _sale!;
      final items = await sales.itemsForSale(sale.id!);
      final bytes = await ReceiptService.buildPdf(
        sale: sale,
        items: items,
        settings: settings,
        pointsEarned: _pointsEarned,
      );
      final file = await ReceiptService.savePdf(bytes, sale.receiptNo);
      setState(() => _savedPdf = file);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved to ${file.path}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not save PDF: $e')));
      }
    }
  }

  Future<void> _printPdf() async {
    try {
      final settings = context.read<AppSettings>();
      final sales = context.read<SalesProvider>();
      final sale = _sale!;
      final items = await sales.itemsForSale(sale.id!);
      final bytes = await ReceiptService.buildPdf(
        sale: sale,
        items: items,
        settings: settings,
        pointsEarned: _pointsEarned,
      );
      await ReceiptService.printPdf(bytes);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Print failed: $e')));
      }
    }
  }

  Future<void> _sharePdf() async {
    if (_savedPdf == null) await _savePdf();
    if (_savedPdf != null) await ReceiptService.sharePdf(_savedPdf!);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final cart = context.watch<CartProvider>();
    final theme = Theme.of(context);
    final total = _sale?.total ?? cart.total(settings.taxRate);

    return PopScope(
      canPop: _stage != _Stage.processing && _stage != _Stage.done,
      child: AlertDialog(
        title: Row(
          children: [
            Icon(
              _stage == _Stage.done ? Icons.check_circle : Icons.payments_outlined,
              color: _stage == _Stage.done ? Colors.green.shade600 : theme.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Text(_stage == _Stage.done ? 'Sale complete' : 'Take payment'),
          ],
        ),
        content: SizedBox(
          width: 400,
          child: switch (_stage) {
            _Stage.done => _buildDone(context, theme, settings),
            _Stage.processing => const Padding(
                padding: EdgeInsets.all(40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Processing sale…'),
                  ],
                ),
              ),
            _Stage.payment => _buildPayment(context, theme, settings, total),
          },
        ),
        actions: _stage == _Stage.done
            ? [
                if (Platform.isAndroid || Platform.isIOS)
                  TextButton.icon(
                    onPressed: _sharePdf,
                    icon: const Icon(Icons.share_outlined, size: 18),
                    label: const Text('Share'),
                  ),
                TextButton.icon(
                  onPressed: _savePdf,
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: const Text('Save PDF'),
                ),
                TextButton.icon(
                  onPressed: _printPdf,
                  icon: const Icon(Icons.print_outlined, size: 18),
                  label: const Text('Print'),
                ),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.add_shopping_cart, size: 18),
                  label: const Text('New sale'),
                ),
              ]
            : [
                TextButton(
                  onPressed:
                      _stage == _Stage.processing ? null : () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: _stage == _Stage.payment ? _completeSale : null,
                  child: const Text('Complete sale'),
                ),
              ],
      ),
    );
  }

  Widget _buildPayment(
      BuildContext context, ThemeData theme, AppSettings settings, double total) {
    final cart = context.watch<CartProvider>();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // totals summary
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Text('Amount due',
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
              const Spacer(),
              Text(
                settings.money(total),
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.primary),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        Text('Payment method', style: theme.textTheme.bodySmall),
        const SizedBox(height: 6),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'cash', icon: Icon(Icons.payments_outlined), label: Text('Cash')),
            ButtonSegment(value: 'card', icon: Icon(Icons.credit_card), label: Text('Card')),
            ButtonSegment(
                value: 'mobile', icon: Icon(Icons.smartphone), label: Text('Mobile')),
          ],
          selected: {_method},
          onSelectionChanged: (s) => setState(() => _method = s.first),
        ),

        if (_method == 'cash') ...[
          const SizedBox(height: 14),
          TextField(
            controller: _tendered,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Cash received (${settings.currencySymbol})',
              suffixIcon: _tenderedValue > 0
                  ? Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Center(
                        widthFactor: 1,
                        child: Text(
                          'Change: ${settings.money((_tenderedValue - total).clamp(0, double.maxFinite))}',
                          style: TextStyle(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.bold,
                              fontSize: 13),
                        ),
                      ),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            children: [
              for (final quick in [
                total.ceilToDouble(),
                (total / 2).ceilToDouble() * 2,
                500.0,
                1000.0,
                2000.0,
              ].where((q) => q >= total))
                ActionChip(
                  label: Text(settings.money(quick)),
                  onPressed: () {
                    _tendered.text = quick.toStringAsFixed(0);
                    setState(() {});
                  },
                ),
            ],
          ),
        ],

        if (cart.customer != null && settings.loyaltyStep > 0) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.loyalty_outlined, size: 16),
              const SizedBox(width: 6),
              Text(
                '${cart.customer!.name} earns ${(total / settings.loyaltyStep).floor()} points',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ],

        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!, style: TextStyle(color: theme.colorScheme.error, fontSize: 13)),
          ),
      ],
    );
  }

  Widget _buildDone(BuildContext context, ThemeData theme, AppSettings settings) {
    final sale = _sale!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.green.shade50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.green.shade200),
          ),
          child: Column(
            children: [
              Text(settings.money(sale.total),
                  style: theme.textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('${sale.receiptNo} · ${_methodLabel(sale.paymentMethod)}'),
              if (sale.changeDue > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Give change: ${settings.money(sale.changeDue)}',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, color: theme.colorScheme.primary),
                  ),
                ),
              if (_pointsEarned > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('+$_pointsEarned loyalty points',
                      style: const TextStyle(fontSize: 12)),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(
          _savedPdf == null
              ? 'Save or print the receipt below.'
              : 'Receipt saved: ${_savedPdf!.path.split('/').last}',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  String _methodLabel(String m) =>
      m == 'cash' ? 'Cash' : m == 'card' ? 'Card' : 'Mobile money';
}
