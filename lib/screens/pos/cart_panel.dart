import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/customer.dart';
import '../../state/cart.dart';
import '../../state/customers.dart';
import '../../state/nav.dart';
import '../../state/settings.dart';
import 'checkout_dialog.dart';

/// Cart contents + totals + checkout button. Reused inside the wide layout
/// (right column) and the narrow-layout bottom sheet.
class CartPanel extends StatelessWidget {
  final bool scrollable;
  const CartPanel({super.key, required this.scrollable});

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartProvider>();
    final settings = context.watch<AppSettings>();
    final theme = Theme.of(context);

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
          child: Row(
            children: [
              const Icon(Icons.shopping_cart_outlined, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Current Sale',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              ),
              if (!cart.isEmpty)
                TextButton(
                  onPressed: () => cart.clear(),
                  child: const Text('Clear'),
                ),
            ],
          ),
        ),

        // customer selector
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _pickCustomer(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.person_outline, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      cart.customer?.name ?? 'Walk-in customer',
                      style: const TextStyle(fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 18),
                ],
              ),
            ),
          ),
        ),

        // items
        Expanded(
          child: cart.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.shopping_basket_outlined,
                          size: 44, color: Colors.grey.shade400),
                      const SizedBox(height: 8),
                      Text('Tap products to add them',
                          style: TextStyle(color: Colors.grey.shade500)),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: cart.items.length,
                  itemBuilder: (context, i) {
                    final item = cart.items[i];
                    return _CartTile(item: item);
                  },
                ),
        ),

        // discount + totals
        if (!cart.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Column(
              children: [
                Row(
                  children: [
                    Text('Discount (${settings.currencySymbol})',
                        style: const TextStyle(fontSize: 13)),
                    const Spacer(),
                    const _DiscountField(),
                  ],
                ),
                const SizedBox(height: 6),
                _totalRow(context, 'Subtotal', settings.money(cart.subtotal)),
                if (cart.discount > 0)
                  _totalRow(context, 'Discount', '- ${settings.money(cart.discount)}'),
                if (settings.taxRate > 0)
                  _totalRow(
                      context, 'Tax (${settings.taxRate.toStringAsFixed(0)}%)',
                      settings.money(cart.tax(settings.taxRate))),
                const Divider(height: 16),
                Row(
                  children: [
                    Text('TOTAL',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text(
                      settings.money(cart.total(settings.taxRate)),
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: cart.isEmpty
                ? null
                : () => showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => const CheckoutDialog(),
                    ),
            icon: const Icon(Icons.payments_outlined),
            label: const Text('Charge'),
          ),
        ),
      ],
    );

    return Card(
      clipBehavior: Clip.antiAlias,
      child: scrollable
          ? content
          : Padding(
              padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom),
              child: content,
            ),
    );
  }

  Widget _totalRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Text(label, style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
          const Spacer(),
          Text(value, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  Future<void> _pickCustomer(BuildContext context) async {
    final customers = context.read<CustomersProvider>();
    final cart = context.read<CartProvider>();
    final nav = context.read<NavProvider>();

    final selected = await showDialog<Customer>(
      context: context,
      builder: (_) => const _CustomerPickerDialog(),
    );
    if (selected == null) return;
    if (selected.id == -1) {
      // "Manage customers" sentinel -> jump to customers tab
      nav.go(3);
      return;
    }
    cart.setCustomer(selected.id == 0 ? null : selected);
    customers.reload();
  }
}

class _CartTile extends StatelessWidget {
  final CartItem item;
  const _CartTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final cart = context.watch<CartProvider>();
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.product.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                Text(
                  '${item.variant.descriptor} · ${settings.money(item.variant.price)}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.remove_circle_outline, size: 20),
            onPressed: () => cart.setQty(item.key, item.qty - 1),
          ),
          Text('${item.qty}', style: const TextStyle(fontWeight: FontWeight.bold)),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add_circle_outline, size: 20),
            onPressed: () => cart.setQty(item.key, item.qty + 1),
          ),
          SizedBox(
            width: 84,
            child: Text(
              settings.money(item.lineTotal),
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiscountField extends StatefulWidget {
  const _DiscountField();

  @override
  State<_DiscountField> createState() => _DiscountFieldState();
}

class _DiscountFieldState extends State<_DiscountField> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 110,
      child: TextField(
        controller: _c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.right,
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          prefixText: '- ',
        ),
        onChanged: (v) =>
            context.read<CartProvider>().setDiscount(double.tryParse(v) ?? 0),
      ),
    );
  }
}

class _CustomerPickerDialog extends StatefulWidget {
  const _CustomerPickerDialog();

  @override
  State<_CustomerPickerDialog> createState() => _CustomerPickerDialogState();
}

class _CustomerPickerDialogState extends State<_CustomerPickerDialog> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final customers = context.watch<CustomersProvider>();
    final list = customers.search(_q);

    return AlertDialog(
      title: const Text('Attach customer'),
      content: SizedBox(
        width: 380,
        height: 420,
        child: Column(
          children: [
            TextField(
              onChanged: (v) => setState(() => _q = v),
              decoration: const InputDecoration(
                hintText: 'Search name or phone…',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  ListTile(
                    leading: const Icon(Icons.person_off_outlined),
                    title: const Text('Walk-in customer'),
                    onTap: () => Navigator.pop(
                        context, const Customer(id: 0, name: 'Walk-in customer', createdAt: 0)),
                  ),
                  const Divider(height: 1),
                  ...list.map(
                    (c) => ListTile(
                      leading: CircleAvatar(
                        child: Text(c.name.isEmpty ? '?' : c.name[0].toUpperCase()),
                      ),
                      title: Text(c.name),
                      subtitle: Text(c.phone ?? ''),
                      trailing: Text('${c.points} pts',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                      onTap: () => Navigator.pop(context, c),
                    ),
                  ),
                ],
              ),
            ),
            TextButton.icon(
              onPressed: () => Navigator.pop(
                  context, const Customer(id: -1, name: '_manage', createdAt: 0)),
              icon: const Icon(Icons.people_outline, size: 18),
              label: const Text('Manage customers…'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      ],
    );
  }
}
