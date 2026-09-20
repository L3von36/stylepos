import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/sale.dart';
import '../../services/approvals.dart';
import '../../services/audit.dart';
import '../../services/receipt_service.dart';
import '../../state/auth.dart';
import '../../state/cart.dart';
import '../../state/catalog.dart';
import '../../state/nav.dart';
import '../../state/sales.dart';
import '../../core/app_log.dart';
import '../../core/errors.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';

/// Receipt view for one sale: items, totals, PDF actions and refund/exchange.
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

  /// Which items the user has checked for partial refund / exchange.
  final Set<int?> _selected = {};
  bool _selectMode = false; // true = show checkboxes

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
        _selected
          ..clear()
          ..addAll(items.map((i) => i.id));
      });
    }
  }

  List<SaleItem> get _selectedItems =>
      _items.where((i) => _selected.contains(i.id)).toList();

  void _toggleSelectMode() {
    setState(() {
      _selectMode = !_selectMode;
      if (!_selectMode) {
        _selected
          ..clear()
          ..addAll(_items.map((i) => i.id));
      }
    });
  }

  Future<Approval?> _requestApproval(String reason) async {
    final auth = context.read<AuthProvider>();
    final actor = auth.user;
    if (actor == null || actor.isAdmin || actor.canRefund) return null;
    return Approvals.request(context,
        title: 'Manager approval required', reason: reason);
  }

  Future<void> _doRefund({required bool isExchange}) async {
    final settings = context.read<AppSettings>();
    final sale = _sale!;
    final toReturn = _selectedItems;
    if (toReturn.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Select at least one item to return')));
      return;
    }
    final auth = context.read<AuthProvider>();
    final actor = auth.user!;
    final returnedTotal = toReturn.fold(0.0, (s, i) => s + i.lineTotal);

    final approval = await _requestApproval(
      '${isExchange ? 'Exchange' : 'Refund'} ${toReturn.length} item(s) '
      'from ${sale.receiptNo} (${settings.money(returnedTotal)}) '
      'restores the items to stock. A manager must approve it.',
    );
    if (!mounted) return;
    if (approval == null && !actor.isAdmin && !actor.canRefund) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Cancelled — manager approval required')));
      return;
    }

    final actionLabel = isExchange ? 'Exchange' : 'Refund';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Row(children: [
          Icon(
            isExchange ? Icons.swap_horiz_rounded : Icons.undo_rounded,
            size: 21,
            color: AppColors.danger,
          ),
          const SizedBox(width: AppSpace.s3),
          Text('$actionLabel ${toReturn.length} item(s)?'),
        ]),
        content: SizedBox(
          width: 380,
          child: Text(
            isExchange
                ? 'The selected items will be returned to stock. '
                    'The cart will open so you can scan the replacement items.'
                : 'The selected items will be returned to stock and '
                    'the sale ${toReturn.length == _items.length ? 'marked as refunded' : 'partially refunded'}. '
                    'This cannot be undone.',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: Text(actionLabel),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final sales = context.read<SalesProvider>();
    final catalog = context.read<CatalogProvider>();
    final cart = context.read<CartProvider>();
    final nav = context.read<NavProvider>();

    final refundedTotal = await sales.refundItems(
      sale: sale,
      items: toReturn,
      actorId: actor.id!,
      isExchange: isExchange,
    );
    await catalog.reload();
    await _load();

    final details = '${sale.receiptNo} · ${settings.money(refundedTotal)} · '
        '${toReturn.length} item(s)'
        '${approval != null ? ' · approved by ${approval.userName} via ${approval.methodLabel}' : ''}';
    await Audit.add(
      isExchange ? 'exchange_return' : 'partial_refund',
      details,
      userId: actor.id,
      userName: actor.name,
    );

    if (!mounted) return;
    if (isExchange) {
      cart.startExchange(sale.receiptNo);
      nav.goTo(NavId.pos);
      Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(
        content: Text('${toReturn.length} item(s) returned — scan replacement items'),
        behavior: SnackBarBehavior.floating,
      ));
    } else {
      messenger.showSnackBar(SnackBar(
        content: Text('${toReturn.length} item(s) refunded, stock restored'),
        behavior: SnackBarBehavior.floating,
      ));
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
    } catch (e, s) {
      AppLog.e('receipt/reprint', e, s);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
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

    final canAct = !sale.isRefunded && sale.status != 'refunded';
    final selectedTotal =
        _selectedItems.fold(0.0, (s, i) => s + i.lineTotal);

    return Scaffold(
      appBar: AppBar(
        title: Text(sale.receiptNo),
        actions: [
          if (canAct) ...[
            IconButton(
              tooltip: _selectMode ? 'Cancel selection' : 'Select items to return',
              icon: Icon(_selectMode
                  ? Icons.close_rounded
                  : Icons.checklist_rounded),
              onPressed: _toggleSelectMode,
            ),
            if (_selectMode) ...[
              IconButton(
                tooltip: 'Exchange selected items',
                icon: const Icon(Icons.swap_horiz_rounded),
                onPressed: () => _doRefund(isExchange: true),
              ),
              IconButton(
                tooltip: 'Refund selected items',
                icon: const Icon(Icons.undo_rounded),
                onPressed: () => _doRefund(isExchange: false),
              ),
            ] else
              IconButton(
                tooltip: (auth.user?.isAdmin ?? false)
                    ? 'Refund'
                    : 'Refund (manager approval required)',
                icon: const Icon(Icons.undo_rounded),
                onPressed: () => _doRefund(isExchange: false),
              ),
          ],
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
                if (_selectMode)
                  Container(
                    margin: const EdgeInsets.only(bottom: AppSpace.s3),
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.s4, vertical: AppSpace.s3),
                    decoration: BoxDecoration(
                      color: AppColors.primarySoft,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      border: Border.all(
                          color: AppColors.primary.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline_rounded,
                            size: 17, color: AppColors.primary),
                        const SizedBox(width: AppSpace.s2),
                        Expanded(
                          child: Text(
                            _selected.isEmpty
                                ? 'Tap items below to select them for return or exchange'
                                : '${_selected.length} item(s) selected · ${settings.money(selectedTotal)} to return',
                            style: TextStyle(
                                fontFamily: 'Carlito',
                                fontSize: 13,
                                color: AppColors.primaryDark),
                          ),
                        ),
                        TextButton(
                          onPressed: () => setState(() {
                            if (_selected.length == _items.length) {
                              _selected.clear();
                            } else {
                              _selected
                                ..clear()
                                ..addAll(_items.map((i) => i.id));
                            }
                          }),
                          style: TextButton.styleFrom(
                              foregroundColor: AppColors.primary,
                              visualDensity: VisualDensity.compact),
                          child: Text(
                            _selected.length == _items.length
                                ? 'None'
                                : 'All',
                          ),
                        ),
                      ],
                    ),
                  ),

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
                            color: sale.isRefunded
                                ? AppColors.dangerSoft
                                : sale.status == 'partial_refund'
                                    ? AppColors.warningSoft
                                    : AppColors.primarySoft,
                            borderRadius: BorderRadius.circular(AppRadius.md),
                          ),
                          child: Icon(
                            sale.isRefunded || sale.status == 'partial_refund'
                                ? Icons.undo_rounded
                                : Icons.receipt_long_rounded,
                            size: 23,
                            color: sale.isRefunded
                                ? AppColors.danger
                                : sale.status == 'partial_refund'
                                    ? AppColors.warning
                                    : AppColors.primary,
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
                                          fontSize: 15,
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.ink)),
                                  if (sale.isRefunded) ...[
                                    const SizedBox(width: AppSpace.s2),
                                    StatusPill.build(context,
                                        label: 'REFUNDED',
                                        foreground: AppColors.danger,
                                        background: AppColors.dangerSoft),
                                  ] else if (sale.status == 'partial_refund') ...[
                                    const SizedBox(width: AppSpace.s2),
                                    StatusPill.build(context,
                                        label: 'PART. REFUND',
                                        foreground: AppColors.warning,
                                        background: AppColors.warningSoft),
                                  ],
                                ],
                              ),
                              const SizedBox(height: AppSpace.s1),
                              Text('$when · Cashier: ${sale.cashierName ?? '-'}'
                                  ' · Customer: ${sale.customerName ?? 'Walk-in'}',
                                  style: TextStyle(
                                      fontFamily: 'Carlito', fontSize: 12, color: AppColors.muted)),
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
                                    fontSize: 13,
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
                        InkWell(
                          onTap: _selectMode
                              ? () => setState(() {
                                    if (_selected.contains(it.id)) {
                                      _selected.remove(it.id);
                                    } else {
                                      _selected.add(it.id);
                                    }
                                  })
                              : null,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: AppSpace.s2),
                            child: Row(
                              children: [
                                if (_selectMode)
                                  Checkbox(
                                    value: _selected.contains(it.id),
                                    activeColor: AppColors.primary,
                                    onChanged: (_) => setState(() {
                                      if (_selected.contains(it.id)) {
                                        _selected.remove(it.id);
                                      } else {
                                        _selected.add(it.id);
                                      }
                                    }),
                                  ),
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
                                              fontFamily: 'Carlito', fontSize: 12, color: AppColors.muted)),
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
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.4,
                                    color: AppColors.muted)),
                            const Spacer(),
                            Text(settings.money(sale.total),
                                style: TextStyle(
                                    fontFamily: 'Carlito',
                                    fontSize: 18,
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
                if (canAct && _selectMode) ...[
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.warning),
                          onPressed: () => _doRefund(isExchange: true),
                          icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                          label: const Text('Exchange'),
                        ),
                      ),
                      const SizedBox(width: AppSpace.s3),
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                              backgroundColor: AppColors.danger),
                          onPressed: () => _doRefund(isExchange: false),
                          icon: const Icon(Icons.undo_rounded, size: 18),
                          label: const Text('Refund'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.s3),
                ],
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
