import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/product.dart';
import '../../state/auth.dart';
import '../../state/catalog.dart';

/// Stock in / out for a product's variants. Records an audited
/// stock movement with a note.
class StockAdjustDialog extends StatefulWidget {
  final Product product;
  const StockAdjustDialog({super.key, required this.product});

  @override
  State<StockAdjustDialog> createState() => _StockAdjustDialogState();
}

class _StockAdjustDialogState extends State<StockAdjustDialog> {
  late int _variantIndex;
  int _delta = 0;
  final _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    _variantIndex = 0;
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final product = widget.product;
    final variants = product.variants;
    if (variants.isEmpty) {
      return AlertDialog(
        content: const Text('This product has no variants.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      );
    }
    final variant = variants[_variantIndex.clamp(0, variants.length - 1)];
    final newStock = (variant.stock + _delta).clamp(0, 1 << 30);

    return AlertDialog(
      title: Text('Adjust stock · ${product.name}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (variants.length > 1)
              DropdownButtonFormField<int>(
                initialValue: _variantIndex,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Variant'),
                items: [
                  for (var i = 0; i < variants.length; i++)
                    DropdownMenuItem(
                      value: i,
                      child: Text(
                          '${variants[i].descriptor} · ${variants[i].sku} · ${variants[i].stock} pcs'),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _variantIndex = v ?? 0;
                  _delta = 0;
                }),
              ),
            const SizedBox(height: 14),
            Text(
              '${variant.descriptor}: ${variant.stock} → $newStock pcs',
              style: theme.textTheme.titleMedium?.copyWith(
                color: _delta == 0 ? null : (_delta > 0 ? Colors.green.shade700 : theme.colorScheme.error),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final d in [-10, -5, -1, 1, 5, 10])
                  OutlinedButton(
                    onPressed: () => setState(() => _delta += d),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: d > 0 ? Colors.green.shade700 : theme.colorScheme.error,
                    ),
                    child: Text(d > 0 ? '+$d' : '$d'),
                  ),
                if (_delta != 0)
                  TextButton(
                    onPressed: () => setState(() => _delta = 0),
                    child: const Text('Reset'),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _note,
              decoration: const InputDecoration(
                  labelText: 'Note (e.g. supplier delivery, damaged items)'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _delta == 0
              ? null
              : () async {
                  final catalog = context.read<CatalogProvider>();
                  final user = context.read<AuthProvider>().user;
                  await catalog.adjustStock(
                    variant,
                    _delta,
                    _delta > 0 ? 'restock' : 'adjustment',
                    _note.text.trim().isEmpty ? null : _note.text.trim(),
                    user?.id,
                  );
                  if (context.mounted) Navigator.pop(context);
                },
          child: Text('Apply ${_delta > 0 ? '+' : ''}$_delta'),
        ),
      ],
    );
  }
}
