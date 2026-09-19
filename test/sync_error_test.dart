import 'package:flutter_test/flutter_test.dart';
import 'package:stylepos/services/sync_service.dart';

void main() {
  group('SyncService.friendlySyncError', () {
    test('decodes RLS rejection (42501) into plain language', () {
      const e =
          'PostgrestException(message: new row violates row-level security '
          'policy for table "sales", code: 42501, details: n/a)';
      final msg = SyncService.friendlySyncError('push sales', e);
      expect(msg, startsWith('push sales:'));
      expect(msg, contains('blocked'));
      expect(msg, isNot(contains('PostgrestException')));
    });

    test('decodes duplicate-key as a merge notice', () {
      const e = 'PostgrestException(message: duplicate key value violates '
          'unique constraint "sales_device_receipt_uq", code: 23505)';
      final msg = SyncService.friendlySyncError('push sales', e);
      expect(msg, contains('already exists'));
    });

    test('decodes foreign-key as a retry notice', () {
      const e = 'PostgrestException(message: insert or update on table '
          '"sale_items" violates foreign key constraint, code: 23503)';
      final msg = SyncService.friendlySyncError('push sale items', e);
      expect(msg, contains('related record'));
    });

    test('decodes schema-cache drift as a patch reminder', () {
      const e = 'PostgrestException(message: Could not find the \'promo_code\' '
          'column of \'sales\' in the schema cache, code: PGRST204)';
      final msg = SyncService.friendlySyncError('push sales', e);
      expect(msg, contains('schema patch'));
    });

    test('decodes network hiccups as an auto-retry notice', () {
      final msg = SyncService.friendlySyncError(
          'pull variants', 'ClientException: Connection closed before full '
          'header was received');
      expect(msg, contains('network hiccup'));
    });

    test('falls back to the raw first line for unknown errors', () {
      final msg = SyncService.friendlySyncError(
          'push suppliers', 'Some totally novel failure\nsecond line');
      expect(msg, 'push suppliers: Some totally novel failure');
    });
  });
}
