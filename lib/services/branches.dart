import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/database.dart';
import 'audit.dart';
import 'cloud_auth.dart';

/// One shop in the manager's branch tree.
class BranchShop {
  final String id;
  final String code;
  final String name;
  final String? parentShopId;

  const BranchShop({
    required this.id,
    required this.code,
    required this.name,
    this.parentShopId,
  });

  factory BranchShop.fromMap(Map<String, dynamic> m) => BranchShop(
        id: m['id'] as String,
        code: (m['code'] as String?) ?? '',
        name: (m['name'] as String?) ?? 'Shop',
        parentShopId: m['parent_shop_id'] as String?,
      );

  bool get isBranch => parentShopId != null;
}

/// Multi-branch support: a manager runs several shops (branches) from one
/// account. Each branch is a fully separate workspace — its own catalog,
/// staff, sales and reports — and the manager hops between them.
///
/// Cloud side (patch 6): `shops.parent_shop_id`, `create_branch` and
/// `switch_to_shop` RPCs, branch-tree RLS. Switching moves the manager's
/// `app_users.shop_id`, so the same Supabase session immediately reads the
/// other branch through the existing RLS — the app then wipes its local
/// mirror and re-pulls (the same flow as "erase this device & re-pull").
class Branches {
  Branches._();

  static SupabaseClient get _c => Supabase.instance.client;

  /// The manager's branch tree: the current shop, its root, and every
  /// sibling branch. Empty when signed out / offline / single shop.
  static Future<List<BranchShop>> list() async {
    try {
      if (_c.auth.currentSession == null) return const [];
      final rows = await _c
          .from('shops')
          .select('id,code,name,parent_shop_id')
          .order('created_at');
      return [for (final r in rows) BranchShop.fromMap(Map.from(r as Map))];
    } catch (_) {
      return const [];
    }
  }

  /// Creates a branch of the current shop tree. Returns the new shop id or
  /// a user-facing error.
  static Future<(String?, String?)> create(String name,
      {int? actorUserId, String? actorName}) async {
    try {
      if (name.trim().isEmpty) return (null, 'Give the branch a name.');
      final id = await _c.rpc('create_branch',
          params: {'p_name': name.trim()});
      await Audit.add('branch_created',
          '${name.trim()} (id ${id.toString().substring(0, 8)}…)',
          userId: actorUserId, userName: actorName);
      return (id as String, null);
    } catch (e) {
      return (null, _friendly(e));
    }
  }

  /// Switches the manager into another branch of their tree. Wipes the
  /// local mirror and re-pulls the target branch's data. Returns null on
  /// success or a user-facing error.
  static Future<String?> switchTo(BranchShop target,
      {int? actorUserId, String? actorName}) async {
    try {
      final res = await _c.rpc('switch_to_shop',
          params: {'p_shop_id': target.id});
      final map = Map<String, dynamic>.from(res as Map);
      if (map['ok'] != true) return 'The cloud refused the switch.';

      await Audit.add('branch_switched',
          'Switched to ${target.name} (${target.code})',
          userId: actorUserId, userName: actorName);

      // Move the device's local mirror to the new branch: wipe everything,
      // remember the new shop, and re-pull. eraseLocalData() does exactly
      // that (wipeAllData -> resolveLegacyData(upload: true) -> sync).
      await CloudAuth.eraseLocalData();
      return null;
    } catch (e) {
      return _friendly(e);
    }
  }

  static String _friendly(Object e) {
    final msg = e.toString();
    if (msg.contains('Only a manager')) return 'Only a manager can do that.';
    if (msg.contains('not one of your branches')) {
      return 'That shop is not one of your branches.';
    }
    return 'Cloud error: ${msg.split('\n').first}';
  }

  /// Name of the branch this device mirrors right now, for labels on
  /// receipts, sale details and report headers — every sale in the local
  /// mirror belongs to this branch by construction (switching wipes the
  /// mirror). Prefers the remembered cloud shop name; falls back to the
  /// local shop name, then "Main shop".
  static Future<String> currentName() async {
    try {
      final db = await DB.instance();
      final rows = await db.query('settings',
          where: 'key IN (?, ?)', whereArgs: ['cloud_shop_name', 'shop_name']);
      String? cloud;
      String? local;
      for (final r in rows) {
        final v = (r['value'] as String?) ?? '';
        switch (r['key'] as String) {
          case 'cloud_shop_name':
            cloud = v;
          case 'shop_name':
            local = v;
        }
      }
      final name = (cloud != null && cloud.isNotEmpty) ? cloud : (local ?? '');
      return name.isEmpty ? 'Main shop' : name;
    } catch (_) {
      return 'Main shop';
    }
  }

  /// PostgREST's "no such function" family — the cloud predates the RPC
  /// (fix: run the latest fix SQL from the guided dialog).
  static bool isMissingRpcError(String msg) {
    final l = msg.toLowerCase();
    return l.contains('could not find the function') ||
        l.contains('pgrst202') ||
        l.contains('does not exist') ||
        l.contains('schema cache');
  }

  /// Cross-branch sales totals for the manager (root shop + every branch):
  /// completed revenue all-time and today. Returns `(rows, needsCloudFix)`;
  /// [needsCloudFix] is true when the cloud doesn't have
  /// `branch_sales_overview` yet and the caller should offer the guided
  /// fix-SQL dialog. Signed-out, offline or non-manager callers get an
  /// empty list — the card simply stays hidden.
  static Future<(List<BranchSales>, bool)> overview() async {
    try {
      if (_c.auth.currentSession == null) return (const <BranchSales>[], false);
      final now = DateTime.now();
      final midnight =
          DateTime(now.year, now.month, now.day).millisecondsSinceEpoch ~/
              1000;
      final rows = await _c.rpc('branch_sales_overview',
          params: {'p_today_epoch': midnight});
      return (
        <BranchSales>[
          for (final r in rows)
            BranchSales.fromMap(Map<String, dynamic>.from(r as Map))
        ],
        false
      );
    } catch (e) {
      if (isMissingRpcError(e.toString())) {
        return (const <BranchSales>[], true);
      }
      // Non-manager ("Only a manager…"), offline or transient — show nothing.
      return (const <BranchSales>[], false);
    }
  }
}

/// One branch's sales totals from the `branch_sales_overview` cloud RPC —
/// the owner's cross-branch answer to "who is selling, and where".
class BranchSales {
  final String id;
  final String name;
  final String code;
  final bool isCurrent;
  final int orders; // completed, all time
  final double revenue; // completed, all time
  final int todayOrders;
  final double todayRevenue;

  const BranchSales({
    required this.id,
    required this.name,
    required this.code,
    required this.isCurrent,
    required this.orders,
    required this.revenue,
    required this.todayOrders,
    required this.todayRevenue,
  });

  factory BranchSales.fromMap(Map<String, dynamic> m) => BranchSales(
        id: m['shop_id'] as String,
        name: (m['name'] as String?) ?? 'Branch',
        code: (m['code'] as String?) ?? '',
        isCurrent: m['is_current'] == true,
        orders: (m['all_orders'] as num?)?.toInt() ?? 0,
        revenue: (m['all_revenue'] as num?)?.toDouble() ?? 0,
        todayOrders: (m['today_orders'] as num?)?.toInt() ?? 0,
        todayRevenue: (m['today_revenue'] as num?)?.toDouble() ?? 0,
      );
}
