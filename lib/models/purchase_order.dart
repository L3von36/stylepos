/// A purchase order: stock the shop ordered from a supplier.
///
/// Lifecycle: `draft` (still editing lines) → `ordered` (sent to the
/// supplier) → `received` (every line fully delivered) — or `cancelled`.
/// Receiving a line tops the variant's stock up and updates its cost price,
/// so margins always reflect the latest buy price.
class PurchaseOrder {
  final int? id;
  final int? supplierId;
  final String status; // draft | ordered | received | cancelled
  final int? orderDate;
  final int? expectedDate;
  final int? receivedDate;
  final String? notes;
  final int createdBy;
  final int createdAt;

  const PurchaseOrder({
    this.id,
    this.supplierId,
    this.status = 'draft',
    this.orderDate,
    this.expectedDate,
    this.receivedDate,
    this.notes,
    this.createdBy = 0,
    required this.createdAt,
  });

  bool get isDraft => status == 'draft';
  bool get isOrdered => status == 'ordered';
  bool get isReceived => status == 'received';
  bool get isCancelled => status == 'cancelled';
  bool get isOpen => status == 'draft' || status == 'ordered';

  PurchaseOrder copyWith({
    int? supplierId,
    String? status,
    int? orderDate,
    int? expectedDate,
    int? receivedDate,
    String? notes,
    Object? clearExpected = _none,
  }) =>
      PurchaseOrder(
        id: id,
        supplierId: supplierId ?? this.supplierId,
        status: status ?? this.status,
        orderDate: orderDate ?? this.orderDate,
        expectedDate: clearExpected == _none
            ? this.expectedDate
            : clearExpected as int?,
        receivedDate: receivedDate ?? this.receivedDate,
        notes: notes ?? this.notes,
        createdBy: createdBy,
        createdAt: createdAt,
      );

  factory PurchaseOrder.fromMap(Map<String, Object?> m) => PurchaseOrder(
        id: m['id'] as int?,
        supplierId: m['supplier_id'] as int?,
        status: m['status'] as String? ?? 'draft',
        orderDate: m['order_date'] as int?,
        expectedDate: m['expected_date'] as int?,
        receivedDate: m['received_date'] as int?,
        notes: m['notes'] as String?,
        createdBy: m['created_by'] as int? ?? 0,
        createdAt: m['created_at'] as int? ?? 0,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'supplier_id': supplierId,
        'status': status,
        'order_date': orderDate,
        'expected_date': expectedDate,
        'received_date': receivedDate,
        'notes': notes,
        'created_by': createdBy,
        'created_at': createdAt,
      };

  static const _none = Object();
}

/// One line on a purchase order. [variantId] is 0/null for free-text items
/// (goods the shop does not track as a variant yet).
class PurchaseOrderItem {
  final int? id;
  final int poId;
  final int? variantId;
  final String productName;
  final String variantDesc;
  final String sku;
  final int qtyOrdered;
  final int qtyReceived;
  final double unitCost;

  const PurchaseOrderItem({
    this.id,
    required this.poId,
    this.variantId,
    this.productName = '',
    this.variantDesc = '',
    this.sku = '',
    this.qtyOrdered = 0,
    this.qtyReceived = 0,
    this.unitCost = 0,
  });

  int get qtyOutstanding => (qtyOrdered - qtyReceived).clamp(0, 1 << 31);
  double get lineTotal => unitCost * qtyOrdered;
  bool get fullyReceived => qtyReceived >= qtyOrdered;

  PurchaseOrderItem copyWith({
    int? poId,
    int? variantId,
    String? productName,
    String? variantDesc,
    String? sku,
    int? qtyOrdered,
    int? qtyReceived,
    double? unitCost,
  }) =>
      PurchaseOrderItem(
        id: id,
        poId: poId ?? this.poId,
        variantId: variantId ?? this.variantId,
        productName: productName ?? this.productName,
        variantDesc: variantDesc ?? this.variantDesc,
        sku: sku ?? this.sku,
        qtyOrdered: qtyOrdered ?? this.qtyOrdered,
        qtyReceived: qtyReceived ?? this.qtyReceived,
        unitCost: unitCost ?? this.unitCost,
      );

  factory PurchaseOrderItem.fromMap(Map<String, Object?> m) =>
      PurchaseOrderItem(
        id: m['id'] as int?,
        poId: m['po_id'] as int,
        variantId: m['variant_id'] as int?,
        productName: m['product_name'] as String? ?? '',
        variantDesc: m['variant_desc'] as String? ?? '',
        sku: m['sku'] as String? ?? '',
        qtyOrdered: m['qty_ordered'] as int? ?? 0,
        qtyReceived: m['qty_received'] as int? ?? 0,
        unitCost: (m['unit_cost'] as num? ?? 0).toDouble(),
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'po_id': poId,
        'variant_id': variantId,
        'product_name': productName,
        'variant_desc': variantDesc,
        'sku': sku,
        'qty_ordered': qtyOrdered,
        'qty_received': qtyReceived,
        'unit_cost': unitCost,
      };
}
