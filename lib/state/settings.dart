import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../data/database.dart';

/// Shop-wide settings persisted in the `settings` key/value table.
class AppSettings extends ChangeNotifier {
  /// Untouched factory value — a device still showing this after the shop
  /// exists means the real shop name never landed locally.
  static const defaultShopName = 'My Clothing Shop';

  String shopName = defaultShopName;
  String shopAddress = '';
  String shopPhone = '';
  String receiptFooter = 'Thank you for shopping with us!';
  String currencyCode = 'KES';
  String currencySymbol = 'KSh';
  double taxRate = 0; // percent, e.g. 16 means 16%
  int lowStockDefault = 5;
  int loyaltyStep = 100; // award 1 point per this many currency units spent; 0 = off

  NumberFormat? _moneyFmt;

  AppSettings() {
    _rebuildFormatter();
  }

  void _rebuildFormatter() {
    _moneyFmt = NumberFormat.currency(
      symbol: currencySymbol.isEmpty ? '$currencyCode ' : '$currencySymbol ',
      decimalDigits: 2,
    );
  }

  /// Formats an amount using the configured currency, e.g. "KSh 1,250.00".
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
  /// the symbol only on the lower bound, e.g. "KSh 1,000.00 – 3,200.00".
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
    currencyCode = g('currency_code') ?? currencyCode;
    currencySymbol = g('currency_symbol') ?? currencySymbol;
    taxRate = double.tryParse(g('tax_rate') ?? '') ?? taxRate;
    lowStockDefault = int.tryParse(g('low_stock_default') ?? '') ?? lowStockDefault;
    loyaltyStep = int.tryParse(g('loyalty_step') ?? '') ?? loyaltyStep;
    _rebuildFormatter();
    notifyListeners();
  }

  Future<void> save({
    String? shopName,
    String? shopAddress,
    String? shopPhone,
    String? receiptFooter,
    String? currencyCode,
    String? currencySymbol,
    double? taxRate,
    int? lowStockDefault,
    int? loyaltyStep,
  }) async {
    if (shopName != null) this.shopName = shopName;
    if (shopAddress != null) this.shopAddress = shopAddress;
    if (shopPhone != null) this.shopPhone = shopPhone;
    if (receiptFooter != null) this.receiptFooter = receiptFooter;
    if (currencyCode != null) this.currencyCode = currencyCode;
    if (currencySymbol != null) this.currencySymbol = currencySymbol;
    if (taxRate != null) this.taxRate = taxRate;
    if (lowStockDefault != null) this.lowStockDefault = lowStockDefault;
    if (loyaltyStep != null) this.loyaltyStep = loyaltyStep;

    final db = await DB.instance();
    final map = <String, String>{
      'shop_name': this.shopName,
      'shop_address': this.shopAddress,
      'shop_phone': this.shopPhone,
      'receipt_footer': this.receiptFooter,
      'currency_code': this.currencyCode,
      'currency_symbol': this.currencySymbol,
      'tax_rate': this.taxRate.toString(),
      'low_stock_default': this.lowStockDefault.toString(),
      'loyalty_step': this.loyaltyStep.toString(),
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
