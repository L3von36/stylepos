/// A completed (or refunded) sale.
class Sale {
  final int? id;
  final String receiptNo;
  final int? customerId;
  final String? customerName;
  final int userId;
  final String? cashierName;
  final double subtotal;
  final double discount;
  final double tax;
  final double total;
  final String paymentMethod;
  final double amountPaid;
  final double changeDue;
  final String status; // 'completed' | 'refunded'
  final int createdAt; // epoch seconds (UTC)

  /// Promotion code applied at checkout (null = none), and how much it
  /// took off the subtotal — kept next to the manual [discount] so
  /// promotions reports can separate campaign impact from haggling.
  final String? promoCode;
  final double promoDiscount;

  const Sale({
    this.id,
    required this.receiptNo,
    this.customerId,
    this.customerName,
    required this.userId,
    this.cashierName,
    required this.subtotal,
    this.discount = 0,
    this.tax = 0,
    required this.total,
    required this.paymentMethod,
    this.amountPaid = 0,
    this.changeDue = 0,
    this.status = 'completed',
    required this.createdAt,
    this.promoCode,
    this.promoDiscount = 0,
  });

  bool get isRefunded => status == 'refunded';

  Sale copyWith({String? status, String? customerName, String? cashierName}) => Sale(
        id: id,
        receiptNo: receiptNo,
        customerId: customerId,
        customerName: customerName ?? this.customerName,
        userId: userId,
        cashierName: cashierName ?? this.cashierName,
        subtotal: subtotal,
        discount: discount,
        tax: tax,
        total: total,
        paymentMethod: paymentMethod,
        amountPaid: amountPaid,
        changeDue: changeDue,
        status: status ?? this.status,
        createdAt: createdAt,
      );

  factory Sale.fromMap(Map<String, Object?> m) => Sale(
        id: m['id'] as int?,
        receiptNo: m['receipt_no'] as String,
        customerId: m['customer_id'] as int?,
        customerName: m['customer_name'] as String?,
        userId: m['user_id'] as int,
        cashierName: m['cashier_name'] as String?,
        subtotal: (m['subtotal'] as num?)?.toDouble() ?? 0,
        discount: (m['discount'] as num?)?.toDouble() ?? 0,
        tax: (m['tax'] as num?)?.toDouble() ?? 0,
        total: (m['total'] as num?)?.toDouble() ?? 0,
        paymentMethod: m['payment_method'] as String? ?? 'cash',
        amountPaid: (m['amount_paid'] as num?)?.toDouble() ?? 0,
        changeDue: (m['change_due'] as num?)?.toDouble() ?? 0,
        status: m['status'] as String? ?? 'completed',
        createdAt: m['created_at'] as int? ?? 0,
        promoCode: m['promo_code'] as String?,
        promoDiscount: (m['promo_discount'] as num?)?.toDouble() ?? 0,
      );
}

/// A line item belonging to a [Sale]. Product / variant names are snapshotted
/// at sale time so receipts stay correct even if products change later.
class SaleItem {
  final int? id;
  final int saleId;
  final int variantId;
  final String productName;
  final String variantDesc;
  final double unitPrice;
  final int qty;
  final double lineTotal;

  const SaleItem({
    this.id,
    required this.saleId,
    required this.variantId,
    required this.productName,
    required this.variantDesc,
    required this.unitPrice,
    required this.qty,
    required this.lineTotal,
  });

  factory SaleItem.fromMap(Map<String, Object?> m) => SaleItem(
        id: m['id'] as int?,
        saleId: m['sale_id'] as int,
        variantId: m['variant_id'] as int,
        productName: m['product_name'] as String? ?? '',
        variantDesc: m['variant_desc'] as String? ?? '',
        unitPrice: (m['unit_price'] as num?)?.toDouble() ?? 0,
        qty: m['qty'] as int? ?? 0,
        lineTotal: (m['line_total'] as num?)?.toDouble() ?? 0,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'sale_id': saleId,
        'variant_id': variantId,
        'product_name': productName,
        'variant_desc': variantDesc,
        'unit_price': unitPrice,
        'qty': qty,
        'line_total': lineTotal,
      };
}
