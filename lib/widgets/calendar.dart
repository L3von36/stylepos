import 'package:flutter/material.dart';

import '../core/calendar_logic.dart';
import 'ui.dart';

const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

const _weekdayLabels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

/// Month-grid sales calendar. Each completed-sale day cell shows the day
/// number plus the day's compact revenue; tapping a cell hands the local
/// day back to the caller ([onDayTap]).
///
/// Pure presentation: the parent owns month navigation state and the
/// totals map (keys are [dayKey] strings), so the same widget serves the
/// Reports card and the Sales-screen day filter.
class MonthCalendar extends StatelessWidget {
  final DateTime month; // any date inside the shown month
  final Map<String, ({int orders, double revenue})> totals;
  final DateTime? selectedDay;
  final ValueChanged<DateTime> onDayTap;
  final VoidCallback? onPrevMonth;
  final VoidCallback? onNextMonth; // null = navigation forward disabled
  final DateTime? now; // injectable today (tests); defaults to real now

  const MonthCalendar({
    super.key,
    required this.month,
    required this.totals,
    required this.onDayTap,
    this.selectedDay,
    this.onPrevMonth,
    this.onNextMonth,
    this.now,
  });

  @override
  Widget build(BuildContext context) {
    final today = now ?? DateTime.now();
    final grid = monthGrid(month);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // month switcher
        Row(
          children: [
            IconButton(
              tooltip: 'Previous month',
              onPressed: onPrevMonth,
              icon: const Icon(Icons.chevron_left_rounded, size: 22),
              color: AppColors.muted,
            ),
            Expanded(
              child: Text(
                '${_monthNames[month.month - 1]} ${month.year}',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontFamily: 'Carlito',
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.ink),
              ),
            ),
            IconButton(
              tooltip: 'Next month',
              onPressed: onNextMonth,
              icon: const Icon(Icons.chevron_right_rounded, size: 22),
              color: AppColors.muted,
            ),
          ],
        ),
        const SizedBox(height: AppSpace.s1),
        // weekday header
        Row(
          children: [
            for (final w in _weekdayLabels)
              Expanded(
                child: Text(w,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontFamily: 'Carlito',
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.4,
                        color: AppColors.faint)),
              ),
          ],
        ),
        const SizedBox(height: AppSpace.s1),
        // day grid
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          mainAxisSpacing: 3,
          crossAxisSpacing: 3,
          childAspectRatio: 1.16,
          children: [
            for (final cell in grid)
              if (cell == null)
                const SizedBox.shrink()
              else
                _DayCell(
                  day: cell,
                  info: totals[dayKey(cell)],
                  isToday: dayKey(cell) == dayKey(today),
                  isSelected:
                      selectedDay != null && dayKey(cell) == dayKey(selectedDay!),
                  onTap: () => onDayTap(cell),
                ),
          ],
        ),
      ],
    );
  }
}

class _DayCell extends StatelessWidget {
  final DateTime day;
  final ({int orders, double revenue})? info;
  final bool isToday;
  final bool isSelected;
  final VoidCallback onTap;

  const _DayCell({
    required this.day,
    required this.onTap,
    this.info,
    this.isToday = false,
    this.isSelected = false,
  });

  @override
  Widget build(BuildContext context) {
    final hasSales = (info?.revenue ?? 0) > 0;
    final filled = isSelected;

    final bg = filled
        ? AppColors.primary
        : hasSales
            ? AppColors.primarySoft
            : Colors.transparent;
    final fg = filled ? Colors.white : AppColors.ink;
    final moneyColor = filled
        ? Colors.white.withValues(alpha: 0.9)
        : hasSales
            ? AppColors.primary
            : AppColors.faint;

    return Material(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        side: isToday && !filled
            ? BorderSide(color: AppColors.primary, width: 1.2)
            : BorderSide(
                color: hasSales && !filled
                    ? AppColors.borderSoft
                    : Colors.transparent,
                width: 1),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('${day.day}',
                style: TextStyle(
                    fontFamily: 'Carlito',
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: fg)),
            const SizedBox(height: 1),
            Text(
              hasSales ? compactMoney(info!.revenue) : '–',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontFamily: 'Carlito',
                  fontSize: 9.5,
                  fontWeight: hasSales ? FontWeight.w700 : FontWeight.w400,
                  color: moneyColor),
            ),
          ],
        ),
      ),
    );
  }
}
