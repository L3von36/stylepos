import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/product.dart';
import '../../state/cart.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';

/// Lets the cashier choose a size / color variant when a product has several.
class VariantPickerDialog extends StatelessWidget {
  final Product product;
  const VariantPickerDialog({super.key, required this.product});

  /// Starter-catalog variants carry machine SKUs derived from the product
  /// barcode (`<barcode>-<size|OS>-<n>`) — noise for humans. Real SKUs the
  /// manager typed are shown; derived ones are not.
  bool _hasRealSku(Product product, ProductVariant v) {
    final sku = v.sku.trim();
    if (sku.isEmpty) return false;
    final bc = (product.barcode ?? '').trim();
    if (bc.isNotEmpty && sku.startsWith('$bc-')) {
      final rest = sku.substring(bc.length + 1);
      if (RegExp(r'^[^-]+-\d+$').hasMatch(rest)) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, AppSpace.s4, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      title: Row(
        children: [
          ProductThumb(
            image: product.image,
            size: 34,
            radius: AppRadius.sm,
            icon: Icons.checkroom_rounded,
            iconSize: 19,
          ),
          const SizedBox(width: AppSpace.s3),
          Expanded(child: Text(product.name, overflow: TextOverflow.ellipsis)),
        ],
      ),
      content: SizedBox(
        width: 430,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Choose a size / color variant',
                style: TextStyle(fontFamily: 'Carlito', fontSize: 12, color: AppColors.muted)),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: product.variants.length,
                itemBuilder: (context, i) {
                  final v = product.variants[i];
                  final soldOut = v.stock <= 0;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: AppSpace.s2),
                    child: ListTile(
                      enabled: !soldOut,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        side: BorderSide(
                            color: soldOut ? AppColors.borderSoft : AppColors.border),
                      ),
                      tileColor: soldOut ? AppColors.surfaceTint : null,
                      leading: Container(
                        width: 40,
                        height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: soldOut ? AppColors.borderSoft : AppColors.primarySoft,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: Text(
                          v.size.isEmpty
                              ? (v.color.isEmpty ? '•' : v.color[0].toUpperCase())
                              : v.size,
                          style: TextStyle(
                            fontSize: v.size.length > 2 ? 10.5 : 14,
                            fontWeight: FontWeight.w700,
                            color: soldOut ? AppColors.faint : AppColors.primary,
                          ),
                        ),
                      ),
                      title: Text(v.descriptor,
                          style: TextStyle(
                              fontFamily: 'Carlito',
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: soldOut ? AppColors.faint : AppColors.ink)),
                      subtitle: Text(
                        soldOut
                            ? 'Out of stock'
                            : _hasRealSku(product, v)
                                ? '${v.stock} in stock · ${v.sku}'
                                : '${v.stock} in stock',
                        style: TextStyle(
                          fontFamily: 'Carlito',
                          fontSize: 12,
                          color: soldOut ? AppColors.danger : AppColors.muted,
                        ),
                      ),
                      trailing: Text(
                        settings.money(v.price),
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: soldOut ? AppColors.faint : AppColors.primaryDark),
                      ),
                      onTap: () {
                        final ok = context.read<CartProvider>().add(product, v);
                        if (!ok) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text('Only ${v.stock} in stock — all are in the cart'),
                            behavior: SnackBarBehavior.floating,
                          ));
                          return;
                        }
                        Navigator.pop(context);
                      },
                    ),
                  );
                },
              ),
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
