import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/receipt_service.dart';
import '../../services/zreport_service.dart';
import '../../state/auth.dart';
import '../../state/sales.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';

/// Manager card: pick a business day, see its trading numbers, print the
/// Z-report PDF, and close the day (a signed snapshot that later refunds
/// cannot rewrite — closing is what turns "yesterday" into an audited
/// number for the day's cash-up).
class ZReportCard extends StatefulWidget {
  const ZReportCard({super.key});

  @override
  State<ZReportCard> createState() => _ZReportCardState();
}

class _ZReportCardState extends State<ZReportCard> {
  DateTime _day = _today();
  ZReportData? _data;
  ZCloseRecord? _closed;
  bool _loading = true;
  int _lastRevision = 0;

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  bool get _isToday => _day == _today();

  @override
  void initState() {
    super.initState();
    _lastRevision = context.read<SalesProvider>().revision;
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final data = await ZReportService.buildData(_day);
    final closed = await ZReportService.closedRecord(_day);
    if (!mounted) return;
    setState(() {
      _data = data;
      _closed = closed;
      _loading = false;
    });
  }

  void _shift(int days) {
    setState(() => _day = _day.add(Duration(days: days)));
    _load();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2000),
      lastDate: _today(),
      helpText: 'Business day',
    );
    if (picked == null) return;
    setState(() => _day = DateTime(picked.year, picked.month, picked.day));
    _load();
  }

  String get _dayLabel {
    String two(int n) => n.toString().padLeft(2, '0');
    final d = _day;
    final label =
        '${d.year}-${two(d.month)}-${two(d.day)}';
    if (_isToday) return '$label · today';
    final t = _today();
    if (t.difference(d).inDays == 1) return '$label · yesterday';
    return label;
  }

  // ------------------------------------------------------------ outputs

  Future<void> _savePdf() async {
    final d = _data;
    if (d == null) return;
    final settings = context.read<AppSettings>();
    final messenger = ScaffoldMessenger.of(context);
    String two(int n) => n.toString().padLeft(2, '0');
    final name = 'Z-report-${d.day.year}-${two(d.day.month)}-${two(d.day.day)}.pdf';
    try {
      final bytes = await ZReportService.buildPdf(
          settings: settings, d: d, closed: _closed);
      if (kIsWeb) {
        // Browser download — same mechanism as the sales CSV export.
        await XFile.fromData(bytes, mimeType: 'application/pdf', name: name)
            .saveTo(name);
        messenger.showSnackBar(const SnackBar(content: Text('Z-report downloaded')));
        return;
      }
      if (Platform.isAndroid || Platform.isIOS) {
        final f = await ReceiptService.savePdf(bytes, name.replaceAll('.pdf', ''));
        await ReceiptService.sharePdf(f);
        return;
      }
      final f = await ReceiptService.savePdf(bytes, name.replaceAll('.pdf', ''));
      messenger.showSnackBar(SnackBar(content: Text('Saved to ${f.path}')));
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('Could not build Z-report: $e')));
    }
  }

  Future<void> _printPdf() async {
    final d = _data;
    if (d == null) return;
    final settings = context.read<AppSettings>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes =
          await ZReportService.buildPdf(settings: settings, d: d, closed: _closed);
      await ReceiptService.printPdf(bytes);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not print: $e')));
    }
  }

  // ------------------------------------------------------- close / open

  Future<void> _closeDay() async {
    final d = _data;
    if (d == null || _loading) return;
    final user = context.read<AuthProvider>().user;
    final settings = context.read<AppSettings>();
    String two(int n) => n.toString().padLeft(2, '0');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Close the day?'),
        content: SizedBox(
          width: 400,
          child: Text(
            'A Z-report snapshot for ${d.day.year}-${two(d.day.month)}-${two(d.day.day)} '
            'will be recorded with net takings of ${settings.money(d.net)} '
            '(${d.orders} order${d.orders == 1 ? '' : 's'}).\n\n'
            'Refunds processed after closing will appear on the next day\'s '
            'report. The day stays re-openable in case of mistakes.',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(c, true),
            icon: const Icon(Icons.event_available_rounded, size: 18),
            label: const Text('Close day'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    await ZReportService.closeDay(
      _day,
      ZCloseRecord(
        closedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        closedBy: user?.name ?? '',
        net: d.net,
        orders: d.orders,
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Day closed — snapshot recorded')));
    _load();
  }

  Future<void> _reopenDay() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Re-open this day?'),
        content: const SizedBox(
          width: 380,
          child: Text(
              'The close snapshot is removed and the day can trade again. '
              'Close it again when you are done.'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Re-open')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ZReportService.reopenDay(_day);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Day re-opened')));
    _load();
  }

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>();
    // Realtime: sales landing from other devices (or a checkout on the POS
    // tab — IndexedStack builds this card long before it is visible) must
    // refresh the day's numbers, same contract as the KPI cards above.
    final rev = context.watch<SalesProvider>().revision;
    if (rev != _lastRevision) {
      _lastRevision = rev;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
    final d = _data;

    return SectionCard(
      icon: Icons.event_available_outlined,
      title: 'Day close (Z-report)',
      subtitle: 'Count the takings, print the report, close the day',
      children: [
        // ---- date navigation ----
        Row(
          children: [
            IconButton(
              tooltip: 'Previous day',
              onPressed: _loading ? null : () => _shift(-1),
              icon: const Icon(Icons.chevron_left_rounded, size: 22),
            ),
            InkWell(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              onTap: _loading ? null : _pickDate,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.s3, vertical: AppSpace.s1 + 2),
                decoration: BoxDecoration(
                  color: AppColors.surfaceTint,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(color: AppColors.borderSoft),
                ),
                child: Text(
                  _dayLabel,
                  style: TextStyle(
                      fontFamily: 'Carlito',
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Next day',
              onPressed: _loading || _isToday ? null : () => _shift(1),
              icon: const Icon(Icons.chevron_right_rounded, size: 22),
            ),
            if (!_isToday) ...[
              const SizedBox(width: AppSpace.s1),
              TextButton(
                onPressed: _loading
                    ? null
                    : () {
                        setState(() => _day = _today());
                        _load();
                      },
                child: const Text('Today'),
              ),
            ],
            const Spacer(),
            if (_loading)
              const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ),
        const SizedBox(height: AppSpace.s3),

        // ---- closed banner ----
        if (_closed != null) ...[
          Container(
            padding: const EdgeInsets.all(AppSpace.s2 + 2),
            decoration: BoxDecoration(
              color: AppColors.successSoft,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border:
                  Border.all(color: AppColors.success.withValues(alpha: 0.35)),
            ),
            child: Row(
              children: [
                Icon(Icons.verified_outlined,
                    size: 18, color: AppColors.success),
                const SizedBox(width: AppSpace.s2),
                Expanded(
                  child: Text(
                    'Closed by ${_closed!.closedBy.isEmpty ? 'manager' : _closed!.closedBy} · '
                    'snapshot net ${s.money(_closed!.net)} · ${_closed!.orders} orders',
                    style: TextStyle(
                        fontFamily: 'Carlito',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.body),
                  ),
                ),
                TextButton(
                  onPressed: _reopenDay,
                  child: const Text('Re-open'),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.s3),
        ],

        // ---- numbers ----
        if (d == null) ...[
          Text('Loading…',
              style: TextStyle(fontSize: 13, color: AppColors.muted)),
        ] else ...[
          LayoutBuilder(builder: (context, c) {
            final narrow = c.maxWidth < 430;
            final tiles = <(String, String, Color, Color)>[
              (
                'Net takings',
                s.money(d.net),
                AppColors.success,
                AppColors.successSoft
              ),
              (
                'Gross sales',
                s.money(d.gross),
                AppColors.primary,
                AppColors.primarySoft
              ),
              (
                'Refunds',
                s.money(d.refundTotal),
                AppColors.danger,
                AppColors.dangerSoft
              ),
            ];
            Widget tile((String, String, Color, Color) t) => Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        vertical: AppSpace.s2 + 2, horizontal: AppSpace.s3),
                    decoration: BoxDecoration(
                      color: t.$4,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.$1,
                            style: TextStyle(
                                fontFamily: 'Carlito',
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: AppColors.muted)),
                        const SizedBox(height: 2),
                        Text(t.$2,
                            style: TextStyle(
                                fontFamily: 'Carlito',
                                fontSize: narrow ? 14 : 16,
                                fontWeight: FontWeight.w700,
                                color: t.$3)),
                      ],
                    ),
                  ),
                );
            return Row(
              children: [
                tile(tiles[0]),
                const SizedBox(width: AppSpace.s2),
                tile(tiles[1]),
                const SizedBox(width: AppSpace.s2),
                tile(tiles[2]),
              ],
            );
          }),
          const SizedBox(height: AppSpace.s3),
          _metaRow(
              'Orders', '${d.orders}', 'Items sold', '${d.itemsSold}'),
          if (d.discounts > 0)
            _metaRow('Discounts given', s.money(d.discounts),
                'Tax collected', s.money(d.tax)),
          if (d.grossProfit != null)
            _metaRow('Est. cost of goods', s.money(d.cogs),
                'Est. gross profit', s.money(d.net - d.cogs)),

          // ---- payment breakdown ----
          if (d.payments.isNotEmpty) ...[
            const SizedBox(height: AppSpace.s3),
            Wrap(
              spacing: AppSpace.s2,
              runSpacing: AppSpace.s2,
              children: [
                for (final p in d.payments)
                  _pill(
                    '${_methodLabel(p.method)} · ${s.money(p.total)}',
                    '${p.orders} order${p.orders == 1 ? '' : 's'}',
                  ),
              ],
            ),
          ],

          // ---- best sellers ----
          if (d.topItems.isNotEmpty) ...[
            const SizedBox(height: AppSpace.s3),
            for (var i = 0; i < d.topItems.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Text('${i + 1}.',
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.faint)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(d.topItems[i].name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontFamily: 'Carlito',
                              fontSize: 12.5,
                              color: AppColors.body)),
                    ),
                    Text('${d.topItems[i].units} pcs',
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.muted)),
                    const SizedBox(width: AppSpace.s3),
                    Text(s.money(d.topItems[i].revenue),
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 12.5,
                            color: AppColors.body)),
                  ],
                ),
              ),
          ],
        ],

        const SizedBox(height: AppSpace.s4),
        // ---- actions ----
        Wrap(
          spacing: AppSpace.s2,
          runSpacing: AppSpace.s2,
          children: [
            OutlinedButton.icon(
              onPressed: _loading || d == null ? null : _savePdf,
              icon: const Icon(Icons.save_outlined, size: 17),
              label: const Text('Save PDF'),
            ),
            OutlinedButton.icon(
              onPressed: _loading || d == null ? null : _printPdf,
              icon: const Icon(Icons.print_outlined, size: 17),
              label: const Text('Print'),
            ),
            FilledButton.icon(
              onPressed:
                  _loading || d == null || _closed != null ? null : _closeDay,
              icon: const Icon(Icons.event_available_rounded, size: 17),
              label: Text(_closed != null ? 'Day closed' : 'Close the day'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _metaRow(String a, String b, String c, String e) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            Expanded(
                child: Text(a,
                    style: TextStyle(
                        fontFamily: 'Carlito', fontSize: 12.5, color: AppColors.muted))),
            Text(b,
                style: TextStyle(
                    fontFamily: 'Carlito',
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.body)),
            const SizedBox(width: AppSpace.s4),
            Expanded(
                child: Text(c,
                    style: TextStyle(
                        fontFamily: 'Carlito', fontSize: 12.5, color: AppColors.muted))),
            Text(e,
                style: TextStyle(
                    fontFamily: 'Carlito',
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.body)),
          ],
        ),
      );

  Widget _pill(String label, String sub) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: AppSpace.s3, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.infoSoft,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(
                    fontFamily: 'Carlito',
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.info)),
            const SizedBox(width: 6),
            Text(sub,
                style: TextStyle(
                    fontFamily: 'Carlito', fontSize: 11.5, color: AppColors.muted)),
          ],
        ),
      );

  static String _methodLabel(String m) => switch (m) {
        'cash' => 'Cash',
        'card' => 'Card',
        'mobile' => 'Mobile money',
        _ => m.isEmpty
            ? 'Other'
            : m[0].toUpperCase() + m.substring(1),
      };
}
