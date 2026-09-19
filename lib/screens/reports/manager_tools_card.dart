import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/approvals.dart';
import '../../services/audit.dart';
import '../../state/auth.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';
import '../settings/audit_log_screen.dart';

/// Manager tools live with the manager's workspace (Reports), not in
/// Settings: the approval PIN used to gate refunds/discounts, the discount
/// threshold that decides when that gate fires, and the audit trail.
class ManagerToolsCard extends StatefulWidget {
  const ManagerToolsCard({super.key});

  @override
  State<ManagerToolsCard> createState() => _ManagerToolsCardState();
}

class _ManagerToolsCardState extends State<ManagerToolsCard> {
  late final TextEditingController _discPin;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppSettings>();
    _discPin = TextEditingController(
        text: s.discountPinThreshold == 0
            ? '0'
            : (s.discountPinThreshold % 1 == 0
                ? s.discountPinThreshold.toStringAsFixed(0)
                : s.discountPinThreshold.toString()));
  }

  @override
  void dispose() {
    _discPin.dispose();
    super.dispose();
  }

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? AppColors.danger : null,
    ));
  }

  // ---- manager PIN (approvals) ----

  Future<void> _changePin() async {
    final pin1 = TextEditingController();
    final pin2 = TextEditingController();
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          title: const Text('Set manager PIN'),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Cashiers type this PIN to approve refunds and manual '
                  'discounts. Keep it manager-only.',
                  style: TextStyle(fontSize: 12, color: AppColors.muted,
                      height: 1.4),
                ),
                const SizedBox(height: AppSpace.s3),
                TextField(
                  controller: pin1,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 8,
                  autofocus: true,
                  decoration: const InputDecoration(
                      labelText: 'New PIN (4–8 digits)', counterText: ''),
                ),
                const SizedBox(height: AppSpace.s3),
                TextField(
                  controller: pin2,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 8,
                  decoration: const InputDecoration(
                      labelText: 'Repeat PIN', counterText: ''),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpace.s2),
                    child: Text(error!,
                        style: TextStyle(
                            color: AppColors.danger, fontSize: 12)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                if (pin1.text != pin2.text) {
                  setD(() => error = 'PINs do not match.');
                  return;
                }
                final err = await Approvals.setPin(pin1.text);
                if (err != null) {
                  setD(() => error = err);
                  return;
                }
                if (!c.mounted) return;
                Navigator.pop(c, true);
              },
              child: const Text('Save PIN'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final me = context.read<AuthProvider>().user;
    await Audit.add('pin_changed', 'Manager PIN set or changed',
        userId: me?.id, userName: me?.name);
    if (!mounted) return;
    setState(() {}); // refresh the PIN status row
    _toast('Manager PIN saved');
  }

  Future<void> _removePin() async {
    final me = context.read<AuthProvider>().user;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Remove the PIN?'),
        content: const SizedBox(
          width: 360,
          child: Text(
              'Approvals will fall back to a manager account email and '
              'password until a new PIN is set.'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await Approvals.clearPin();
    await Audit.add('pin_changed', 'Manager PIN removed',
        userId: me?.id, userName: me?.name);
    if (!mounted) return;
    setState(() {});
    _toast('PIN removed');
  }

  Future<void> _saveThreshold() async {
    await context.read<AppSettings>().save(
          discountPinThreshold:
              (double.tryParse(_discPin.text) ?? 0).clamp(0.0, double.maxFinite),
        );
    _toast('Approval threshold saved');
  }

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      icon: Icons.verified_user_outlined,
      title: 'Manager tools',
      subtitle: 'Approval PIN · discount gate · audit trail',
      children: [
        FutureBuilder<bool>(
          future: Approvals.hasPin(),
          builder: (context, snap) {
            final has = snap.data ?? false;
            return Row(
              children: [
                Icon(
                  has ? Icons.pin_rounded : Icons.pin_outlined,
                  size: 18,
                  color: has ? AppColors.success : AppColors.warning,
                ),
                const SizedBox(width: AppSpace.s2),
                Expanded(
                  child: Text(
                    has
                        ? 'Manager PIN is set — cashiers approve with '
                            'the PIN or a manager password'
                        : 'No PIN set — approvals ask for a manager '
                            'account email and password',
                    style: TextStyle(
                        fontFamily: 'Carlito',
                        fontSize: 12,
                        color: AppColors.body),
                  ),
                ),
                TextButton(
                  onPressed: _changePin,
                  child: Text(has ? 'Change' : 'Set PIN'),
                ),
                if (has)
                  TextButton(
                    onPressed: _removePin,
                    child: Text('Remove',
                        style: TextStyle(color: AppColors.danger)),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: AppSpace.s2),
        TextField(
          controller: _discPin,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Discount approval threshold (Br)',
            helperText:
                'Discounts at or above this need manager approval '
                'when a salesperson checks out. 0 = every discount.',
          ),
        ),
        const SizedBox(height: AppSpace.s3),
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: _saveThreshold,
              icon: const Icon(Icons.save_outlined, size: 17),
              label: const Text('Save threshold'),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.s2),
        Text(
          'Salespeople only see their own sales; refunds and stock '
          'adjustments stay manager-controlled.',
          style: TextStyle(
              fontFamily: 'Carlito',
              fontSize: 11,
              color: AppColors.faint),
        ),
        const SizedBox(height: AppSpace.s2),
        Card(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: AppColors.surfaceTint,
          child: ListTile(
            dense: true,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.md)),
            leading: Icon(Icons.history_rounded,
                size: 20, color: AppColors.primary),
            title: const Text('Audit log',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            subtitle: Text('Who refunded, approved, adjusted and closed',
                style: TextStyle(fontSize: 11, color: AppColors.muted)),
            trailing: Icon(Icons.chevron_right_rounded,
                size: 20, color: AppColors.faint),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AuditLogScreen())),
          ),
        ),
      ],
    );
  }
}
