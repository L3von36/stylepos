import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/product.dart';
import '../../services/barcode.dart';
import '../../services/images.dart';
import '../../services/label_service.dart';
import '../../services/receipt_service.dart';
import '../../state/catalog.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';

/// Full-screen editor for a product and its size/color variants.
/// Open without [product] to create a new one.
class ProductEditScreen extends StatefulWidget {
  final Product? product;
  const ProductEditScreen({super.key, this.product});

  @override
  State<ProductEditScreen> createState() => _ProductEditScreenState();
}

class _ProductEditScreenState extends State<ProductEditScreen> {
  late final TextEditingController _name;
  late final TextEditingController _barcode;
  late final TextEditingController _description;
  late final TextEditingController _lowStock;
  int? _categoryId;
  late List<ProductVariant> _variants;
  final Set<int> _removedIds = {};

  // Product photo: `_image` is the pending value, `_oldImage` the one
  // currently stored in the DB (deleted on save after being replaced).
  String? _image;
  String? _oldImage;
  bool _pickingImage = false;

  bool get _isNew => widget.product == null;

  @override
  void initState() {
    super.initState();
    final p = widget.product;
    _name = TextEditingController(text: p?.name ?? '');
    _barcode = TextEditingController(text: p?.barcode ?? '');
    _description = TextEditingController(text: p?.description ?? '');
    _lowStock = TextEditingController(text: (p?.lowStock ?? 5).toString());
    _categoryId = p?.categoryId;
    _image = p?.image;
    _oldImage = p?.image;
    _variants = p == null
        ? [ProductVariant(productId: 0, sku: '')]
        : List.of(p.variants);
  }

  @override
  void dispose() {
    _name.dispose();
    _barcode.dispose();
    _description.dispose();
    _lowStock.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    if (_pickingImage) return;
    setState(() => _pickingImage = true);
    final rel = await ProductImages.pick(context);
    if (!mounted) return;
    setState(() {
      _pickingImage = false;
      if (rel != null) _image = rel;
    });
  }

  Future<void> _removePhoto() async {
    // Keep the stored file until save so cancelling the editor
    // leaves the product untouched.
    setState(() => _image = null);
  }

  String _autoSku(String base) {
    final initials = _name.text
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase())
        .take(3)
        .join();
    final seed = DateTime.now().millisecondsSinceEpoch % 10000;
    final prefix = base.isEmpty ? initials : base;
    return '${prefix.isEmpty ? "ITM" : prefix}-$seed';
  }

  /// Barcodes already used anywhere in the catalog, so generated codes
  /// never collide with an existing variant or product code.
  Set<String> _takenCodes(CatalogProvider catalog) {
    return {
      for (final p in catalog.products) ...[
        if (p.barcode != null && p.barcode!.trim().isNotEmpty) p.barcode!.trim(),
        for (final v in p.variants) ...[
          if (v.barcode != null && v.barcode!.trim().isNotEmpty) v.barcode!.trim(),
        ],
      ],
      for (final v in _variants)
        if (v.barcode != null && v.barcode!.trim().isNotEmpty) v.barcode!.trim(),
    };
  }

  Future<void> _editVariant(ProductVariant v) async {
    final settings = context.read<AppSettings>();
    final catalog = context.read<CatalogProvider>();
    final isNew = v.id == null;
    final size = TextEditingController(text: v.size);
    final color = TextEditingController(text: v.color);
    final sku = TextEditingController(text: v.sku);
    final barcode = TextEditingController(text: v.barcode ?? '');
    final price = TextEditingController(text: v.price == 0 ? '' : v.price.toString());
    final cost = TextEditingController(text: v.cost == 0 ? '' : v.cost.toString());
    final stock = TextEditingController(text: v.stock.toString());
    String? err;

    final result = await showDialog<ProductVariant>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
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
              child: Icon(Icons.style_outlined, size: 19, color: AppColors.primary),
            ),
            const SizedBox(width: AppSpace.s3),
            Text(isNew ? 'Add variant' : 'Edit variant'),
          ]),
          content: SizedBox(
            // Form-dialog width family (matches stock adjust / variant picker).
            width: 430,
            child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: size,
                        decoration: const InputDecoration(
                            labelText: 'Size (S/M/L/…)'), // clothing sizes
                      ),
                    ),
                    const SizedBox(width: AppSpace.s3),
                    Expanded(
                      child: TextField(
                        controller: color,
                        decoration: const InputDecoration(labelText: 'Color'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.s3),
                TextField(
                  controller: sku,
                  decoration: InputDecoration(
                    labelText: 'SKU *',
                    suffixIcon: IconButton(
                      tooltip: 'Generate SKU',
                      icon: const Icon(Icons.auto_awesome_outlined, size: 19),
                      onPressed: () {
                        sku.text = _autoSku(sku.text.split('-').first);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: AppSpace.s3),
                TextField(
                  controller: barcode,
                  decoration: InputDecoration(
                    labelText: 'Barcode (unique, scanner-friendly)',
                    helperText: 'Print and tag the garment so one scan sells it',
                    suffixIcon: IconButton(
                      tooltip: 'Generate in-store barcode',
                      icon: const Icon(Icons.qr_code_2_rounded, size: 19),
                      onPressed: () {
                        final taken = _takenCodes(catalog);
                        setD(() => barcode.text =
                            BarcodeGen.generateInStore(isTaken: taken.contains));
                      },
                    ),
                  ),
                ),
                const SizedBox(height: AppSpace.s3),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: price,
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(
                            labelText: 'Price (${settings.currencySymbol}) *'),
                      ),
                    ),
                    const SizedBox(width: AppSpace.s3),
                    Expanded(
                      child: TextField(
                        controller: cost,
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(
                            labelText: 'Cost (${settings.currencySymbol})'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.s3),
                TextField(
                  controller: stock,
                  enabled: isNew,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: isNew ? 'Opening stock' : 'Stock (use Adjust stock)',
                    helperText: isNew ? null : 'Edit stock from the product menu',
                  ),
                ),
                if (err != null) ...[
                  const SizedBox(height: AppSpace.s3),
                  Container(
                    padding: const EdgeInsets.all(AppSpace.s3),
                    decoration: BoxDecoration(
                      color: AppColors.dangerSoft,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline_rounded, size: 17, color: AppColors.danger),
                        const SizedBox(width: AppSpace.s2),
                        Expanded(
                          child: Text(err!,
                              style: TextStyle(
                                  fontFamily: 'Carlito', fontSize: 12.5, color: AppColors.danger)),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final p = double.tryParse(price.text);
                if (p == null || p < 0) {
                  setD(() => err = 'Enter a valid price.');
                  return;
                }
                // The auto-created "Standard" variant ships with an empty
                // SKU. Demanding one here used to dead-end the manager right
                // after they typed a price ("SKU is required." with no way
                // forward but the tiny wand icon) — generate a code instead.
                if (sku.text.trim().isEmpty) {
                  sku.text = _autoSku('');
                }
                Navigator.pop(c, v.copyWith(
                  size: size.text.trim(),
                  color: color.text.trim(),
                  sku: sku.text.trim(),
                  barcode: barcode.text.trim().isEmpty ? null : barcode.text.trim(),
                  price: p,
                  cost: double.tryParse(cost.text) ?? 0,
                  stock: int.tryParse(stock.text) ?? 0,
                ));
              },
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );

    if (result != null) {
      setState(() {
        _variants[_variants.indexWhere((x) => identical(x, v))] = result;
      });
    }
  }

  /// Print tag labels (item name + size/color + price + barcode) so the
  /// sales person can ring up garments straight off the rack.
  Future<void> _printLabels() async {
    if (_variants.isEmpty) {
      _snack(context, 'Add at least one variant first.');
      return;
    }
    final settings = context.read<AppSettings>();
    final messenger = ScaffoldMessenger.of(context);
    LabelPaper paper = LabelPaper.a4;
    final copies = [for (final _ in _variants) 1];

    await showDialog(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          title: Row(children: [
            Icon(Icons.style_outlined, size: 22, color: AppColors.primary),
            SizedBox(width: AppSpace.s3),
            Text('Barcode labels'),
          ]),
          content: SizedBox(
            width: 430,
            height: 400,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<LabelPaper>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: LabelPaper.a4, label: Text('A4 sheet')),
                    ButtonSegment(
                        value: LabelPaper.roll50x30, label: Text('50×30 roll')),
                  ],
                  selected: {paper},
                  onSelectionChanged: (s) => setD(() => paper = s.first),
                ),
                const SizedBox(height: AppSpace.s3),
                Expanded(
                  child: ListView.builder(
                    itemCount: _variants.length,
                    itemBuilder: (context, i) {
                      final v = _variants[i];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(v.descriptor,
                            style: const TextStyle(
                                fontFamily: 'Carlito',
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700)),
                        subtitle: Text(v.barcode?.isEmpty == false
                            ? v.barcode!
                            : v.sku,
                            style: const TextStyle(
                                fontFamily: 'Carlito', fontSize: 12)),
                        trailing: QtyStepper(
                          qty: copies[i],
                          onMinus: () => setD(() =>
                              copies[i] = (copies[i] - 1).clamp(0, 99)),
                          onPlus: () => setD(
                              () => copies[i] = (copies[i] + 1).clamp(0, 99)),
                        ),
                      );
                    },
                  ),
                ),
                Text(
                  '${copies.fold<int>(0, (a, b) => a + b)} label(s) will be printed',
                  style: TextStyle(
                      fontFamily: 'Carlito', fontSize: 12.5, color: AppColors.muted),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            TextButton.icon(
              onPressed: () async {
                try {
                  final bytes = await LabelService.build(
                    settings: settings,
                    paper: paper,
                    entries: [
                      for (var i = 0; i < _variants.length; i++)
                        (
                          Product(
                              name: _name.text.isEmpty
                                  ? 'Product'
                                  : _name.text,
                              createdAt: 0),
                          _variants[i],
                          copies[i],
                        ),
                    ],
                  );
                  final file = await ReceiptService.savePdf(
                      bytes, 'labels-${DateTime.now().millisecondsSinceEpoch}');
                  messenger.showSnackBar(
                      SnackBar(content: Text('Saved to ${file.path}')));
                } catch (e) {
                  messenger.showSnackBar(
                      SnackBar(content: Text('Could not build labels: $e')));
                }
              },
              icon: const Icon(Icons.save_outlined, size: 17),
              label: const Text('Save PDF'),
            ),
            FilledButton.icon(
              onPressed: () async {
                try {
                  final bytes = await LabelService.build(
                    settings: settings,
                    paper: paper,
                    entries: [
                      for (var i = 0; i < _variants.length; i++)
                        (
                          Product(
                              name: _name.text.isEmpty
                                  ? 'Product'
                                  : _name.text,
                              createdAt: 0),
                          _variants[i],
                          copies[i],
                        ),
                    ],
                  );
                  await ReceiptService.printPdf(bytes);
                } catch (e) {
                  messenger.showSnackBar(
                      SnackBar(content: Text('Could not print: $e')));
                }
              },
              icon: const Icon(Icons.print_outlined, size: 17),
              label: const Text('Print'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final catalog = context.read<CatalogProvider>();
    final settings = context.read<AppSettings>();
    if (_name.text.trim().isEmpty) {
      _snack(context, 'Product name is required.');
      return;
    }
    if (_variants.isEmpty) {
      _snack(context, 'Add at least one variant.');
      return;
    }
    final skus = _variants.map((v) => v.sku.toLowerCase()).toSet();
    if (skus.length != _variants.length) {
      _snack(context, 'Each variant needs a unique SKU.');
      return;
    }

    // Barcodes must be unique — the scan-to-sell flow depends on it.
    final seenBc = <String>{};
    for (final v in _variants) {
      final bc = (v.barcode ?? '').trim();
      if (bc.isEmpty) continue;
      if (!seenBc.add(bc.toLowerCase())) {
        _snack(context, 'Two variants share barcode $bc — barcodes must be unique.');
        return;
      }
    }

    // Tag every variant with a unique scannable code so the POS can
    // ring it up with one scan. Codes are generated for any variant
    // left without one.
    final taken = _takenCodes(catalog);
    final tagged = <ProductVariant>[];
    var autoTagged = false;
    for (final v in _variants) {
      final bc = (v.barcode ?? '').trim();
      if (bc.isNotEmpty) {
        taken.add(bc);
        tagged.add(v);
        continue;
      }
      final code = BarcodeGen.generateInStore(isTaken: taken.contains);
      taken.add(code);
      tagged.add(v.copyWith(barcode: code));
      autoTagged = true;
    }
    if (autoTagged) {
      setState(() {
        _variants
          ..clear()
          ..addAll(tagged);
      });
    }

    final product = (widget.product ?? Product(
      name: '',
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    )).copyWith(
      name: _name.text.trim(),
      categoryId: _categoryId,
      barcode: _barcode.text.trim().isEmpty ? null : _barcode.text.trim(),
      description: _description.text.trim().isEmpty ? null : _description.text.trim(),
      lowStock: int.tryParse(_lowStock.text) ?? settings.lowStockDefault,
      image: _image,
      clearImage: _image == null,
      variants: _variants,
    );

    await catalog.saveProduct(product, removeVariantIds: _removedIds.toList());
    // Clean up the replaced photo file (if any) after a successful save.
    final replaced = _oldImage;
    if (replaced != null && replaced != _image) {
      await ProductImages.delete(replaced);
    }
    if (mounted) Navigator.pop(context);
  }

  void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final catalog = context.watch<CatalogProvider>();
    final settings = context.watch<AppSettings>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New product' : 'Edit product'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpace.s4),
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('Save'),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpace.s4),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 780),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // --- details card ---
                SectionCard(
                  icon: Icons.edit_note_outlined,
                  title: 'Product details',
                  children: [
                    // --- photo picker ---
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Stack(
                          children: [
                            ProductThumb(
                              image: _image,
                              size: 88,
                              radius: AppRadius.md,
                              icon: Icons.add_photo_alternate_outlined,
                              iconSize: 30,
                            ),
                            if (_pickingImage)
                              const Positioned.fill(
                                child: ColoredBox(
                                  color: Color(0x66FFFFFF),
                                  child: Center(
                                    child: SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(width: AppSpace.s4),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Product photo',
                                  style: TextStyle(
                                      fontFamily: 'Carlito',
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.ink)),
                              const SizedBox(height: 2),
                              Text(
                                'Shows on the sell screen so staff spot items faster.',
                                style: TextStyle(
                                    fontFamily: 'Carlito',
                                    fontSize: 12,
                                    color: AppColors.muted,
                                    height: 1.35),
                              ),
                              const SizedBox(height: AppSpace.s2),
                              Row(
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: _pickPhoto,
                                    icon: Icon(
                                        _image == null
                                            ? Icons.add_a_photo_outlined
                                            : Icons.swap_horiz_rounded,
                                        size: 17),
                                    label: Text(_image == null
                                        ? 'Add photo'
                                        : 'Replace'),
                                  ),
                                  if (_image != null) ...[
                                    const SizedBox(width: AppSpace.s2),
                                    TextButton.icon(
                                      onPressed: _removePhoto,
                                      icon: Icon(Icons.delete_outline,
                                          size: 17, color: AppColors.danger),
                                      label: Text('Remove',
                                          style: TextStyle(color: AppColors.danger)),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpace.s4),
                    TextField(
                      controller: _name,
                      decoration: const InputDecoration(
                          labelText: 'Product name *',
                          hintText: 'e.g. Classic Cotton Tee'),
                    ),
                    const SizedBox(height: AppSpace.s3),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<int?>(
                            initialValue: _categoryId,
                            icon: const Icon(Icons.expand_more_rounded, size: 19),
                            decoration:
                                const InputDecoration(labelText: 'Category'),
                            items: [
                              const DropdownMenuItem(
                                  value: null, child: Text('Uncategorized')),
                              for (final c in catalog.categories)
                                DropdownMenuItem(value: c.id, child: Text(c.name)),
                            ],
                            onChanged: (v) => setState(() => _categoryId = v),
                          ),
                        ),
                        const SizedBox(width: AppSpace.s3),
                        Expanded(
                          child: TextField(
                            controller: _barcode,
                            decoration: const InputDecoration(
                                labelText: 'Default barcode (optional)'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpace.s3),
                    TextField(
                      controller: _description,
                      maxLines: 2,
                      decoration: const InputDecoration(
                          labelText: 'Description (optional)'),
                    ),
                    const SizedBox(height: AppSpace.s3),
                    SizedBox(
                      width: 220,
                      child: TextField(
                        controller: _lowStock,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            labelText: 'Low stock alert at',
                            helperText: 'Units per variant'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.s4),

                // --- variants card ---
                SectionCard(
                  icon: Icons.style_outlined,
                  title: 'Variants',
                  subtitle: 'Each size/color combination tracks its own stock, price and barcode.',
                  action: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _printLabels,
                        icon: const Icon(Icons.qr_code_2_rounded, size: 17),
                        label: const Text('Labels'),
                      ),
                      const SizedBox(width: AppSpace.s2),
                      FilledButton.icon(
                        onPressed: () {
                          setState(() {
                            _variants.add(ProductVariant(
                              productId: widget.product?.id ?? 0,
                              sku: _autoSku(''),
                            ));
                          });
                        },
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('Add variant'),
                      ),
                    ],
                  ),
                  children: [
                    for (final v in _variants)
                      Container(
                        margin: const EdgeInsets.only(bottom: AppSpace.s2),
                        padding: const EdgeInsets.symmetric(horizontal: AppSpace.s3, vertical: AppSpace.s2),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceTint,
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          border: Border.all(color: AppColors.borderSoft),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: AppColors.primarySoft,
                                borderRadius: BorderRadius.circular(AppRadius.sm),
                              ),
                              child: Text(
                                v.size.isEmpty
                                    ? (v.color.isEmpty ? '•' : v.color[0].toUpperCase())
                                    : v.size,
                                style: TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.primary),
                              ),
                            ),
                            const SizedBox(width: AppSpace.s3),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(v.descriptor,
                                      style: TextStyle(
                                          fontFamily: 'Carlito',
                                          fontWeight: FontWeight.w700,
                                          fontSize: 14,
                                          color: AppColors.ink)),
                                  Text(
                                    '${v.sku} · ${settings.money(v.price)} · stock: ${v.stock}',
                                    style: TextStyle(
                                        fontFamily: 'Carlito', fontSize: 12, color: AppColors.muted),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Edit',
                              icon: const Icon(Icons.edit_outlined, size: 19),
                              onPressed: () => _editVariant(v),
                            ),
                            IconButton(
                              tooltip: 'Remove',
                              icon: Icon(Icons.delete_outline,
                                  size: 19, color: AppColors.danger),
                              onPressed: () {
                                setState(() {
                                  _variants.removeWhere((x) => identical(x, v));
                                  if (v.id != null) _removedIds.add(v.id!);
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                    if (_variants.isEmpty)
                      Text('No variants yet — add at least one.',
                          style: theme.textTheme.bodySmall),
                  ],
                ),
                const SizedBox(height: AppSpace.s6),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
