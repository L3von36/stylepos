import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

import '../widgets/ui.dart';
import 'photo_store.dart';

export 'photo_store.dart'
    show photoExists, photoPath, photoReadBytes, photoSave;

/// Offline product-photo pipeline.
///
/// Photos are picked with the system camera/gallery on phones
/// (image_picker), a file dialog on desktop (file_selector) or the
/// browser file picker on web — then stored by [ProductImages]'s
/// platform store: files under `<app support>/product_images/` on
/// native devices, data URLs inside the local database on web.
/// Only the relative ref is stored in the database, so it stays
/// portable.
class ProductImages {
  /// Resolves the images folder once at startup (IO only; no-op on web).
  static Future<void> init() => ensureInit();

  /// Full path for a stored relative filename (IO; empty on web).
  static String path(String relativeName) => photoPath(relativeName);

  /// Opens a picker and stores the chosen photo. Returns the ref to
  /// persist on the product, or null when cancelled.
  static Future<String?> pick(BuildContext context) async {
    try {
      XFile? picked;
      if (kIsWeb) {
        // Browser: image_picker serves the native file picker.
        picked = await ImagePicker().pickImage(
          source: ImageSource.gallery, // ignored by the web implementation
          imageQuality: 82,
          maxWidth: 1600,
        );
      } else if (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS) {
        // Phones: let the user choose camera or gallery.
        final source = await showModalBottomSheet<ImageSource>(
          context: context,
          backgroundColor: AppColors.surface,
          shape: const RoundedRectangleBorder(
            borderRadius:
                BorderRadius.vertical(top: Radius.circular(28)),
          ),
          builder: (sheetContext) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 20),
                Text('Add product photo',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink)),
                const SizedBox(height: 4),
                Text(
                    'Photos show on the sell screen so staff find items faster.',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.muted)),
                const SizedBox(height: 12),
                ListTile(
                  leading: Icon(Icons.photo_camera_outlined,
                      color: AppColors.primary),
                  title: const Text('Take a photo'),
                  onTap: () =>
                      Navigator.pop(sheetContext, ImageSource.camera),
                ),
                ListTile(
                  leading: Icon(Icons.photo_library_outlined,
                      color: AppColors.primary),
                  title: const Text('Choose from gallery'),
                  onTap: () =>
                      Navigator.pop(sheetContext, ImageSource.gallery),
                ),
                ListTile(
                  leading: Icon(Icons.close_rounded,
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
      } else {
        // Desktop: native open-file dialog.
        picked = await openFile(
          acceptedTypeGroups: const [
            XTypeGroup(
              label: 'Images',
              extensions: ['jpg', 'jpeg', 'png', 'webp'],
            ),
          ],
        );
      }
      if (picked == null) return null;

      final bytes = await picked.readAsBytes();
      var ext = p.extension(picked.name).toLowerCase();
      if (ext.isEmpty || ext.length > 5) ext = '.jpg';
      final name = 'img_${DateTime.now().millisecondsSinceEpoch}$ext';
      return await photoSave(name, bytes);
    } catch (_) {
      // Picker unavailable / permission denied — treat as cancelled.
      return null;
    }
  }

  /// Deletes a stored photo (best effort) after it was replaced.
  static Future<void> delete(String ref) => photoDelete(ref);
}
