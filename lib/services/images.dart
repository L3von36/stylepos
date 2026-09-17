import 'dart:io' show Directory, File, Platform;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../widgets/ui.dart';

/// Offline product-photo pipeline.
///
/// Photos are picked with the system camera/gallery on phones
/// (image_picker) or a file dialog on desktop (file_selector), then
/// copied into `<app support>/product_images/`. Only the relative
/// filename is stored in the database, so the DB stays portable.
class ProductImages {
  static const _dirName = 'product_images';
  static String? _baseDir;

  /// Resolves the images folder once at startup so widgets can turn a
  /// stored relative filename into a full path synchronously.
  static Future<void> init() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, _dirName));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _baseDir = dir.path;
  }

  /// Full path for a stored relative filename.
  static String path(String relativeName) =>
      p.join(_baseDir ?? '', relativeName);

  /// Opens a picker and stores the chosen photo. Returns the relative
  /// filename to persist on the product, or null when cancelled.
  static Future<String?> pick(BuildContext context) async {
    try {
      final XFile? picked;
      if (!Platform.isAndroid && !Platform.isIOS) {
        // Desktop: native open-file dialog.
        final file = await openFile(
          acceptedTypeGroups: const [
            XTypeGroup(
              label: 'Images',
              extensions: ['jpg', 'jpeg', 'png', 'webp'],
            ),
          ],
        );
        picked = file;
      } else {
        // Phones: let the user choose camera or gallery.
        final source = await showModalBottomSheet<ImageSource>(
          context: context,
          backgroundColor: Colors.white,
          shape: const RoundedRectangleBorder(
            borderRadius:
                BorderRadius.vertical(top: Radius.circular(28)),
          ),
          builder: (sheetContext) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 20),
                const Text('Add product photo',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink)),
                const SizedBox(height: 4),
                const Text(
                    'Photos show on the sell screen so staff find items faster.',
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.muted)),
                const SizedBox(height: 12),
                ListTile(
                  leading: const Icon(Icons.photo_camera_outlined,
                      color: AppColors.primary),
                  title: const Text('Take a photo'),
                  onTap: () =>
                      Navigator.pop(sheetContext, ImageSource.camera),
                ),
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined,
                      color: AppColors.primary),
                  title: const Text('Choose from gallery'),
                  onTap: () =>
                      Navigator.pop(sheetContext, ImageSource.gallery),
                ),
                ListTile(
                  leading: const Icon(Icons.close_rounded,
                      color: AppColors.muted),
                  title: const Text('Cancel'),
                  onTap: () => Navigator.pop(sheetContext),
                ),
              ],
            ),
          ),
        );
        if (source == null) return null;
        picked = await ImagePicker().pickImage(
          source: source,
          imageQuality: 82,
          maxWidth: 1600,
        );
      }
      if (picked == null) return null;

      final ext = p.extension(picked.path).toLowerCase();
      final name =
          'img_${DateTime.now().millisecondsSinceEpoch}$ext';
      await _ensureDir();
      await File(picked.path).copy(p.join(_baseDir!, name));
      return name;
    } catch (_) {
      // Picker unavailable / permission denied — treat as cancelled.
      return null;
    }
  }

  /// Deletes a stored photo (best effort) after it was replaced.
  static Future<void> delete(String relativeName) async {
    try {
      final f = File(path(relativeName));
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      // Best effort only — orphaned files are harmless.
    }
  }

  static Future<void> _ensureDir() async {
    if (_baseDir == null) await init();
    final dir = Directory(_baseDir!);
    if (!dir.existsSync()) dir.createSync(recursive: true);
  }
}
