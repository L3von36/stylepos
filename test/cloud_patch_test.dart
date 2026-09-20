import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stylepos/services/cloud_patch.dart';

/// The in-app "Copy fix SQL" button and the repo's SQL file must NEVER
/// drift apart — the Manager copies exactly what Support/docs point at.
void main() {
  test('embedded cloud fix SQL is byte-identical to scripts/sql/cloud_fix.sql',
      () {
    final f = File('scripts/sql/cloud_fix.sql');
    expect(f.existsSync(), isTrue,
        reason: 'run flutter test from the project root');
    expect(f.readAsStringSync(), kCloudFixSql);
  });

  test('fix SQL covers every known cloud schema gap', () {
    // stock movements device tag (the reported "push movements" failure)
    expect(kCloudFixSql, contains('add column if not exists device_id text'));
    // promo columns on sales
    expect(kCloudFixSql, contains('add column if not exists promo_code text'));
    expect(kCloudFixSql,
        contains('add column if not exists promo_discount double precision'));
    // whole optional tables the app syncs
    for (final t in ['promotions', 'suppliers', 'purchase_orders',
        'purchase_order_items', 'commissions', 'attendance']) {
      expect(kCloudFixSql,
          contains(RegExp('create table if not exists public\\.$t')));
    }
    // realtime joins must not break re-runs
    expect(kCloudFixSql, contains('exception when others then null'));
  });

  test('fix SQL covers the multi-branch RPCs (patch 6 + 7)', () {
    // branch tree column + visibility
    expect(kCloudFixSql,
        contains('add column if not exists parent_shop_id'));
    expect(kCloudFixSql, contains('my_root_shop_id'));
    // Branches.create / Branches.switchTo call these RPCs by name
    expect(kCloudFixSql, contains('create or replace function public.create_branch'));
    expect(kCloudFixSql, contains('create or replace function public.switch_to_shop'));
    // Reports -> Branch sales overview (owner's cross-branch totals)
    expect(kCloudFixSql,
        contains('create or replace function public.branch_sales_overview'));
    // grants so the app's authenticated session can actually call them
    expect(kCloudFixSql,
        contains('grant execute on function public.branch_sales_overview'));
  });
}
