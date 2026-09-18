import 'dart:io' show File, Directory;

import 'dart:typed_data';

import 'package:flutter/painting.dart' show FileImage, ImageProvider, ResizeImage;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const String kImagesDirName = 'product_images';
String? _baseDir;

Future<void> ensureInit() async {
  if (_baseDir != null) return;
  final support = await getApplicationSupportDirectory();
  final dir = Directory(p.join(support.path, kImagesDirName));
  if (!dir.existsSync()) dir.createSync(recursive: true);
  _baseDir = dir.path;
}

String photoPath(String ref) {
  if (ref.startsWith('data:')) return '';
  return p.join(_baseDir ?? '', ref);
}

bool photoExists(String ref) {
  if (ref.startsWith('data:')) return true;
  try {
    return File(photoPath(ref)).existsSync();
  } catch (_) {
    return false;
  }
}

Uint8List? photoReadBytes(String ref) {
  try {
    final f = File(photoPath(ref));
    if (!f.existsSync()) return null;
    return f.readAsBytesSync();
  } catch (_) {
    return null;
  }
}

Future<String> photoSave(String name, Uint8List bytes) async {
  await ensureInit();
  final dir = Directory(_baseDir!);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  await File(p.join(_baseDir!, name)).writeAsBytes(bytes, flush: true);
  return name;
}

Future<void> photoDelete(String ref) async {
  try {
    final f = File(photoPath(ref));
    if (f.existsSync()) f.deleteSync();
  } catch (_) {// Best effort only — orphaned files are harmless.
  }
}

ImageProvider? photoProvider(String ref, {int? cacheWidth}) {
  try {
    final f = File(photoPath(ref));
    if (!f.existsSync()) return null;
    final base = FileImage(f);
    if (cacheWidth == null) return base;
    return ResizeImage(base, width: cacheWidth, allowUpscaling: false);
  } catch (_) {
    return null;
  }
}
