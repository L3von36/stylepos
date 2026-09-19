/// A supplier / vendor the shop buys stock from.
class Supplier {
  final int? id;
  final String name;
  final String? phone;
  final String? email;
  final String? address;
  final String? notes;
  final int createdAt;
  final bool deleted;

  const Supplier({
    this.id,
    required this.name,
    this.phone,
    this.email,
    this.address,
    this.notes,
    required this.createdAt,
    this.deleted = false,
  });

  /// Best contact line for the tile subtitle (phone, else email).
  String? get contact => (phone?.isNotEmpty ?? false)
      ? phone
      : ((email?.isNotEmpty ?? false) ? email : null);

  Supplier copyWith({
    String? name,
    String? phone,
    String? email,
    String? address,
    String? notes,
  }) =>
      Supplier(
        id: id,
        name: name ?? this.name,
        phone: phone ?? this.phone,
        email: email ?? this.email,
        address: address ?? this.address,
        notes: notes ?? this.notes,
        createdAt: createdAt,
        deleted: deleted,
      );

  factory Supplier.fromMap(Map<String, Object?> m) => Supplier(
        id: m['id'] as int?,
        name: m['name'] as String? ?? '',
        phone: m['phone'] as String?,
        email: m['email'] as String?,
        address: m['address'] as String?,
        notes: m['notes'] as String?,
        createdAt: m['created_at'] as int? ?? 0,
        deleted: (m['deleted'] as int? ?? 0) == 1,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name.trim(),
        'phone': phone,
        'email': email,
        'address': address,
        'notes': notes,
        'created_at': createdAt,
        'deleted': deleted ? 1 : 0,
      };
}
