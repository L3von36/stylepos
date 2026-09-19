/// A promotion: a coupon code or a seasonal campaign the cashier can
/// apply to a sale at the till.
///
/// Both kinds live in one table — a *coupon* is a plain code (WELCOME10),
/// a *campaign* is the same mechanism presented with a date window
/// ("Summer Sale", runs 1–31 Dec, code SUMMER25). Discount math is
/// identical; the kind only drives labelling and default date fields.
///
/// Lifecycle rules enforced at apply time (POS):
///  * [active] must be on;
///  * now must fall inside [startsAt]..[endsAt] (when set);
///  * cart subtotal must reach [minSubtotal];
///  * [usageLimit] (0 = unlimited) must not be exhausted.
class Promotion {
  final int? id;
  final String name;
  final String code;

  /// coupon | campaign
  final String kind;

  /// percent | fixed
  final String type;

  /// percent (0-100) or a flat amount in shop currency.
  final double value;
  final double minSubtotal;
  final int? startsAt; // epoch seconds, null = starts immediately
  final int? endsAt; // epoch seconds, null = never expires
  final int usageLimit; // 0 = unlimited
  final int usedCount;
  final bool active;
  final int createdAt;

  const Promotion({
    this.id,
    required this.name,
    required this.code,
    this.kind = 'coupon',
    this.type = 'percent',
    this.value = 0,
    this.minSubtotal = 0,
    this.startsAt,
    this.endsAt,
    this.usageLimit = 0,
    this.usedCount = 0,
    this.active = true,
    required this.createdAt,
  });

  bool get isCampaign => kind == 'campaign';
  bool get isPercent => type == 'percent';

  /// Why this promotion cannot be applied right now, or null when it can.
  String? blockedReason({int? nowEpoch, double? subtotal}) {
    final now = nowEpoch ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (!active) return 'This promotion is paused.';
    if (startsAt != null && startsAt! > now) {
      return 'Not started yet — begins ${_fmtDate(startsAt!)}.';
    }
    if (endsAt != null && endsAt! < now) {
      return 'Expired on ${_fmtDate(endsAt!)}.';
    }
    if (usageLimit > 0 && usedCount >= usageLimit) {
      return 'Usage limit reached ($usedCount of $usageLimit).';
    }
    if (subtotal != null && subtotal < minSubtotal) {
      return 'Needs a minimum subtotal of $minSubtotal.';
    }
    return null;
  }

  /// Discount for the given subtotal (already clamped to it).
  double discountFor(double subtotal) {
    if (subtotal <= 0) return 0;
    final raw = isPercent ? subtotal * value / 100.0 : value;
    return raw.clamp(0.0, subtotal);
  }

  String describe(AppMoneyFmt fmt) => isPercent
      ? '${_trimNum(value)}% off'
      : '${fmt(value)} off';

  static String _trimNum(double v) => trimPublic(v);

  /// Public number formatter: 10 → "10", 12.5 → "12.50".
  static String trimPublic(double v) =>
      v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  static String _fmtDate(int epoch) {
    final d = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
    two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Promotion copyWith({
    String? name,
    String? code,
    String? kind,
    String? type,
    double? value,
    double? minSubtotal,
    int? startsAt,
    int? endsAt,
    int? usageLimit,
    int? usedCount,
    bool? active,
    Object? clearStarts = _none,
    Object? clearEnds = _none,
  }) =>
      Promotion(
        id: id,
        name: name ?? this.name,
        code: code ?? this.code,
        kind: kind ?? this.kind,
        type: type ?? this.type,
        value: value ?? this.value,
        minSubtotal: minSubtotal ?? this.minSubtotal,
        startsAt: clearStarts == _none ? (startsAt ?? this.startsAt) : startsAt,
        endsAt: clearEnds == _none ? (endsAt ?? this.endsAt) : endsAt,
        usageLimit: usageLimit ?? this.usageLimit,
        usedCount: usedCount ?? this.usedCount,
        active: active ?? this.active,
        createdAt: createdAt,
      );

  factory Promotion.fromMap(Map<String, Object?> m) => Promotion(
        id: m['id'] as int?,
        name: m['name'] as String? ?? '',
        code: (m['code'] as String? ?? '').toUpperCase(),
        kind: m['kind'] as String? ?? 'coupon',
        type: m['type'] as String? ?? 'percent',
        value: (m['value'] as num? ?? 0).toDouble(),
        minSubtotal: (m['min_subtotal'] as num? ?? 0).toDouble(),
        startsAt: m['starts_at'] as int?,
        endsAt: m['ends_at'] as int?,
        usageLimit: m['usage_limit'] as int? ?? 0,
        usedCount: m['used_count'] as int? ?? 0,
        active: (m['active'] as int? ?? 1) == 1,
        createdAt: m['created_at'] as int? ?? 0,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'code': code.toUpperCase(),
        'kind': kind,
        'type': type,
        'value': value,
        'min_subtotal': minSubtotal,
        'starts_at': startsAt,
        'ends_at': endsAt,
        'usage_limit': usageLimit,
        'used_count': usedCount,
        'active': active ? 1 : 0,
        'created_at': createdAt,
      };

  static const _none = Object();
}

/// Money formatter hook so the model can render "KSh 200 off" without a
/// Flutter import (tests pass a plain function).
typedef AppMoneyFmt = String Function(double v);
