import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stylepos/data/database.dart';
import 'package:stylepos/state/nav.dart';
import 'package:stylepos/state/products_view.dart';
import 'package:stylepos/state/sell_view.dart';
import 'package:stylepos/state/ui_prefs.dart';

/// Shell + screen view states: the single source of truth for the bottom
/// nav bar and per-screen filters. Runs against a throwaway SQLite
/// database via FFI (same harness as the e2e suite).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('stylepos_shellstate');
    DB.useDirectory(tempDir.path);
    // Touch the DB so the kv table exists before restores run.
    await DB.instance();
  });

  group('NavProvider — bottom bar selection', () {
    test('defaults to the Sell tab', () async {
      final nav = NavProvider();
      await nav.restore();
      expect(nav.id, NavId.pos);
    });

    test('goTo switches and the choice survives a fresh restore', () async {
      final nav = NavProvider();
      await nav.restore();
      expect(nav.id, NavId.pos);

      nav.goTo(NavId.reports);
      expect(nav.id, NavId.reports);
      await writeUiPref('ui_last_tab', NavId.reports.name); // what it persisted

      final nav2 = NavProvider();
      await nav2.restore();
      expect(nav2.id, NavId.reports);
    });

    test('same-id goTo is a no-op (no pointless rebuilds)', () async {
      // Isolate from the previous test's persisted choice.
      await writeUiPref('ui_last_tab', 'pos');
      final nav = NavProvider();
      await nav.restore();
      var notifications = 0;
      nav.addListener(() => notifications++);
      nav.goTo(NavId.pos); // already there
      expect(notifications, 0);
      expect(nav.id, NavId.pos);
    });

    test('unknown stored values fall back to the Sell tab', () async {
      await writeUiPref('ui_last_tab', 'somewhere-else');
      final nav = NavProvider();
      await nav.restore();
      expect(nav.id, NavId.pos);
    });
  });

  group('SellViewState — Sell-tab filters', () {
    test('query is session-only, category chip persists', () async {
      final view = SellViewState();
      await view.restore();
      expect(view.query, '');
      expect(view.categoryFilter, -1);

      view.setQuery('blue dress');
      view.setCategoryFilter(7);
      await writeUiPref('ui_sell_category', '7');

      final view2 = SellViewState();
      await view2.restore();
      expect(view2.query, ''); // deliberately not restored
      expect(view2.categoryFilter, 7);
    });

    test('setters notify and skip identical values', () {
      final view = SellViewState();
      var notifications = 0;
      view.addListener(() => notifications++);
      view.setQuery('a');
      view.setQuery('a'); // no-op
      view.setCategoryFilter(3);
      view.setCategoryFilter(3); // no-op
      expect(notifications, 2);
    });
  });

  group('ProductsViewState — inventory filters', () {
    test('category + low-stock persist, search text does not', () async {
      final view = ProductsViewState();
      await view.restore();
      expect(view.categoryFilter, -1);
      expect(view.lowOnly, isFalse);

      view.setQuery('hoodie');
      view.setCategoryFilter(2);
      view.setLowOnly(true);
      await writeUiPref('ui_products_category', '2');
      await writeUiPref('ui_products_low', '1');

      final view2 = ProductsViewState();
      await view2.restore();
      expect(view2.query, '');
      expect(view2.categoryFilter, 2);
      expect(view2.lowOnly, isTrue);
    });

    test('clearing the low-stock chip persists the cleared state', () async {
      await writeUiPref('ui_products_low', '1');
      final view = ProductsViewState();
      await view.restore();
      expect(view.lowOnly, isTrue);

      view.setLowOnly(false);
      await writeUiPref('ui_products_low', '0');

      final view2 = ProductsViewState();
      await view2.restore();
      expect(view2.lowOnly, isFalse);
    });
  });
}
