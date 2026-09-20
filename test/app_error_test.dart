import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stylepos/core/app_log.dart';
import 'package:stylepos/core/errors.dart';

void main() {
  group('friendlyError — one calm sentence per failure family', () {
    test('AppException messages pass through untouched', () {
      const e = AppException(AppErrorKind.validation, 'Add a variant first.');
      expect(friendlyError(e), 'Add a variant first.');
    });

    test('network failures promise offline-safe sync', () {
      final msg = friendlyError(
          const SocketException('failed host lookup: supabase.co'));
      expect(msg, contains('offline'));
      expect(msg, contains('syncs'));
    });

    test('row-level-security errors point at the Manager, not SQL', () {
      final msg = friendlyError(Exception(
          'PostgrestException: new row violates row-level security policy '
          'for table "variants" (42501)'));
      expect(msg, contains('Manager'));
      expect(msg.toLowerCase(), isNot(contains('postgrest')));
      expect(msg, isNot(contains('42501')));
    });

    test('expired sessions ask for a fresh sign-in', () {
      final msg = friendlyError(Exception('PostgrestException: JWT expired (401)'));
      expect(msg, contains('session expired'));
    });

    test('unknown errors never leak internals', () {
      final msg = friendlyError(StateError('Bad state: no element'));
      expect(msg, 'Something went wrong — your sales are saved. Try again.');
    });

    test('storage failures suggest space/backup without stack traces', () {
      final msg = friendlyError(const FileSystemException('quota exceeded'));
      expect(msg, isNot(contains('FileSystemException')));
    });
  });

  group('ErrorCenter — the app-wide error sink', () {
    test('report advances seq and notifies listeners', () {
      final center = ErrorCenter.I;
      final seq0 = center.seq;
      var notified = 0;
      void listener() => notified++;
      center.addListener(listener);
      center.report('Test failure one');
      center.report('Test failure two');
      center.removeListener(listener);
      expect(notified, 2);
      expect(center.seq, seq0 + 2);
      expect(center.last, 'Test failure two');
    });

    test('reportError logs first, then surfaces the friendly mapping', () {
      final center = ErrorCenter.I;
      AppLog.reset();
      final seq0 = center.seq;
      center.reportError('test/subsystem', StateError('boom'));
      expect(center.seq, seq0 + 1);
      expect(center.last, 'Something went wrong — your sales are saved. Try again.');
      expect(AppLog.recent().first, contains('ERROR'));
      expect(AppLog.recent().first, contains('test/subsystem'));
    });
  });

  group('ErrorToaster — reports become floating SnackBars', () {
    testWidgets('shows a reported error once the UI is listening', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: ErrorToaster(child: SizedBox.expand())),
      ));
      ErrorCenter.I.report('Toaster check: sale saved offline');
      await tester.pumpAndSettle();
      expect(find.text('Toaster check: sale saved offline'), findsOneWidget);
    });
  });

  group('AppLog — bounded ring of recent entries', () {
    test('keeps newest first and respects the cap', () {
      AppLog.reset();
      for (var i = 0; i < 260; i++) {
        AppLog.d('test/loop', 'entry $i');
      }
      final recent = AppLog.recent();
      expect(recent.length, 40); // default window
      expect(recent.first, contains('entry 259'));
      expect(AppLog.recent(count: 300).length, 200); // hard ring cap
    });
  });
}
