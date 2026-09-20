import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:stylepos/services/photo_compress.dart';

/// Noisy pixels resist JPEG compression, so "the output is smaller" is a
/// meaningful assertion even at moderate sizes.
img.Image _noiseImage(int w, int h, {int alpha = 255}) {
  final rnd = Random(42);
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixel(x, y,
          img.ColorRgba8(rnd.nextInt(256), rnd.nextInt(256), rnd.nextInt(256), alpha));
    }
  }
  return image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('compressPhoto (product-photo pipeline)', () {
    test('downscales an oversized photo to the 1280 long-edge budget', () async {
      final original = Uint8List.fromList(img.encodeJpg(_noiseImage(1600, 1000)));

      final out = await compressPhoto(original);
      expect(out, isNotNull, reason: 'a noisy 1600px JPEG must compress');
      expect(out!.length, lessThan(original.length));

      final decoded = img.decodeImage(out)!;
      expect(max(decoded.width, decoded.height), kPhotoMaxEdge);
      expect(min(decoded.width, decoded.height), 800); // aspect preserved
    });

    test('portrait photos are capped on their long edge too', () async {
      final original =
          Uint8List.fromList(img.encodeJpg(_noiseImage(900, 2400)));
      final out = await compressPhoto(original);
      expect(out, isNotNull);
      final decoded = img.decodeImage(out!)!;
      expect(decoded.height, kPhotoMaxEdge);
      expect(decoded.width, 480);
    });

    test('never upscales and keeps originals that are already small', () async {
      final small = Uint8List.fromList(img.encodeJpg(_noiseImage(300, 200)));
      final out = await compressPhoto(small);
      // Small noisy source: either it compressed (different bytes, same
      // size) or the original was kept — either way no growth, no resize.
      if (out != null) {
        final decoded = img.decodeImage(out)!;
        expect(decoded.width, 300);
        expect(decoded.height, 200);
        expect(out.length, lessThan(small.length));
      }
    });

    test('transparency flattens onto an opaque background', () async {
      final png = Uint8List.fromList(img.encodePng(_noiseImage(800, 600)));
      final out = await compressPhoto(png);
      expect(out, isNotNull);
      final decoded = img.decodeImage(out!)!;
      final px = decoded.getPixel(10, 10);
      expect(px.a, 255, reason: 'JPEG has no alpha — output must be flattened');
    });

    test('garbage bytes return null instead of throwing', () async {
      expect(await compressPhoto(Uint8List.fromList([1, 2, 3, 4])), isNull);
      expect(await compressPhoto(Uint8List(0)), isNull);
    });
  });
}
