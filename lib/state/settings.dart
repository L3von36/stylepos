import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../data/database.dart';

/// Shop-wide settings persisted in the `settings` key/value table.
class AppSettings extends ChangeNotifier {
  /// Untouched factory value — a device still showing this after the shop
  /// exists means the real shop name never landed locally.
  static const defaultShopName = 'My Clothing Shop';

  /// The one and only shop currency — Ethiopian Birr. Sami is built for
  /// Ethiopian shops, so the currency is fixed (not configurable) and any
  /// older stored value (e.g. KES) is ignored on load.
  static const currencyCode = 'ETB';
  static const currencySymbol = 'Br';

  String shopName = defaultShopName;
  String shopAddress = '';
  String shopPhone = '';
  String receiptFooter = 'Thank you for shopping with us!';
  double taxRate = 0; // percent, e.g. 16 means 16%
  int lowStockDefault = 5;
  int loyaltyStep = 100; // award 1 point per this many currency units spent; 0 = off

  /// Order discounts at or above this amount (in currency units) require
  /// manager approval when a salesperson enters them (0 = every discount
  /// needs approval). Managers always skip the gate.
  double discountPinThreshold = 0;

  /// Appearance: 'system' | 'light' | 'dark' (Material [ThemeMode]).
  String themeModeName = 'system';
  ThemeMode get themeMode => switch (themeModeName) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  /// Receipt logo: base64 PNG (resized on import). Null = no logo set.
  String? receiptLogoB64;

  /// Whether receipts render the configured logo (default on).
  bool receiptShowLogo = true;

  /// Whether receipts print the cashier's name (default on).
  bool receiptShowCashier = true;

  /// Checkout payment methods the shop accepts, in display order.
  /// Managers configure this; the POS builds its method picker from it.
  List<String> paymentMethods = ['cash', 'card', 'mobile'];

  /// Last successful backup on this device (epoch seconds), null = never.
  /// Device-local on purpose: backups are per-device files, and the local
  /// settings kv is not mirrored to the cloud.
  int? lastBackupAt;

  /// Backup nudge snoozed until this epoch second (banner "Later" button).
  int? backupSnoozeUntil;

  /// How often the manager should be nudged to export a backup.
  static const backupReminderDays = 7;

  /// True when the backup-reminder banner should show: manager-only is
  /// decided by the caller; here — never backed up, or the last backup is
  /// older than [backupReminderDays] days and the nudge isn't snoozed.
  bool get backupReminderDue {
    if (backupSnoozeUntil != null &&
        backupSnoozeUntil! > DateTime.now().millisecondsSinceEpoch ~/ 1000) {
      return false;
    }
    final last = lastBackupAt;
    if (last == null || last <= 0) return true;
    final ageDays =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000 - last) / 86400.0;
    return ageDays >= backupReminderDays;
  }

  /// Records that a backup was just produced on this device.
  Future<void> markBackedUp() async {
    lastBackupAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    backupSnoozeUntil = null;
    final db = await DB.instance();
    final batch = db.batch();
    batch.insert('settings',
        {'key': 'last_backup_at', 'value': '$lastBackupAt'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    batch.insert('settings', {'key': 'backup_snooze_until', 'value': ''},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await batch.commit(noResult: true);
    notifyListeners();
  }

  /// Postpones the backup nudge (banner "Not now").
  Future<void> snoozeBackupReminder({int days = 3}) async {
    backupSnoozeUntil =
        DateTime.now().add(Duration(days: days)).millisecondsSinceEpoch ~/ 1000;
    final db = await DB.instance();
    await db.insert('settings',
        {'key': 'backup_snooze_until', 'value': '$backupSnoozeUntil'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
  }

  NumberFormat? _moneyFmt;

  /// Forces listeners to re-read settings (e.g. the OS dark-mode flip while
  /// in System mode re-resolves the effective brightness).
  void resync() => notifyListeners();

  AppSettings() {
    _rebuildFormatter();
  }

  void _rebuildFormatter() {
    _moneyFmt = NumberFormat.currency(
      symbol: '$currencySymbol ',
      decimalDigits: 2,
    );
  }

  /// Formats an amount in Birr, e.g. "Br 1,250.00".
  String money(double v) {
    final fmt = _moneyFmt;
    if (fmt == null) return v.toStringAsFixed(2);
    return fmt.format(v);
  }

  /// Formats an amount without the currency symbol, e.g. "1,250.00" —
  /// used as the upper bound of a price range.
  String moneyPlain(double v) {
    final fmt = _moneyFmt;
    if (fmt == null) return v.toStringAsFixed(2);
    return NumberFormat('#,##0.00').format(v);
  }

  /// Price label for product cards / inventory rows: one formatted price
  /// when all variants share it, otherwise a compact min–max range with
  /// the symbol only on the lower bound, e.g. "Br 1,000.00 – 3,200.00".
  String priceLabel(double min, double max) {
    if (min == max) return money(min);
    return '${money(min)} – ${moneyPlain(max)}';
  }

  Future<void> load() async {
    final db = await DB.instance();
    final rows = await db.query('settings');
    final kv = {for (final r in rows) r['key'] as String: r['value'] as String?};
    String? g(String key) => kv[key];

    shopName = g('shop_name') ?? shopName;
    shopAddress = g('shop_address') ?? shopAddress;
    shopPhone = g('shop_phone') ?? shopPhone;
    receiptFooter = g('receipt_footer') ?? receiptFooter;
    // Currency is FIXED to Ethiopian Birr — stored values from older
    // builds (KES/KSh etc.) are deliberately ignored.
    taxRate = double.tryParse(g('tax_rate') ?? '') ?? taxRate;
    lowStockDefault = int.tryParse(g('low_stock_default') ?? '') ?? lowStockDefault;
    loyaltyStep = int.tryParse(g('loyalty_step') ?? '') ?? loyaltyStep;
    discountPinThreshold =
        double.tryParse(g('discount_pin_threshold') ?? '') ?? discountPinThreshold;
    themeModeName = g('theme_mode') ?? themeModeName;
    receiptLogoB64 = g('receipt_logo_b64');
    receiptShowLogo = (g('receipt_show_logo') ?? '1') != '0';
    receiptShowCashier = (g('receipt_show_cashier') ?? '1') != '0';
    final pmRaw = g('payment_methods') ?? '';
    if (pmRaw.trim().isNotEmpty) {
      final list = pmRaw
          .split(',')
          .map((e) => e.trim())
          .where((e) => ['cash', 'card', 'mobile'].contains(e))
          .toList();
      if (list.isNotEmpty) paymentMethods = list;
    }
    lastBackupAt = int.tryParse(g('last_backup_at') ?? '');
    backupSnoozeUntil = int.tryParse(g('backup_snooze_until') ?? '');
    _rebuildFormatter();
    notifyListeners();
  }

  /// [receiptLogo] accepts a base64 PNG to set the logo, or an empty string
  /// to clear it (null leaves the current value untouched).
  Future<void> save({
    String? shopName,
    String? shopAddress,
    String? shopPhone,
    String? receiptFooter,
    double? taxRate,
    int? lowStockDefault,
    int? loyaltyStep,
    double? discountPinThreshold,
    String? themeMode,
    String? receiptLogo,
    bool? receiptShowLogo,
    bool? receiptShowCashier,
    List<String>? paymentMethods,
  }) async {
    if (shopName != null) this.shopName = shopName;
    if (shopAddress != null) this.shopAddress = shopAddress;
    if (shopPhone != null) this.shopPhone = shopPhone;
    if (receiptFooter != null) this.receiptFooter = receiptFooter;
    if (taxRate != null) this.taxRate = taxRate;
    if (lowStockDefault != null) this.lowStockDefault = lowStockDefault;
    if (loyaltyStep != null) this.loyaltyStep = loyaltyStep;
    if (discountPinThreshold != null) this.discountPinThreshold = discountPinThreshold;
    if (themeMode != null) themeModeName = themeMode;
    if (receiptLogo != null) receiptLogoB64 = receiptLogo.isEmpty ? null : receiptLogo;
    if (receiptShowLogo != null) this.receiptShowLogo = receiptShowLogo;
    if (receiptShowCashier != null) this.receiptShowCashier = receiptShowCashier;
    if (paymentMethods != null && paymentMethods.isNotEmpty) {
      this.paymentMethods = paymentMethods;
    }

    final db = await DB.instance();
    final map = <String, String>{
      'shop_name': this.shopName,
      'shop_address': this.shopAddress,
      'shop_phone': this.shopPhone,
      'receipt_footer': this.receiptFooter,
      'tax_rate': this.taxRate.toString(),
      'low_stock_default': this.lowStockDefault.toString(),
      'loyalty_step': this.loyaltyStep.toString(),
      'discount_pin_threshold': this.discountPinThreshold.toString(),
      'theme_mode': themeModeName,
      'receipt_show_logo': this.receiptShowLogo ? '1' : '0',
      'receipt_show_cashier': this.receiptShowCashier ? '1' : '0',
      'payment_methods': this.paymentMethods.join(','),
      'receipt_logo_b64': ?receiptLogoB64,
    };
    final batch = db.batch();
    for (final e in map.entries) {
      batch.insert('settings', {'key': e.key, 'value': e.value},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
    _rebuildFormatter();
    notifyListeners();
  }
}
