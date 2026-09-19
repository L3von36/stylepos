import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/customer.dart';
import '../../models/sale.dart';
import '../../services/csv_util.dart';
import '../../state/auth.dart';
import '../../state/cart.dart';
import '../../state/customers.dart';
import '../../state/nav.dart';
import '../../state/sales.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';
import 'customer_edit_dialog.dart';

/// Customer list with search -> detail (history, loyalty) -> quick sale.
class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  final _search = TextEditingController();
  String _query = '';
  int? _openCustomerId;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _openEdit([Customer? existing]) {
    showDialog(
      context: context,
      builder: (_) => CustomerEditDialog(customer: existing),
    );
  }

  /// Manager-only: exports the customer list (name / phone / email / 
  /// points) — the "marketing lists" export for email or SMS campaigns.
  Future<void> _exportCsv() async {
    final messenger = ScaffoldMessenger.of(context);
    final buf = StringBuffer('name,phone,email,points,notes\n');
    String s(String? v) => v ?? '';
    for (final c in context.read<CustomersProvider>().customers) {
      buf.writeln([
        c.name, s(c.phone), s(c.email), '${c.points}', s(c.notes),
      ].map(CsvUtil.escape).join(','));
    }
    final name =
        'Sami-customers-${DateTime.now().toIso8601String().substring(0, 10)}.csv';
    try {
      final res = await CsvUtil.saveFile(
          name: name, data: CsvUtil.encodeUtf8(buf.toString()));
      if (res != null) messenger.showSnackBar(SnackBar(content: Text('CSV $res')));
    } catch (_) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Export failed — please try again')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final customers = context.watch<CustomersProvider>();
    final list = customers.search(_query);

    if (_openCustomerId != null) {
      final c = customers.customers.where((x) => x.id == _openCustomerId).firstOrNull;
      if (c != null) return _CustomerDetail(customer: c, onBack: () => setState(() => _openCustomerId = null));
    }

    return Padding(
      padding: const EdgeInsets.all(AppSpace.s4),
      child: Column(
        children: [
          PageHeader(
            title: 'Customers',
            subtitle: '${customers.customers.length} registered',
            actions: [
              if ((context.watch<AuthProvider>().user?.isAdmin ?? false) &&
                  customers.customers.isNotEmpty)
                IconButton(
                  tooltip: 'Export customer list (CSV)',
                  icon: const Icon(Icons.file_download_outlined, size: 21),
                  onPressed: _exportCsv,
                ),
              FilledButton.icon(
                onPressed: () => _openEdit(),
                icon: const Icon(Icons.person_add_alt_rounded, size: 19),
                label: const Text('New customer'),
              ),
            ],
          ),
          SearchField(
            controller: _search,
            hint: 'Search customers by name, phone or email…',
            onChanged: (v) => setState(() => _query = v),
            onClear: () {
              _search.clear();
              setState(() => _query = '');
            },
          ),
          const SizedBox(height: AppSpace.s4),
          Expanded(
            child: list.isEmpty
                ? EmptyState(
                    icon: Icons.people_outline,
                    title: 'No customers yet',
                    message: 'Add customers to track loyalty points and purchases.',
                    actionLabel: 'Add customer',
                    onAction: () => _openEdit(),
                  )
                : ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final c = list[i];
                      return Card(
                        child: ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppRadius.md),
                            side: const BorderSide(color: Colors.transparent),
                          ),
                          onTap: () => setState(() => _openCustomerId = c.id),
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: AppSpace.s4, vertical: AppSpace.s1),
                          leading: InitialsAvatar(c.name),
                          title: Text(c.name),
                          subtitle: Text(c.phone ?? c.email ?? '—'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              StatusPill.build(context,
                                  label: '${c.points} pts',
                                  foreground: AppColors.primary,
                                  background: AppColors.primarySoft,
                                  icon: Icons.loyalty_outlined),
                              const SizedBox(width: AppSpace.s2),
                              Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.faint),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _CustomerDetail extends StatefulWidget {
  final Customer customer;
  final VoidCallback onBack;
  const _CustomerDetail({required this.customer, required this.onBack});

  @override
  State<_CustomerDetail> createState() => _CustomerDetailState();
}

class _CustomerDetailState extends State<_CustomerDetail> {
  List<Sale>? _history;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sales = await context.read<SalesProvider>().listSales(customerId: widget.customer.id);
    if (mounted) setState(() => _history = sales);
  }

  /// Deleting a customer removes their loyalty record — always confirm.
  Future<void> _confirmDelete(Customer c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete customer?'),
        content: const SizedBox(
            width: 380,
            child: Text(
                'Their loyalty points and contact details will be removed. Past receipts are kept.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final provider = context.read<CustomersProvider>();
    final err = await provider.delete(c);
    if (!mounted) return;
    if (err != null) {
      messenger.showSnackBar(SnackBar(content: Text(err)));
    } else {
      widget.onBack();
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final customers = context.watch<CustomersProvider>();
    final c = customers.customers
            .where((x) => x.id == widget.customer.id)
            .firstOrNull ??
        widget.customer;

    final spent = _history == null
        ? 0.0
        : _history!.where((s) => !s.isRefunded).fold(0.0, (sum, s) => sum + s.total);

    return Padding(
      padding: const EdgeInsets.all(AppSpace.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Responsive header: on phones the three actions wrap to a
          // second line instead of squeezing/overflowing the Row.
          LayoutBuilder(builder: (context, hc) {
            final narrow = hc.maxWidth < 640;
            final who = <Widget>[
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: widget.onBack,
              ),
              const SizedBox(width: AppSpace.s2),
              InitialsAvatar(c.name, size: 48),
              const SizedBox(width: AppSpace.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.name,
                        style: Theme.of(context).textTheme.titleLarge),
                    Text(
                      [c.phone, c.email].whereType<String>().join(' · '),
                      style: TextStyle(fontFamily: 'Carlito', fontSize: 12, color: AppColors.muted),
                    ),
                  ],
                ),
              ),
            ];
            if (!narrow) {
              return Row(
                children: [
                  ...who,
                  const SizedBox(width: AppSpace.s4),
                  OutlinedButton.icon(
                    onPressed: () =>
                        showDialog(context: context, builder: (_) => CustomerEditDialog(customer: c)),
                    icon: const Icon(Icons.edit_outlined, size: 17),
                    label: const Text('Edit'),
                  ),
                  const SizedBox(width: AppSpace.s2),
                  FilledButton.icon(
                    onPressed: () {
                      context.read<CartProvider>().setCustomer(c);
                      context.read<NavProvider>().goTo(NavId.pos); // jump to POS tab
                    },
                    icon: const Icon(Icons.point_of_sale_rounded, size: 18),
                    label: const Text('Start sale'),
                  ),
                  const SizedBox(width: AppSpace.s2),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
                    onPressed: () => _confirmDelete(c),
                    child: const Text('Delete'),
                  ),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: who),
                const SizedBox(height: AppSpace.s3),
                Wrap(
                  spacing: AppSpace.s2,
                  runSpacing: AppSpace.s2,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () =>
                          showDialog(context: context, builder: (_) => CustomerEditDialog(customer: c)),
                      icon: const Icon(Icons.edit_outlined, size: 17),
                      label: const Text('Edit'),
                    ),
                    FilledButton.icon(
                      onPressed: () {
                        context.read<CartProvider>().setCustomer(c);
                        context.read<NavProvider>().goTo(NavId.pos);
                      },
                      icon: const Icon(Icons.point_of_sale_rounded, size: 18),
                      label: const Text('Start sale'),
                    ),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
                      onPressed: () => _confirmDelete(c),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              ],
            );
          }),
          const SizedBox(height: AppSpace.s4),
          Row(
            children: [
              Expanded(
                child: KpiCard(
                  label: 'Loyalty points',
                  value: '${c.points}',
                  icon: Icons.loyalty_outlined,
                ),
              ),
              const SizedBox(width: AppSpace.s3),
              Expanded(
                child: KpiCard(
                  label: 'Purchases',
                  value: _history == null ? '…' : '${_history!.length}',
                  icon: Icons.shopping_bag_outlined,
                  color: AppColors.info,
                  soft: AppColors.infoSoft,
                ),
              ),
              const SizedBox(width: AppSpace.s3),
              Expanded(
                child: KpiCard(
                  label: 'Total spent',
                  value: settings.money(spent),
                  icon: Icons.savings_outlined,
                  color: AppColors.success,
                  soft: AppColors.successSoft,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.s4),
          Text('Purchase history',
              style: TextStyle(
                  fontFamily: 'Carlito',
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppColors.ink)),
          const SizedBox(height: AppSpace.s2),
          Expanded(
            child: _history == null
                ? const Center(child: CircularProgressIndicator())
                : _history!.isEmpty
                    ? EmptyState(
                        icon: Icons.receipt_long_outlined,
                        title: 'No purchases yet',
                        message: 'Sales linked to this customer will show up here.',
                      )
                    : ListView.builder(
                        itemCount: _history!.length,
                        itemBuilder: (context, i) {
                          final s = _history![i];
                          final dt = DateTime.fromMillisecondsSinceEpoch(s.createdAt * 1000);
                          return Container(
                            margin: const EdgeInsets.only(bottom: AppSpace.s2),
                            padding: const EdgeInsets.symmetric(horizontal: AppSpace.s4, vertical: AppSpace.s2 + 2),
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: BorderRadius.circular(AppRadius.md),
                              border: Border.all(color: AppColors.borderSoft),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.receipt_long_outlined, size: 19, color: AppColors.muted),
                                const SizedBox(width: AppSpace.s3),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(s.receiptNo,
                                          style: TextStyle(
                                              fontFamily: 'Carlito',
                                              fontSize: 13,
                                              fontWeight: FontWeight.w700,
                                              color: AppColors.ink)),
                                      Text(
                                          '${dt.day}/${dt.month}/${dt.year} · ${s.cashierName ?? ""}',
                                          style: TextStyle(
                                              fontFamily: 'Carlito', fontSize: 12, color: AppColors.muted)),
                                    ],
                                  ),
                                ),
                                Text(settings.money(s.total),
                                    style: TextStyle(
                                        fontFamily: 'Carlito',
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.body)),
                              ],
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
