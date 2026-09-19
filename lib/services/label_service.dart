import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/product.dart';
import '../state/settings.dart';

/// Paper layouts supported by the label printer dialog.
enum LabelPaper { a4, roll50x30 }

/// Renders printable barcode tag sheets for shop items.
///
/// Each tagged variant gets a sticker with the item name, size/color,
/// price and a scannable Code 128 barcode, so the sales person can ring
/// up any garment on the rack with one scan.
class LabelService {
  LabelService._();

  static const _mm = 2.83465; // points per millimetre

  static pw.Font? _fontRegular;
  static pw.Font? _fontBold;

  static Future<void> _ensureFonts() async {
    if (_fontRegular != null) return;
    final reg = await rootBundle.load('assets/fonts/Carlito-Regular.ttf');
    final bold = await rootBundle.load('assets/fonts/Carlito-Bold.ttf');
    _fontRegular = pw.Font.ttf(reg);
    _fontBold = pw.Font.ttf(bold);
  }

  /// Builds the label PDF. [entries] are `(product, variant, copies)`.
  static Future<Uint8List> build({
    required AppSettings settings,
    required List<(Product, ProductVariant, int)> entries,
    required LabelPaper paper,
  }) async {
    await _ensureFonts();
    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: _fontRegular!, bold: _fontBold!),
    );

    const base = pw.TextStyle(fontSize: 8);
    const bold = pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold);

    // Expand entries into ordered label cells.
    final cells = <(Product, ProductVariant)>[];
    for (final (p, v, copies) in entries) {
      for (var i = 0; i < copies; i++) {
        cells.add((p, v));
      }
    }

    pw.Widget label((Product, ProductVariant) cell) {
      final (p, v) = cell;
      final code = v.barcode?.trim().isNotEmpty == true ? v.barcode!.trim() : v.sku;
      return pw.Container(
        decoration: const pw.BoxDecoration(),
        padding: const pw.EdgeInsets.all(4),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            pw.Text(settings.shopName,
                style: base.copyWith(fontSize: 6.5, color: PdfColors.grey700),
                maxLines: 1,
                overflow: pw.TextOverflow.clip),
            pw.SizedBox(height: 1),
            pw.Text(p.name,
                style: bold, maxLines: 1, overflow: pw.TextOverflow.clip),
            pw.SizedBox(height: 1),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(v.descriptor,
                    style: base.copyWith(fontSize: 7.5),
                    maxLines: 1,
                    overflow: pw.TextOverflow.clip),
                pw.Text('${AppSettings.currencySymbol} ${v.price.toStringAsFixed(0)}',
                    style: bold.copyWith(fontSize: 8.5)),
              ],
            ),
            pw.SizedBox(height: 2),
            pw.Expanded(
              child: pw.BarcodeWidget(
                barcode: pw.Barcode.code128(),
                data: code,
                drawText: true,
                textStyle: base.copyWith(fontSize: 6.5),
              ),
            ),
          ],
        ),
      );
    }

    if (paper == LabelPaper.roll50x30) {
      // Thermal roll: one 50 x 30 mm label per page.
      for (final cell in cells) {
        doc.addPage(pw.Page(
          pageFormat: PdfPageFormat(50 * _mm, 30 * _mm),
          margin: const pw.EdgeInsets.all(2),
          build: (_) => label(cell),
        ));
      }
    } else {
      // A4 sticker sheets: 3 columns x 8 rows (65 x 33 mm cells).
      const cols = 3;
      const rows = 8;
      for (var pageStart = 0; pageStart < cells.length; pageStart += cols * rows) {
        final slice = cells.skip(pageStart).take(cols * rows).toList();
        doc.addPage(pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(8 * _mm),
          build: (_) => pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.6),
            children: [
              for (var r = 0; r < rows; r++)
                pw.TableRow(
                  children: [
                    for (var c = 0; c < cols; c++)
                      pw.SizedBox(
                        width: 65 * _mm,
                        height: 33 * _mm,
                        child: r * cols + c < slice.length
                            ? label(slice[r * cols + c])
                            : pw.SizedBox(),
                      ),
                  ],
                ),
            ],
          ),
        ));
      }
    }

    return doc.save();
  }
}
