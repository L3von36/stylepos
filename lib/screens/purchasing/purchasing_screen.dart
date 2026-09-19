import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/database.dart';
import '../../models/purchase_order.dart';
import '../../models/supplier.dart';
import '../../services/audit.dart';
import '../../state/auth.dart';
import '../../state/catalog.dart';
import '../../state/purchasing.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';

/// Purchasing hub (manager only): the supplier database and purchase
/// orders with goods-received tracking. Receiving stock updates variant
/// quantities and cost prices, so margins always reflect the latest buy.
class PurchasingScreen extends StatefulWidget {
  const PurchasingScreen({super.key});

  @override
  State<PurchasingScreen> createState() => _PurchasingScreenState();
}

class _PurchasingScreenState extends State<PurchasingScreen> {
  int _tab = 0; // 0 = suppliers, 1 = purchase orders
  String _statusFilter = 'open';

  @override
  void initState() {
    super.initState();
    final purchasing = context.read<PurchasingProvider>();
    Future.microtask(() => purchasing.reloadAll());
  }

  Future<void> _addOrEditSupplier([Supplier? existing]) async {
    final purchasing = context.read<PurchasingProvider>();
    await showDialog<void>(
      context: context,
      builder: (_) => _SupplierDialog(existing: existing),
    );
    if (mounted) purchasing.reloadAll();
  }

  Future<void> _deleteSupplier(Supplier s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete supplier?'),
        content: Text(
            '${s.name} will be removed from the supplier list. Past purchase '
            'orders keep their records.',
            style: TextStyle(fontFamily: 'Carlito', fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final me = context.read<AuthProvider>().user;
    await context.read<PurchasingProvider>().deleteSupplier(s);
    await Audit.add('supplier_deleted', s.name,
        userId: me?.id, userName: me?.name);
  }

  Future<void> _newPO([Supplier? supplier]) async {
    final p = context.read<PurchasingProvider>();
    await p.reloadSuppliers();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PODialog(suppliers: p.suppliers, presetSupplier: supplier),
    );
    p.reloadAll();
  }

  Future<void> _openPO(
      ({PurchaseOrder po, String? supplierName, double total}) entry) async {
    final purchasing = context.read<PurchasingProvider>();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PODetailDialog(
          poId: entry.po.id!, supplierName: entry.supplierName),
    );
    if (mounted) purchasing.reloadAll();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<PurchasingProvider>();
    final settings = context.watch<AppSettings>();
    final money = settings.money;

    final visibleOrders = p.orders.where((e) {
      switch (_statusFilter) {
        case 'open':
          return e.po.isOpen;
        case 'ordered':
          return e.po.status == 'ordered';
        case 'received':
          return e.po.isReceived;
        case 'cancelled':
          return e.po.isCancelled;
      }
      return true;
    }).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Purchasing')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _tab == 0
            ? () => _addOrEditSupplier()
            : () => _newPO(),
        icon: Icon(_tab == 0
            ? Icons.group_add_rounded
            : Icons.add_shopping_cart_rounded),
        label: Text(_tab == 0 ? 'Add supplier' : 'New order'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.s4, AppSpace.s3, AppSpace.s4, 0),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(
                    value: 0,
                    icon: Icon(Icons.storefront_outlined, size: 17),
                    label: Text('Suppliers')),
                ButtonSegment(
                    value: 1,
                    icon: Icon(Icons.local_shipping_outlined, size: 17),
                    label: Text('Purchase orders')),
              ],
              selected: {_tab},
              onSelectionChanged: (s) => setState(() => _tab = s.first),
            ),
          ),
          if (_tab == 1)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.s4),
              child: Row(children: [
                for (final f in const [
                  ('open', 'Open'),
                  ('ordered', 'Ordered'),
                  ('received', 'Received'),
                  ('cancelled', 'Cancelled'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpace.s2, top: AppSpace.s3),
                    child: ChoiceChip(
                      label: Text(f.$2),
                      selected: _statusFilter == f.$1,
                      onSelected: (_) => setState(() => _statusFilter = f.$1),
                    ),
                  ),
              ]),
            ),
          Expanded(
            child: _tab == 0
                ? _SuppliersTab(
                    suppliers: p.suppliers,
                    orders: p.orders,
                    onEdit: _addOrEditSupplier,
                    onDelete: _deleteSupplier,
                    onNewPO: _newPO,
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(AppSpace.s4),
                    itemCount: visibleOrders.length,
                    separatorBuilder: (_, _) => const SizedBox(height: AppSpace.s2),
                    itemBuilder: (context, i) {
                      final e = visibleOrders[i];
                      return _OrderTile(
                        entry: e,
                        money: money,
                        onTap: () => _openPO(e),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- tabs

class _SuppliersTab extends StatelessWidget {
  final List<Supplier> suppliers;
  final List<({PurchaseOrder po, String? supplierName, double total})> orders;
  final ValueChanged<Supplier?> onEdit;
  final ValueChanged<Supplier> onDelete;
  final ValueChanged<Supplier> onNewPO;

  const _SuppliersTab({
    required this.suppliers,
    required this.orders,
    required this.onEdit,
    required this.onDelete,
    required this.onNewPO,
  });

  @override
  Widget build(BuildContext context) {
    if (suppliers.isEmpty) {
      return const EmptyState(
        icon: Icons.storefront_outlined,
        title: 'No suppliers yet',
        message: 'Add the shops and vendors you buy stock from, then raise '
            'purchase orders against them.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(AppSpace.s4),
      itemCount: suppliers.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpace.s2),
      itemBuilder: (context, i) {
        final s = suppliers[i];
        final openCount =
            orders.where((e) => e.po.supplierId == s.id && e.po.isOpen).length;
        return Card(
          child: ListTile(
            onTap: () => onEdit(s),
            leading: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: AppColors.primarySoft,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Icon(Icons.storefront_outlined,
                  size: 21, color: AppColors.primary),
            ),
            title: Text(s.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: 'Carlito',
                    fontSize: 14,
                    fontWeight: FontWeight.w700)),
            subtitle: Text(
              [
                if (s.contact != null) s.contact!,
                if (openCount > 0) '$openCount open order${openCount == 1 ? '' : 's'}',
                if (s.notes?.isNotEmpty ?? false) s.notes!,
              ].join(' · '),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: 'Carlito', fontSize: 12),
            ),
            trailing: PopupMenuButton<String>(
              icon: Icon(Icons.more_vert_rounded, size: 20, color: AppColors.muted),
              onSelected: (v) {
                if (v == 'edit') onEdit(s);
                if (v == 'delete') onDelete(s);
                if (v == 'po') onNewPO(s);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'po', child: Text('New purchase order')),
                PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _OrderTile extends StatelessWidget {
  final ({PurchaseOrder po, String? supplierName, double total}) entry;
  final String Function(double) money;
  final VoidCallback onTap;

  const _OrderTile({required this.entry, required this.money, required this.onTap});

  static final Map<String, (Color, Color)> _statusColors = {
    'draft': (AppColors.muted, AppColors.surfaceTint),
    'ordered': (AppColors.primaryDark, AppColors.primarySoft),
    'received': (AppColors.success, AppColors.successSoft),
    'cancelled': (AppColors.danger, AppColors.dangerSoft),
  };

  @override
  Widget build(BuildContext context) {
    final po = entry.po;
    final (fg, bg) = _statusColors[po.status] ??
        (AppColors.muted, AppColors.surfaceTint);
    final date = po.orderDate ?? po.createdAt;
    final created = DateTime.fromMillisecondsSinceEpoch(date * 1000);
    return Card(
      child: ListTile(
        onTap: onTap,
        title: Row(children: [
          Expanded(
            child: Text(
              entry.supplierName ?? 'No supplier',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontFamily: 'Carlito', fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: AppSpace.s2),
          StatusPill.build(context,
              label: po.status[0].toUpperCase() + po.status.substring(1),
              foreground: fg,
              background: bg),
        ]),
        subtitle: Text(
          '${created.year}-${created.month.toString().padLeft(2, '0')}-${created.day.toString().padLeft(2, '0')}'
          '${po.isReceived && po.receivedDate != null ? ' · received' : ''}',
          style: TextStyle(fontFamily: 'Carlito', fontSize: 12),
        ),
        trailing: Text(money(entry.total),
            style: TextStyle(
                fontFamily: 'Carlito',
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.ink)),
      ),
    );
  }
}

// ---------------------------------------------------------------- dialogs

class _SupplierDialog extends StatefulWidget {
  final Supplier? existing;
  const _SupplierDialog({this.existing});
  @override
  State<_SupplierDialog> createState() => _SupplierDialogState();
}

class _SupplierDialogState extends State<_SupplierDialog> {
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _email;
  late final TextEditingController _address;
  late final TextEditingController _notes;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _phone = TextEditingController(text: widget.existing?.phone ?? '');
    _email = TextEditingController(text: widget.existing?.email ?? '');
    _address = TextEditingController(text: widget.existing?.address ?? '');
    _notes = TextEditingController(text: widget.existing?.notes ?? '');
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _email, _address, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final me = context.read<AuthProvider>().user;
    final p = context.read<PurchasingProvider>();
    final err = await p.saveSupplier(Supplier(
      id: widget.existing?.id,
      name: _name.text,
      phone: _phone.text.trim(),
      email: _email.text.trim(),
      address: _address.text.trim(),
      notes: _notes.text.trim(),
      createdAt: widget.existing?.createdAt ??
          DateTime.now().millisecondsSinceEpoch ~/ 1000,
    ));
    if (err != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(err), behavior: SnackBarBehavior.floating));
      }
      return;
    }
    if (widget.existing == null) {
      await Audit.add('supplier_created', _name.text.trim(),
          userId: me?.id, userName: me?.name);
    } else {
      await Audit.add('supplier_updated', _name.text.trim(),
          userId: me?.id, userName: me?.name);
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add supplier' : 'Edit supplier'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: 'Supplier name *',
                  prefixIcon: Icon(Icons.storefront_outlined, size: 20)),
            ),
            const SizedBox(height: AppSpace.s3),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                      labelText: 'Phone', prefixIcon: Icon(Icons.call_outlined, size: 19)),
                ),
              ),
              const SizedBox(width: AppSpace.s3),
              Expanded(
                child: TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.alternate_email_rounded, size: 19)),
                ),
              ),
            ]),
            const SizedBox(height: AppSpace.s3),
            TextField(
              controller: _address,
              decoration: const InputDecoration(
                  labelText: 'Address',
                  prefixIcon: Icon(Icons.location_on_outlined, size: 19)),
            ),
            const SizedBox(height: AppSpace.s3),
            TextField(
              controller: _notes,
              decoration: const InputDecoration(
                  labelText: 'Notes (payment terms, contact person…)',
                  prefixIcon: Icon(Icons.notes_rounded, size: 19)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

/// Create a draft purchase order: supplier + lines.
class _PODialog extends StatefulWidget {
  final List<Supplier> suppliers;
  final Supplier? presetSupplier;
  const _PODialog({required this.suppliers, this.presetSupplier});
  @override
  State<_PODialog> createState() => _PODialogState();
}

class _PODialogState extends State<_PODialog> {
  int? _supplierId;
  final _notes = TextEditingController();
  final List<_LineInput> _lines = [];

  bool get _canSave =>
      _lines.isNotEmpty &&
      _lines.every((l) =>
          l.nameCtrl.text.trim().isNotEmpty &&
          (int.tryParse(l.qtyCtrl.text) ?? 0) > 0);

  @override
  void initState() {
    super.initState();
    _supplierId = widget.presetSupplier?.id ??
        (widget.suppliers.length == 1 ? widget.suppliers.first.id : null);
  }

  @override
  void dispose() {
    _notes.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  void _addLine() =>
      setState(() => _lines.add(_LineInput()..onChange = () => setState(() {})));

  Future<void> _addVariantLine() async {
    final catalog = context.read<CatalogProvider>();
    final choices = <({int variantId, String label, double price})>[
      for (final prod in catalog.products)
        for (final v in prod.variants)
          (
            variantId: v.id!,
            label: '${prod.name}'
                '${v.descriptor.isEmpty ? '' : ' · ${v.descriptor}'}',
            price: v.price,
          )
    ];
    if (!mounted) return;
    final picked =
        await showDialog<({int variantId, String label, double price})>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Pick a product'),
        content: SizedBox(
          width: 360,
          height: 380,
          child: choices.isEmpty
              ? const Center(
                  child: Text(
                      'No products yet — add stock with a free-text line.',
                      style: TextStyle(fontFamily: 'Carlito', fontSize: 13)))
              : ListView.builder(
                  itemCount: choices.length,
                  itemBuilder: (_, i) => ListTile(
                    dense: true,
                    title: Text(choices[i].label,
                        style: TextStyle(
                            fontFamily: 'Carlito', fontSize: 13)),
                    onTap: () => Navigator.pop(c, choices[i]),
                  ),
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        ],
      ),
    );
    if (picked == null) return;
    setState(() => _lines.add(_LineInput(
          variant: picked,
          nameCtrlText: picked.label,
        )..onChange = () => setState(() {})));
  }

  Future<void> _save({bool sendNow = false}) async {
    if (!_canSave) return;
    final me = context.read<AuthProvider>().user;
    final p = context.read<PurchasingProvider>();
    final lines = [
      for (final l in _lines)
        PurchaseOrderItem(
          poId: 0,
          variantId: l.variant?.variantId,
          productName: l.nameCtrl.text.trim(),
          sku: l.skuCtrl.text.trim(),
          qtyOrdered: int.tryParse(l.qtyCtrl.text) ?? 0,
          unitCost: double.tryParse(l.costCtrl.text) ?? 0,
        )
    ];
    final id = await p.saveDraft(
        supplierId: _supplierId, notes: _notes.text.trim(), lines: lines);
    if (id != null && sendNow) {
      await p.markOrdered(id);
      await Audit.add('purchase_ordered', 'PO #$id · ${lines.length} line(s)',
          userId: me?.id, userName: me?.name);
    } else if (id != null) {
      await Audit.add('purchase_draft', 'PO #$id · ${lines.length} line(s)',
          userId: me?.id, userName: me?.name);
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      title: const Text('New purchase order'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<int>(
              initialValue: _supplierId,
              decoration: InputDecoration(
                labelText: 'Supplier',
                prefixIcon: const Icon(Icons.storefront_outlined, size: 20),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.person_add_alt_rounded, size: 18),
                  tooltip: 'New supplier',
                  onPressed: () =>
                      showDialog<void>(context: context,
                          builder: (_) => const _SupplierDialog()),
                ),
              ),
              items: [
                for (final s in widget.suppliers)
                  DropdownMenuItem(value: s.id, child: Text(s.name)),
              ],
              onChanged: (v) => setState(() => _supplierId = v),
            ),
            const SizedBox(height: AppSpace.s3),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: _lines.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(AppSpace.s3),
                      child: Text(
                          'Add the items you are ordering — pick them from the '
                          'catalog or type free-text lines for new stock.',
                          style: TextStyle(fontFamily: 'Carlito', fontSize: 12)),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: _lines.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: AppSpace.s2),
                      itemBuilder: (context, i) => _buildLine(_lines[i], i),
                    ),
            ),
            const SizedBox(height: AppSpace.s2),
            Row(children: [
              OutlinedButton.icon(
                onPressed: _addVariantLine,
                icon: const Icon(Icons.inventory_2_outlined, size: 17),
                label: const Text('From catalog'),
              ),
              const SizedBox(width: AppSpace.s2),
              OutlinedButton.icon(
                onPressed: _addLine,
                icon: const Icon(Icons.edit_note_rounded, size: 17),
                label: const Text('Free-text line'),
              ),
              const Spacer(),
              Text('Total: ',
                  style: TextStyle(
                      fontFamily: 'Carlito', fontSize: 13, color: AppColors.muted)),
              Text(
                _lines
                    .fold<double>(
                        0,
                        (t, l) =>
                            t +
                            (double.tryParse(l.costCtrl.text) ?? 0) *
                                (int.tryParse(l.qtyCtrl.text) ?? 0))
                    .toStringAsFixed(2),
                style: TextStyle(
                    fontFamily: 'Carlito',
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.ink),
              ),
            ]),
            const SizedBox(height: AppSpace.s3),
            TextField(
              controller: _notes,
              decoration: const InputDecoration(
                  labelText: 'Notes (delivery terms…)',
                  prefixIcon: Icon(Icons.notes_rounded, size: 19)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        OutlinedButton(
          onPressed: _canSave ? () => _save() : null,
          child: const Text('Save draft'),
        ),
        FilledButton.icon(
          onPressed: _canSave ? () => _save(sendNow: true) : null,
          icon: const Icon(Icons.send_rounded, size: 16),
          label: const Text('Save & mark ordered'),
        ),
      ],
    );
  }

  Widget _buildLine(_LineInput l, int index) {
    return Container(
      padding: const EdgeInsets.all(AppSpace.s2 + 2),
      decoration: BoxDecoration(
        color: AppColors.surfaceTint,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Column(children: [
        Row(children: [
          Expanded(
            child: TextField(
              controller: l.nameCtrl,
              enabled: l.variant == null,
              decoration: InputDecoration(
                  labelText: l.variant != null
                      ? 'Item (from catalog)'
                      : 'Item name *',
                  isDense: true),
            ),
          ),
          const SizedBox(width: AppSpace.s2),
          SizedBox(
            width: 64,
            child: TextField(
              controller: l.qtyCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                  labelText: 'Qty *', isDense: true),
            ),
          ),
          const SizedBox(width: AppSpace.s2),
          SizedBox(
            width: 92,
            child: TextField(
              controller: l.costCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'Unit cost', isDense: true),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 17),
            color: AppColors.muted,
            onPressed: () => setState(() => _lines.removeAt(index)),
          ),
        ]),
        if (l.variant == null)
          TextField(
            controller: l.skuCtrl,
            decoration: const InputDecoration(
                labelText: 'SKU / code (optional)', isDense: true),
          ),
      ]),
    );
  }
}

class _LineInput {
  final ({int variantId, String label, double price})? variant;
  final TextEditingController nameCtrl;
  final TextEditingController skuCtrl;
  final TextEditingController qtyCtrl;
  final TextEditingController costCtrl;

  /// Called on every edit so the dialog can re-evaluate [save state]
  /// (the Save button and running total live-update).
  VoidCallback? onChange;

  _LineInput({this.variant, String? nameCtrlText})
      : nameCtrl = TextEditingController(text: nameCtrlText),
        skuCtrl = TextEditingController(),
        qtyCtrl = TextEditingController(),
        costCtrl = TextEditingController() {
    for (final c in [nameCtrl, skuCtrl, qtyCtrl, costCtrl]) {
      c.addListener(() => onChange?.call());
    }
  }

  void dispose() {
    nameCtrl.dispose();
    skuCtrl.dispose();
    qtyCtrl.dispose();
    costCtrl.dispose();
  }
}

/// PO detail: header, lines with received progress, receive / order /
/// cancel / delete actions.
class _PODetailDialog extends StatefulWidget {
  final int poId;
  final String? supplierName;
  const _PODetailDialog({required this.poId, this.supplierName});
  @override
  State<_PODetailDialog> createState() => _PODetailDialogState();
}

class _PODetailDialogState extends State<_PODetailDialog> {
  late Future<({PurchaseOrder po, List<PurchaseOrderItem> items})> _load;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _load = _fetch();
  }

  Future<({PurchaseOrder po, List<PurchaseOrderItem> items})> _fetch() async {
    final p = context.read<PurchasingProvider>();
    final db = await DB.instance();
    final rows = await db
        .query('purchase_orders', where: 'id = ?', whereArgs: [widget.poId]);
    final items = await p.itemsFor(widget.poId);
    return (
      po: rows.isEmpty
          ? const PurchaseOrder(createdAt: 0)
          : PurchaseOrder.fromMap(rows.first),
      items: items,
    );
  }

  Future<void> _receive(
      PurchaseOrder po, List<PurchaseOrderItem> items) async {
    final open = items.where((l) => !l.fullyReceived).toList();
    if (open.isEmpty) return;
    final result = await showDialog<Map<int, (int, double)>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ReceiveDialog(lines: open),
    );
    if (result == null || result.isEmpty) return;
    if (!mounted) return;
    final me = context.read<AuthProvider>().user;
    final p = context.read<PurchasingProvider>();
    await p.receiveGoods(
      po.id!,
      {for (final e in result.entries) e.key: e.value.$1},
      {for (final e in result.entries) e.key: e.value.$2},
      actorUserId: me?.id,
    );
    await Audit.add('goods_received',
        'PO #${po.id} · ${result.length} line(s) received',
        userId: me?.id, userName: me?.name);
    // Stock + cost prices changed — refresh the catalog so POS/Products
    // show the new quantities immediately.
    if (mounted) {
      await context.read<CatalogProvider>().reload();
      setState(() => _reload());
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final money = settings.money;
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      title: Text('Purchase order · ${widget.supplierName ?? 'no supplier'}'),
      content: SizedBox(
        width: 560,
        child: FutureBuilder<
                ({PurchaseOrder po, List<PurchaseOrderItem> items})>(
            future: _load,
            builder: (context, snap) {
              if (!snap.hasData) {
                return const SizedBox(
                    height: 120,
                    child: Center(child: CircularProgressIndicator()));
              }
              final po = snap.data!.po;
              final items = snap.data!.items;
              final total = items.fold<double>(0, (t, l) => t + l.lineTotal);
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    StatusPill.build(context,
                        label: po.status,
                        foreground: po.isReceived
                            ? AppColors.success
                            : po.isCancelled
                                ? AppColors.danger
                                : AppColors.primaryDark,
                        background: po.isReceived
                            ? AppColors.successSoft
                            : po.isCancelled
                                ? AppColors.dangerSoft
                                : AppColors.primarySoft),
                    const Spacer(),
                    Text('Total ${money(total)}',
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppColors.ink)),
                  ]),
                  const SizedBox(height: AppSpace.s3),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: items.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: AppSpace.s1),
                      itemBuilder: (context, i) {
                        final l = items[i];
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppSpace.s3, vertical: AppSpace.s2),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceTint,
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                          ),
                          child: Row(children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    l.productName,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontFamily: 'Carlito',
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700),
                                  ),
                                  Text(
                                    '${l.qtyReceived}/${l.qtyOrdered} received'
                                    '${l.sku.isNotEmpty ? ' · ${l.sku}' : ''}'
                                    ' · cost ${money(l.unitCost)}',
                                    style: TextStyle(
                                        fontFamily: 'Carlito',
                                        fontSize: 12,
                                        color: AppColors.muted),
                                  ),
                                ],
                              ),
                            ),
                            if (l.fullyReceived)
                              Icon(Icons.check_circle_rounded,
                                  size: 19, color: AppColors.success),
                          ]),
                        );
                      },
                    ),
                  ),
                  if (po.notes?.isNotEmpty ?? false) ...[
                    const SizedBox(height: AppSpace.s2),
                    Text(po.notes!,
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 12,
                            color: AppColors.muted)),
                  ],
                ],
              );
            }),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ..._actions(),
      ],
    );
  }

  List<Widget> _actions() {
    return [
      FutureBuilder<({PurchaseOrder po, List<PurchaseOrderItem> items})>(
          future: _load,
          builder: (context, snap) {
            if (!snap.hasData) return const SizedBox.shrink();
            final po = snap.data!.po;
            final items = snap.data!.items;
            final hasOpen = items.any((l) => !l.fullyReceived);
            final p = context.read<PurchasingProvider>();
            return Row(mainAxisSize: MainAxisSize.min, children: [
              if (po.isDraft)
                OutlinedButton(
                  onPressed: () async {
                    await p.deleteDraft(po.id!);
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('Delete'),
                ),
              if (po.isDraft)
                FilledButton.icon(
                  onPressed: () async {
                    final me = context.read<AuthProvider>().user;
                    await p.markOrdered(po.id!);
                    await Audit.add('purchase_ordered',
                        'PO #${po.id} marked ordered',
                        userId: me?.id, userName: me?.name);
                    if (context.mounted) setState(() => _reload());
                  },
                  icon: const Icon(Icons.send_rounded, size: 15),
                  label: const Text('Mark ordered'),
                ),
              if (po.isOrdered && hasOpen)
                FilledButton.icon(
                  onPressed: () => _receive(po, items),
                  icon: const Icon(Icons.archive_outlined, size: 15),
                  label: const Text('Receive goods'),
                ),
              if (po.isOrdered)
                OutlinedButton(
                  onPressed: () async {
                    await p.cancelOrder(po.id!);
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('Cancel order'),
                ),
            ]);
          }),
    ];
  }
}

/// Per-line receive sheet: qty to receive (capped at outstanding) + cost.
class _ReceiveDialog extends StatefulWidget {
  final List<PurchaseOrderItem> lines;
  const _ReceiveDialog({required this.lines});
  @override
  State<_ReceiveDialog> createState() => _ReceiveDialogState();
}

class _ReceiveDialogState extends State<_ReceiveDialog> {
  late final Map<int, TextEditingController> _qty;
  late final Map<int, TextEditingController> _cost;

  @override
  void initState() {
    super.initState();
    _qty = {
      for (final l in widget.lines)
        l.id!: TextEditingController(text: '${l.qtyOutstanding}')
    };
    _cost = {
      for (final l in widget.lines)
        l.id!: TextEditingController(text: l.unitCost.toStringAsFixed(2))
    };
  }

  @override
  void dispose() {
    for (final c in _qty.values) {
      c.dispose();
    }
    for (final c in _cost.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Receive goods'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
                'Confirm what arrived. Stock and cost prices update instantly.',
                style: TextStyle(fontFamily: 'Carlito', fontSize: 12)),
            const SizedBox(height: AppSpace.s3),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: widget.lines.length,
                separatorBuilder: (_, _) => const SizedBox(height: AppSpace.s2),
                itemBuilder: (context, i) {
                  final l = widget.lines[i];
                  return Container(
                    padding: const EdgeInsets.all(AppSpace.s2 + 2),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceTint,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Column(children: [
                      Row(children: [
                        Expanded(
                          child: Text(l.productName,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontFamily: 'Carlito',
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700)),
                        ),
                        Text('${l.qtyReceived}/${l.qtyOrdered} in',
                            style: TextStyle(
                                fontFamily: 'Carlito',
                                fontSize: 12,
                                color: AppColors.muted)),
                      ]),
                      Row(children: [
                        Expanded(
                          child: TextField(
                            controller: _qty[l.id!],
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly
                            ],
                            decoration: const InputDecoration(
                                labelText: 'Receive qty', isDense: true),
                          ),
                        ),
                        const SizedBox(width: AppSpace.s2),
                        Expanded(
                          child: TextField(
                            controller: _cost[l.id!],
                            keyboardType:
                                const TextInputType.numberWithOptions(
                                    decimal: true),
                            decoration: const InputDecoration(
                                labelText: 'Unit cost', isDense: true),
                          ),
                        ),
                      ]),
                    ]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton.icon(
          onPressed: () {
            final out = <int, (int, double)>{};
            for (final e in _qty.entries) {
              final qty = int.tryParse(e.value.text) ?? 0;
              if (qty > 0) {
                out[e.key] = (qty, double.tryParse(_cost[e.key]!.text) ?? 0);
              }
            }
            Navigator.pop(context, out);
          },
          icon: const Icon(Icons.check_rounded, size: 16),
          label: const Text('Receive'),
        ),
      ],
    );
  }
}
