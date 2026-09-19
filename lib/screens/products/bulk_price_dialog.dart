import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/audit.dart';
import '../../state/auth.dart';
import '../../state/catalog.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';

enum _BulkMode { setPrice, increasePct, decreasePct, increaseAmt, decreaseAmt }

/// Manager tool: reprice many variants at once — set a fixed price or
/// move every price by a percentage/amount, optionally scoped to one
/// category. Every changed variant is marked dirty (syncs to all devices)
/// and the operation lands in the audit log.
Future<void> showBulkPriceDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (_) => const _BulkPriceDialog(),
  );
}

class _BulkPriceDialog extends StatefulWidget {
  const _BulkPriceDialog();

  @override
  State<_BulkPriceDialog> createState() => _BulkPriceDialogState();
}

class _BulkPriceDialogState extends State<_BulkPriceDialog> {
  _BulkMode _mode = _BulkMode.increasePct;
  int? _categoryId; // null = whole catalog
  final _amount = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  double get _value => double.tryParse(_amount.text) ?? 0;

  /// New price for a variant under the current mode, or null when
  /// unchanged/invalid.
  double? _newPrice(double old) => switch (_mode) {
        _BulkMode.setPrice => _value <= 0 ? null : _value,
        _BulkMode.increasePct => _value <= 0
            ? null
            : double.parse((old * (1 + _value / 100)).toStringAsFixed(2)),
        _BulkMode.decreasePct => _value <= 0
            ? null
            : double.parse((old * (1 - _value / 100))
                .clamp(0, double.maxFinite)
                .toStringAsFixed(2)),
        _BulkMode.increaseAmt => _value <= 0 ? null : old + _value,
        _BulkMode.decreaseAmt => _value <= 0
            ? null
            : (old - _value).clamp(0, double.maxFinite).toDouble(),
      };

  @override
  Widget build(BuildContext context) {
    final catalog = context.watch<CatalogProvider>();
    final settings = context.watch<AppSettings>();

    final variants = <(String, double)>[];
    for (final p in catalog.products) {
      if (_categoryId != null && p.categoryId != _categoryId) continue;
      for (final v in p.variants) {
        variants.add(('${p.name}${v.descriptor.isEmpty ? '' : ' · ${v.descriptor}'}', v.price));
      }
    }

    final modeLabel = switch (_mode) {
      _BulkMode.setPrice => 'Set price to',
      _BulkMode.increasePct => 'Increase by %',
      _BulkMode.decreasePct => 'Decrease by %',
      _BulkMode.increaseAmt => 'Increase by',
      _BulkMode.decreaseAmt => 'Decrease by',
    };

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      title: Row(children: [
        Icon(Icons.price_change_outlined, size: 22, color: AppColors.primary),
        const SizedBox(width: AppSpace.s2),
        const Text('Bulk price update'),
      ]),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<int?>(
                initialValue: _categoryId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Scope'),
                items: [
                  const DropdownMenuItem<int?>(
                      value: null, child: Text('All products')),
                  for (final c in catalog.categories)
                    DropdownMenuItem<int?>(value: c.id, child: Text(c.name)),
                ],
                onChanged: (v) => setState(() => _categoryId = v),
              ),
              const SizedBox(height: AppSpace.s3),
              SegmentedButton<_BulkMode>(
                showSelectedIcon: false,
                style: primarySegmentStyle(),
                segments: const [
                  ButtonSegment(value: _BulkMode.increasePct, label: Text('+ %')),
                  ButtonSegment(value: _BulkMode.decreasePct, label: Text('− %')),
                  ButtonSegment(value: _BulkMode.setPrice, label: Text('Set')),
                ],
                selected: {_mode},
                onSelectionChanged: (s) =>
                    setState(() => _mode = s.first),
              ),
              const SizedBox(height: AppSpace.s3),
              TextField(
                controller: _amount,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: modeLabel.contains('%')
                      ? modeLabel
                      : '$modeLabel (${AppSettings.currencySymbol})',
                  helperText: _mode == _BulkMode.setPrice
                      ? 'Every selected variant gets exactly this price'
                      : 'Applied per variant on top of its current price',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: AppSpace.s3),
              Container(
                padding: const EdgeInsets.all(AppSpace.s3),
                decoration: BoxDecoration(
                  color: AppColors.surfaceTint,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(color: AppColors.borderSoft),
                ),
                child: Row(children: [
                  Icon(Icons.info_outline_rounded,
                      size: 17, color: AppColors.info),
                  const SizedBox(width: AppSpace.s2),
                  Expanded(
                    child: Text(
                      '${variants.length} variant${variants.length == 1 ? '' : 's'} '
                      'in scope. Example: ${_example(variants, settings)}.',
                      style: TextStyle(
                          fontFamily: 'Carlito',
                          fontSize: 12,
                          color: AppColors.body),
                    ),
                  ),
                ]),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpace.s2),
                  child: Text(_error!,
                      style: TextStyle(
                          fontFamily: 'Carlito',
                          fontSize: 12,
                          color: AppColors.danger)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton.icon(
          onPressed: variants.isEmpty || _value <= 0 ? null : () => _apply(context),
          icon: const Icon(Icons.price_check_rounded, size: 18),
          label: Text('Update ${variants.length} prices'),
        ),
      ],
    );
  }

  String _example(List<(String, double)> variants, AppSettings settings) {
    if (variants.isEmpty) return 'no variants in scope';
    final old = variants.first.$2;
    final neu = _newPrice(old);
    if (neu == null || neu == old) {
      return '${settings.money(old)} stays ${settings.money(old)}';
    }
    return '${settings.money(old)} becomes ${settings.money(neu)}';
  }

  Future<void> _apply(BuildContext context) async {
    final catalog = context.read<CatalogProvider>();
    final auth = context.read<AuthProvider>();

    var changed = 0;
    double min = double.infinity, max = 0;
    for (final p in catalog.products) {
      if (_categoryId != null && p.categoryId != _categoryId) continue;
      for (final v in p.variants) {
        final neu = _newPrice(v.price);
        if (neu == null || (neu - v.price).abs() < 0.005) continue;
        min = min < v.price ? min : v.price;
        max = max > v.price ? max : v.price;
        changed++;
      }
    }
    if (changed == 0) {
      setState(() => _error = 'No prices would change with those values.');
      return;
    }

    final catName = _categoryId == null
        ? 'all products'
        : 'category "${catalog.categories.where((c) => c.id == _categoryId).first.name}"';
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Update prices?'),
        content: SizedBox(
          width: 380,
          child: Text(
              '$changed variant prices in $catName will change. This syncs to '
              'every device and is recorded in the audit log.'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Update prices')),
        ],
      ),
    );
    if (sure != true || !context.mounted) return;

    await catalog.bulkPriceUpdate(
      categoryId: _categoryId,
      transform: (old) => _newPrice(old),
    );
    await Audit.add(
      'bulk_price_update',
      '$changed variants repriced in $catName '
      '(${_modeLabel()} ${_amount.text})',
      userId: auth.user?.id,
      userName: auth.user?.name,
    );
    if (!context.mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$changed prices updated — syncing to every device'),
      behavior: SnackBarBehavior.floating,
    ));
  }

  String _modeLabel() => switch (_mode) {
        _BulkMode.setPrice => 'set',
        _BulkMode.increasePct => '+%',
        _BulkMode.decreasePct => '-%',
        _BulkMode.increaseAmt => '+amount',
        _BulkMode.decreaseAmt => '-amount',
      };
}
