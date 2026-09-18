import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../data/database.dart';
import '../state/settings.dart';

/// One day's trading numbers, as printed on the Z-report.
class ZReportData {
  final DateTime day;
  final int orders;
  final int itemsSold;
  final double gross; // sum of sale totals (after discount, incl. tax)
  final double discounts; // sum of discounts given
  final double tax; // sum of tax charged
  final int refundCount;
  final double refundTotal;
  final double cogs; // estimated cost of goods sold
  final List<({String method, int orders, double total})> payments;
  final List<({String name, int orders, double revenue})> staff;
  final List<({String name, int units, double revenue})> topItems;

  /// Cash payments received (completed sales only).
  final double cashIn;

  /// Cash refunds processed today (refunded sales paid by cash).
  final double cashRefunds;

  ZReportData({
    required this.day,
    required this.orders,
    required this.itemsSold,
    required this.gross,
    required this.discounts,
    required this.tax,
    required this.refundCount,
    required this.refundTotal,
    required this.cogs,
    required this.payments,
    required this.staff,
    required this.topItems,
    this.cashIn = 0,
    this.cashRefunds = 0,
  });

  /// Net takings = gross sales minus refunds processed that day.
  double get net => gross - refundTotal;

  /// Expected cash in the drawer at day close: cash sales minus cash
  /// refunds. Reconciliation compares the counted float against this.
  double get expectedCash => cashIn - cashRefunds;

  /// Estimated profit margin (null when no cost prices are set).
  double? get grossProfit => cogs > 0 ? net - cogs : null;
}

/// Snapshot stored when a manager closes a day, so the Z-report can be
/// re-printed later even as refunds/edits land afterwards.
class ZCloseRecord {
  final int closedAt; // epoch seconds
  final String closedBy;
  final double net;
  final int orders;

  /// Cash reconciliation captured at close (null = not counted).
  final double? expectedCash;
  final double? countedCash;

  const ZCloseRecord({
    required this.closedAt,
    required this.closedBy,
    required this.net,
    required this.orders,
    this.expectedCash,
    this.countedCash,
  });

  /// counted − expected (null when no count was taken).
  double? get variance =>
      (countedCash == null || expectedCash == null)
          ? null
          : countedCash! - expectedCash!;

  Map<String, dynamic> toJson() => {
        'at': closedAt,
        'by': closedBy,
        'net': net,
        'orders': orders,
        if (expectedCash != null) 'expectedCash': expectedCash,
        if (countedCash != null) 'countedCash': countedCash,
      };

  static ZCloseRecord fromJson(Map<String, dynamic> j) => ZCloseRecord(
        closedAt: (j['at'] as num?)?.toInt() ?? 0,
        closedBy: j['by'] as String? ?? '',
        net: (j['net'] as num?)?.toDouble() ?? 0,
        orders: (j['orders'] as num?)?.toInt() ?? 0,
        expectedCash: (j['expectedCash'] as num?)?.toDouble(),
        countedCash: (j['countedCash'] as num?)?.toDouble(),
      );
}

/// Day-close Z-report: trading numbers for one business day, a printable
/// A4 PDF, and the close/reopen bookkeeping.
///
/// Business day = local midnight to local midnight. The numbers are always
/// computed live from the sales tables; closing a day stores a signed
/// snapshot (who/when/net/orders) so later refunds never rewrite history.
class ZReportService {
  ZReportService._();

  // ------------------------------------------------------------ queries

  static DateTime _dayStart(DateTime day) =>
      DateTime(day.year, day.month, day.day);

  /// YYYY-MM-DD key used by the close store and SQL grouping.
  static String dayKey(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  /// Trading numbers for [day] (local time), computed live from the DB.
  static Future<ZReportData> buildData(DateTime day) async {
    final db = await DB.instance();
    final from = _dayStart(day).millisecondsSinceEpoch ~/ 1000;
    final to = _dayStart(day).add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000;
    // Some queries alias sales (joined with users/variants), so the window
    // predicate must take the column prefix — plain `created_at` is
    // ambiguous once users joins in.
    String win(String col) => '$col >= ? AND $col < ?';
    final args = [from, to];

    final totals = await db.rawQuery('''
      SELECT COUNT(*) AS orders,
             COALESCE(SUM(total), 0) AS gross,
             COALESCE(SUM(discount), 0) AS discounts,
             COALESCE(SUM(tax), 0) AS tax
      FROM sales
      WHERE status = 'completed' AND ${win('created_at')}
    ''', args);

    final items = await db.rawQuery('''
      SELECT COALESCE(SUM(si.qty), 0) AS items
      FROM sale_items si
      JOIN sales s ON s.id = si.sale_id
      WHERE s.status = 'completed' AND ${win('s.created_at')}
    ''', args);

    final refunds = await db.rawQuery('''
      SELECT COUNT(*) AS n, COALESCE(SUM(total), 0) AS amount,
             COALESCE(SUM(CASE WHEN payment_method = 'cash' THEN total ELSE 0 END), 0) AS cash
      FROM sales
      WHERE status = 'refunded' AND ${win('created_at')}
    ''', args);

    final cogsRows = await db.rawQuery('''
      SELECT COALESCE(SUM(si.qty * COALESCE(v.cost, 0)), 0) AS cost
      FROM sale_items si
      JOIN sales s ON s.id = si.sale_id
      LEFT JOIN variants v ON v.id = si.variant_id
      WHERE s.status = 'completed' AND ${win('s.created_at')}
    ''', args);

    final payments = await db.rawQuery('''
      SELECT payment_method AS method, COUNT(*) AS orders,
             COALESCE(SUM(total), 0) AS total
      FROM sales
      WHERE status = 'completed' AND ${win('created_at')}
      GROUP BY payment_method
      ORDER BY total DESC
    ''', args);

    final staff = await db.rawQuery('''
      SELECT IFNULL(u.name, 'Unknown') AS name, COUNT(*) AS orders,
             COALESCE(SUM(s.total), 0) AS revenue
      FROM sales s
      LEFT JOIN users u ON u.id = s.user_id
      WHERE s.status = 'completed' AND ${win('s.created_at')}
      GROUP BY u.id, u.name
      ORDER BY revenue DESC
    ''', args);

    final top = await db.rawQuery('''
      SELECT si.product_name AS name, SUM(si.qty) AS units,
             SUM(si.line_total) AS revenue
      FROM sale_items si
      JOIN sales s ON s.id = si.sale_id
      WHERE s.status = 'completed' AND ${win('s.created_at')}
      GROUP BY si.product_name
      ORDER BY units DESC
      LIMIT 5
    ''', args);

    final paymentRows = [
      for (final r in payments)
        (
          method: r['method'] as String? ?? 'cash',
          orders: r['orders'] as int? ?? 0,
          total: (r['total'] as num?)?.toDouble() ?? 0,
        ),
    ];
    final cashIn = paymentRows
        .where((p) => p.method == 'cash')
        .fold(0.0, (s, p) => s + p.total);

    return ZReportData(
      day: _dayStart(day),
      orders: totals.first['orders'] as int? ?? 0,
      itemsSold: items.first['items'] as int? ?? 0,
      gross: (totals.first['gross'] as num?)?.toDouble() ?? 0,
      discounts: (totals.first['discounts'] as num?)?.toDouble() ?? 0,
      tax: (totals.first['tax'] as num?)?.toDouble() ?? 0,
      refundCount: refunds.first['n'] as int? ?? 0,
      refundTotal: (refunds.first['amount'] as num?)?.toDouble() ?? 0,
      cogs: (cogsRows.first['cost'] as num?)?.toDouble() ?? 0,
      payments: paymentRows,
      cashIn: cashIn,
      cashRefunds: (refunds.first['cash'] as num?)?.toDouble() ?? 0,
      staff: [
        for (final r in staff)
          (
            name: r['name'] as String? ?? 'Unknown',
            orders: r['orders'] as int? ?? 0,
            revenue: (r['revenue'] as num?)?.toDouble() ?? 0,
          ),
      ],
      topItems: [
        for (final r in top)
          (
            name: r['name'] as String? ?? '',
            units: r['units'] as int? ?? 0,
            revenue: (r['revenue'] as num?)?.toDouble() ?? 0,
          ),
      ],
    );
  }

  // ------------------------------------------------------- close store

  static const _storeKey = 'z_closed_days';

  /// All closed days: { 'yyyy-MM-dd': record }.
  static Future<Map<String, ZCloseRecord>> closedDays() async {
    final db = await DB.instance();
    final rows = await db.query('settings',
        where: 'key = ?', whereArgs: [_storeKey]);
    final raw = rows.isEmpty ? '' : (rows.first['value'] as String? ?? '');
    if (raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) =>
          MapEntry(k, ZCloseRecord.fromJson(v as Map<String, dynamic>)));
    } catch (_) {
      return {}; // corrupted blob behaves like "nothing closed yet"
    }
  }

  /// The snapshot for [day], or null when the day is still open.
  static Future<ZCloseRecord?> closedRecord(DateTime day) async =>
      (await closedDays())[dayKey(day)];

  /// Persists the close snapshot for [day] (idempotent overwrite).
  static Future<void> closeDay(
      DateTime day, ZCloseRecord record) async {
    final all = await closedDays();
    all[dayKey(day)] = record;
    await _writeStore(all);
  }

  /// Re-opens [day] (undo a mistaken close). Nothing to do when open.
  static Future<void> reopenDay(DateTime day) async {
    final all = await closedDays();
    final removed = all.remove(dayKey(day));
    if (removed == null) return;
    await _writeStore(all);
  }

  static Future<void> _writeStore(Map<String, ZCloseRecord> all) async {
    final db = await DB.instance();
    final json = {for (final e in all.entries) e.key: e.value.toJson()};
    await db.insert('settings', {'key': _storeKey, 'value': jsonEncode(json)},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // --------------------------------------------------------------- PDF

  static pw.Font? _fontRegular;
  static pw.Font? _fontBold;

  static Future<void> _ensureFonts() async {
    if (_fontRegular != null) return;
    final reg = await rootBundle.load('assets/fonts/Carlito-Regular.ttf');
    final bold = await rootBundle.load('assets/fonts/Carlito-Bold.ttf');
    _fontRegular = pw.Font.ttf(reg);
    _fontBold = pw.Font.ttf(bold);
  }

  static pw.Widget _row(String label, String value, {bool bold = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label,
              style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
          pw.Text(value,
              style: pw.TextStyle(
                  fontSize: bold ? 11.5 : 10,
                  fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
        ],
      ),
    );
  }

  static pw.Table _table(List<pw.TableRow> rows) => pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
        children: rows,
      );

  static pw.TableRow _head3(String a, String b, String c) => pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.grey200),
        children: [
          for (final (i, s) in [a, b, c].indexed)
            pw.Container(
                padding: const pw.EdgeInsets.all(4),
                alignment: i == 0 ? pw.Alignment.centerLeft : pw.Alignment.centerRight,
                child: pw.Text(s,
                    style: const pw.TextStyle(
                        fontSize: 8.5, fontWeight: pw.FontWeight.bold))),
        ],
      );

  static pw.TableRow _row3(String a, String b, String c) => pw.TableRow(
        children: [
          pw.Container(
              padding: const pw.EdgeInsets.all(4),
              alignment: pw.Alignment.centerLeft,
              child: pw.Text(a, style: const pw.TextStyle(fontSize: 9.5))),
          pw.Container(
              padding: const pw.EdgeInsets.all(4),
              alignment: pw.Alignment.centerRight,
              child: pw.Text(b, style: const pw.TextStyle(fontSize: 9.5))),
          pw.Container(
              padding: const pw.EdgeInsets.all(4),
              alignment: pw.Alignment.centerRight,
              child: pw.Text(c, style: const pw.TextStyle(fontSize: 9.5))),
        ],
      );

  /// Builds the A4 Z-report PDF.
  static Future<Uint8List> buildPdf({
    required AppSettings settings,
    required ZReportData d,
    ZCloseRecord? closed,
  }) async {
    await _ensureFonts();
    final money = settings.money;
    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: _fontRegular!, bold: _fontBold!),
    );

    final dateLabel =
        '${d.day.year}-${d.day.month.toString().padLeft(2, '0')}-${d.day.day.toString().padLeft(2, '0')}';
    final generatedAt = DateTime.now();

    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(36),
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          // ---- header ----
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(settings.shopName,
                      style: pw.TextStyle(
                          fontSize: 15, fontWeight: pw.FontWeight.bold)),
                  if (settings.shopAddress.isNotEmpty)
                    pw.Text(settings.shopAddress,
                        style: const pw.TextStyle(fontSize: 8.5)),
                  if (settings.shopPhone.isNotEmpty)
                    pw.Text('Tel: ${settings.shopPhone}',
                        style: const pw.TextStyle(fontSize: 8.5)),
                ],
              ),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text('Z-REPORT · DAY CLOSE',
                      style: pw.TextStyle(
                          fontSize: 13, fontWeight: pw.FontWeight.bold)),
                  pw.Text('Business day $dateLabel',
                      style: const pw.TextStyle(fontSize: 9)),
                  pw.Text(
                      'Printed ${generatedAt.year}-${generatedAt.month.toString().padLeft(2, '0')}-${generatedAt.day.toString().padLeft(2, '0')} '
                      '${generatedAt.hour.toString().padLeft(2, '0')}:${generatedAt.minute.toString().padLeft(2, '0')}',
                      style: const pw.TextStyle(
                          fontSize: 8, color: PdfColors.grey600)),
                ],
              ),
            ],
          ),
          pw.Divider(),

          if (closed != null)
            pw.Container(
              margin: const pw.EdgeInsets.only(bottom: 10),
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.green),
                color: PdfColors.green50,
              ),
              child: pw.Text(
                'CLOSED — by ${closed.closedBy} at '
                '${DateTime.fromMillisecondsSinceEpoch(closed.closedAt * 1000).toString().substring(0, 16)}. '
                'Snapshot net ${money(closed.net)} · ${closed.orders} orders.',
                style: const pw.TextStyle(fontSize: 9),
              ),
            ),

          // ---- takings ----
          pw.Text('TAKINGS',
              style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 4),
          _row('Gross sales (${d.orders} orders)', money(d.gross)),
          if (d.discounts > 0) _row('Discounts given', '− ${money(d.discounts)}'),
          if (d.tax > 0) _row('Tax collected', money(d.tax)),
          if (d.refundCount > 0)
            _row('Refunds (${d.refundCount})', '− ${money(d.refundTotal)}'),
          pw.Divider(),
          _row('NET TAKINGS', money(d.net), bold: true),
          _row('Items sold', '${d.itemsSold}'),
          if (d.grossProfit != null)
            _row('Estimated cost of goods', '− ${money(d.cogs)}'),
          if (d.grossProfit != null)
            _row('Estimated gross profit', money(d.net - d.cogs), bold: true),
          pw.SizedBox(height: 12),

          // ---- payments ----
          if (d.payments.isNotEmpty) ...[
            pw.Text('PAYMENT METHODS',
                style: pw.TextStyle(
                    fontSize: 10, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 4),
            _table([
              _head3('Method', 'Orders', 'Total'),
              for (final p in d.payments)
                _row3(_methodLabel(p.method), '${p.orders}', money(p.total)),
            ]),
            pw.SizedBox(height: 12),
          ],

          // ---- cash reconciliation (when a count was taken at close) ----
          if (closed?.countedCash != null) ...[
            pw.Text('CASH RECONCILIATION',
                style: pw.TextStyle(
                    fontSize: 10, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 4),
            _row('Cash sales', money(d.cashIn)),
            if (d.cashRefunds > 0)
              _row('Cash refunds', '− ${money(d.cashRefunds)}'),
            _row('Expected in drawer', money(d.expectedCash)),
            _row('Counted at close', money(closed!.countedCash!)),
            pw.Divider(),
            _row(
              'VARIANCE',
              closed.variance! == 0
                  ? '0.00 — balanced'
                  : '${closed.variance! > 0 ? '+' : '−'}${money(closed.variance!.abs())}',
              bold: true,
            ),
            pw.SizedBox(height: 12),
          ],

          // ---- staff ----
          if (d.staff.isNotEmpty) ...[
            pw.Text('BY STAFF',
                style: pw.TextStyle(
                    fontSize: 10, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 4),
            _table([
              _head3('Cashier', 'Orders', 'Revenue'),
              for (final s in d.staff)
                _row3(s.name, '${s.orders}', money(s.revenue)),
            ]),
            pw.SizedBox(height: 12),
          ],

          // ---- top items ----
          if (d.topItems.isNotEmpty) ...[
            pw.Text('BEST SELLERS',
                style: pw.TextStyle(
                    fontSize: 10, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 4),
            _table([
              _head3('Item', 'Units', 'Revenue'),
              for (final t in d.topItems)
                _row3(t.name, '${t.units}', money(t.revenue)),
            ]),
          ],

          pw.Spacer(),
          pw.Divider(),
          pw.Text(
            'Counts taken at day close are binding; refunds processed after '
            'closing appear on the next day\'s report. Powered by Sami.',
            textAlign: pw.TextAlign.center,
            style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey600),
          ),
        ],
      ),
    ));

    return doc.save();
  }

  static String _methodLabel(String m) => switch (m) {
        'cash' => 'Cash',
        'card' => 'Card',
        'mobile' => 'Mobile money',
        _ => m[0].toUpperCase() + m.substring(1),
      };
}
