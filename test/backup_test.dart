import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stylepos/data/database.dart';
import 'package:stylepos/services/backup_service.dart';

/// End-to-end backup/restore roundtrip against real SQLite (FFI) in
/// temporary directories, mirroring what the Settings buttons do.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory shopA;
  late Directory shopB;
  late Directory imgA;
  late Directory imgB;
  const markerEmail = 'backup-roundtrip@test.stylepos';

  setUp(() async {
    shopA = await Directory.systemTemp.createTemp('stylepos_backup_a');
    shopB = await Directory.systemTemp.createTemp('stylepos_backup_b');
    imgA = Directory(p.join(shopA.path, 'images'))..createSync(recursive: true);
    imgB = Directory(p.join(shopB.path, 'images'))..createSync(recursive: true);
  });

  tearDown(() async {
    await DB.closeAndReset();
    await shopA.delete(recursive: true);
    await shopB.delete(recursive: true);
  });

  test('export then restore preserves users and product photos', () async {
    // --- shop A: seed + one extra user + one product photo ---
    DB.useDirectory(shopA.path);
    final dbA = await DB.instance();
    await dbA.insert('users', {
      'name': 'Backup Check',
      'email': markerEmail,
      'pass_hash': 'x',
      'salt': 'y',
      'role': 'cashier',
      'active': 1,
      'created_at': 12345,
    });
    final photoBytes = [1, 2, 3, 42, 250, 128, 7];
    File(p.join(imgA.path, 'dress_red.jpg')).writeAsBytesSync(photoBytes);

    // --- export ---
    final zipPath = p.join(shopA.path, 'backup.stylepos');
    await BackupService.createBackup(
      outPath: zipPath,
      dbDirOverride: shopA.path,
      imagesDirOverride: imgA.path,
    );
    expect(File(zipPath).existsSync(), isTrue,
        reason: 'backup zip must be created');
    await DB.closeAndReset();

    // --- restore into an empty shop B ---
    DB.useDirectory(shopB.path);
    final salesCount = await BackupService.restoreBackup(
      zipPath,
      dbDirOverride: shopB.path,
      imagesDirOverride: imgB.path,
    );
    expect(salesCount, 0, reason: 'fresh shop has no sales');

    // restored database contains the marker user
    final dbB = await DB.instance();
    final found = await dbB
        .query('users', where: 'email = ?', whereArgs: [markerEmail]);
    expect(found, hasLength(1), reason: 'extra user must survive the roundtrip');

    // restored photo bytes are identical
    final restored = File(p.join(imgB.path, 'dress_red.jpg'));
    expect(restored.existsSync(), isTrue, reason: 'photo must be restored');
    expect(restored.readAsBytesSync(), photoBytes);

    // seeded catalog came along too (A was seeded on first open)
    final products = await dbB.query('products');
    expect(products, isNotEmpty,
        reason: 'seed products must be included in the backup');
  });

  test('restore rejects files that are not StylePOS backups', () async {
    final bogus = File(p.join(shopB.path, 'not-a-backup.stylepos'))
      ..writeAsStringSync('hello, this is text');
    DB.useDirectory(shopB.path);
    expect(
      () => BackupService.restoreBackup(
        bogus.path,
        dbDirOverride: shopB.path,
        imagesDirOverride: imgB.path,
      ),
      throwsA(isA<BackupException>()),
    );
  });
}
