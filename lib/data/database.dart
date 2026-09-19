import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../services/hash.dart';
import 'db_factory.dart';

/// Opens (and creates/seeds on first run) the local SQLite database.
/// Uses sqflite on Android and sqlite3 FFI on desktop (Windows).
///
/// Only functional defaults are seeded (settings, the local admin login
/// and the Walk-in Customer). NO demo catalog: the shop adds its own
/// products, and the cloud pull brings the shop's real catalog.
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
    configureDatabaseFactory();

    final String dbPath;
    if (_dirOverride != null) {
      dbPath = p.join(_dirOverride!, 'stylepos.db');
    } else if (kIsWeb) {
      dbPath = 'stylepos.db'; // stored in the browser via sqlite3 wasm
    } else if (Platform.isAndroid || Platform.isIOS) {
      dbPath = p.join(await getDatabasesPath(), 'stylepos.db');
    } else {
      final dir = await getApplicationSupportDirectory();
      dbPath = p.join(dir.path, 'stylepos.db');
    }

    _instance = await openDatabase(
      dbPath,
      version: 8,
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
        // v5: one-time purge of the hardcoded demo catalog + demo history.
        // Older versions seeded 7 categories / 8 products / 56 variants and
        // the sync engine kept re-pushing them (fresh installs seeded again;
        // an empty cloud triggered a full local-catalog re-push). The shop
        // must own its catalog: wipe the local copy and let the (now clean)
        // cloud pull bring back only real data. Deleting in the cloud sticks
        // from this version on.
        if (oldVersion < 5) {
          await _purgeCatalogAndHistory(db);
        }
        // v6: staff shift logs (clock in/out) and the audit trail (who did
        // what, when) — accountability features. Both are local-first:
        // attendance/audit are per-device records by design (a shift log
        // belongs to the till it was punched on), so they are NOT mirrored
        // to the cloud tables.
        if (oldVersion < 6) {
          await _createAccountabilityTables(db);
        }
        // v7: (a) purchasing (suppliers + purchase orders + received goods) and
        // commissions, cost snapshot on sale lines (true margins), staff
        // permissions (discount/refund rights) and commission rates.
        // (b) device_id on stock_movements — tracks which device
        //     originated each movement so conflict reports are actionable.
        // (c) sync_version on variants — incremented on every stock change
        //     so the sync engine can detect concurrent edits.
        // (d) cloud sync columns on attendance — shifts are now mirrored
        //     to Supabase so managers on any device see who is clocked in.
        if (oldVersion < 7) {
          await _createOpsTables(db);
          try {
            await db.execute(
                'ALTER TABLE users ADD COLUMN permissions TEXT');
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE users ADD COLUMN commission_rate REAL NOT NULL DEFAULT 0');
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE sale_items ADD COLUMN unit_cost REAL NOT NULL DEFAULT 0');
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE stock_movements ADD COLUMN device_id TEXT');
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE variants ADD COLUMN sync_version INTEGER NOT NULL DEFAULT 0');
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE attendance ADD COLUMN cloud_id TEXT');
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE attendance ADD COLUMN dirty INTEGER NOT NULL DEFAULT 0');
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE attendance ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0');
          } catch (_) {}
          await db.execute(
              'UPDATE attendance SET updated_at = clock_in WHERE updated_at = 0');
        }
        // v8: pricing & promotions (coupons + seasonal campaigns applied
        // by code at the till) and the promo reference on sales so receipts
        // and reports can show which promotion a sale used.
        if (oldVersion < 8) {
          await _createPromoTables(db);
          try {
            await db.execute('ALTER TABLE sales ADD COLUMN promo_code TEXT');
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE sales ADD COLUMN promo_discount REAL NOT NULL DEFAULT 0');
          } catch (_) {}
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
            cloud_id TEXT,
            permissions TEXT,
            commission_rate REAL NOT NULL DEFAULT 0
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
            updated_at INTEGER NOT NULL DEFAULT 0,
            sync_version INTEGER NOT NULL DEFAULT 0
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
            promo_code TEXT,
            promo_discount REAL NOT NULL DEFAULT 0,
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
            unit_cost REAL NOT NULL DEFAULT 0,
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
            device_id TEXT,
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

        await _createAccountabilityTables(db);
        await _createOpsTables(db);
        await _createPromoTables(db);

        await _seed(db);
      },
    );
    return _instance!;
  }

  /// Purchasing + commissions tables. Kept in a helper so both fresh
  /// installs (onCreate) and upgrades (< v7) build them once. All four
  /// carry the standard sync bookkeeping (cloud_id / dirty / deleted /
  /// updated_at); commissions and po items are append-or-status rows.
  static Future<void> _createOpsTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS suppliers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        phone TEXT,
        email TEXT,
        address TEXT,
        notes TEXT,
        created_at INTEGER NOT NULL,
        cloud_id TEXT,
        dirty INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_suppliers_name ON suppliers(name)');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS purchase_orders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        supplier_id INTEGER,
        status TEXT NOT NULL DEFAULT 'draft',
        order_date INTEGER,
        expected_date INTEGER,
        received_date INTEGER,
        notes TEXT,
        created_by INTEGER,
        created_at INTEGER NOT NULL,
        cloud_id TEXT,
        dirty INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_pos_supplier ON purchase_orders(supplier_id)');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS purchase_order_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        po_id INTEGER NOT NULL,
        variant_id INTEGER,
        product_name TEXT NOT NULL DEFAULT '',
        variant_desc TEXT NOT NULL DEFAULT '',
        sku TEXT NOT NULL DEFAULT '',
        qty_ordered INTEGER NOT NULL DEFAULT 0,
        qty_received INTEGER NOT NULL DEFAULT 0,
        unit_cost REAL NOT NULL DEFAULT 0,
        cloud_id TEXT,
        dirty INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_po_items_po ON purchase_order_items(po_id)');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS commissions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL DEFAULT 0,
        sale_id INTEGER,
        amount REAL NOT NULL DEFAULT 0,
        basis TEXT NOT NULL DEFAULT 'sale',
        status TEXT NOT NULL DEFAULT 'pending',
        note TEXT,
        period TEXT NOT NULL DEFAULT '',
        paid_at INTEGER,
        created_at INTEGER NOT NULL,
        cloud_id TEXT,
        dirty INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_commissions_user ON commissions(user_id)');
  }

  /// Promotions (coupons + seasonal campaigns). Kept in a helper so both
  /// fresh installs (onCreate) and upgrades (< v8) build it once. Carries
  /// the standard sync bookkeeping — promotions are manager-created on any
  /// device and must reach every till.
  static Future<void> _createPromoTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS promotions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        code TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'coupon',
        type TEXT NOT NULL DEFAULT 'percent',
        value REAL NOT NULL DEFAULT 0,
        min_subtotal REAL NOT NULL DEFAULT 0,
        starts_at INTEGER,
        ends_at INTEGER,
        usage_limit INTEGER NOT NULL DEFAULT 0,
        used_count INTEGER NOT NULL DEFAULT 0,
        active INTEGER NOT NULL DEFAULT 1,
        created_at INTEGER NOT NULL,
        cloud_id TEXT,
        dirty INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_promotions_code ON promotions(code)');
  }

  /// Shift logs (clock in/out) and the audit trail. Kept in a helper so
  /// both fresh installs (onCreate) and upgrades (< v6) build them once.
  static Future<void> _createAccountabilityTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS attendance (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        clock_in INTEGER NOT NULL,
        clock_out INTEGER,
        cloud_id TEXT,
        dirty INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_attendance_user ON attendance(user_id)');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS audit_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER,
        user_name TEXT,
        action TEXT NOT NULL,
        details TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_log(created_at)');
  }

  /// One-time (DB v5) purge of the demo catalog and demo sales history.
  /// Deletes every category/product/variant and every sale locally —
  /// including rows that never made it to the cloud — so nothing can be
  /// re-pushed after the cloud cleanup. Pull cursors reset so the next
  /// sync re-downloads the shop's real data from scratch.
  static Future<void> _purgeCatalogAndHistory(Database db) async {
    await db.transaction((txn) async {
      for (final t in const [
        'sale_items',
        'stock_movements',
        'sales',
        'variants',
        'products',
        'categories',
      ]) {
        await txn.execute('DELETE FROM $t');
      }
      // Reset autoincrement counters so fresh rows start from 1.
      for (final t in const [
        'sale_items',
        'stock_movements',
        'sales',
        'variants',
        'products',
        'categories',
      ]) {
        // Missing rows are fine; ignore errors per table.
        try {
          await txn.execute(
              "DELETE FROM sqlite_sequence WHERE name = '$t'");
        } catch (_) {}
      }
      // Forget pull cursors: the next sync re-reads the whole cloud
      // (tombstones for unknown rows are skipped, real rows re-downloaded).
      for (final t in const [
        'categories',
        'products',
        'variants',
        'sales',
        'sale_items',
        'stock_movements',
      ]) {
        await txn.delete('settings',
            where: 'key = ?', whereArgs: ['sync_last_pull_$t']);
      }
    });
  }

  /// Erases EVERYTHING from the local database (used by the Manager's
  /// "start fresh" tool when a device holds old pre-cloud data). Settings
  /// get their defaults back; no demo catalog is re-seeded — the cloud
  /// pull brings the shop's real data instead.
  static Future<void> wipeAllData() async {
    final db = await instance();
    await db.transaction((txn) async {
      for (final t in const [
        'sale_items',
        'stock_movements',
        'sales',
        'variants',
        'products',
        'categories',
        'customers',
        'users',
        'attendance',
        'audit_log',
        'settings',
        'suppliers',
        'purchase_orders',
        'purchase_order_items',
        'commissions',
        'promotions',
      ]) {
        await txn.execute('DELETE FROM $t');
      }
    });
    try {
      // Restart autoincrement counters so fresh rows start from 1.
      await db.execute(
          "DELETE FROM sqlite_sequence WHERE name NOT IN ('users', 'categories', 'products', 'variants', 'customers', 'sales', 'sale_items', 'stock_movements')");
      await db.execute(
          "UPDATE sqlite_sequence SET seq = 0 WHERE name IN ('users', 'categories', 'products', 'variants', 'customers', 'sales', 'sale_items', 'stock_movements')");
    } catch (_) {// sqlite_sequence may not exist yet — nothing to reset.
    }
    await _seedSettings(db);
  }

  static Future<void> _seedSettings(Database db) async {
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
      'payment_methods': 'cash,card,mobile',
    };
    for (final e in defaults.entries) {
      await db.insert('settings', {'key': e.key, 'value': e.value});
    }
  }

  static Future<void> _seed(Database db) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // --- default settings ---
    await _seedSettings(db);

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

    // NO demo catalog: the shop adds its own products (or pulls the
    // catalog its manager already created on another device).

    // one functional customer — the default counter customer
    await db.insert('customers', {
      'name': 'Walk-in Customer',
      'phone': null,
      'email': null,
      'notes': 'Default counter customer',
      'points': 0,
      'created_at': now,
    });

    // The walk-in customer is created offline-first: cloud_id stays NULL
    // so the first pull can adopt it onto an existing cloud row instead
    // of duplicating it.
    await db.execute('UPDATE customers SET updated_at = $now');
  }
}
