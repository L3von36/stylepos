import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/product.dart';
import '../../state/cart.dart';
import '../../state/settings.dart';

/// Lets the cashier choose a size / color variant when a product has several.
class VariantPickerDialog extends StatelessWidget {
  final Product product;
  const VariantPickerDialog({super.key, required this.product});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();

    return AlertDialog(
      title: Text(product.name),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Choose a variant',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
            const SizedBox(height: 10),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: product.variants.length,
                itemBuilder: (context, i) {
                  final v = product.variants[i];
                  final soldOut = v.stock <= 0;
                  return ListTile(
                    enabled: !soldOut,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(color: Colors.grey.shade300),
                    ),
                    leading: CircleAvatar(
                      backgroundColor: soldOut
                          ? Colors.grey.shade200
                          : Theme.of(context).colorScheme.primaryContainer,
                      child: Text(
                        v.size.isEmpty
                            ? (v.color.isEmpty ? '•' : v.color[0].toUpperCase())
                            : v.size,
                        style: TextStyle(
                          fontSize: v.size.length > 2 ? 10 : 14,
                          fontWeight: FontWeight.bold,
                          color: soldOut ? Colors.grey : null,
                        ),
                      ),
                    ),
                    title: Text(v.descriptor),
                    subtitle: Text(
                      soldOut ? 'Out of stock' : '${v.stock} in stock · ${v.sku}',
                      style: TextStyle(
                        fontSize: 12,
                        color: soldOut ? Theme.of(context).colorScheme.error : null,
                      ),
                    ),
                    trailing: Text(
                      settings.money(v.price),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onTap: () {
                      context.read<CartProvider>().add(product, v);
                      Navigator.pop(context);
                    },
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
