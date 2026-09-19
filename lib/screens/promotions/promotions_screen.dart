import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/promotion.dart';
import '../../state/auth.dart';
import '../../state/promotions.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';

/// Manager screen: coupons + seasonal sale campaigns.
///
/// A promotion is a code the cashier applies at the till. A *campaign* is
/// the same mechanism with a date window and a campaign name — "Summer
/// Sale, SUMMER25, 10% off, 1–31 Dec". Usage counts come from real sales
/// (sales.promo_code), so the list always shows true uptake.
class PromotionsScreen extends StatefulWidget {
  const PromotionsScreen({super.key});

  @override
  State<PromotionsScreen> createState() => _PromotionsScreenState();
}

class _PromotionsScreenState extends State<PromotionsScreen> {
  Map<String, int> _usage = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final usage = await context.read<PromotionsProvider>().usageByCode();
    if (mounted) setState(() => _usage = usage);
  }

  @override
  Widget build(BuildContext context) {
    final promos = context.watch<PromotionsProvider>();
    final settings = context.watch<AppSettings>();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    final live = <Promotion>[];
    final scheduled = <Promotion>[];
    final expired = <Promotion>[];
    for (final p in promos.promotions) {
      if (!p.active) {
        expired.add(p);
      } else if (p.startsAt != null && p.startsAt! > now) {
        scheduled.add(p);
      } else if (p.endsAt != null && p.endsAt! < now) {
        expired.add(p);
      } else {
        live.add(p);
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Promotions')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editPromotion(context),
        icon: const Icon(Icons.add_rounded, size: 20),
        label: const Text('New promotion'),
      ),
      body: promos.loading && promos.promotions.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                  AppSpace.s4, AppSpace.s4, AppSpace.s4, AppSpace.s10),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Cashiers apply these codes at checkout — they can '
                        'use them but never create or edit them.',
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 12,
                            color: AppColors.muted),
                      ),
                      const SizedBox(height: AppSpace.s4),
                      if (promos.promotions.isEmpty)
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(AppSpace.s6),
                            child: Column(
                              children: [
                                Icon(Icons.sell_outlined,
                                    size: 40, color: AppColors.faint),
                                const SizedBox(height: AppSpace.s3),
                                Text('No promotions yet',
                                    style: TextStyle(
                                        fontFamily: 'Carlito',
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.ink)),
                                const SizedBox(height: AppSpace.s1),
                                Text(
                                  'Create a coupon like WELCOME10, or a '
                                  'seasonal campaign with start and end dates.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      fontFamily: 'Carlito',
                                      fontSize: 12,
                                      color: AppColors.muted),
                                ),
                              ],
                            ),
                          ),
                        )
                      else ...[
                        if (live.isNotEmpty) ...[
                          _groupLabel('Live now', AppColors.success),
                          for (final p in live)
                            _PromoTile(
                              promo: p,
                              usage: _usage[p.code.toUpperCase()] ?? p.usedCount,
                              onEdit: () => _editPromotion(context, existing: p),
                              onDelete: () => _deletePromotion(context, p),
                              onCopied: () => _load(),
                            ),
                        ],
                        if (scheduled.isNotEmpty) ...[
                          _groupLabel('Scheduled', AppColors.info),
                          for (final p in scheduled)
                            _PromoTile(
                              promo: p,
                              usage: _usage[p.code.toUpperCase()] ?? p.usedCount,
                              onEdit: () => _editPromotion(context, existing: p),
                              onDelete: () => _deletePromotion(context, p),
                              onCopied: () => _load(),
                            ),
                        ],
                        if (expired.isNotEmpty) ...[
                          _groupLabel('Paused / expired', AppColors.muted),
                          for (final p in expired)
                            _PromoTile(
                              promo: p,
                              usage: _usage[p.code.toUpperCase()] ?? p.usedCount,
                              onEdit: () => _editPromotion(context, existing: p),
                              onDelete: () => _deletePromotion(context, p),
                              onCopied: () => _load(),
                            ),
                        ],
                      ],
                      Text(
                        'Settings currency: ${settings.currencyCode}. Usage '
                        'counts update as sales sync in from every till.',
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 11,
                            color: AppColors.faint),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _groupLabel(String label, Color color) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpace.s2),
        child: Row(children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: AppSpace.s2),
          Text(label.toUpperCase(),
              style: TextStyle(
                  fontFamily: 'Carlito',
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: AppColors.muted)),
        ]),
      );

  Future<void> _editPromotion(BuildContext context, {Promotion? existing}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _PromoEditDialog(existing: existing),
    );
    if (saved == true) _load();
  }

  Future<void> _deletePromotion(BuildContext context, Promotion p) async {
    final auth = context.read<AuthProvider>();
    final promos = context.read<PromotionsProvider>();
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete promotion?'),
        content: SizedBox(
          width: 380,
          child: Text(
              '${p.code} (${p.name}) will stop working at the till on every '
              'device. Sales already made keep their discount.'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    await promos.delete(p,
        actorUserId: auth.user?.id, actorName: auth.user?.name);
    _load();
  }
}

class _PromoTile extends StatelessWidget {
  final Promotion promo;
  final int usage;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onCopied;

  const _PromoTile({
    required this.promo,
    required this.usage,
    required this.onEdit,
    required this.onDelete,
    required this.onCopied,
  });

  String _date(int? epoch) {
    if (epoch == null) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
    two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final discount = promo.isPercent
        ? '${Promotion.trimPublic(promo.value)}% off'
        : '${settings.money(promo.value)} off';

    return Card(
      margin: const EdgeInsets.only(bottom: AppSpace.s2),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpace.s4, AppSpace.s3, AppSpace.s2, AppSpace.s3),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color:
                    promo.isCampaign ? AppColors.infoSoft : AppColors.primarySoft,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Icon(
                promo.isCampaign ? Icons.campaign_outlined : Icons.sell_outlined,
                size: 21,
                color: promo.isCampaign ? AppColors.info : AppColors.primary,
              ),
            ),
            const SizedBox(width: AppSpace.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(promo.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontFamily: 'Carlito',
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: AppColors.ink)),
                    ),
                    const SizedBox(width: AppSpace.s2),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpace.s2, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceTint,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Text(
                        promo.isCampaign ? 'Campaign' : 'Coupon',
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: AppColors.muted),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 2),
                  Text(
                    '$discount · min ${settings.money(promo.minSubtotal)} · '
                    '${_date(promo.startsAt)} → ${_date(promo.endsAt)} · '
                    'used $usage${promo.usageLimit > 0 ? '/${promo.usageLimit}' : ''}'
                    '${promo.active ? '' : ' · PAUSED'}',
                    style: TextStyle(
                        fontFamily: 'Carlito',
                        fontSize: 12,
                        color: AppColors.muted),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Copy code',
              icon: Icon(Icons.copy_rounded, size: 18, color: AppColors.info),
              onPressed: () {
                onCopied();
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(
                      'Code ${promo.code} — share it with cashiers or print '
                      'it at the counter'),
                  behavior: SnackBarBehavior.floating,
                ));
              },
            ),
            IconButton(
              tooltip: 'Edit',
              icon:
                  Icon(Icons.edit_outlined, size: 18, color: AppColors.primary),
              onPressed: onEdit,
            ),
            IconButton(
              tooltip: 'Delete',
              icon: Icon(Icons.delete_outline_rounded,
                  size: 18, color: AppColors.danger),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

class _PromoEditDialog extends StatefulWidget {
  final Promotion? existing;
  const _PromoEditDialog({this.existing});

  @override
  State<_PromoEditDialog> createState() => _PromoEditDialogState();
}

class _PromoEditDialogState extends State<_PromoEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _code;
  late final TextEditingController _value;
  late final TextEditingController _min;
  late final TextEditingController _limit;
  late String _kind;
  late String _type;
  late bool _active;
  DateTime? _starts;
  DateTime? _ends;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _code = TextEditingController(text: e?.code ?? '');
    _value = TextEditingController(
        text: e == null
            ? ''
            : (e.value % 1 == 0 ? e.value.toStringAsFixed(0) : e.value.toString()));
    _min = TextEditingController(
        text: e == null || e.minSubtotal == 0 ? '' : e.minSubtotal.toString());
    _limit = TextEditingController(
        text: e == null || e.usageLimit == 0 ? '' : e.usageLimit.toString());
    _kind = e?.kind ?? 'coupon';
    _type = e?.type ?? 'percent';
    _active = e?.active ?? true;
    _starts = e?.startsAt != null
        ? DateTime.fromMillisecondsSinceEpoch(e!.startsAt! * 1000)
        : null;
    _ends = e?.endsAt != null
        ? DateTime.fromMillisecondsSinceEpoch(e!.endsAt! * 1000)
        : null;
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    _value.dispose();
    _min.dispose();
    _limit.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool start}) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: (start ? _starts : _ends) ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (picked == null) return;
    setState(() {
      if (start) {
        _starts = picked;
      } else {
        _ends = DateTime(picked.year, picked.month, picked.day, 23, 59, 59);
      }
    });
  }

  Future<void> _save() async {
    final auth = context.read<AuthProvider>();
    final err = await context.read<PromotionsProvider>().save(
          Promotion(
            id: widget.existing?.id,
            name: _name.text.trim(),
            code: _code.text.trim(),
            kind: _kind,
            type: _type,
            value: double.tryParse(_value.text) ?? 0,
            minSubtotal: double.tryParse(_min.text) ?? 0,
            startsAt: _starts == null
                ? null
                : _starts!.millisecondsSinceEpoch ~/ 1000,
            endsAt: _ends == null
                ? null
                : _ends!.millisecondsSinceEpoch ~/ 1000,
            usageLimit: int.tryParse(_limit.text) ?? 0,
            active: _active,
            createdAt: widget.existing?.createdAt ??
                DateTime.now().millisecondsSinceEpoch ~/ 1000,
          ),
          actorUserId: auth.user?.id,
          actorName: auth.user?.name,
        );
    if (!mounted) return;
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      title: Row(children: [
        Icon(
            widget.existing == null
                ? Icons.add_circle_outline
                : Icons.edit_outlined,
            size: 22,
            color: AppColors.primary),
        const SizedBox(width: AppSpace.s2),
        Text(widget.existing == null ? 'New promotion' : 'Edit promotion'),
      ]),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<String>(
                showSelectedIcon: false,
                style: primarySegmentStyle(),
                segments: const [
                  ButtonSegment(value: 'coupon', label: Text('Coupon')),
                  ButtonSegment(
                      value: 'campaign', label: Text('Seasonal campaign')),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() => _kind = s.first),
              ),
              const SizedBox(height: AppSpace.s3),
              TextField(
                controller: _name,
                decoration: InputDecoration(
                  labelText: 'Name',
                  helperText: _kind == 'campaign'
                      ? 'Shown in reports, e.g. "December Sale"'
                      : 'e.g. "New customer welcome"',
                ),
              ),
              const SizedBox(height: AppSpace.s3),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _code,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                        labelText: 'Code', helperText: 'What cashiers type'),
                  ),
                ),
                const SizedBox(width: AppSpace.s3),
                Expanded(
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'percent', label: Text('%')),
                      ButtonSegment(value: 'fixed', label: Text('Amount')),
                    ],
                    selected: {_type},
                    onSelectionChanged: (s) => setState(() => _type = s.first),
                  ),
                ),
              ]),
              const SizedBox(height: AppSpace.s3),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _value,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText:
                          _type == 'percent' ? 'Discount (%)' : 'Discount amount',
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.s3),
                Expanded(
                  child: TextField(
                    controller: _min,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Min. subtotal', helperText: '0 = none'),
                  ),
                ),
              ]),
              const SizedBox(height: AppSpace.s3),
              Row(children: [
                Expanded(
                  child: _DateTile(
                    label: 'Starts',
                    date: _starts,
                    onTap: () => _pickDate(start: true),
                    onClear: _starts == null
                        ? null
                        : () => setState(() => _starts = null),
                  ),
                ),
                const SizedBox(width: AppSpace.s3),
                Expanded(
                  child: _DateTile(
                    label: 'Ends',
                    date: _ends,
                    onTap: () => _pickDate(start: false),
                    onClear: _ends == null
                        ? null
                        : () => setState(() => _ends = null),
                  ),
                ),
              ]),
              const SizedBox(height: AppSpace.s3),
              TextField(
                controller: _limit,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Usage limit',
                    helperText: 'How many sales may use it · 0 = unlimited'),
              ),
              const SizedBox(height: AppSpace.s2),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                activeThumbColor: AppColors.primary,
                title: const Text('Active (cashiers can apply it)'),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpace.s2),
                  child: Text(_error!,
                      style: TextStyle(
                          fontFamily: 'Carlito',
                          fontSize: 12,
                          color: AppColors.danger)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel')),
        FilledButton.icon(
          onPressed: _save,
          icon: const Icon(Icons.save_outlined, size: 18),
          label: const Text('Save promotion'),
        ),
      ],
    );
  }
}

class _DateTile extends StatelessWidget {
  final String label;
  final DateTime? date;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  const _DateTile({
    required this.label,
    required this.date,
    required this.onTap,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final text = date == null
        ? 'Any time'
        : '${date!.year}-${date!.month.toString().padLeft(2, '0')}-${date!.day.toString().padLeft(2, '0')}';
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      onTap: onTap,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: onClear != null
              ? InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  onTap: onClear,
                  child:
                      Icon(Icons.close_rounded, size: 16, color: AppColors.muted))
              : Icon(Icons.calendar_today_rounded,
                  size: 16, color: AppColors.faint),
        ),
        child: Text(text,
            style: TextStyle(
                fontFamily: 'Carlito',
                fontSize: 13,
                color: date == null ? AppColors.faint : AppColors.ink)),
      ),
    );
  }
}
