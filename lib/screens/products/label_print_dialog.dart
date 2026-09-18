import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/product.dart';
import '../../services/label_service.dart';
import '../../services/receipt_service.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';

/// One selectable group of variants to tag: a product (or the in-progress
/// product in the editor, whose name may not be saved yet).
class LabelGroup {
  final Product product;
  final List<ProductVariant> variants;
  const LabelGroup(this.product, this.variants);
}

/// Bulk barcode shelf-tag printing: pick products/variants, copies per
/// variant, and the paper (A4 sticker sheet or 50×30 thermal roll), then
/// print or save the PDF built by [LabelService].
///
/// Shared by the Products screen (tag the whole shelf / a whole delivery)
/// and the product editor (tag one item before it goes on sale).
Future<void> showLabelPrintDialog(
  BuildContext context, {
  required List<LabelGroup> groups,
}) async {
  // Read dependencies before any async gap — the editor screen can pop
  // while the dialog is open.
  final settings = context.read<AppSettings>();
  final messenger = ScaffoldMessenger.of(context);

  await showDialog(
    context: context,
    builder: (c) =>
        _LabelDialogBody(groups: groups, settings: settings, messenger: messenger),
  );
}

class _LabelDialogBody extends StatefulWidget {
  final List<LabelGroup> groups;
  final AppSettings settings;
  final ScaffoldMessengerState messenger;

  const _LabelDialogBody({
    required this.groups,
    required this.settings,
    required this.messenger,
  });

  @override
  State<_LabelDialogBody> createState() => _LabelDialogBodyState();
}

class _LabelDialogBodyState extends State<_LabelDialogBody> {
  LabelPaper _paper = LabelPaper.a4;
  bool _busy = false;

  // One copy per variant by default — tagging a fresh delivery should
  // need zero per-variant fiddling.
  late final List<List<int>> _copies = [
    for (final g in widget.groups) [for (final _ in g.variants) 1],
  ];
  final Set<int> _expanded = {};

  int get _total {
    var n = 0;
    for (final g in _copies) {
      for (final c in g) {
        n += c;
      }
    }
    return n;
  }

  int _groupCopies(int gi) => _copies[gi].fold<int>(0, (a, b) => a + b);

  void _setGroup(int gi, int value) {
    for (var vi = 0; vi < _copies[gi].length; vi++) {
      _copies[gi][vi] = value;
    }
  }

  Future<void> _run({required bool printIt}) async {
    setState(() => _busy = true);
    try {
      final cells = <(Product, ProductVariant)>[];
      for (var gi = 0; gi < widget.groups.length; gi++) {
        final g = widget.groups[gi];
        for (var vi = 0; vi < g.variants.length; vi++) {
          for (var i = 0; i < _copies[gi][vi]; i++) {
            cells.add((g.product, g.variants[vi]));
          }
        }
      }
      if (cells.isEmpty) return;
      final bytes = await LabelService.build(
        settings: widget.settings,
        paper: _paper,
        entries: [for (final (p, v) in cells) (p, v, 1)],
      );
      final stem = 'labels-${DateTime.now().millisecondsSinceEpoch}';
      if (printIt) {
        await ReceiptService.printPdf(bytes);
      } else if (kIsWeb) {
        // Browser download — path_provider has no web implementation.
        await XFile.fromData(bytes, mimeType: 'application/pdf',
                name: '$stem.pdf')
            .saveTo('$stem.pdf');
        widget.messenger
            .showSnackBar(const SnackBar(content: Text('Labels downloaded')));
      } else if (Platform.isAndroid || Platform.isIOS) {
        final f = await ReceiptService.savePdf(bytes, stem);
        await ReceiptService.sharePdf(f);
      } else {
        final f = await ReceiptService.savePdf(bytes, stem);
        widget.messenger
            .showSnackBar(SnackBar(content: Text('Saved to ${f.path}')));
      }
      if (mounted && Navigator.of(context).canPop()) Navigator.pop(context);
    } catch (e) {
      widget.messenger.showSnackBar(SnackBar(
          content: Text(
              printIt ? 'Could not print: $e' : 'Could not build labels: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = _total;
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      title: Row(children: [
        Icon(Icons.style_outlined, size: 22, color: AppColors.primary),
        const SizedBox(width: AppSpace.s3),
        const Expanded(child: Text('Barcode labels')),
      ]),
      content: SizedBox(
        width: 470,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<LabelPaper>(
              showSelectedIcon: false,
              style: primarySegmentStyle(),
              segments: const [
                ButtonSegment(value: LabelPaper.a4, label: Text('A4 sheet')),
                ButtonSegment(
                    value: LabelPaper.roll50x30, label: Text('50×30 roll')),
              ],
              selected: {_paper},
              onSelectionChanged: (s) => setState(() => _paper = s.first),
            ),
            const SizedBox(height: AppSpace.s2),
            Row(
              children: [
                TextButton(
                  onPressed: widget.groups.isEmpty
                      ? null
                      : () {
                          for (var gi = 0; gi < _copies.length; gi++) {
                            _setGroup(gi, 1);
                          }
                          setState(() {});
                        },
                  child: const Text('Select all'),
                ),
                const SizedBox(width: AppSpace.s2),
                TextButton(
                  onPressed: widget.groups.isEmpty
                      ? null
                      : () {
                          for (var gi = 0; gi < _copies.length; gi++) {
                            _setGroup(gi, 0);
                          }
                          setState(() {});
                        },
                  child: const Text('Clear'),
                ),
                const Spacer(),
                Text(
                  '$n label${n == 1 ? '' : 's'}',
                  style: TextStyle(
                      fontFamily: 'Carlito',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: n > 0 ? AppColors.primary : AppColors.faint),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.s1),
            Expanded(
              child: widget.groups.isEmpty
                  ? Center(
                      child: Text('Nothing to tag yet',
                          style: TextStyle(
                              fontSize: 13, color: AppColors.muted)))
                  : ListView.builder(
                      itemCount: widget.groups.length,
                      itemBuilder: (context, gi) {
                        final g = widget.groups[gi];
                        final gc = _groupCopies(gi);
                        final open = _expanded.contains(gi);
                        final multiVariant = g.variants.length > 1;
                        return Column(
                          children: [
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Checkbox(
                                value: gc > 0,
                                tristate: false,
                                activeColor: AppColors.primary,
                                onChanged: (v) {
                                  _setGroup(gi, (v ?? false) ? 1 : 0);
                                  setState(() {});
                                },
                              ),
                              title: Text(
                                g.product.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontFamily: 'Carlito',
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700),
                              ),
                              subtitle: Text(
                                multiVariant
                                    ? '${g.variants.length} sizes/colors · $gc label${gc == 1 ? '' : 's'}'
                                    : '${g.variants.first.descriptor} · $gc label${gc == 1 ? '' : 's'}',
                                style: TextStyle(
                                    fontFamily: 'Carlito',
                                    fontSize: 12,
                                    color: AppColors.muted),
                              ),
                              trailing: multiVariant
                                  ? IconButton(
                                      icon: Icon(
                                          open
                                              ? Icons.expand_less_rounded
                                              : Icons.expand_more_rounded,
                                          size: 20,
                                          color: AppColors.muted),
                                      onPressed: () {
                                        open
                                            ? _expanded.remove(gi)
                                            : _expanded.add(gi);
                                        setState(() {});
                                      },
                                    )
                                  : null,
                              onTap: multiVariant
                                  ? () {
                                      open
                                          ? _expanded.remove(gi)
                                          : _expanded.add(gi);
                                      setState(() {});
                                    }
                                  : null,
                            ),
                            if (open)
                              Padding(
                                padding:
                                    const EdgeInsets.only(left: AppSpace.s4),
                                child: Column(
                                  children: [
                                    for (var vi = 0;
                                        vi < g.variants.length;
                                        vi++)
                                      ListTile(
                                        dense: true,
                                        contentPadding: EdgeInsets.zero,
                                        title: Text(g.variants[vi].descriptor,
                                            style: const TextStyle(
                                                fontFamily: 'Carlito',
                                                fontSize: 12.5)),
                                        subtitle: Text(
                                            g.variants[vi].barcode?.isEmpty ==
                                                    false
                                                ? g.variants[vi].barcode!
                                                : g.variants[vi].sku,
                                            style: TextStyle(
                                                fontFamily: 'Carlito',
                                                fontSize: 11.5,
                                                color: AppColors.muted)),
                                        trailing: QtyStepper(
                                          qty: _copies[gi][vi],
                                          onMinus: () => setState(() =>
                                              _copies[gi][vi] =
                                                  (_copies[gi][vi] - 1)
                                                      .clamp(0, 99)),
                                          onPlus: () => setState(() =>
                                              _copies[gi][vi] =
                                                  (_copies[gi][vi] + 1)
                                                      .clamp(0, 99)),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Cancel')),
        TextButton.icon(
          onPressed: (_busy || n == 0) ? null : () => _run(printIt: false),
          icon: const Icon(Icons.save_outlined, size: 17),
          label: const Text('Save PDF'),
        ),
        FilledButton.icon(
          onPressed: (_busy || n == 0) ? null : () => _run(printIt: true),
          icon: _busy
              ? const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.print_outlined, size: 17),
          label: const Text('Print'),
        ),
      ],
    );
  }
}
