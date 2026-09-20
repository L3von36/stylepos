import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stylepos/models/product.dart';
import 'package:stylepos/screens/pos/pos_screen.dart';

Product _p(String name, {String? image, int stock = 10}) {
  return Product(
    name: name,
    createdAt: 0,
    image: image,
    variants: [
      ProductVariant(productId: 0, sku: '$name-1', price: 500, stock: stock),
    ],
  );
}

void main() {
  group('splitByPhoto (Sell-tab catalog layout rule)', () {
    test('a shop with no uploaded photos renders everything as a list', () {
      final split = splitByPhoto([
        _p('Baggy Jeans'),
        _p('Floral Dress'),
        _p('Polo Tee'),
      ]);
      expect(split.withPhotos, isEmpty);
      expect(split.withoutPhotos.map((p) => p.name).toList(),
          ['Baggy Jeans', 'Floral Dress', 'Polo Tee']);
    });

    test('a fully photographed shop keeps the grid — nothing lands in the list',
        () {
      final split = splitByPhoto([
        _p('Baggy Jeans', image: 'jeans.jpg'),
        _p('Floral Dress', image: 'dress.jpg'),
      ]);
      expect(split.withPhotos.length, 2);
      expect(split.withoutPhotos, isEmpty);
    });

    test('mixed catalog: photo-less items are pulled out of the grid', () {
      final split = splitByPhoto([
        _p('Baggy Jeans', image: 'jeans.jpg'),
        _p('Polo Tee'),
        _p('Bomber Jacket', image: ' jacket.jpg '),
        _p('Wool Hat'),
      ]);
      expect(split.withPhotos.map((p) => p.name).toList(),
          ['Baggy Jeans', 'Bomber Jacket']);
      expect(split.withoutPhotos.map((p) => p.name).toList(),
          ['Polo Tee', 'Wool Hat']);
    });

    test('null and whitespace-only image fields count as "no photo"', () {
      final split = splitByPhoto([
        _p('Null Image', image: null),
        _p('Blank Image', image: ''),
        _p('Space Image', image: '   '),
        _p('Real Photo', image: 'a.png'),
      ]);
      expect(split.withPhotos.map((p) => p.name).toList(), ['Real Photo']);
      expect(split.withoutPhotos.length, 3);
    });

    test('relative order is preserved inside each section', () {
      final split = splitByPhoto([
        _p('A'),
        _p('B', image: 'b.jpg'),
        _p('C'),
        _p('D', image: 'd.jpg'),
        _p('E'),
      ]);
      expect(split.withPhotos.map((p) => p.name).toList(), ['B', 'D']);
      expect(split.withoutPhotos.map((p) => p.name).toList(), ['A', 'C', 'E']);
    });
  });

  group('garmentIconFor (fallback icon for photo-less items)', () {
    test('picks a garment-flavoured icon from the product name', () {
      expect(garmentIconFor(_p('Blue Dress'), ), Icons.woman_rounded);
      expect(garmentIconFor(_p('Cargo Jeans')), Icons.checkroom_rounded);
      expect(garmentIconFor(_p('Polo Shirt')), Icons.dry_cleaning_rounded);
      expect(garmentIconFor(_p('Winter Jacket')), Icons.storm_rounded);
      expect(garmentIconFor(_p('Running Shoes')), Icons.hiking_rounded);
      expect(garmentIconFor(_p('Leather Belt')), Icons.watch_outlined);
    });

    test('unknown names fall back to the hanger icon', () {
      expect(garmentIconFor(_p('Mystery Bundle')), Icons.checkroom_rounded);
    });
  });
}
