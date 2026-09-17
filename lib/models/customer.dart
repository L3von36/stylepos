class Customer {
  final int? id;
  final String name;
  final String? phone;
  final String? email;
  final String? notes;
  final int points;
  final int createdAt;

  const Customer({
    this.id,
    required this.name,
    this.phone,
    this.email,
    this.notes,
    this.points = 0,
    required this.createdAt,
  });

  Customer copyWith({
    int? id,
    String? name,
    String? phone,
    String? email,
    String? notes,
    int? points,
    int? createdAt,
  }) {
    return Customer(
      id: id ?? this.id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      notes: notes ?? this.notes,
      points: points ?? this.points,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  factory Customer.fromMap(Map<String, Object?> m) => Customer(
        id: m['id'] as int?,
        name: m['name'] as String,
        phone: m['phone'] as String?,
        email: m['email'] as String?,
        notes: m['notes'] as String?,
        points: m['points'] as int? ?? 0,
        createdAt: m['created_at'] as int? ?? 0,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'phone': phone,
        'email': email,
        'notes': notes,
        'points': points,
        'created_at': createdAt,
      };
}
