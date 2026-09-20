import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../core/app_log.dart';

/// Long-edge cap for stored product photos. 1280px reads crisply on the
/// Sell-tab tiles, list rows and Windows cards (nothing renders above
/// ~400px) while keeping files around 100–250 KB.
const int kPhotoMaxEdge = 1280;

/// JPEG quality for stored product photos (matches the old picker value).
const int kPhotoJpegQuality = 82;

/// Deterministic photo compression for product photos on EVERY platform.
///
/// The picker-side `imageQuality`/`maxWidth` is only a first pass — mobile
/// camera picks honour it, but desktop file dialogs (file_selector) hand
/// over the raw file, and a 6 MB photo per product would bloat backups and
/// the cloud mirror. This step guarantees the budget:
///
///   1. decode (jpg / png / webp / gif — whatever the user picked),
///   2. downscale so the long edge <= [maxEdge] (never upscales),
///   3. flatten transparency onto white and re-encode as JPEG [quality],
///   4. keep the ORIGINAL bytes when the result is not actually smaller
///      (already-tiny images are left alone — recompression never grows
///      the file).
///
/// Returns the compressed bytes, or null when the input is not an image,
/// cannot be decoded, or compression would not help — the caller should
/// store the original bytes then. Runs on the main isolate (same trade-off
/// the receipt-logo import already makes): a 12 MP photo costs a fraction
/// of a second once per pick, acceptable for a user-triggered action.
Future<Uint8List?> compressPhoto(
  Uint8List bytes, {
  int maxEdge = kPhotoMaxEdge,
  int quality = kPhotoJpegQuality,
}) async {
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      AppLog.d('photo/compress', 'not a decodable image — keeping original');
      return null;
    }

    final longEdge = math.max(decoded.width, decoded.height);
    final resized = longEdge > maxEdge
        ? img.copyResize(
            decoded,
            width: decoded.width >= decoded.height ? maxEdge : null,
            height: decoded.height > decoded.width ? maxEdge : null,
          )
        : decoded;

    final encoded = Uint8List.fromList(img.encodeJpg(resized, quality: quality));
    if (encoded.length >= bytes.length) {
      AppLog.d('photo/compress',
          'original already smaller (${bytes.length}B) — keeping it');
      return null;
    }

    AppLog.d('photo/compress',
        '${decoded.width}x${decoded.height} ${bytes.length}B -> '
        '${resized.width}x${resized.height} ${encoded.length}B');
    return encoded;
  } catch (e, s) {
    // Compression is an optimisation — never let it break a photo pick.
    AppLog.w('photo/compress failed — keeping original', e, s);
    return null;
  }
}
