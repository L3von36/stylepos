import 'dart:convert' show utf8;
import 'dart:io' show File, Platform;
import 'dart:typed_data' show Uint8List;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Minimal RFC-4180-ish CSV toolkit shared by the import/export features:
/// quoting-aware parser, escaping, and the 3-platform file save/download.
class CsvUtil {
  CsvUtil._();

  /// Escapes a field per RFC 4180 (quote wrapping when needed).
  static String escape(String v) {
    if (v.contains(',') || v.contains('"') || v.contains('\n') || v.contains('\r')) {
      return '"${v.replaceAll('"', '""')}"';
    }
    return v;
  }

  /// Parses CSV text into rows of fields. Handles quoted fields containing
  /// commas / quotes / newlines, CRLF and LF, and a trailing newline.
  static List<List<String>> parse(String text) {
    final rows = <List<String>>[];
    final field = StringBuffer();
    var row = <String>[];
    var inQuotes = false;
    var i = 0;

    void endField() {
      row.add(field.toString());
      field.clear();
    }

    void endRow() {
      endField();
      // Skip fully-empty trailing rows (e.g. final newline).
      if (row.length > 1 || row.first.trim().isNotEmpty) rows.add(row);
      row = <String>[];
    }

    while (i < text.length) {
      final ch = text[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i += 2;
            continue;
          }
          inQuotes = false;
          i++;
          continue;
        }
        field.write(ch);
        i++;
        continue;
      }
      if (ch == '"') {
        inQuotes = true;
        i++;
      } else if (ch == ',') {
        endField();
        i++;
      } else if (ch == '\r') {
        // CRLF (or stray CR) ends the row.
        if (i + 1 < text.length && text[i + 1] == '\n') i++;
        endRow();
        i++;
      } else if (ch == '\n') {
        endRow();
        i++;
      } else {
        field.write(ch);
        i++;
      }
    }
    if (field.isNotEmpty || row.isNotEmpty) endRow();
    return rows;
  }

  /// Case-insensitive header lookup: returns column indexes keyed by the
  /// canonical header names the caller asks for. Unknown headers are
  /// ignored; missing ones map to -1.
  static Map<String, int> headerIndex(List<String> header, List<String> wanted) {
    final lower = [for (final h in header) h.trim().toLowerCase()];
    return {for (final w in wanted) w: lower.indexOf(w.toLowerCase())};
  }

  /// Saves/downloads [name] with [data]: browser download on web, share
  /// sheet on phones, save dialog on desktop. Returns a user-facing result
  /// message, or null when the user cancelled.
  static Future<String?> saveFile({
    required String name,
    required Uint8List data,
    String mime = 'text/csv',
  }) async {
    if (kIsWeb) {
      await XFile.fromData(data, mimeType: mime, name: name).saveTo(name);
      return 'Downloaded';
    }
    if (Platform.isAndroid || Platform.isIOS) {
      final dir = await getTemporaryDirectory();
      final f = File(p.join(dir.path, name));
      await f.writeAsBytes(data, flush: true);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(f.path, mimeType: mime)],
        subject: name,
        text: name,
      ));
      return 'Shared';
    }
    final loc = await getSaveLocation(suggestedName: name);
    if (loc == null) return null;
    await File(loc.path).writeAsBytes(data, flush: true);
    return 'Saved to ${loc.path}';
  }

  static Uint8List encodeUtf8(String text) => Uint8List.fromList(utf8.encode(text));
}
