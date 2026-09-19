import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/attendance.dart';
import '../../widgets/ui.dart';

/// Manager view of the staff shift log (clock in / clock out punches made
/// on this device). Reachable from Staff accounts (clock icon) — the log
/// lives on the till where the punches happened.
class ShiftLogsScreen extends StatefulWidget {
  const ShiftLogsScreen({super.key});

  @override
  State<ShiftLogsScreen> createState() => _ShiftLogsScreenState();
}

class _ShiftLogsScreenState extends State<ShiftLogsScreen> {
  List<({Shift shift, String userName})>? _logs;
  int _days = 7;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final logs =
        await context.read<AttendanceProvider>().logs(days: _days);
    if (mounted) setState(() => _logs = logs);
  }

  String _hm(int epoch) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.hour)}:${two(dt.minute)}';
  }

  String _day(int epoch) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}/${two(dt.month)}';
  }

  @override
  Widget build(BuildContext context) {
    final attendance = context.watch<AttendanceProvider>();
    if (attendance.revision != (_rev ?? 0)) {
      _rev = attendance.revision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Shift logs')),
      body: _logs == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(AppSpace.s4),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 660),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SegmentedButton<int>(
                            showSelectedIcon: false,
                            style: primarySegmentStyle(),
                            segments: const [
                              ButtonSegment(value: 1, label: Text('Today')),
                              ButtonSegment(value: 7, label: Text('7 days')),
                              ButtonSegment(value: 30, label: Text('30 days')),
                              ButtonSegment(value: 0, label: Text('All')),
                            ],
                            selected: {_days},
                            onSelectionChanged: (s) {
                              setState(() => _days = s.first);
                              _load();
                            },
                          ),
                          const SizedBox(height: AppSpace.s4),
                          if (_logs!.isEmpty)
                            const EmptyState(
                              icon: Icons.badge_outlined,
                              title: 'No shifts in this period',
                              message:
                                  'Staff clock in and out from the strip on the Sell screen.',
                            )
                          else
                            for (final l in _logs!)
                              Container(
                                margin:
                                    const EdgeInsets.only(bottom: AppSpace.s2),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpace.s4,
                                    vertical: AppSpace.s3),
                                decoration: BoxDecoration(
                                  color: AppColors.surface,
                                  borderRadius:
                                      BorderRadius.circular(AppRadius.md),
                                  border:
                                      Border.all(color: AppColors.borderSoft),
                                ),
                                child: Row(
                                  children: [
                                    InitialsAvatar(l.userName, size: 36),
                                    const SizedBox(width: AppSpace.s3),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(l.userName,
                                              style: TextStyle(
                                                  fontFamily: 'Carlito',
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w700,
                                                  color: AppColors.ink)),
                                          const SizedBox(height: 2),
                                          Text(
                                            '${_day(l.shift.clockIn)} '
                                            '${_hm(l.shift.clockIn)} → '
                                            '${l.shift.clockOut == null ? 'still on duty' : _hm(l.shift.clockOut!)}',
                                            style: TextStyle(
                                                fontFamily: 'Carlito',
                                                fontSize: 12,
                                                color: AppColors.muted),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: AppSpace.s2,
                                          vertical: 3),
                                      decoration: BoxDecoration(
                                        color: l.shift.isOpen
                                            ? AppColors.successSoft
                                            : AppColors.surfaceTint,
                                        borderRadius: BorderRadius.circular(
                                            AppRadius.pill),
                                      ),
                                      child: Text(
                                        l.shift.isOpen
                                            ? 'On duty'
                                            : l.shift.durationLabel,
                                        style: TextStyle(
                                            fontFamily: 'Carlito',
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: l.shift.isOpen
                                                ? AppColors.success
                                                : AppColors.body),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          if (_logs!.isNotEmpty) ...[
                            const SizedBox(height: AppSpace.s2),
                            Text(
                              'Shifts are recorded on this device — the log '
                              'belongs to the till where staff punch in.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontFamily: 'Carlito',
                                  fontSize: 11,
                                  color: AppColors.faint),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  int? _rev;
}
