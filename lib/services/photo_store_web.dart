import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/painting.dart' show ImageProvider, MemoryImage;

/// Web storage: product photos are kept directly in the SQLite database
/// as `data:` URLs (the local SQLite lives in IndexedDB via
/// sqflite_common_ffi_web). No filesystem is involved.
const String kImagesDirName = 'product_images';

Future<void> ensureInit() async {}

String photoPath(String ref) => '';

bool photoExists(String ref) => ref.startsWith('data:');

Uint8List? photoReadBytes(String ref) {
  if (!ref.startsWith('data:')) return null;
  final i = ref.indexOf(',');
  if (i < 0 || i == ref.length - 1) return null;
  try {
    return base64Decode(ref.substring(i + 1));
  } catch (_) {
    return null;
  }
}

Future<String> photoSave(String name, Uint8List bytes) async {
  return 'data:${_sniffMime(bytes)};base64,${base64Encode(bytes)}';
}

Future<void> photoDelete(String ref) async {}

ImageProvider? photoProvider(String ref, {int? cacheWidth}) {
  final bytes = photoReadBytes(ref);
  if (bytes == null || bytes.isEmpty) return null;
  return MemoryImage(bytes);
}

String _sniffMime(Uint8List b) {
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    return 'image/png';
  }
  if (b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return 'image/webp';
  }
  return 'image/jpeg';
}
