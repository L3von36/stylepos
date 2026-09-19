import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/sale.dart';
import '../../services/approvals.dart';
import '../../services/audit.dart';
import '../../services/receipt_service.dart';
import '../../state/auth.dart';
import '../../state/cart.dart';
import '../../state/catalog.dart';
import '../../state/customers.dart';
import '../../state/sales.dart';
import '../../state/settings.dart';
import '../../widgets/rive_view.dart';
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
    final cart = context.read<CartProvider>();
    final settings = context.read<AppSettings>();
    // Read everything up-front: the approval dialog and the audit write
    // introduce async gaps, so no context reads may happen after them.
    final auth = context.read<AuthProvider>();
    final sales = context.read<SalesProvider>();
    final catalog = context.read<CatalogProvider>();
    final customers = context.read<CustomersProvider>();
    final actor = auth.user!;

    // ---- manager approval for manual discounts (salesperson gate) -------
    // A discount at or above the configured threshold needs a manager PIN
    // (or manager password) before the sale can complete — the single
    // approval moment is checkout, not the cart field.
    final discount = cart.discount;
    if (discountNeedsApproval(
        isAdmin: actor.isAdmin,
        discount: discount,
        threshold: settings.discountPinThreshold)) {
      final ok = await Approvals.request(
        context,
        title: 'Discount needs approval',
        reason:
            'This sale carries a ${settings.money(discount)} manual discount. '
            'A manager must approve it before checkout.',
      );
      if (ok == null) {
        setState(() {
          _error = 'Discount not approved — reduce it or ask a manager.';
        });
        return;
      }
      await Audit.add(
        'discount_approved',
        '${settings.money(discount)} approved via ${ok.methodLabel} '
        '(sale by ${actor.name})',
        userId: ok.userId > 0 ? ok.userId : actor.id,
        userName: ok.userId > 0 ? ok.userName : actor.name,
      );
    }

    // Cash guard: never record a cash sale that was not fully tendered.
    final due = cart.total(settings.taxRate);
    if (_method == 'cash' && _tenderedValue + 0.001 < due) {
      setState(() {
        _error = 'Cash received is less than the amount due — collect '
            '${settings.money(due - _tenderedValue)} more.';
      });
      return;
    }

    setState(() {
      _stage = _Stage.processing;
      _error = null;
    });
    try {
      // loyalty preview (mirrors sales.checkout logic)
      final total = cart.total(settings.taxRate);
      _pointsEarned = (cart.customer?.id != null && settings.loyaltyStep > 0)
          ? (total / settings.loyaltyStep).floor()
          : 0;

      final sale = await sales.checkout(
        cart: cart,
        userId: actor.id!,
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
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
        contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
        actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        title: Row(
          children: [
            if (_stage == _Stage.done)
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(color: AppColors.successSoft, shape: BoxShape.circle),
                child: Icon(Icons.check_rounded, size: 21, color: AppColors.success),
              )
            else
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(Icons.payments_outlined, size: 19, color: AppColors.primary),
              ),
            const SizedBox(width: AppSpace.s3),
            Text(_stage == _Stage.done ? 'Sale complete' : 'Take payment'),
          ],
        ),
        content: SizedBox(
          width: 410,
          child: switch (_stage) {
            _Stage.done => _buildDone(context, settings),
            _Stage.processing => const Padding(
                padding: EdgeInsets.all(AppSpace.s10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: AppSpace.s4),
                    Text('Processing sale…'),
                  ],
                ),
              ),
            _Stage.payment => _buildPayment(context, settings, total),
          },
        ),
        actions: _stage == _Stage.done
            ? [
                // Share / Save rely on a local file system (not on web);
                // on web, Print opens the browser dialog which can save PDFs.
                if (!kIsWeb && (Platform.isAndroid || Platform.isIOS))
                  TextButton.icon(
                    onPressed: _sharePdf,
                    icon: const Icon(Icons.share_outlined, size: 17),
                    label: const Text('Share'),
                  ),
                if (!kIsWeb)
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
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.s4, vertical: AppSpace.s4),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF4F46E5), Color(0xFF6D28D9)],
            ),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Amount due',
                  style: TextStyle(
                      fontFamily: 'Carlito',
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: Colors.white.withValues(alpha: 0.8))),
              const SizedBox(height: AppSpace.s1),
              Text(
                settings.money(total),
                style: const TextStyle(
                    fontFamily: 'Carlito',
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: Colors.white),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        Text('Payment method',
            style: TextStyle(fontFamily: 'Carlito', fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.muted)),
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
          const SizedBox(height: AppSpace.s4),
          TextField(
            controller: _tendered,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            // Changing the amount invalidates a previously-shown
            // underpayment error — otherwise the dialog can show the red
            // "collect more" banner and the green "Change due" banner at
            // the same time.
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            decoration: InputDecoration(
              labelText: 'Cash received (${settings.currencySymbol})',
            ),
          ),
          const SizedBox(height: AppSpace.s3),
          Wrap(
            spacing: AppSpace.s2,
            runSpacing: AppSpace.s2,
            children: [
              for (final quick in [
                total.ceilToDouble(),
                (total / 2).ceilToDouble() * 2,
                500.0,
                1000.0,
                2000.0,
              ].where((q) => q >= total).toSet())
                ActionChip(
                  label: Text(settings.money(quick)),
                  labelStyle: const TextStyle(fontFamily: 'Carlito', fontSize: 12, fontWeight: FontWeight.w700),
                  backgroundColor: AppColors.primarySoft,
                  side: BorderSide.none,
                  onPressed: () {
                    _tendered.text = quick.toStringAsFixed(0);
                    // Same stale-error rule as typing: re-tendering clears it.
                    if (_error != null) {
                      setState(() => _error = null);
                    } else {
                      setState(() {});
                    }
                  },
                ),
            ],
          ),
          if (_tenderedValue > 0) ...[
            const SizedBox(height: AppSpace.s3),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.s4, vertical: AppSpace.s3),
              decoration: BoxDecoration(
                // Short payment shows red with the missing amount;
                // fully covered shows green with the change.
                color: _tenderedValue + 0.001 < total
                    ? AppColors.dangerSoft
                    : AppColors.successSoft,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Row(
                children: [
                  Icon(
                    _tenderedValue + 0.001 < total
                        ? Icons.error_outline_rounded
                        : Icons.savings_outlined,
                    size: 19,
                    color: _tenderedValue + 0.001 < total
                        ? AppColors.danger
                        : AppColors.success,
                  ),
                  const SizedBox(width: AppSpace.s2),
                  Text(
                      _tenderedValue + 0.001 < total
                          ? 'Still owed'
                          : 'Change due',
                      style: TextStyle(fontFamily: 'Carlito', fontSize: 13, color: AppColors.body)),
                  const Spacer(),
                  Text(
                    settings.money(_tenderedValue + 0.001 < total
                        ? total - _tenderedValue
                        : change),
                    style: TextStyle(
                        fontFamily: 'Carlito',
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: _tenderedValue + 0.001 < total
                            ? AppColors.danger
                            : AppColors.success),
                  ),
                ],
              ),
            ),
          ],
        ],

        if (cart.customer != null && settings.loyaltyStep > 0) ...[
          const SizedBox(height: AppSpace.s3),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.s3, vertical: AppSpace.s2),
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Row(
              children: [
                Icon(Icons.loyalty_outlined, size: 17, color: AppColors.primary),
                const SizedBox(width: AppSpace.s2),
                Expanded(
                  child: Text(
                    '${cart.customer!.name} earns ${(total / settings.loyaltyStep).floor()} loyalty points',
                    style: TextStyle(fontFamily: 'Carlito', fontSize: 12, color: AppColors.primaryDark),
                  ),
                ),
              ],
            ),
          ),
        ],

        if (_error != null) ...[
          const SizedBox(height: AppSpace.s3),
          Container(
            padding: const EdgeInsets.all(AppSpace.s3),
            decoration: BoxDecoration(
              color: AppColors.dangerSoft,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline_rounded, size: 17, color: AppColors.danger),
                const SizedBox(width: AppSpace.s2),
                Expanded(
                  child: Text(_error!,
                      style: TextStyle(fontFamily: 'Carlito', fontSize: 12, color: AppColors.danger)),
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
          padding: const EdgeInsets.all(AppSpace.s4),
          decoration: BoxDecoration(
            color: AppColors.successSoft,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: AppColors.success.withValues(alpha: 0.25)),
          ),
          child: Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SaleSuccessArt(size: 64),
                  const SizedBox(width: AppSpace.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(settings.money(sale.total),
                            style: TextStyle(
                                fontFamily: 'Carlito',
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                                color: AppColors.success)),
                        const SizedBox(height: 2),
                        Text('${sale.receiptNo} · ${_methodLabel(sale.paymentMethod)}',
                            style: TextStyle(
                                fontFamily: 'Carlito', fontSize: 13, color: AppColors.body)),
                      ],
                    ),
                  ),
                ],
              ),
              if (sale.changeDue > 0)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpace.s2),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpace.s4, vertical: AppSpace.s1),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    child: Text(
                      'Give change: ${settings.money(sale.changeDue)}',
                      style: TextStyle(
                          fontFamily: 'Carlito',
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.success),
                    ),
                  ),
                ),
              if (_pointsEarned > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('+$_pointsEarned loyalty points',
                      style: TextStyle(fontFamily: 'Carlito', fontSize: 12, color: AppColors.success)),
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
          style: TextStyle(fontFamily: 'Carlito', fontSize: 12, color: AppColors.muted),
        ),
      ],
    );
  }

  String _methodLabel(String m) =>
      m == 'cash' ? 'Cash' : m == 'card' ? 'Card' : 'Mobile money';
}
