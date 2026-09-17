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
import '../../widgets/ui.dart';

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

  double _changeDue(double total) {
    final change = _tenderedValue - total;
    return change > 0 ? change : 0.0;
  }

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
    final total = _sale?.total ?? cart.total(settings.taxRate);

    return PopScope(
      canPop: _stage != _Stage.processing && _stage != _Stage.done,
      child: AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
        contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
        actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        title: Row(
          children: [
            if (_stage == _Stage.done)
              Container(
                width: 34,
                height: 34,
                decoration: const BoxDecoration(color: AppColors.successSoft, shape: BoxShape.circle),
                child: const Icon(Icons.check_rounded, size: 21, color: AppColors.success),
              )
            else
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.payments_outlined, size: 19, color: AppColors.primary),
              ),
            const SizedBox(width: 11),
            Text(_stage == _Stage.done ? 'Sale complete' : 'Take payment'),
          ],
        ),
        content: SizedBox(
          width: 410,
          child: switch (_stage) {
            _Stage.done => _buildDone(context, settings),
            _Stage.processing => const Padding(
                padding: EdgeInsets.all(40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 18),
                    Text('Processing sale…'),
                  ],
                ),
              ),
            _Stage.payment => _buildPayment(context, settings, total),
          },
        ),
        actions: _stage == _Stage.done
            ? [
                if (Platform.isAndroid || Platform.isIOS)
                  TextButton.icon(
                    onPressed: _sharePdf,
                    icon: const Icon(Icons.share_outlined, size: 17),
                    label: const Text('Share'),
                  ),
                TextButton.icon(
                  onPressed: _savePdf,
                  icon: const Icon(Icons.save_outlined, size: 17),
                  label: const Text('Save PDF'),
                ),
                TextButton.icon(
                  onPressed: _printPdf,
                  icon: const Icon(Icons.print_outlined, size: 17),
                  label: const Text('Print'),
                ),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.add_shopping_cart, size: 17),
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

  Widget _buildPayment(BuildContext context, AppSettings settings, double total) {
    final cart = context.watch<CartProvider>();
    final change = _changeDue(total);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // totals summary
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF4F46E5), Color(0xFF6D28D9)],
            ),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Amount due',
                  style: TextStyle(
                      fontFamily: 'Carlito',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                      color: Colors.white.withValues(alpha: 0.8))),
              const SizedBox(height: 2),
              Text(
                settings.money(total),
                style: const TextStyle(
                    fontFamily: 'Carlito',
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: Colors.white),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        const Text('Payment method',
            style: TextStyle(fontFamily: 'Carlito', fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.muted)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          showSelectedIcon: false,
          style: const ButtonStyle(
            visualDensity: VisualDensity(vertical: 1.6),
          ),
          segments: const [
            ButtonSegment(value: 'cash', icon: Icon(Icons.payments_outlined, size: 18), label: Text('Cash')),
            ButtonSegment(value: 'card', icon: Icon(Icons.credit_card_rounded, size: 18), label: Text('Card')),
            ButtonSegment(
                value: 'mobile', icon: Icon(Icons.smartphone_rounded, size: 18), label: Text('Mobile')),
          ],
          selected: {_method},
          onSelectionChanged: (s) => setState(() => _method = s.first),
        ),

        if (_method == 'cash') ...[
          const SizedBox(height: 16),
          TextField(
            controller: _tendered,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            decoration: InputDecoration(
              labelText: 'Cash received (${settings.currencySymbol})',
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 7,
            runSpacing: 7,
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
                  labelStyle: const TextStyle(fontFamily: 'Carlito', fontSize: 12.5, fontWeight: FontWeight.w700),
                  backgroundColor: AppColors.primarySoft,
                  side: BorderSide.none,
                  onPressed: () {
                    _tendered.text = quick.toStringAsFixed(0);
                    setState(() {});
                  },
                ),
            ],
          ),
          if (_tenderedValue > 0) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.successSoft,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Row(
                children: [
                  const Icon(Icons.savings_outlined, size: 19, color: AppColors.success),
                  const SizedBox(width: 9),
                  const Text('Change due',
                      style: TextStyle(fontFamily: 'Carlito', fontSize: 13.5, color: AppColors.body)),
                  const Spacer(),
                  Text(
                    settings.money(change),
                    style: const TextStyle(
                        fontFamily: 'Carlito',
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.success),
                  ),
                ],
              ),
            ),
          ],
        ],

        if (cart.customer != null && settings.loyaltyStep > 0) ...[
          const SizedBox(height: 13),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Row(
              children: [
                const Icon(Icons.loyalty_outlined, size: 17, color: AppColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${cart.customer!.name} earns ${(total / settings.loyaltyStep).floor()} loyalty points',
                    style: const TextStyle(fontFamily: 'Carlito', fontSize: 12.5, color: AppColors.primaryDark),
                  ),
                ),
              ],
            ),
          ),
        ],

        if (_error != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: AppColors.dangerSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline_rounded, size: 17, color: AppColors.danger),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_error!,
                      style: const TextStyle(fontFamily: 'Carlito', fontSize: 12.5, color: AppColors.danger)),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildDone(BuildContext context, AppSettings settings) {
    final sale = _sale!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.successSoft,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: AppColors.success.withValues(alpha: 0.25)),
          ),
          child: Column(
            children: [
              Text(settings.money(sale.total),
                  style: const TextStyle(
                      fontFamily: 'Carlito',
                      fontSize: 32,
                      fontWeight: FontWeight.w700,
                      color: AppColors.success)),
              const SizedBox(height: 4),
              Text('${sale.receiptNo} · ${_methodLabel(sale.paymentMethod)}',
                  style: const TextStyle(fontFamily: 'Carlito', fontSize: 13, color: AppColors.body)),
              if (sale.changeDue > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'Give change: ${settings.money(sale.changeDue)}',
                      style: const TextStyle(
                          fontFamily: 'Carlito',
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.success),
                    ),
                  ),
                ),
              if (_pointsEarned > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('+$_pointsEarned loyalty points',
                      style: const TextStyle(fontFamily: 'Carlito', fontSize: 12.5, color: AppColors.success)),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          _savedPdf == null
              ? 'Save or print the receipt below.'
              : 'Receipt saved: ${_savedPdf!.path.split('/').last}',
          textAlign: TextAlign.center,
          style: const TextStyle(fontFamily: 'Carlito', fontSize: 12.5, color: AppColors.muted),
        ),
      ],
    );
  }

  String _methodLabel(String m) =>
      m == 'cash' ? 'Cash' : m == 'card' ? 'Card' : 'Mobile money';
}
