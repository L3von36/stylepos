import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors.dart';
import '../../models/category.dart';
import '../../state/catalog.dart';
import '../../widgets/ui.dart';

/// Quick "new category" prompt usable from ANY category picker: type a
/// name, get the created [Category] back (null when cancelled).
///
/// Validation is live — the Create button stays disabled for blank or
/// duplicate (case-insensitive) names, so the flow can never produce a
/// confusing "item already exists" error after the fact. Creation goes
/// through [CatalogProvider.addCategory], which marks the row dirty and
/// schedules the cloud sync.
Future<Category?> showAddCategoryDialog(
    BuildContext context, CatalogProvider catalog) {
  return showDialog<Category>(
    context: context,
    builder: (dialogContext) => const _AddCategoryDialog(),
  );
}

class _AddCategoryDialog extends StatefulWidget {
  const _AddCategoryDialog();

  @override
  State<_AddCategoryDialog> createState() => _AddCategoryDialogState();
}

class _AddCategoryDialogState extends State<_AddCategoryDialog> {
  final _name = TextEditingController();
  bool _busy = false;

  bool get _valid {
    final name = _name.text.trim();
    if (name.isEmpty) return false;
    final catalog = context.read<CatalogProvider>();
    final dup = catalog.categories.any(
        (c) => c.name.trim().toLowerCase() == name.toLowerCase());
    return !dup;
  }

  String? get _problem {
    final name = _name.text.trim();
    if (name.isEmpty) return null;
    final catalog = context.read<CatalogProvider>();
    final dup = catalog.categories.any(
        (c) => c.name.trim().toLowerCase() == name.toLowerCase());
    return dup ? 'A category with this name already exists.' : null;
  }

  Future<void> _create() async {
    if (!_valid || _busy) return;
    setState(() => _busy = true);
    final name = _name.text.trim();
    final catalog = context.read<CatalogProvider>();
    final navigator = Navigator.of(context);
    try {
      await catalog.addCategory(name);
      // addCategory() reloads the list; find the fresh row to select it.
      final created = catalog.categories.firstWhere(
        (c) => c.name.trim().toLowerCase() == name.toLowerCase(),
        orElse: () => catalog.categories.last,
      );
      navigator.pop(created);
    } catch (e, s) {
      ErrorCenter.I.reportError('product/add-category', e, s);
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _name,
      builder: (context, _) => AlertDialog(
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
            child: Icon(Icons.category_outlined,
                size: 19, color: AppColors.primary),
          ),
          const SizedBox(width: AppSpace.s3),
          const Text('New category'),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            onSubmitted: (_) => _create(),
            decoration:
                const InputDecoration(labelText: 'Category name *'),
          ),
          if (_problem != null) ...[
            const SizedBox(height: AppSpace.s2),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(_problem!,
                  style: TextStyle(
                      fontSize: 12, color: AppColors.danger)),
            ),
          ],
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton.icon(
            onPressed: _valid && !_busy ? _create : null,
            icon: _busy
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.add_rounded, size: 18),
            label: const Text('Create'),
          ),
        ],
      ),
    );
  }
}
