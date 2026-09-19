/// One commission row: money owed to a salesperson.
///
/// Rows appear automatically at checkout (basis `sale`, computed from the
/// seller's commission rate) or as manual adjustments the manager enters
/// (basis `adjustment`, which may be negative — e.g. a cash advance).
/// Payouts flip [status] to `paid`; the report buckets by [period] (YYYY-MM).
class Commission {
  final int? id;
  final int userId;
  final int? saleId;
  final double amount;
  final String basis; // sale | adjustment
  final String status; // pending | paid
  final String? note;
  final String period;
  final int? paidAt;
  final int createdAt;

  const Commission({
    this.id,
    required this.userId,
    this.saleId,
    required this.amount,
    this.basis = 'sale',
    this.status = 'pending',
    this.note,
    this.period = '',
    this.paidAt,
    required this.createdAt,
  });

  bool get isPaid => status == 'paid';
  bool get isAdjustment => basis == 'adjustment';

  Commission copyWith({String? status, int? paidAt, String? note}) =>
      Commission(
        id: id,
        userId: userId,
        saleId: saleId,
        amount: amount,
        basis: basis,
        status: status ?? this.status,
        note: note ?? this.note,
        period: period,
        paidAt: paidAt ?? this.paidAt,
        createdAt: createdAt,
      );

  factory Commission.fromMap(Map<String, Object?> m) => Commission(
        id: m['id'] as int?,
        userId: m['user_id'] as int? ?? 0,
        saleId: m['sale_id'] as int?,
        amount: (m['amount'] as num? ?? 0).toDouble(),
        basis: m['basis'] as String? ?? 'sale',
        status: m['status'] as String? ?? 'pending',
        note: m['note'] as String?,
        period: m['period'] as String? ?? '',
        paidAt: m['paid_at'] as int?,
        createdAt: m['created_at'] as int? ?? 0,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'user_id': userId,
        'sale_id': saleId,
        'amount': amount,
        'basis': basis,
        'status': status,
        'note': note,
        'period': period,
        'paid_at': paidAt,
        'created_at': createdAt,
      };
}
