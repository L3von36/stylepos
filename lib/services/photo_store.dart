/// Platform-split product-photo storage.
///
///   IO (Android / Windows / macOS / Linux): photos live as files inside
///   `<app support>/product_images/`, the DB stores the relative filename.
///   Web: there is no filesystem, so the DB stores the photo itself as a
///   compact `data:` URL. Both platforms are handled behind this facade.
library;

import 'dart:typed_data';

import 'package:flutter/painting.dart' show ImageProvider;

import 'photo_store_io.dart'
    if (dart.library.js_interop) 'photo_store_web.dart' as impl;

/// Initializes the underlying store (resolves the images folder on IO).
Future<void> ensureInit() => impl.ensureInit();

/// Debug/IO path for a stored ref (empty string on web).
String photoPath(String ref) => impl.photoPath(ref);

/// True when [ref] can be read back.
bool photoExists(String ref) => impl.photoExists(ref);

/// Raw bytes of a stored photo, or null when unavailable.
Uint8List? photoReadBytes(String ref) => impl.photoReadBytes(ref);

/// Persists [bytes]; returns the ref to store in the database.
Future<String> photoSave(String name, Uint8List bytes) =>
    impl.photoSave(name, bytes);

/// Best-effort delete.
Future<void> photoDelete(String ref) => impl.photoDelete(ref);

/// An ImageProvider for the stored photo, or null when unavailable.
ImageProvider? photoProvider(String ref, {int? cacheWidth}) =>
    impl.photoProvider(ref, cacheWidth: cacheWidth);
