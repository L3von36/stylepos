import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Minimal PDF text extractor for simple, server-generated receipt PDFs
/// (Dashen, Zemen, legacy CBE). Full PDF viewers use font metrics and
/// ToUnicode maps; these receipts only need the text runs in reading order,
/// which is enough for the label-slicing parsers.
///
/// Strategy: find every `stream … endstream` chunk whose dictionary says
/// `/FlateDecode`, inflate it, then walk the content stream and pull the
/// strings out of `Tj` / `'` / `"` / `[ … ] TJ` operators. Line moves
/// (Td / TD / T* / BT / ET) become newlines.

String extractPdfText(Uint8List bytes) {
  // latin-1 is byte-preserving, so string offsets == byte offsets.
  final file = latin1.decode(bytes, allowInvalid: true);
  final out = StringBuffer();

  var searchFrom = 0;
  while (true) {
    final streamAt = file.indexOf('stream', searchFrom);
    if (streamAt == -1) break;

    // The dictionary is the << … >> immediately before the stream keyword.
    final dictOpen = file.lastIndexOf('<<', streamAt);
    final dict = dictOpen == -1
        ? ''
        : file.substring(dictOpen, streamAt > dictOpen + 512 ? dictOpen + 512 : streamAt);

    // Data starts after the EOL that follows the `stream` keyword.
    var dataStart = streamAt + 'stream'.length;
    if (dataStart < file.length && file[dataStart] == '\r') dataStart++;
    if (dataStart < file.length && file[dataStart] == '\n') dataStart++;
    final dataEnd = file.indexOf('endstream', dataStart);
    if (dataEnd == -1) break;
    searchFrom = dataEnd + 'endstream'.length;

    final isText = dict.contains('/FlateDecode') ||
        (dict.contains('/Length') && !dict.contains('/Image') && !dict.contains('/DCTDecode'));
    if (!isText) continue;

    List<int>? inflated;
    final chunk = Uint8List.sublistView(bytes, dataStart, dataEnd);
    if (dict.contains('/FlateDecode')) {
      try {
        inflated = const ZLibDecoder().decodeBytes(chunk);
      } catch (_) {
        try {
          inflated = const ZLibDecoder().decodeBytes(chunk, raw: true);
        } catch (_) {
          inflated = null;
        }
      }
    } else {
      inflated = chunk;
    }
    if (inflated == null || inflated.isEmpty) continue;

    final content = latin1.decode(inflated, allowInvalid: true);
    final text = _textFromContentStream(content);
    if (text.trim().isNotEmpty) out.write(' $text');
  }

  // Space-join (not newline): these PDFs position every word separately, so
  // the goal is one long reading-order line — exactly what the label-slicing
  // receipt parsers (and pdf.js/unpdf, which cheki targets) expect.
  return out.toString().trim();
}

/// Walks a PDF content stream and returns the visible text as one long
/// reading-order line (word runs separated by spaces). Bank receipt parsers
/// slice labels across the whole string, so line structure is irrelevant —
/// matching unpdf/pdf.js's "one long line" output is what matters.
String _textFromContentStream(String content) {
  final out = <String>[];
  final cur = StringBuffer();

  void flush() {
    final s = cur.toString().trim();
    if (s.isNotEmpty) out.add(s);
    cur.clear();
  }

  // Pre-index operator keywords so we only scan each position once. We look
  // for whole-word operator tokens at the current index.
  bool isOp(int i, String op) {
    if (i + op.length > content.length) return false;
    if (content.substring(i, i + op.length) != op) return false;
    final before =
        i == 0 || _isTokenBoundary(content.codeUnitAt(i - 1));
    final afterIdx = i + op.length;
    final after = afterIdx >= content.length ||
        _isTokenBoundary(content.codeUnitAt(afterIdx));
    return before && after;
  }

  var i = 0;
  while (i < content.length) {
    final ch = content[i];

    if (ch == '(') {
      // Literal string with escapes and balanced nested parens.
      final sb = StringBuffer();
      var depth = 1;
      i++;
      while (i < content.length && depth > 0) {
        final c = content[i];
        if (c == '\\' && i + 1 < content.length) {
          final n = content[i + 1];
          switch (n) {
            case 'n':
              sb.write('\n');
            case 'r':
              sb.write('\r');
            case 't':
              sb.write('\t');
            case 'b':
            case 'f':
              break; // seldom meaningful in receipts
            case '0':
            case '1':
            case '2':
            case '3':
            case '4':
            case '5':
            case '6':
            case '7':
              var j = i + 1;
              var oct = '';
              while (j < content.length &&
                  oct.length < 3 &&
                  content.codeUnitAt(j) >= 0x30 &&
                  content.codeUnitAt(j) <= 0x37) {
                oct += content[j];
                j++;
              }
              sb.writeCharCode(int.parse(oct, radix: 8));
              i = j;
              continue;
            default:
              sb.write(n);
          }
          i += 2;
          continue;
        }
        if (c == '(') {
          depth++;
          sb.write(c);
        } else if (c == ')') {
          depth--;
          if (depth > 0) sb.write(c);
        } else {
          sb.write(c);
        }
        i++;
      }
      cur.write(sb);
      continue;
    }

    if (ch == '<') {
      if (i + 1 < content.length && content[i + 1] == '<') {
        i += 2; // dictionary operator inside a content stream (rare)
        continue;
      }
      final close = content.indexOf('>', i);
      if (close == -1) {
        i++;
        continue;
      }
      final hex = content
          .substring(i + 1, close)
          .replaceAll(RegExp(r'\s'), '')
          .replaceAll('<', '');
      if (hex.isNotEmpty && hex.length.isEven) {
        final bytes = List<int>.generate(
            hex.length ~/ 2, (k) => int.parse(hex.substring(k * 2, k * 2 + 2), radix: 16));
        cur.write(_decodeHexString(bytes));
      }
      i = close + 1;
      continue;
    }

    if (ch == '>' || ch == '[' || ch == ']' || ch == ')' || ch == ' ') {
      i++;
      continue;
    }

    // Operator keywords that end a text line.
    if (isOp(i, 'Td') || isOp(i, 'TD') || isOp(i, 'T*') || isOp(i, 'BT') || isOp(i, 'ET')) {
      flush();
      i++;
      continue;
    }
    // Text-showing ops just separate runs — no separator needed between the
    // string we already appended and the next one.
    if (isOp(i, 'Tj') || isOp(i, 'TJ')) {
      i += 2;
      continue;
    }
    i++;
  }
  flush();
  return out.join(' ');
}

bool _isTokenBoundary(int codeUnit) =>
    codeUnit <= 0x20 || codeUnit == 0x2F /* / */ || codeUnit == 0x3E /* > */;

/// Hex strings in these receipts are either 1-byte (WinAnsi) or 2-byte
/// (UTF-16BE) encoded — sniff by the high bytes.
String _decodeHexString(List<int> bytes) {
  var highZero = 0;
  for (final b in bytes) {
    if (b == 0) highZero++;
  }
  if (bytes.length >= 2 && highZero > bytes.length ~/ 3) {
    final sb = StringBuffer();
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final unit = (bytes[i] << 8) | bytes[i + 1];
      if (unit != 0) sb.writeCharCode(unit);
    }
    return sb.toString();
  }
  return latin1.decode(bytes, allowInvalid: true);
}
