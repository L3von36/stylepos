import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

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

  /// Contact captured before the cart clears — the done stage offers to
  /// email/SMS the receipt to the attached customer.
  String? _customerEmail;
  String? _customerPhone;

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

    // Capture who the receipt goes to (cart is cleared after checkout).
    _customerEmail = cart.customer?.email;
    _customerPhone = cart.customer?.phone;

    // ---- manager approval for manual discounts (salesperson gate) -------
    // A discount at or above the configured threshold needs a manager PIN
    // (or manager password) before the sale can complete — the single
    // approval moment is checkout, not the cart field.
    final discount = cart.discount;
    if (discountNeedsApproval(
        isAdmin: actor.isAdmin,
        discount: discount,
        threshold: settings.discountPinThreshold,
        canDiscount: actor.canDiscount,
        discountCap: actor.discountCap)) {
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

  String _receiptText(Sale sale, AppSettings settings) {
    final b = StringBuffer()
      ..writeln(settings.shopName)
      ..writeln('Receipt ${sale.receiptNo}')
      ..writeln('Date: ${DateTime.fromMillisecondsSinceEpoch(sale.createdAt * 1000)}')
      ..writeln('--------------------------------')
      ..writeln('Total: ${settings.money(sale.total)}')
      ..writeln('Paid by: ${_methodLabel(sale.paymentMethod)}');
    if (sale.changeDue > 0) b.writeln('Change: ${settings.money(sale.changeDue)}');
    b
      ..writeln('--------------------------------')
      ..writeln(settings.receiptFooter);
    return b.toString();
  }

  /// Email: share sheet with the PDF attached (Gmail/Outlook pick it up);
  /// falls back to a plain-text share on platforms without file sharing.
  Future<void> _emailReceipt() async {
    final sale = _sale!;
    final settings = context.read<AppSettings>();
    final text = _receiptText(sale, settings);
    try {
      if (!kIsWeb && _savedPdf != null) {
        await SharePlus.instance.share(ShareParams(
          files: [XFile(_savedPdf!.path, mimeType: 'application/pdf')],
          subject: 'Receipt ${sale.receiptNo} — ${settings.shopName}',
          text: text,
        ));
      } else {
        await SharePlus.instance.share(ShareParams(
          text: text,
          subject: 'Receipt ${sale.receiptNo} — ${settings.shopName}',
        ));
      }
      await Audit.add('receipt_emailed',
          '${sale.receiptNo} to ${_customerEmail ?? 'customer'}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not share receipt: $e')));
      }
    }
  }

  /// SMS: plain-text receipt through the phone's share/SMS sheet.
  Future<void> _smsReceipt() async {
    final sale = _sale!;
    final settings = context.read<AppSettings>();
    try {
      await SharePlus.instance.share(ShareParams(
        text: _receiptText(sale, settings),
        subject: 'Receipt ${sale.receiptNo}',
      ));
      await Audit.add(
          'receipt_sms', '${sale.receiptNo} to ${_customerPhone ?? 'customer'}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not share receipt: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final cart = context.watch<CartProvider>();
    final total = _sale?.total ?? cart.total(settings.taxRate);
    // Keep the chosen method valid when the manager disables it later.
    if (!settings.paymentMethods.contains(_method) &&
        settings.paymentMethods.isNotEmpty) {
      _method = settings.paymentMethods.first;
    }

    // Phones get the touch-first layout: on-screen keypad (no IME eating
    // half the dialog), compact header with a close button and one
    // full-width thumb-zone confirm button. Desktop keeps the text field.
    final mobile = MediaQuery.sizeOf(context).width < 720;

    return PopScope(
      canPop: _stage != _Stage.processing && _stage != _Stage.done,
      child: AlertDialog(
        titlePadding: EdgeInsets.fromLTRB(16, 16, mobile ? 8 : 24, 0),
        contentPadding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        // Phones: the default 40dp side insets shrink the dialog to ~280dp
        // and everything wraps awkwardly — 16dp keeps it readable without
        // touching the screen edges.
        insetPadding: EdgeInsets.symmetric(
            horizontal: mobile ? 12 : 16, vertical: mobile ? 16 : 24),
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
            Expanded(
              child: Text(_stage == _Stage.done ? 'Sale complete' : 'Take payment'),
            ),
            if (mobile && _stage == _Stage.payment)
              IconButton(
                tooltip: 'Cancel',
                icon: const Icon(Icons.close_rounded, size: 21),
                onPressed: () => Navigator.pop(context),
              ),
          ],
        ),
        // Responsive width: the fixed 410dp SizedBox forced the dialog to
        // overflow (clipped right edge) on phone screens — a maxWidth cap
        // fills whatever the phone gives and keeps 410dp on desktop.
        content: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: mobile ? 440 : 410),
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
            // Scrollable: with the keyboard up on a small phone the payment
            // column no longer clips the actions at the bottom.
            _Stage.payment =>
              SingleChildScrollView(child: _buildPayment(context, settings, total, mobile: mobile)),
          },
        ),
        actions: _stage == _Stage.done
            ? [
                // Full-width thumb-zone primary (mobile pattern); on wide
                // screens it sits beside the receipt actions.
                SizedBox(
                  width: mobile ? double.infinity : null,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.add_shopping_cart, size: 17),
                    label: const Text('New sale'),
                  ),
                ),
              ]
            : [
                SizedBox(
                  width: mobile ? double.infinity : null,
                  child: FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
                    onPressed: _stage == _Stage.payment ? _completeSale : null,
                    child: Text(mobile
                        ? 'Complete sale · ${settings.money(total)}'
                        : 'Complete sale'),
                  ),
                ),
              ],
      ),
    );
  }

  Widget _buildPayment(BuildContext context, AppSettings settings, double total,
      {required bool mobile}) {
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
              Row(
                children: [
                  Expanded(
                    child: Text('AMOUNT DUE',
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                            color: Colors.white.withValues(alpha: 0.75))),
                  ),
                  if (cart.itemCount > 0)
                    Text('${cart.itemCount} item${cart.itemCount == 1 ? '' : 's'}',
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Colors.white.withValues(alpha: 0.75))),
                ],
              ),
              const SizedBox(height: AppSpace.s1),
              Text(
                settings.money(total),
                style: const TextStyle(
                    fontFamily: 'Carlito',
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    color: Colors.white),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        Text('Payment method',
            style: TextStyle(fontFamily: 'Carlito', fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.muted)),
        const SizedBox(height: 8),
        // Three methods with icons + full labels overflow phone-sized
        // dialogs (~280dp content width) — compact them on tight widths.
        LayoutBuilder(builder: (context, lc) {
          final compact = lc.maxWidth < 400 || settings.paymentMethods.length > 3;
          return SegmentedButton<String>(
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity(vertical: 1.6),
            ),
            segments: [
              for (final m in settings.paymentMethods)
                ButtonSegment(
                  value: m,
                  icon: compact ? null : Icon(_methodIcon(m), size: 18),
                  label: Text(compact ? _shortMethodLabel(m) : _methodLabel(m)),
                ),
            ],
            selected: {_method},
            onSelectionChanged: (s) => setState(() => _method = s.first),
          );
        }),

        if (_method == 'cash') ...[
          const SizedBox(height: AppSpace.s4),
          if (mobile) ...[
            // Touch-first cash entry: a read-only display + on-screen
            // keypad. The soft keyboard used to cover half the dialog and
            // made the payment stage feel broken on small phones.
            _TenderedDisplay(
              value: _tendered.text,
              symbol: AppSettings.currencySymbol,
              onClear: () => _keypadApply('C'),
            ),
            const SizedBox(height: AppSpace.s3),
            _PaymentKeypad(onKey: _keypadApply),
          ] else
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
                labelText: 'Cash received (${AppSettings.currencySymbol})',
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
                    // Defer the controller write + rebuild out of the gesture
                    // dispatch: mutating the focused field's text mid-tap
                    // fouled the web pointer stream — every later tap on the
                    // dialog (actions included) was swallowed until some
                    // unrelated relayout unstuck it.
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      _tendered.text = quick.toStringAsFixed(0);
                      // Same stale-error rule as typing: re-tendering clears it.
                      _error = null;
                      setState(() {});
                    });
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

  /// Keypad input: digits, '.', '00', backspace and 'C' (clear).
  /// Mutations run post-frame — the same guard the quick-cash chips use —
  /// because mutating state during pointer dispatch fouls the web tap
  /// stream (taps on later targets get swallowed until a relayout).
  void _keypadApply(String key) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _stage != _Stage.payment) return;
      var v = _tendered.text;
      switch (key) {
        case 'C':
          v = '';
        case '<':
          if (v.isNotEmpty) v = v.substring(0, v.length - 1);
        case '.':
          if (!v.contains('.')) v = v.isEmpty ? '0.' : '$v.';
        case '00':
          if (v.isNotEmpty && v != '0' && v.length < 9) v = '${v}00';
        default: // digits
          if (v == '0') v = key;
          if (v.length < 9) v = v + key;
      }
      setState(() {
        _tendered.text = v;
        _error = null; // re-tendering clears a stale underpayment error
      });
    });
    setState(() {}); // schedule the frame the post-frame callback runs after
  }

  Widget _buildDone(BuildContext context, AppSettings settings) {
    final sale = _sale!;
    final canEmail = (_customerEmail ?? '').trim().isNotEmpty;
    final canSms = (_customerPhone ?? '').trim().isNotEmpty;
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
        if (canEmail || canSms) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (canEmail)
                OutlinedButton.icon(
                  onPressed: _emailReceipt,
                  icon: const Icon(Icons.mail_outline_rounded, size: 17),
                  label: const Text('Email receipt'),
                ),
              if (canEmail && canSms) const SizedBox(width: AppSpace.s2),
              if (canSms)
                OutlinedButton.icon(
                  onPressed: _smsReceipt,
                  icon: const Icon(Icons.sms_outlined, size: 17),
                  label: const Text('SMS receipt'),
                ),
            ],
          ),
          const SizedBox(height: AppSpace.s2),
        ],
        // Receipt actions moved out of the (now single-button) actions row —
        // four buttons wrapped onto two cramped rows on phones.
        Wrap(
          alignment: WrapAlignment.center,
          spacing: AppSpace.s1 + 2,
          runSpacing: AppSpace.s1,
          children: [
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
          ],
        ),
        const SizedBox(height: AppSpace.s1),
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

  /// Compact label for tight phone dialogs ("Mobile money" wraps/overflows).
  String _shortMethodLabel(String m) =>
      m == 'cash' ? 'Cash' : m == 'card' ? 'Card' : 'Mobile';

  IconData _methodIcon(String m) => m == 'cash'
      ? Icons.payments_outlined
      : m == 'card'
          ? Icons.credit_card_rounded
          : Icons.smartphone_rounded;
}

/// The cash-received display for the touch layout: shows the running entry
/// big and bold, with a clear (X) affordance. Read-only by design — the
/// digits come from [_PaymentKeypad], so the soft keyboard never opens.
class _TenderedDisplay extends StatelessWidget {
  final String value;
  final String symbol;
  final VoidCallback onClear;
  const _TenderedDisplay(
      {required this.value, required this.symbol, required this.onClear});

  @override
  Widget build(BuildContext context) {
    final hasEntry = value.isNotEmpty;
    return Container(
      height: 62,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.s4),
      decoration: BoxDecoration(
        color: AppColors.surfaceTint,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
            color: hasEntry ? AppColors.primary : AppColors.borderSoft,
            width: hasEntry ? 2 : 1),
      ),
      child: Row(
        children: [
          Text(symbol,
              style: TextStyle(
                  fontFamily: 'Carlito',
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: hasEntry ? AppColors.primary : AppColors.faint)),
          const SizedBox(width: AppSpace.s2),
          Expanded(
            child: Text(
              hasEntry ? value : '0',
              style: TextStyle(
                  fontFamily: 'Carlito',
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: hasEntry ? AppColors.ink : AppColors.faint),
            ),
          ),
          if (hasEntry)
            IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.backspace_outlined, size: 20),
              color: AppColors.muted,
              onPressed: onClear,
            ),
        ],
      ),
    );
  }
}

/// A POS-style numeric keypad for the cash amount: 4 columns x 4 rows of
/// 52dp-tall keys — thumb-friendly, no IME. Layout matches payment
/// terminals (1-2-3 top row, backspace bottom-right).
class _PaymentKeypad extends StatelessWidget {
  final ValueChanged<String> onKey;
  const _PaymentKeypad({required this.onKey});

  static const _keys = [
    ['1', '2', '3', 'C'],
    ['4', '5', '6', '00'],
    ['7', '8', '9', '.'],
    ['0', '<'],
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in _keys)
          Row(
            children: [
              for (final k in row)
                if (k == '<')
                  Expanded(
                    flex: 2,
                    child: _key(context, k, Icons.backspace_outlined, null),
                  )
                else
                  Expanded(child: _key(context, k, null, k)),
              // bottom row: 0 gets flex 2 to fill the 4th column
              if (row.first == '0') const Spacer(flex: 1),
            ],
          ),
      ],
    );
  }

  Widget _key(BuildContext context, String code, IconData? icon, String? label) {
    final isAction = code == 'C' || code == '<';
    return Padding(
      padding: const EdgeInsets.all(3),
      child: Material(
        color: isAction ? AppColors.surfaceTint : AppColors.primarySoft,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: () => onKey(code),
          child: SizedBox(
            height: 52,
            child: Center(
              child: icon != null
                  ? Icon(icon, size: 21, color: AppColors.muted)
                  : Text(label!,
                      style: TextStyle(
                          fontFamily: 'Carlito',
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primaryDark)),
            ),
          ),
        ),
      ),
    );
  }
}
