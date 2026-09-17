import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/customer.dart';
import '../../state/cart.dart';
import '../../state/customers.dart';
import '../../state/nav.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';
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
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
          child: Row(
            children: [
              const Icon(Icons.shopping_cart_outlined, size: 19, color: AppColors.primary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Current Sale',
                    style: TextStyle(
                        fontFamily: 'Carlito',
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink)),
              ),
              if (!cart.isEmpty)
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: AppColors.danger, visualDensity: VisualDensity.compact),
                  onPressed: () => cart.clear(),
                  child: const Text('Clear'),
                ),
            ],
          ),
        ),

        // customer selector
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: InkWell(
            borderRadius: BorderRadius.circular(11),
            onTap: () => _pickCustomer(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              decoration: BoxDecoration(
                color: AppColors.surfaceTint,
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: AppColors.borderSoft),
              ),
              child: Row(
                children: [
                  InitialsAvatar(cart.customer?.name ?? 'Walk-in', size: 26),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          cart.customer?.name ?? 'Walk-in customer',
                          style: const TextStyle(
                              fontFamily: 'Carlito', fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.ink),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (cart.customer != null && cart.customer!.points > 0)
                          Text('${cart.customer!.points} loyalty points',
                              style: const TextStyle(fontFamily: 'Carlito', fontSize: 11, color: AppColors.muted)),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, size: 19, color: AppColors.faint),
                ],
              ),
            ),
          ),
        ),

        // items
        Expanded(
          child: cart.isEmpty
              ? EmptyState(
                  icon: Icons.shopping_basket_outlined,
                  title: 'Cart is empty',
                  message: 'Tap products or scan a barcode to add them.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
                  itemCount: cart.items.length,
                  itemBuilder: (context, i) => _CartTile(item: cart.items[i]),
                ),
        ),

        // discount + totals
        if (!cart.isEmpty)
          Container(
            margin: const EdgeInsets.fromLTRB(14, 6, 14, 0),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: AppColors.surfaceTint,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.borderSoft),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Text('Discount (${settings.currencySymbol})',
                        style: const TextStyle(fontFamily: 'Carlito', fontSize: 13, color: AppColors.muted)),
                    const Spacer(),
                    const _DiscountField(),
                  ],
                ),
                const SizedBox(height: 8),
                _totalRow(context, 'Subtotal', settings.money(cart.subtotal)),
                if (cart.discount > 0)
                  _totalRow(context, 'Discount', '- ${settings.money(cart.discount)}',
                      color: AppColors.danger),
                if (settings.taxRate > 0)
                  _totalRow(
                      context, 'Tax (${settings.taxRate.toStringAsFixed(0)}%)',
                      settings.money(cart.tax(settings.taxRate))),
                Divider(height: 16, color: Colors.grey.shade200, thickness: 1),
                Row(
                  children: [
                    const Text('TOTAL',
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                            color: AppColors.muted)),
                    const Spacer(),
                    Text(
                      settings.money(cart.total(settings.taxRate)),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontSize: 22,
                        color: AppColors.primaryDark,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

        Padding(
          padding: const EdgeInsets.all(14),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
            onPressed: cart.isEmpty
                ? null
                : () => showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => const CheckoutDialog(),
                    ),
            icon: const Icon(Icons.payments_outlined, size: 20),
            label: Text(
              cart.isEmpty
                  ? 'Charge'
                  : 'Charge · ${settings.money(cart.total(settings.taxRate))}',
              style: const TextStyle(fontSize: 15.5),
            ),
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

  Widget _totalRow(BuildContext context, String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontFamily: 'Carlito', fontSize: 13, color: AppColors.muted)),
          const Spacer(),
          Text(value, style: TextStyle(
              fontFamily: 'Carlito', fontSize: 13, fontWeight: FontWeight.w600,
              color: color ?? AppColors.body)),
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

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
      padding: const EdgeInsets.fromLTRB(11, 9, 8, 9),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: AppColors.borderSoft),
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
                    style: const TextStyle(
                        fontFamily: 'Carlito', fontWeight: FontWeight.w700, fontSize: 13.5, color: AppColors.ink)),
                const SizedBox(height: 1),
                Text(
                  '${item.variant.descriptor} · ${settings.money(item.variant.price)}',
                  style: const TextStyle(fontFamily: 'Carlito', fontSize: 12, color: AppColors.muted),
                ),
              ],
            ),
          ),
          QtyStepper(
            qty: item.qty,
            onMinus: () => cart.setQty(item.key, item.qty - 1),
            onPlus: () => cart.setQty(item.key, item.qty + 1),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 86,
            child: Text(
              settings.money(item.lineTotal),
              textAlign: TextAlign.right,
              style: const TextStyle(
                  fontFamily: 'Carlito', fontWeight: FontWeight.w700, fontSize: 13.5, color: AppColors.ink),
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
        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          prefixText: '- ',
          prefixStyle: const TextStyle(color: AppColors.danger, fontWeight: FontWeight.w700),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
          ),
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
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      title: const Row(children: [
        Icon(Icons.person_search_rounded, size: 22, color: AppColors.primary),
        SizedBox(width: 10),
        Text('Attach customer'),
      ]),
      content: SizedBox(
        width: 400,
        height: 430,
        child: Column(
          children: [
            TextField(
              onChanged: (v) => setState(() => _q = v),
              decoration: const InputDecoration(
                hintText: 'Search name or phone…',
                prefixIcon: Icon(Icons.search_rounded, size: 20),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ListView(
                children: [
                  ListTile(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(11),
                        side: const BorderSide(color: AppColors.borderSoft)),
                    leading: const Icon(Icons.person_off_outlined, size: 21),
                    title: const Text('Walk-in customer'),
                    onTap: () => Navigator.pop(
                        context, const Customer(id: 0, name: 'Walk-in customer', createdAt: 0)),
                  ),
                  const SizedBox(height: 6),
                  ...list.map(
                    (c) => ListTile(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(11),
                          side: const BorderSide(color: AppColors.borderSoft)),
                      leading: InitialsAvatar(c.name, size: 34),
                      title: Text(c.name),
                      subtitle: Text(c.phone ?? ''),
                      trailing: Text('${c.points} pts',
                          style: const TextStyle(
                              fontFamily: 'Carlito',
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppColors.primary)),
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
