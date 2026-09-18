import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io' show File, Platform;
import 'dart:typed_data' show Uint8List;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/sale.dart';
import '../../state/auth.dart';
import '../../state/sales.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';
import 'sale_detail_screen.dart';

/// Sales history with time filters and search by receipt / customer / cashier.
class SalesScreen extends StatefulWidget {
  const SalesScreen({super.key});

  @override
  State<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends State<SalesScreen> {
  int _days = 1; // 1 = today
  final _search = TextEditingController();
  String _query = '';
  List<Sale>? _sales;
  Timer? _debounce;
  int _lastRevision = 0;

  @override
  void initState() {
    super.initState();
    _lastRevision = context.read<SalesProvider>().revision;
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final sales = await context.read<SalesProvider>().listSales(
          days: _days,
          query: _query,
        );
    if (mounted) setState(() => _sales = sales);
  }

  /// Manager-only: exports the currently filtered sales list as CSV —
  /// browser download on web, share sheet on phones, save dialog on desktop.
  Future<void> _exportCsv() async {
    final rows = _sales;
    if (rows == null || rows.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);

    String esc(String v) {
      if (v.contains(',') || v.contains('"') || v.contains('\n')) {
        return '"${v.replaceAll('"', '""')}"';
      }
      return v;
    }

    String two(int n) => n.toString().padLeft(2, '0');
    final buf = StringBuffer(
        'receipt,date,customer,cashier,payment,status,subtotal,discount,tax,total\n');
    for (final s in rows) {
      final dt = DateTime.fromMillisecondsSinceEpoch(s.createdAt * 1000);
      final date =
          '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
      buf.writeln([
        s.receiptNo,
        date,
        s.customerName ?? '',
        s.cashierName ?? '',
        s.paymentMethod,
        s.status,
        s.subtotal.toStringAsFixed(2),
        s.discount.toStringAsFixed(2),
        s.tax.toStringAsFixed(2),
        s.total.toStringAsFixed(2),
      ].map(esc).join(','));
    }

    final name =
        'Sami-sales-${DateTime.now().toIso8601String().substring(0, 10)}.csv';
    final data = Uint8List.fromList(utf8.encode(buf.toString()));
    try {
      if (kIsWeb) {
        // Browser download (cross_file writes the object URL to the name).
        await XFile.fromData(data, mimeType: 'text/csv', name: name)
            .saveTo(name);
        messenger.showSnackBar(const SnackBar(content: Text('CSV downloaded')));
      } else if (Platform.isAndroid || Platform.isIOS) {
        final dir = await getTemporaryDirectory();
        final f = File(p.join(dir.path, name));
        await f.writeAsBytes(data, flush: true);
        await SharePlus.instance.share(ShareParams(
          files: [XFile(f.path, mimeType: 'text/csv')],
          subject: name,
          text: 'Sales export from Sami',
        ));
      } else {
        final loc = await getSaveLocation(suggestedName: name);
        if (loc == null) return;
        await File(loc.path).writeAsBytes(data, flush: true);
        messenger.showSnackBar(const SnackBar(content: Text('CSV saved')));
      }
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Export failed — please try again')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    // Realtime: a local checkout bumps the revision, and sync bumps it
    // again when sales from other devices land — reload after this frame
    // so the list always shows the newest receipts without a pull.
    final salesRev = context.watch<SalesProvider>().revision;
    if (salesRev != _lastRevision) {
      _lastRevision = salesRev;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
    final totalRevenue =
        _sales?.where((s) => !s.isRefunded).fold(0.0, (sum, s) => sum + s.total) ?? 0.0;
    final isAdmin = context.watch<AuthProvider>().user?.isAdmin ?? false;

    return Padding(
      padding: const EdgeInsets.all(AppSpace.s4),
      child: Column(
        children: [
          PageHeader(
            title: 'Sales',
            subtitle: _sales == null
                ? 'Loading…'
                : '${_sales!.length} receipt${_sales!.length == 1 ? '' : 's'}'
                    ' · ${settings.money(totalRevenue)} revenue',
            actions: [
              if (isAdmin && _sales != null && _sales!.isNotEmpty)
                IconButton(
                  tooltip: 'Export CSV',
                  icon: const Icon(Icons.file_download_outlined, size: 21),
                  onPressed: _exportCsv,
                ),
            ],
          ),
          // Responsive: on phones the period picker moves under the
          // search field (a 4-segment button + search overflows 360dp).
          LayoutBuilder(builder: (context, fc) {
            final search = SearchField(
              controller: _search,
              hint: 'Search receipt no, customer or cashier…',
              onChanged: (v) {
                _query = v;
                // Debounced: one query per pause, not one per keystroke.
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 350), _load);
              },
              onClear: () {
                _debounce?.cancel();
                _search.clear();
                _query = '';
                _load();
              },
            );
            final periods = SegmentedButton<int>(
              showSelectedIcon: false,
              style: primarySegmentStyle(),
              segments: const [
                ButtonSegment(value: 1, label: Text('Today')),
                ButtonSegment(value: 7, label: Text('7 days')),
                ButtonSegment(value: 30, label: Text('30 days')),
                ButtonSegment(value: 0, label: Text('All')),
              ],
              selected: {_days},
              onSelectionChanged: (s) {
                setState(() => _days = s.first);
                _load();
              },
            );
            if (fc.maxWidth < 560) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  search,
                  const SizedBox(height: AppSpace.s2),
                  periods,
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: search),
                const SizedBox(width: AppSpace.s3),
                periods,
              ],
            );
          }),
          const SizedBox(height: AppSpace.s4),
          Expanded(
            child: _sales == null
                ? const Center(child: CircularProgressIndicator())
                : _sales!.isEmpty
                    ? EmptyState(
                        icon: Icons.receipt_long_outlined,
                        title: 'No sales in this period',
                        message: 'Completed checkouts will appear here as receipts.',
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          itemCount: _sales!.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, i) =>
                              _SaleTile(sale: _sales![i], settings: settings),
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

class _SaleTile extends StatelessWidget {
  final Sale sale;
  final AppSettings settings;
  const _SaleTile({required this.sale, required this.settings});

  @override
  Widget build(BuildContext context) {
    final dt = DateTime.fromMillisecondsSinceEpoch(sale.createdAt * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    final when =
        '${two(dt.day)}/${two(dt.month)} ${two(dt.hour)}:${two(dt.minute)}';

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () async {
          await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SaleDetailScreen(saleId: sale.id!)));
          // refresh totals/stock if a refund happened in the detail screen
          if (context.mounted) {
            _reloadSales(context);
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.s4, vertical: AppSpace.s3),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: sale.isRefunded ? AppColors.dangerSoft : AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Icon(
                  switch (sale.paymentMethod) {
                    'card' => Icons.credit_card_rounded,
                    'mobile' => Icons.smartphone_rounded,
                    _ => Icons.payments_outlined,
                  },
                  size: 21,
                  color: sale.isRefunded ? AppColors.danger : AppColors.primary,
                ),
              ),
              const SizedBox(width: AppSpace.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(sale.receiptNo,
                            style: TextStyle(
                                fontFamily: 'Carlito',
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                                color: AppColors.ink)),
                        if (sale.isRefunded) ...[
                          const SizedBox(width: AppSpace.s2),
                          StatusPill.build(context,
                              label: 'Refunded',
                              foreground: AppColors.danger,
                              background: AppColors.dangerSoft,
                              icon: Icons.undo_rounded),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$when · ${sale.customerName ?? 'Walk-in'} · ${sale.cashierName ?? ''}',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: 'Carlito', fontSize: 12.5, color: AppColors.muted),
                    ),
                  ],
                ),
              ),
              Text(
                settings.money(sale.total),
                style: TextStyle(
                  fontFamily: 'Carlito',
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: sale.isRefunded ? AppColors.faint : AppColors.ink,
                  decoration: sale.isRefunded ? TextDecoration.lineThrough : null,
                ),
              ),
              const SizedBox(width: AppSpace.s2),
              Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.faint),
            ],
          ),
        ),
      ),
    );
  }
}

void _reloadSales(BuildContext context) {
  final state = context.findAncestorStateOfType<_SalesScreenState>();
  state?._load();
}
