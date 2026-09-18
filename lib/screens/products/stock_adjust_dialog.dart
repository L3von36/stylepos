import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/product.dart';
import '../../state/auth.dart';
import '../../state/catalog.dart';
import '../../widgets/ui.dart';

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
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      title: Row(children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Icon(Icons.inventory_rounded, size: 19, color: AppColors.primary),
        ),
        const SizedBox(width: AppSpace.s3),
        Expanded(child: Text('Adjust stock · ${product.name}', overflow: TextOverflow.ellipsis)),
      ]),
      content: SizedBox(
        width: 430,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (variants.length > 1)
              DropdownButtonFormField<int>(
                initialValue: _variantIndex,
                isExpanded: true,
                icon: const Icon(Icons.expand_more_rounded, size: 19),
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
            const SizedBox(height: AppSpace.s4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.s4, vertical: AppSpace.s3),
              decoration: BoxDecoration(
                color: AppColors.surfaceTint,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: AppColors.borderSoft),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(variant.descriptor,
                            style: TextStyle(
                                fontFamily: 'Carlito',
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppColors.body)),
                        const SizedBox(height: AppSpace.s1),
                        Text('Current stock: ${variant.stock} pcs',
                            style: TextStyle(fontFamily: 'Carlito', fontSize: 12, color: AppColors.muted)),
                      ],
                    ),
                  ),
                  Icon(Icons.arrow_forward_rounded, size: 18, color: AppColors.faint),
                  const SizedBox(width: AppSpace.s3),
                  Text(
                    '$newStock pcs',
                    style: TextStyle(
                      fontFamily: 'Carlito',
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: _delta == 0
                          ? AppColors.ink
                          : (_delta > 0 ? AppColors.success : AppColors.danger),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.s3),
            Wrap(
              spacing: AppSpace.s2,
              runSpacing: AppSpace.s2,
              children: [
                for (final d in [-10, -5, -1, 1, 5, 10])
                  OutlinedButton(
                    onPressed: () => setState(() => _delta += d),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(56, 40),
                      backgroundColor: d > 0 ? AppColors.successSoft : AppColors.dangerSoft,
                      foregroundColor: d > 0 ? AppColors.success : AppColors.danger,
                      side: BorderSide.none,
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
            const SizedBox(height: 12),
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
