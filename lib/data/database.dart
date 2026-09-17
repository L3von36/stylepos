import 'dart:io' show Platform;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/category.dart';
import '../models/product.dart';
import '../services/hash.dart';

/// Opens (and creates/seeds on first run) the local SQLite database.
/// Uses sqflite on Android and sqlite3 FFI on desktop (Windows).
class DB {
  static Database? _instance;

  /// Closes the pooled database and forgets it, so the next instance()
  /// call reopens (and sees a replaced file). Used by backup restore.
  static Future<void> closeAndReset() async {
    final db = _instance;
    _instance = null;
    await db?.close();
  }

  /// Optional override of the folder holding stylepos.db.
  /// Used by tests to run against a throwaway database.
  static String? _dirOverride;
  static void useDirectory(String dir) => _dirOverride = dir;

  static Future<Database> instance() async {
    if (_instance != null) return _instance!;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final String dbPath;
    if (_dirOverride != null) {
      dbPath = p.join(_dirOverride!, 'stylepos.db');
    } else if (Platform.isAndroid || Platform.isIOS) {
      dbPath = p.join(await getDatabasesPath(), 'stylepos.db');
    } else {
      final dir = await getApplicationSupportDirectory();
      dbPath = p.join(dir.path, 'stylepos.db');
    }

    _instance = await openDatabase(
      dbPath,
      version: 4,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onUpgrade: (db, oldVersion, newVersion) async {
        // v2: product photos (relative filename inside the app images dir).
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE products ADD COLUMN image TEXT');
        }
        // v3: cloud-sync bookkeeping (see services/sync_service.dart).
        if (oldVersion < 3) {
          final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          const tables = ['categories', 'products', 'variants', 'customers'];
          for (final t in tables) {
            await db.execute('ALTER TABLE $t ADD COLUMN cloud_id TEXT');
            await db.execute(
                'ALTER TABLE $t ADD COLUMN dirty INTEGER NOT NULL DEFAULT 0');
            await db.execute(
                'ALTER TABLE $t ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0');
            await db.execute(
                'ALTER TABLE $t ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0');
            if (t == 'products') {
              await db.execute(
                  'ALTER TABLE products ADD COLUMN cloud_image TEXT');
            }
            // Pre-existing rows keep cloud_id NULL so the pull step can
            // ADOPT them onto matching cloud rows (same barcode/SKU/name)
            // instead of duplicating them. Rows that end up unmatched are
            // pushed as new by the sync engine.
            await db.execute('UPDATE $t SET updated_at = $now');
          }
        }
        // v4: sales history sync (Phase 2). The three sales tables gain the
        // same sync bookkeeping; they are append-only (refunds are a status
        // change), so no tombstone column is needed. Local staff rows link
        // to their cloud identity so pulled sales attribute to the right
        // cashier on every device.
        if (oldVersion < 4) {
          await db.execute('ALTER TABLE users ADD COLUMN cloud_id TEXT');
          for (final t in const ['sales', 'sale_items', 'stock_movements']) {
            await db.execute('ALTER TABLE $t ADD COLUMN cloud_id TEXT');
            await db.execute(
                'ALTER TABLE $t ADD COLUMN dirty INTEGER NOT NULL DEFAULT 0');
            await db.execute(
                'ALTER TABLE $t ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0');
          }
          // Keep the original order of history rows.
          await db.execute('UPDATE sales SET updated_at = created_at');
        }
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            email TEXT NOT NULL UNIQUE,
            pass_hash TEXT NOT NULL,
            salt TEXT NOT NULL,
            role TEXT NOT NULL DEFAULT 'cashier',
            active INTEGER NOT NULL DEFAULT 1,
            created_at INTEGER NOT NULL,
            cloud_id TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE categories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            cloud_id TEXT,
            dirty INTEGER NOT NULL DEFAULT 0,
            deleted INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE products (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            category_id INTEGER,
            barcode TEXT,
            image TEXT,
            description TEXT,
            low_stock INTEGER NOT NULL DEFAULT 5,
            archived INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            cloud_id TEXT,
            cloud_image TEXT,
            dirty INTEGER NOT NULL DEFAULT 0,
            deleted INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE variants (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            product_id INTEGER NOT NULL,
            size TEXT NOT NULL DEFAULT '',
            color TEXT NOT NULL DEFAULT '',
            sku TEXT NOT NULL,
            barcode TEXT,
            price REAL NOT NULL DEFAULT 0,
            cost REAL NOT NULL DEFAULT 0,
            stock INTEGER NOT NULL DEFAULT 0,
            archived INTEGER NOT NULL DEFAULT 0,
            cloud_id TEXT,
            dirty INTEGER NOT NULL DEFAULT 0,
            deleted INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('CREATE INDEX idx_variants_product ON variants(product_id)');
        await db.execute('CREATE INDEX idx_variants_sku ON variants(sku)');
        await db.execute('''
          CREATE TABLE customers (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            phone TEXT,
            email TEXT,
            notes TEXT,
            points INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            cloud_id TEXT,
            dirty INTEGER NOT NULL DEFAULT 0,
            deleted INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE sales (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            receipt_no TEXT NOT NULL UNIQUE,
            customer_id INTEGER,
            user_id INTEGER NOT NULL,
            subtotal REAL NOT NULL DEFAULT 0,
            discount REAL NOT NULL DEFAULT 0,
            tax REAL NOT NULL DEFAULT 0,
            total REAL NOT NULL DEFAULT 0,
            payment_method TEXT NOT NULL DEFAULT 'cash',
            amount_paid REAL NOT NULL DEFAULT 0,
            change_due REAL NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'completed',
            created_at INTEGER NOT NULL,
            cloud_id TEXT,
            dirty INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('CREATE INDEX idx_sales_created ON sales(created_at)');
        await db.execute('CREATE INDEX idx_sales_customer ON sales(customer_id)');
        await db.execute('''
          CREATE TABLE sale_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sale_id INTEGER NOT NULL,
            variant_id INTEGER NOT NULL,
            product_name TEXT NOT NULL,
            variant_desc TEXT NOT NULL,
            unit_price REAL NOT NULL DEFAULT 0,
            qty INTEGER NOT NULL DEFAULT 0,
            line_total REAL NOT NULL DEFAULT 0,
            cloud_id TEXT,
            dirty INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('CREATE INDEX idx_sale_items_sale ON sale_items(sale_id)');
        await db.execute('''
          CREATE TABLE stock_movements (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            variant_id INTEGER NOT NULL,
            qty INTEGER NOT NULL,
            reason TEXT NOT NULL,
            note TEXT,
            user_id INTEGER,
            created_at INTEGER NOT NULL,
            cloud_id TEXT,
            dirty INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE settings (
            key TEXT PRIMARY KEY,
            value TEXT
          )
        ''');

        await _seed(db);
      },
    );
    return _instance!;
  }

  static Future<void> _seed(Database db) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // --- default settings ---
    final defaults = <String, String>{
      'shop_name': 'My Clothing Shop',
      'shop_address': '',
      'shop_phone': '',
      'receipt_footer': 'Thank you for shopping with us!',
      'currency_code': 'KES',
      'currency_symbol': 'KSh',
      'tax_rate': '0',
      'low_stock_default': '5',
      'loyalty_step': '100',
      'receipt_seq': '0',
    };
    for (final e in defaults.entries) {
      await db.insert('settings', {'key': e.key, 'value': e.value});
    }

    // --- default admin account ---
    final salt = newSalt();
    await db.insert('users', {
      'name': 'Admin',
      'email': 'admin@stylepos.app',
      'pass_hash': hashPassword('admin123', salt),
      'salt': salt,
      'role': 'admin',
      'active': 1,
      'created_at': now,
    });

    // --- starter catalog so the shop can start selling immediately ---
    const cats = [
      'T-Shirts', 'Shirts', 'Dresses', 'Jeans', 'Jackets', 'Shoes', 'Accessories',
    ];
    final catIds = <String, int>{};
    for (final c in cats) {
      catIds[c] = await db.insert('categories', Category(name: c).toMap());
    }

    Future<void> addProduct({
      required String name,
      required String category,
      required String barcode,
      required double price,
      required double cost,
      required List<(String, String, int)> variants, // (size, color, stock)
    }) async {
      final pid = await db.insert('products', Product(
        name: name,
        categoryId: catIds[category],
        barcode: barcode,
        lowStock: 5,
        createdAt: now,
      ).toMap());
      var i = 0;
      for (final (size, color, stock) in variants) {
        i++;
        await db.insert('variants', ProductVariant(
          productId: pid,
          size: size,
          color: color,
          sku: '$barcode-${size.isNotEmpty ? size : "OS"}-$i',
          barcode: '$barcode$i',
          price: price,
          cost: cost,
          stock: stock,
        ).toMap());
      }
    }

    await addProduct(
      name: 'Classic Cotton Tee',
      category: 'T-Shirts',
      barcode: '600123400001',
      price: 850,
      cost: 400,
      variants: const [
        ('S', 'Black', 12), ('M', 'Black', 18), ('L', 'Black', 15),
        ('M', 'White', 20), ('L', 'White', 9),
      ],
    );
    await addProduct(
      name: 'Oxford Button-Down Shirt',
      category: 'Shirts',
      barcode: '600123400002',
      price: 2200,
      cost: 1100,
      variants: const [
        ('M', 'Blue', 8), ('L', 'Blue', 6), ('M', 'White', 7), ('XL', 'White', 3),
      ],
    );
    await addProduct(
      name: 'Floral Summer Dress',
      category: 'Dresses',
      barcode: '600123400003',
      price: 3200,
      cost: 1500,
      variants: const [
        ('S', 'Red', 5), ('M', 'Red', 8), ('L', 'Red', 4), ('M', 'Navy', 6),
      ],
    );
    await addProduct(
      name: 'Slim Fit Jeans',
      category: 'Jeans',
      barcode: '600123400004',
      price: 2800,
      cost: 1400,
      variants: const [
        ('30', 'Blue', 10), ('32', 'Blue', 14), ('34', 'Blue', 11), ('36', 'Black', 6),
      ],
    );
    await addProduct(
      name: 'Denim Jacket',
      category: 'Jackets',
      barcode: '600123400005',
      price: 4500,
      cost: 2400,
      variants: const [
        ('M', 'Blue', 4), ('L', 'Blue', 3), ('XL', 'Blue', 2),
      ],
    );
    await addProduct(
      name: 'Canvas Sneakers',
      category: 'Shoes',
      barcode: '600123400006',
      price: 2600,
      cost: 1300,
      variants: const [
        ('40', 'White', 7), ('41', 'White', 9), ('42', 'Black', 8), ('43', 'Black', 4),
      ],
    );
    await addProduct(
      name: 'Leather Belt',
      category: 'Accessories',
      barcode: '600123400007',
      price: 1200,
      cost: 500,
      variants: const [
        ('', 'Brown', 15), ('', 'Black', 12),
      ],
    );
    await addProduct(
      name: 'Wool Beanie',
      category: 'Accessories',
      barcode: '600123400008',
      price: 650,
      cost: 250,
      variants: const [
        ('', 'Grey', 3), ('', 'Red', 2),
      ],
    );

    // one sample customer
    await db.insert('customers', {
      'name': 'Walk-in Customer',
      'phone': null,
      'email': null,
      'notes': 'Default counter customer',
      'points': 0,
      'created_at': now,
    });

    // Sync bookkeeping for the seeded rows: timestamped, but cloud_id
    // stays NULL so the first pull can adopt them onto cloud rows
    // (matched by barcode / SKU / name) instead of duplicating.
    await db.execute('UPDATE categories SET updated_at = $now');
    await db.execute('UPDATE products SET updated_at = $now');
    await db.execute('UPDATE variants SET updated_at = $now');
    await db.execute('UPDATE customers SET updated_at = $now');
  }
}
