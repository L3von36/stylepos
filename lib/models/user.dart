import 'dart:convert';

/// A staff account that can log into the POS.
/// Roles: `admin` (full access) and `cashier` (sell, view sales, manage customers).
///
/// Cashier [permissions] are granted by the Manager per person:
///  * `can_discount` — may apply manual discounts up to [discountCap]
///    (0 cap = unlimited) without a manager PIN at checkout;
///  * `can_refund`   — may refund a sale without a manager PIN;
///  * `commissionRate` — percent of net sale revenue earned as commission.
class AppUser {
  final int? id;
  final String name;
  final String email;
  final String role;
  final bool active;
  final int createdAt;

  /// JSON string as stored in `users.permissions`; null/empty = no grants.
  final String? permissions;
  final double commissionRate;

  const AppUser({
    this.id,
    required this.name,
    required this.email,
    required this.role,
    this.active = true,
    required this.createdAt,
    this.permissions,
    this.commissionRate = 0,
  });

  bool get isAdmin => role == 'admin';

  // ---- parsed permission helpers ------------------------------------------

  Map<String, Object?> get _perm {
    final raw = permissions?.trim() ?? '';
    if (raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, Object?> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  /// May apply manual discounts without manager approval…
  bool get canDiscount => isAdmin || (_perm['can_discount'] == true);

  /// …up to this amount per sale (0 = no cap). Managers are never capped.
  double get discountCap {
    if (isAdmin) return double.infinity;
    return (_perm['discount_cap'] as num?)?.toDouble() ?? 0;
  }

  /// May refund sales without manager approval.
  bool get canRefund => isAdmin || (_perm['can_refund'] == true);

  bool get earnsCommission => commissionRate > 0;

  /// Serialises the editable permission fields back to the JSON column.
  static String encodePermissions({
    required bool canDiscount,
    required double discountCap,
    required bool canRefund,
  }) =>
      jsonEncode({
        'can_discount': canDiscount,
        'discount_cap': discountCap,
        'can_refund': canRefund,
      });

  AppUser copyWith({
    String? name,
    String? email,
    String? role,
    bool? active,
    String? permissions,
    double? commissionRate,
  }) =>
      AppUser(
        id: id,
        name: name ?? this.name,
        email: email ?? this.email,
        role: role ?? this.role,
        active: active ?? this.active,
        createdAt: createdAt,
        permissions: permissions ?? this.permissions,
        commissionRate: commissionRate ?? this.commissionRate,
      );

  factory AppUser.fromMap(Map<String, Object?> m) => AppUser(
        id: m['id'] as int?,
        name: m['name'] as String,
        email: m['email'] as String,
        role: m['role'] as String? ?? 'cashier',
        active: (m['active'] as int? ?? 1) == 1,
        createdAt: m['created_at'] as int? ?? 0,
        permissions: m['permissions'] as String?,
        commissionRate: (m['commission_rate'] as num? ?? 0).toDouble(),
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'email': email.toLowerCase().trim(),
        'role': role,
        'active': active ? 1 : 0,
        'created_at': createdAt,
        if (permissions != null) 'permissions': permissions,
        'commission_rate': commissionRate,
      };
}
