/// A staff account that can log into the POS.
/// Roles: `admin` (full access) and `cashier` (sell, view sales, manage customers).
class AppUser {
  final int? id;
  final String name;
  final String email;
  final String role;
  final bool active;
  final int createdAt;

  const AppUser({
    this.id,
    required this.name,
    required this.email,
    required this.role,
    this.active = true,
    required this.createdAt,
  });

  bool get isAdmin => role == 'admin';

  AppUser copyWith({String? name, String? email, String? role, bool? active}) {
    return AppUser(
      id: id,
      name: name ?? this.name,
      email: email ?? this.email,
      role: role ?? this.role,
      active: active ?? this.active,
      createdAt: createdAt,
    );
  }

  factory AppUser.fromMap(Map<String, Object?> m) => AppUser(
        id: m['id'] as int?,
        name: m['name'] as String,
        email: m['email'] as String,
        role: m['role'] as String? ?? 'cashier',
        active: (m['active'] as int? ?? 1) == 1,
        createdAt: m['created_at'] as int? ?? 0,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'email': email.toLowerCase().trim(),
        'role': role,
        'active': active ? 1 : 0,
        'created_at': createdAt,
      };
}
