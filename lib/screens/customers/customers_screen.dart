import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/customer.dart';
import '../../models/sale.dart';
import '../../state/cart.dart';
import '../../state/customers.dart';
import '../../state/nav.dart';
import '../../state/sales.dart';
import '../../state/settings.dart';
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

  @override
  Widget build(BuildContext context) {
    final customers = context.watch<CustomersProvider>();
    final list = customers.search(_query);

    if (_openCustomerId != null) {
      final c = customers.customers.where((x) => x.id == _openCustomerId).firstOrNull;
      if (c != null) return _CustomerDetail(customer: c, onBack: () => setState(() => _openCustomerId = null));
    }

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: 'Search customers by name, phone or email…',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _search.clear();
                              setState(() => _query = '');
                            },
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: () => _openEdit(),
                icon: const Icon(Icons.person_add_alt),
                label: const Text('New customer'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.people_outline, size: 48, color: Colors.grey.shade400),
                        const SizedBox(height: 8),
                        const Text('No customers yet'),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, i) {
                      final c = list[i];
                      return Card(
                        child: ListTile(
                          onTap: () => setState(() => _openCustomerId = c.id),
                          leading: CircleAvatar(
                            backgroundColor:
                                Theme.of(context).colorScheme.primaryContainer,
                            child: Text(
                              c.name.isEmpty ? '?' : c.name[0].toUpperCase(),
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.primary,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                          title: Text(c.name,
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(c.phone ?? c.email ?? '—',
                              style: const TextStyle(fontSize: 12)),
                          trailing: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .primaryContainer
                                  .withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.loyalty_outlined, size: 14),
                                const SizedBox(width: 4),
                                Text('${c.points}',
                                    style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold)),
                              ],
                            ),
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

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final customers = context.watch<CustomersProvider>();
    final theme = Theme.of(context);
    final c = customers.customers
            .where((x) => x.id == widget.customer.id)
            .firstOrNull ??
        widget.customer;

    final spent = _history == null
        ? 0.0
        : _history!.where((s) => !s.isRefunded).fold(0.0, (sum, s) => sum + s.total);

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(icon: const Icon(Icons.arrow_back), onPressed: widget.onBack),
              const SizedBox(width: 4),
              CircleAvatar(
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Text(c.name.isEmpty ? '?' : c.name[0].toUpperCase(),
                    style: TextStyle(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.name,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    Text(
                      [c.phone, c.email].whereType<String>().join(' · '),
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Edit',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () =>
                    showDialog(context: context, builder: (_) => CustomerEditDialog(customer: c)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      children: [
                        const Icon(Icons.loyalty_outlined),
                        const SizedBox(height: 4),
                        Text('${c.points}',
                            style: theme.textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.bold)),
                        const Text('Points', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      children: [
                        const Icon(Icons.shopping_bag_outlined),
                        const SizedBox(height: 4),
                        Text('${_history?.length ?? "…"}',
                            style: theme.textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.bold)),
                        const Text('Purchases', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      children: [
                        const Icon(Icons.savings_outlined),
                        const SizedBox(height: 4),
                        Text(settings.money(spent),
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold)),
                        const Text('Total spent', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.icon(
                onPressed: () {
                  context.read<CartProvider>().setCustomer(c);
                  context.read<NavProvider>().go(0); // jump to POS tab
                },
                icon: const Icon(Icons.point_of_sale, size: 18),
                label: const Text('Start sale'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final provider = context.read<CustomersProvider>();
                  final err = await provider.delete(c);
                  if (!mounted) return;
                  if (err != null) {
                    messenger.showSnackBar(SnackBar(content: Text(err)));
                  } else {
                    widget.onBack();
                  }
                },
                icon: Icon(Icons.delete_outline,
                    size: 18, color: theme.colorScheme.error),
                label: const Text('Delete'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('Purchase history', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Expanded(
            child: _history == null
                ? const Center(child: CircularProgressIndicator())
                : _history!.isEmpty
                    ? Center(
                        child: Text('No purchases yet',
                            style: TextStyle(color: Colors.grey.shade500)))
                    : ListView.builder(
                        itemCount: _history!.length,
                        itemBuilder: (context, i) {
                          final s = _history![i];
                          final dt = DateTime.fromMillisecondsSinceEpoch(s.createdAt * 1000);
                          return ListTile(
                            dense: true,
                            leading: const Icon(Icons.receipt_long_outlined, size: 20),
                            title: Text(s.receiptNo),
                            subtitle: Text(
                                '${dt.day}/${dt.month}/${dt.year} · ${s.cashierName ?? ""}'),
                            trailing: Text(settings.money(s.total),
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
