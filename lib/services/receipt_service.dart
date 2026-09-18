import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/sale.dart';
import '../state/settings.dart';

/// Generates 80mm roll-style PDF receipts, saves them to disk and
/// opens the platform print dialog.
class ReceiptService {
  static pw.Font? _fontRegular;
  static pw.Font? _fontBold;

  static Future<void> _ensureFonts() async {
    if (_fontRegular != null) return;
    final reg = await rootBundle.load('assets/fonts/Carlito-Regular.ttf');
    final bold = await rootBundle.load('assets/fonts/Carlito-Bold.ttf');
    _fontRegular = pw.Font.ttf(reg);
    _fontBold = pw.Font.ttf(bold);
  }

  /// Builds the PDF bytes for a receipt.
  static Future<Uint8List> buildPdf({
    required Sale sale,
    required List<SaleItem> items,
    required AppSettings settings,
    required int pointsEarned,
  }) async {
    await _ensureFonts();
    final doc = pw.Document(
      theme: pw.ThemeData.withFont(
        base: _fontRegular!,
        bold: _fontBold!,
      ),
    );

    final dateStr = _fmtDateTime(sale.createdAt);
    final money = settings.money;

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.roll80,
        build: (context) {
          final header = pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.Text(
                settings.shopName,
                style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
                textAlign: pw.TextAlign.center,
              ),
              if (settings.shopAddress.trim().isNotEmpty)
                pw.Text(settings.shopAddress,
                    style: const pw.TextStyle(fontSize: 8), textAlign: pw.TextAlign.center),
              if (settings.shopPhone.trim().isNotEmpty)
                pw.Text('Tel: ${settings.shopPhone}',
                    style: const pw.TextStyle(fontSize: 8)),
              pw.SizedBox(height: 6),
              pw.Divider(),
              pw.SizedBox(height: 2),
            ],
          );

          final meta = pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _row('Receipt', sale.receiptNo, boldValue: true),
              _row('Date', dateStr),
              _row('Served by', sale.cashierName ?? '-'),
              if (sale.customerName != null && sale.customerName!.isNotEmpty)
                _row('Customer', sale.customerName!),
              pw.SizedBox(height: 4),
              pw.Divider(),
            ],
          );

          final itemRows = items.map((it) => pw.TableRow(children: [
                pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(vertical: 2),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(it.productName, style: pw.TextStyle(fontSize: 9)),
                      if (it.variantDesc != 'Standard')
                        pw.Text(it.variantDesc,
                            style: const pw.TextStyle(
                                fontSize: 7, color: PdfColors.grey700)),
                    ],
                  ),
                ),
                pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(vertical: 2),
                  child: pw.Text('${it.qty}',
                      style: pw.TextStyle(fontSize: 9),
                      textAlign: pw.TextAlign.right),
                ),
                pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(vertical: 2),
                  child: pw.Text(money(it.unitPrice),
                      style: pw.TextStyle(fontSize: 9),
                      textAlign: pw.TextAlign.right),
                ),
                pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(vertical: 2),
                  child: pw.Text(money(it.lineTotal),
                      style: pw.TextStyle(fontSize: 9),
                      textAlign: pw.TextAlign.right),
                ),
              ]));

          final itemsTable = pw.Table(
            columnWidths: const {
              0: pw.FlexColumnWidth(4),
              1: pw.FlexColumnWidth(1),
              2: pw.FlexColumnWidth(2.4),
              3: pw.FlexColumnWidth(2.4),
            },
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(
                    border: pw.Border(bottom: pw.BorderSide(color: PdfColors.grey600))),
                children: [
                  pw.Text('ITEM', style: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold)),
                  pw.Text('QTY', style: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold),
                      textAlign: pw.TextAlign.right),
                  pw.Text('PRICE', style: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold),
                      textAlign: pw.TextAlign.right),
                  pw.Text('TOTAL', style: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold),
                      textAlign: pw.TextAlign.right),
                ],
              ),
              ...itemRows,
            ],
          );

          final totals = pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.SizedBox(height: 4),
              pw.Divider(),
              _row('Subtotal', money(sale.subtotal)),
              if (sale.discount > 0) _row('Discount', '-${money(sale.discount)}'),
              if (sale.tax > 0) _row('Tax', money(sale.tax)),
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 3),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('TOTAL',
                        style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
                    pw.Text(money(sale.total),
                        style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
                  ],
                ),
              ),
              _row('Payment', _paymentLabel(sale.paymentMethod)),
              if (sale.paymentMethod == 'cash') ...[
                _row('Tendered', money(sale.amountPaid)),
                if (sale.changeDue > 0) _row('Change', money(sale.changeDue)),
              ],
              if (pointsEarned > 0)
                _row('Points earned', '+$pointsEarned',
                    boldValue: true),
              pw.SizedBox(height: 6),
              pw.Divider(),
              if (sale.isRefunded)
                pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 4),
                  child: pw.Text('*** REFUNDED ***',
                      style: pw.TextStyle(
                          fontSize: 11,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.red700),
                      textAlign: pw.TextAlign.center),
                ),
              pw.Text(
                settings.receiptFooter,
                style: const pw.TextStyle(fontSize: 8),
                textAlign: pw.TextAlign.center,
              ),
              pw.SizedBox(height: 2),
              pw.Text('Powered by Sami',
                  style: const pw.TextStyle(fontSize: 6.5, color: PdfColors.grey600),
                  textAlign: pw.TextAlign.center),
            ],
          );

          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [header, meta, itemsTable, totals],
          );
        },
      ),
    );

    return doc.save();
  }

  /// Saves the receipt PDF to the device. Returns the created file.
  static Future<File> savePdf(Uint8List bytes, String receiptNo) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'Sami Receipts'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File(p.join(dir.path, '$receiptNo.pdf'));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Opens the OS print dialog for the receipt.
  static Future<void> printPdf(Uint8List bytes) async {
    await Printing.layoutPdf(onLayout: (_) async => bytes);
  }

  /// Share sheet (mobile) for the saved receipt file.
  static Future<void> sharePdf(File file) async {
    await Printing.sharePdf(bytes: await file.readAsBytes(), filename: p.basename(file.path));
  }

  static String _paymentLabel(String method) {
    switch (method) {
      case 'card':
        return 'Card';
      case 'mobile':
        return 'Mobile money';
      default:
        return 'Cash';
    }
  }

  static String _fmtDateTime(int epochSeconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}/${two(dt.month)}/${dt.year} ${two(dt.hour)}:${two(dt.minute)}';
  }

  static pw.Widget _row(String label, String value, {bool boldValue = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 0.5),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label, style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey800)),
          pw.Text(value,
              style: pw.TextStyle(
                  fontSize: 8.5,
                  fontWeight: boldValue ? pw.FontWeight.bold : pw.FontWeight.normal)),
        ],
      ),
    );
  }
}
