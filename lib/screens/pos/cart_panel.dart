import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/customer.dart';
import '../../models/promotion.dart';
import '../../services/approvals.dart';
import '../../state/auth.dart';
import '../../state/cart.dart';
import '../../state/catalog.dart';
import '../../state/customers.dart';
import '../../state/nav.dart';
import '../../state/promotions.dart';
import '../../state/settings.dart';
import '../../widgets/rive_view.dart';
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
    final user = context.watch<AuthProvider>().user;
    final needsApproval = discountNeedsApproval(
        isAdmin: user?.isAdmin ?? false,
        discount: cart.discount,
        threshold: settings.discountPinThreshold,
        canDiscount: user?.canDiscount ?? false,
        discountCap: user?.discountCap ?? 0);

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (cart.exchangeNote != null)
          Container(
            margin: const EdgeInsets.fromLTRB(AppSpace.s4, AppSpace.s3, AppSpace.s4, 0),
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.s4, vertical: AppSpace.s2 + 2),
            decoration: BoxDecoration(
              color: AppColors.warningSoft,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border:
                  Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                Icon(Icons.swap_horiz_rounded,
                    size: 16, color: AppColors.warning),
                const SizedBox(width: AppSpace.s2),
                Expanded(
                  child: Text(
                    cart.exchangeNote!,
                    style: TextStyle(
                        fontFamily: 'Carlito',
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.warning),
                  ),
                ),
                InkWell(
                  onTap: () => cart.clearExchange(),
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.close_rounded,
                        size: 14, color: AppColors.warning),
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.s4, AppSpace.s4, AppSpace.s2, 0),
          child: Row(
            children: [
              Icon(Icons.shopping_cart_outlined, size: 19, color: AppColors.primary),
              const SizedBox(width: AppSpace.s2),
              Expanded(
                child: Text('Current Sale',
                    style: TextStyle(
                        fontFamily: 'Carlito',
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink)),
              ),
              if (cart.heldCount > 0)
                TextButton.icon(
                  style: TextButton.styleFrom(
                      foregroundColor: AppColors.info, visualDensity: VisualDensity.compact),
                  onPressed: () => _showHeldSheet(context),
                  icon: const Icon(Icons.bookmark_rounded, size: 17),
                  label: Text('${cart.heldCount} held'),
                ),
              if (cart.isNotEmpty)
                TextButton.icon(
                  style: TextButton.styleFrom(
                      foregroundColor: AppColors.primary, visualDensity: VisualDensity.compact),
                  onPressed: () async {
                    await context.read<CartProvider>().holdCurrentSale();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Sale held — serve the next customer'),
                        behavior: SnackBarBehavior.floating,
                      ));
                    }
                  },
                  icon: const Icon(Icons.bookmark_border_rounded, size: 17),
                  label: const Text('Hold'),
                ),
              if (cart.isNotEmpty)
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: AppColors.danger, visualDensity: VisualDensity.compact),
                  onPressed: () {
                    // Undoable clear — an accidental tap never costs the
                    // cashier a full re-scan of the basket.
                    cart.stageUndo();
                    cart.clear();
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: const Text('Cart cleared'),
                      behavior: SnackBarBehavior.floating,
                      duration: const Duration(seconds: 4),
                      action: SnackBarAction(
                        label: 'Undo',
                        onPressed: () => cart.undoClear(),
                      ),
                    ));
                  },
                  child: const Text('Clear'),
                ),
            ],
          ),
        ),

        // customer selector
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.s4, AppSpace.s2 + 2, AppSpace.s4, 2),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            onTap: () => _pickCustomer(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.s3, vertical: AppSpace.s2),
              decoration: BoxDecoration(
                color: AppColors.surfaceTint,
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: AppColors.borderSoft),
              ),
              child: Row(
                children: [
                  InitialsAvatar(cart.customer?.name ?? 'Walk-in', size: 26),
                  const SizedBox(width: AppSpace.s2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          cart.customer?.name ?? 'Walk-in customer',
                          style: TextStyle(
                              fontFamily: 'Carlito', fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.ink),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (cart.customer != null && cart.customer!.points > 0)
                          Text('${cart.customer!.points} loyalty points',
                              style: TextStyle(fontFamily: 'Carlito', fontSize: 11, color: AppColors.muted)),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, size: 19, color: AppColors.faint),
                ],
              ),
            ),
          ),
        ),

        // items
        Expanded(
          child: cart.isEmpty
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const EmptyCartArt(),
                    const SizedBox(height: AppSpace.s3),
                    Text('Cart is empty',
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppColors.ink)),
                    const SizedBox(height: 4),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: AppSpace.s5),
                      child: Text(
                        'Tap products or scan a barcode to add them.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 12,
                            height: 16 / 12,
                            color: AppColors.muted),
                      ),
                    ),
                  ],
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(AppSpace.s3, AppSpace.s2, AppSpace.s3, AppSpace.s1),
                  itemCount: cart.items.length,
                  itemBuilder: (context, i) => _CartTile(item: cart.items[i]),
                ),
        ),

        // discount + totals
        if (cart.isNotEmpty)
          Container(
            margin: const EdgeInsets.fromLTRB(AppSpace.s4, AppSpace.s2, AppSpace.s4, 0),
            padding: const EdgeInsets.fromLTRB(AppSpace.s4, AppSpace.s3, AppSpace.s4, AppSpace.s3),
            decoration: BoxDecoration(
              color: AppColors.surfaceTint,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: AppColors.borderSoft),
            ),
            child: Column(
              children: [
                // Promotion code: apply / applied state. Promo discounts
                // are manager-approved by design — no PIN gate here.
                _PromoRow(),
                const SizedBox(height: AppSpace.s2),
                Row(
                  children: [
                    Text('Discount (${AppSettings.currencySymbol})',
                        style: TextStyle(fontFamily: 'Carlito', fontSize: 13, color: AppColors.muted)),
                    const Spacer(),
                    const _DiscountField(),
                  ],
                ),
                if (needsApproval) ...[
                  const SizedBox(height: AppSpace.s2),
                  Row(
                    children: [
                      Icon(Icons.verified_user_outlined, size: 14, color: AppColors.warning),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Manager approval needed to charge this discount',
                          style: TextStyle(
                              fontFamily: 'Carlito',
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppColors.warning),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: AppSpace.s2),
                _totalRow(context, 'Subtotal', settings.money(cart.subtotal)),
                if (cart.discount > 0)
                  _totalRow(context, 'Manual discount', '- ${settings.money(cart.discount)}',
                      color: AppColors.danger),
                if (cart.promoDiscount > 0)
                  _totalRow(context, 'Promo ${cart.promo!.code}',
                      '- ${settings.money(cart.promoDiscount)}',
                      color: AppColors.danger),
                if (settings.taxRate > 0)
                  _totalRow(
                      context, 'Tax (${settings.taxRate.toStringAsFixed(0)}%)',
                      settings.money(cart.tax(settings.taxRate))),
                Divider(height: AppSpace.s4, color: AppColors.borderSoft, thickness: 1),
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
                    Text(
                      settings.money(cart.total(settings.taxRate)),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontSize: 18,
                        color: AppColors.primaryDark,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

        Padding(
          padding: const EdgeInsets.all(AppSpace.s4),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 48)), // M3 touch target
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
              style: const TextStyle(fontSize: 15),
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

  /// Lists parked sales so the sales person can serve several customers
  /// at once (e.g. one keeps browsing while another pays).
  Future<void> _showHeldSheet(BuildContext context) async {
    final cart = context.read<CartProvider>();
    final catalog = context.read<CatalogProvider>();
    await showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (sheetContext) => AnimatedBuilder(
        animation: cart,
        builder: (sheetContext, _) {
          final settings = sheetContext.watch<AppSettings>();
          final held = cart.held;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpace.s5, AppSpace.s5, AppSpace.s5, AppSpace.s2),
                  child: Row(
                    children: [
                      Icon(Icons.bookmark_rounded, size: 20, color: AppColors.primary),
                      const SizedBox(width: AppSpace.s2),
                      Expanded(
                        child: Text('Held sales',
                            style: TextStyle(
                                fontFamily: 'Carlito',
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: AppColors.ink)),
                      ),
                      Text('${held.length} parked',
                          style: TextStyle(
                              fontFamily: 'Carlito', fontSize: 12, color: AppColors.muted)),
                    ],
                  ),
                ),
                if (held.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(AppSpace.s6),
                    child: EmptyState(
                      icon: Icons.bookmark_border_rounded,
                      title: 'Nothing held',
                      message: 'Use Hold in the cart to park a sale.',
                    ),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(
                          AppSpace.s4, 0, AppSpace.s4, AppSpace.s4),
                      itemCount: held.length,
                      itemBuilder: (listContext, i) {
                        final h = held[i];
                        final when = DateTime.fromMillisecondsSinceEpoch(h.heldAt * 1000);
                        String two(int n) => n.toString().padLeft(2, '0');
                        return Container(
                          margin: const EdgeInsets.only(bottom: AppSpace.s2),
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppSpace.s3, vertical: AppSpace.s2),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceTint,
                            borderRadius: BorderRadius.circular(AppRadius.md),
                            border: Border.all(color: AppColors.borderSoft),
                          ),
                          child: Row(
                            children: [
                              InitialsAvatar(h.customerName ?? 'Held', size: 34),
                              const SizedBox(width: AppSpace.s3),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      h.customerName ?? 'Walk-in customer',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontFamily: 'Carlito',
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.ink),
                                    ),
                                    Text(
                                      '${h.itemCount} item${h.itemCount == 1 ? '' : 's'} · '
                                      '${two(when.hour)}:${two(when.minute)}'
                                      '${h.discount > 0 ? ' · disc ${settings.money(h.discount)}' : ''}'
                                      '${h.promoCode != null ? ' · ${h.promoCode}' : ''}',
                                      style: TextStyle(
                                          fontFamily: 'Carlito', fontSize: 12, color: AppColors.muted),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: 'Discard',
                                icon: Icon(Icons.delete_outline,
                                    size: 19, color: AppColors.danger),
                                onPressed: () async {
                                  // A held sale holds a customer's picks —
                                  // never lose it to a single stray tap.
                                  final ok = await showDialog<bool>(
                                    context: sheetContext,
                                    builder: (c) => AlertDialog(
                                      title: const Text('Discard held sale?'),
                                      content: const SizedBox(
                                          width: 380,
                                          child: Text(
                                              'Its items and customer link will be removed. This cannot be undone.')),
                                      actions: [
                                        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                                        FilledButton(
                                          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
                                          onPressed: () => Navigator.pop(c, true),
                                          child: const Text('Discard'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (ok == true) await cart.dropHeld(h);
                                },
                              ),
                              const SizedBox(width: AppSpace.s1),
                              FilledButton.tonal(
                                onPressed: () async {
                                  // Resuming replaces whatever is in the
                                  // cart — confirm rather than silently
                                  // wiping an in-progress basket.
                                  if (cart.isNotEmpty) {
                                    final go = await showDialog<bool>(
                                      context: sheetContext,
                                      builder: (c) => AlertDialog(
                                        title: const Text('Replace current cart?'),
                                        content: const SizedBox(
                                            width: 380,
                                            child: Text(
                                                'Resuming this held sale will replace the items currently in the cart.')),
                                        actions: [
                                          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                                          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Replace')),
                                        ],
                                      ),
                                    );
                                    if (go != true) return;
                                  }
                                  if (!sheetContext.mounted) return;
                                  final promos = sheetContext.read<PromotionsProvider>();
                                  final ok = await cart.resumeHeld(
                                      h, catalog.findVariantById,
                                      promoLookup: promos.findByCode);
                                  if (sheetContext.mounted && !ok) {
                                    Navigator.pop(sheetContext);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                            'That sale\'s items are no longer in the catalog'),
                                        behavior: SnackBarBehavior.floating,
                                      ),
                                    );
                                  } else if (sheetContext.mounted) {
                                    Navigator.pop(sheetContext);
                                  }
                                },
                                style: FilledButton.styleFrom(
                                    minimumSize: const Size(0, 40)),
                                child: const Text('Resume'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _totalRow(BuildContext context, String label, String value, {Color? color}) {
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
      nav.goTo(NavId.customers);
      return;
    }
    cart.setCustomer(selected.id == 0 ? null : selected);
    customers.reload();
  }
}

class _PromoRow extends StatelessWidget {
  const _PromoRow();

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartProvider>();
    final settings = context.watch<AppSettings>();

    if (cart.promo != null) {
      final p = cart.promo!;
      return Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.s3, vertical: AppSpace.s2),
        decoration: BoxDecoration(
          color: AppColors.successSoft,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: AppColors.success.withValues(alpha: 0.3)),
        ),
        child: Row(children: [
          Icon(Icons.sell_rounded, size: 16, color: AppColors.success),
          const SizedBox(width: AppSpace.s2),
          Expanded(
            child: Text(
              '${p.code} · ${p.isPercent ? '${Promotion.trimPublic(p.value)}% off' : '${settings.money(p.value)} off'}'
              '  (−${settings.money(cart.promoDiscount)})',
              style: TextStyle(
                  fontFamily: 'Carlito',
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.success),
            ),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            onTap: () => context.read<CartProvider>().setPromo(null),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(Icons.close_rounded,
                  size: 14, color: AppColors.success),
            ),
          ),
        ]),
      );
    }

    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      onTap: () => _applyPromoCode(context),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.s3, vertical: AppSpace.s2),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
              color: AppColors.border,
              strokeAlign: BorderSide.strokeAlignInside),
        ),
        child: Row(children: [
          Icon(Icons.local_offer_outlined, size: 15, color: AppColors.info),
          const SizedBox(width: AppSpace.s2),
          Text('Apply promo code',
              style: TextStyle(
                  fontFamily: 'Carlito',
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.info)),
          const Spacer(),
          Icon(Icons.chevron_right_rounded, size: 15, color: AppColors.faint),
        ]),
      ),
    );
  }

  Future<void> _applyPromoCode(BuildContext context) async {
    final promos = context.read<PromotionsProvider>();
    final cart = context.read<CartProvider>();
    final settings = context.read<AppSettings>();

    final code = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final c = TextEditingController();
        String? err;
        return StatefulBuilder(
          builder: (dialogContext, setD) => AlertDialog(
            titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
            contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            title: Row(children: [
              Icon(Icons.local_offer_outlined, size: 21, color: AppColors.info),
              const SizedBox(width: AppSpace.s2),
              const Text('Promo code'),
            ]),
            content: SizedBox(
              width: 340,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  controller: c,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Code (e.g. SUMMER25)',
                  ),
                  onSubmitted: (v) =>
                      Navigator.pop(dialogContext, v.trim().toUpperCase()),
                ),
                if (err != null)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpace.s2),
                    child: Text(err!,
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 12,
                            color: AppColors.danger)),
                  ),
              ]),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel')),
              FilledButton(
                onPressed: () {
                  final p = promos.findByCode(c.text);
                  final reason = p?.blockedReason(subtotal: cart.subtotal);
                  if (p == null) {
                    setD(() => err = 'Unknown code — check with your manager.');
                    return;
                  }
                  if (reason != null) {
                    setD(() => err = reason);
                    return;
                  }
                  Navigator.pop(dialogContext, c.text.trim().toUpperCase());
                },
                child: const Text('Apply'),
              ),
            ],
          ),
        );
      },
    );

    if (code == null || code.isEmpty || !context.mounted) return;
    final p = promos.findByCode(code);
    if (p == null || p.blockedReason(subtotal: cart.subtotal) != null) return;
    cart.setPromo(p);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '${p.code} applied — ${p.isPercent ? '${Promotion.trimPublic(p.value)}% off' : '${settings.money(p.value)} off'}'),
        behavior: SnackBarBehavior.floating,
      ));
    }
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
      margin: const EdgeInsets.symmetric(vertical: AppSpace.s1, horizontal: 0),
      padding: const EdgeInsets.fromLTRB(AppSpace.s3, AppSpace.s2, AppSpace.s2, AppSpace.s2),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.borderSoft),
      ),
      child: Row(
        children: [
          ProductThumb(
            image: item.product.image,
            size: 40,
            radius: AppRadius.sm,
            icon: Icons.checkroom_rounded,
            iconSize: 20,
          ),
          const SizedBox(width: AppSpace.s2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.product.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: 'Carlito', fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.ink)),
                const SizedBox(height: 2),
                Text(
                  '${item.variant.descriptor} · ${settings.money(item.variant.price)}',
                  style: TextStyle(fontFamily: 'Carlito', fontSize: 12, color: AppColors.muted),
                ),
              ],
            ),
          ),
          QtyStepper(
            qty: item.qty,
            onMinus: () => cart.setQty(item.key, item.qty - 1),
            onPlus: () => cart.setQty(item.key, item.qty + 1),
          ),
          const SizedBox(width: AppSpace.s2),
          SizedBox(
            width: 88,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(
                settings.money(item.lineTotal),
                maxLines: 1,
                style: TextStyle(
                    fontFamily: 'Carlito', fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.ink),
              ),
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
  final _focus = FocusNode();

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keep the field in sync with cart state (hold / resume / clear all
    // change the discount elsewhere) — but never fight the user while
    // they are typing.
    final discount = context.watch<CartProvider>().discount;
    if (!_focus.hasFocus) {
      final parsed = double.tryParse(_c.text) ?? 0;
      if ((parsed - discount).abs() > 0.001) {
        _c.text = discount == 0
            ? ''
            : (discount % 1 == 0 ? discount.toStringAsFixed(0) : discount.toString());
      }
    }
    return SizedBox(
      width: 110,
      child: TextField(
        controller: _c,
        focusNode: _focus,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.right,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: AppColors.surface,
          contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.s3, vertical: AppSpace.s2),
          prefixText: '- ',
          prefixStyle: TextStyle(color: AppColors.danger, fontWeight: FontWeight.w700),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            borderSide: BorderSide(color: AppColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            borderSide: BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            borderSide: BorderSide(color: AppColors.primary, width: 2), // M3 2dp indicator
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
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, AppSpace.s4, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(AppSpace.s4, AppSpace.s2, AppSpace.s4, AppSpace.s4),
      title: Row(children: [
        Icon(Icons.person_search_rounded, size: 22, color: AppColors.primary),
        SizedBox(width: AppSpace.s3),
        Text('Attach customer'),
      ]),
      content: SizedBox(
        width: 400,
        height: 432,
        child: Column(
          children: [
            TextField(
              onChanged: (v) => setState(() => _q = v),
              decoration: const InputDecoration(
                hintText: 'Search name or phone…',
                prefixIcon: Icon(Icons.search_rounded, size: 20),
              ),
            ),
            const SizedBox(height: AppSpace.s3),
            Expanded(
              child: ListView(
                children: [
                  ListTile(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        side: BorderSide(color: AppColors.borderSoft)),
                    leading: const Icon(Icons.person_off_outlined, size: 21),
                    title: const Text('Walk-in customer'),
                    onTap: () => Navigator.pop(
                        context, const Customer(id: 0, name: 'Walk-in customer', createdAt: 0)),
                  ),
                  const SizedBox(height: AppSpace.s2),
                  ...list.map(
                    (c) => ListTile(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          side: BorderSide(color: AppColors.borderSoft)),
                      leading: InitialsAvatar(c.name, size: 34),
                      title: Text(c.name),
                      subtitle: Text(c.phone ?? ''),
                      trailing: Text('${c.points} pts',
                          style: TextStyle(
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
