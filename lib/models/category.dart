class Category {
  final int? id;
  final String name;

  const Category({this.id, required this.name});

  factory Category.fromMap(Map<String, Object?> m) => Category(
        id: m['id'] as int?,
        name: m['name'] as String,
      );

  Map<String, Object?> toMap() => {if (id != null) 'id': id, 'name': name};
}
