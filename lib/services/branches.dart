import 'package:supabase_flutter/supabase_flutter.dart';

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
}
