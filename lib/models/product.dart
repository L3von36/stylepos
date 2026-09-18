/// A purchasable variant of a product (size + color combination).
/// Every variant carries its own SKU / barcode, price, cost and stock level,
/// which is how real clothing inventory is tracked.
class ProductVariant {
  final int? id;
  final int productId;
  final String size;
  final String color;
  final String sku;
  final String? barcode;
  final double price;
  final double cost;
  final int stock;
  final bool archived;

  const ProductVariant({
    this.id,
    required this.productId,
    this.size = '',
    this.color = '',
    required this.sku,
    this.barcode,
    this.price = 0,
    this.cost = 0,
    this.stock = 0,
    this.archived = false,
  });

  /// Human readable description used on receipts / carts, e.g. "M · Black".
  String get descriptor {
    final parts = [size, color].where((p) => p.trim().isNotEmpty).toList();
    return parts.isEmpty ? 'Standard' : parts.join(' · ');
  }

  bool matchesCode(String code) {
    final c = code.trim().toLowerCase();
    return c.isNotEmpty &&
        ((barcode != null && barcode!.trim().toLowerCase() == c) ||
            sku.trim().toLowerCase() == c);
  }

  ProductVariant copyWith({
    int? id,
    int? productId,
    String? size,
    String? color,
    String? sku,
    String? barcode,
    double? price,
    double? cost,
    int? stock,
    bool? archived,
  }) {
    return ProductVariant(
      id: id ?? this.id,
      productId: productId ?? this.productId,
      size: size ?? this.size,
      color: color ?? this.color,
      sku: sku ?? this.sku,
      barcode: barcode ?? this.barcode,
      price: price ?? this.price,
      cost: cost ?? this.cost,
      stock: stock ?? this.stock,
      archived: archived ?? this.archived,
    );
  }

  factory ProductVariant.fromMap(Map<String, Object?> m) => ProductVariant(
        id: m['id'] as int?,
        productId: m['product_id'] as int,
        size: m['size'] as String? ?? '',
        color: m['color'] as String? ?? '',
        sku: m['sku'] as String? ?? '',
        barcode: m['barcode'] as String?,
        price: (m['price'] as num?)?.toDouble() ?? 0,
        cost: (m['cost'] as num?)?.toDouble() ?? 0,
        stock: m['stock'] as int? ?? 0,
        archived: (m['archived'] as int? ?? 0) == 1,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'product_id': productId,
        'size': size,
        'color': color,
        'sku': sku,
        'barcode': barcode,
        'price': price,
        'cost': cost,
        'stock': stock,
        'archived': archived ? 1 : 0,
      };
}

class Product {
  final int? id;
  final String name;
  final int? categoryId;
  final String? barcode;
  final String? image; // relative filename inside the app images dir
  final String? description;
  final int lowStock;
  final bool archived;
  final int createdAt;
  final List<ProductVariant> variants;

  const Product({
    this.id,
    required this.name,
    this.categoryId,
    this.barcode,
    this.image,
    this.description,
    this.lowStock = 5,
    this.archived = false,
    required this.createdAt,
    this.variants = const [],
  });

  double get minPrice =>
      variants.isEmpty ? 0 : variants.map((v) => v.price).reduce((a, b) => a < b ? a : b);

  double get maxPrice =>
      variants.isEmpty ? 0 : variants.map((v) => v.price).reduce((a, b) => a > b ? a : b);

  int get totalStock => variants.fold(0, (s, v) => s + v.stock);

  bool get hasLowStock => variants.any((v) => v.stock <= lowStock);

  Product copyWith({
    int? id,
    String? name,
    int? categoryId,
    String? barcode,
    String? image,
    bool clearImage = false,
    String? description,
    int? lowStock,
    bool? archived,
    int? createdAt,
    List<ProductVariant>? variants,
  }) {
    return Product(
      id: id ?? this.id,
      name: name ?? this.name,
      categoryId: categoryId ?? this.categoryId,
      barcode: barcode ?? this.barcode,
      image: clearImage ? null : (image ?? this.image),
      description: description ?? this.description,
      lowStock: lowStock ?? this.lowStock,
      archived: archived ?? this.archived,
      createdAt: createdAt ?? this.createdAt,
      variants: variants ?? this.variants,
    );
  }

  factory Product.fromMap(Map<String, Object?> m) => Product(
        id: m['id'] as int?,
        name: m['name'] as String,
        categoryId: m['category_id'] as int?,
        barcode: m['barcode'] as String?,
        image: m['image'] as String?,
        description: m['description'] as String?,
        lowStock: m['low_stock'] as int? ?? 5,
        archived: (m['archived'] as int? ?? 0) == 1,
        createdAt: m['created_at'] as int? ?? 0,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'category_id': categoryId,
        'barcode': barcode,
        'image': image,
        'description': description,
        'low_stock': lowStock,
        'archived': archived ? 1 : 0,
        'created_at': createdAt,
      };
}
