import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../design/parts/calendar_choice.dart';
import '../../design/tokens.dart';
import '../../state/app_state.dart';
import '../../state/format.dart';
import '../calendar/calendar_time.dart';
import 'recurrence.dart';

enum _Ends { never, onDate, after }

/// The repeat part of the event editor: how often, on which days, and when it stops. A rule
/// from another app that Den can't express is shown as it is, read-only, until the person
/// chooses to replace it, so saving never quietly changes it.
class RecurrenceEditor extends StatelessWidget {
  const RecurrenceEditor({
    super.key,
    required this.value,
    required this.custom,
    required this.startDate,
    required this.onChanged,
    required this.onReplaceCustom,
    this.error,
  });

  /// Null when it doesn't repeat.
  final Recurrence? value;

  /// The stored rule text when Den can't express it.
  final String? custom;
  final String startDate;
  final ValueChanged<Recurrence?> onChanged;
  final VoidCallback onReplaceCustom;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final f = app.formats;
    final c = context.colors;
    final weekStart = app.den.family?.weekStart ?? 0;

    if (custom != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const FieldLabel('Repeats'),
          Text('On a custom schedule from another calendar app', style: context.type.body(c.ink)),
          const SizedBox(height: Sp.xs),
          SelectableText(custom!, style: context.type.meta(c.ink2)),
          const SizedBox(height: Sp.s),
          OutlinedButton(onPressed: onReplaceCustom, child: const Text('Set a new repeat')),
        ],
      );
    }

    final rule = value;
    final options = <RepeatFrequency?, String>{
      null: 'Never',
      RepeatFrequency.daily: 'Daily',
      RepeatFrequency.weekly: 'Weekly',
      RepeatFrequency.monthly: 'Monthly',
      RepeatFrequency.yearly: 'Yearly',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FieldLabel('Repeats'),
        ChoiceRow<RepeatFrequency?>(
          options: options,
          value: rule?.frequency,
          onChanged: (frequency) {
            if (frequency == null) {
              onChanged(null);
              return;
            }
            final fresh = Recurrence.starting(frequency, startDate, f);
            onChanged(
              Recurrence(
                frequency: fresh.frequency,
                weekdays: fresh.weekdays,
                monthDay: fresh.monthDay,
                ordinal: fresh.ordinal,
                ordinalWeekday: fresh.ordinalWeekday,
                until: rule?.until,
                count: rule?.count,
                weekStartCode: rule?.weekStartCode,
              ),
            );
          },
        ),
        if (rule != null) ...[
          const SizedBox(height: Sp.l),
          _every(context, rule),
          if (rule.frequency == RepeatFrequency.weekly) ...[
            const SizedBox(height: Sp.m),
            _weekdays(context, rule, weekStart),
          ],
          if (rule.frequency == RepeatFrequency.monthly) ...[const SizedBox(height: Sp.m), _monthly(context, rule)],
          const SizedBox(height: Sp.l),
          _ends(context, rule),
          const SizedBox(height: Sp.m),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(PhosphorIconsRegular.repeat, size: 18, color: c.ink2),
              ),
              const SizedBox(width: Sp.s),
              Expanded(
                child: Text(
                  describeRecurrence(rule, f, startDate: startDate, weekStart: weekStart),
                  style: context.type.body(c.ink2),
                ),
              ),
            ],
          ),
        ],
        if (error != null) ...[const SizedBox(height: Sp.s), _Error(error!)],
      ],
    );
  }

  Widget _every(BuildContext context, Recurrence rule) {
    final c = context.colors;
    final n = rule.interval;
    final unit = switch (rule.frequency) {
      RepeatFrequency.daily => n == 1 ? 'day' : 'days',
      RepeatFrequency.weekly => n == 1 ? 'week' : 'weeks',
      RepeatFrequency.monthly => n == 1 ? 'month' : 'months',
      RepeatFrequency.yearly => n == 1 ? 'year' : 'years',
    };
    return Row(
      children: [
        Text('Every', style: context.type.body(c.ink)),
        const SizedBox(width: Sp.m),
        CountStepper(
          value: n,
          min: 1,
          max: 99,
          label: 'Repeat interval',
          onChanged: (v) => onChanged(rule.copyWith(interval: v)),
        ),
        const SizedBox(width: Sp.m),
        Text(unit, style: context.type.body(c.ink)),
      ],
    );
  }

  Widget _weekdays(BuildContext context, Recurrence rule, int weekStart) {
    final f = context.app.formats;
    final c = context.colors;
    return Row(
      children: [
        for (var i = 0; i < 7; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          Expanded(child: _dayTile(context, rule, (weekStart + i) % 7, f, c)),
        ],
      ],
    );
  }

  Widget _dayTile(BuildContext context, Recurrence rule, int day, Formats f, DenColors c) {
    final on = rule.weekdays.contains(day);
    return Semantics(
      selected: on,
      button: true,
      label: f.weekdayName(day, long: true),
      excludeSemantics: true,
      child: Material(
        color: on ? c.ink : c.well,
        borderRadius: BorderRadius.circular(Radii.control),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.control),
          onTap: () {
            final next = {...rule.weekdays};
            if (on) {
              if (next.length == 1) return;
              next.remove(day);
            } else {
              next.add(day);
            }
            onChanged(rule.copyWith(weekdays: next));
          },
          child: SizedBox(
            height: Targets.adult,
            child: Center(
              child: Text(f.weekdayName(day), style: on ? context.type.bodyStrong(c.onInk) : context.type.body(c.ink)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _monthly(BuildContext context, Recurrence rule) {
    final f = context.app.formats;
    final start = f.dateTime(startDate);
    final startWeekday = start.weekday % 7;
    final dayChoice = rule.copyWith(
      monthlyBy: MonthlyBy.day,
      monthDay: rule.monthlyBy == MonthlyBy.day ? rule.monthDay : start.day,
    );
    final weekdayChoices = <Recurrence>[
      for (final ord in ordinalFor(startDate, f))
        rule.copyWith(monthlyBy: MonthlyBy.weekday, ordinal: ord, ordinalWeekday: startWeekday),
    ];
    if (rule.monthlyBy == MonthlyBy.weekday && !weekdayChoices.any((r) => r == rule)) weekdayChoices.insert(0, rule);
    String words(Recurrence r) {
      final whole = describeRecurrence(r.copyWith(interval: 1, clearEnd: true), f, startDate: startDate);
      final on = whole.substring(whole.indexOf(' on ') + 4);
      return 'On $on';
    }

    return Wrap(
      spacing: Sp.s,
      runSpacing: Sp.s,
      children: [
        ChoiceTile(
          label: 'On day ${dayChoice.monthDay}',
          selected: rule.monthlyBy == MonthlyBy.day,
          onTap: () => onChanged(dayChoice),
        ),
        for (final choice in weekdayChoices)
          ChoiceTile(label: words(choice), selected: rule == choice, onTap: () => onChanged(choice)),
      ],
    );
  }

  Widget _ends(BuildContext context, Recurrence rule) {
    final f = context.app.formats;
    final ends = rule.count != null
        ? _Ends.after
        : rule.until != null
        ? _Ends.onDate
        : _Ends.never;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FieldLabel('Ends'),
        ChoiceRow<_Ends>(
          options: {_Ends.never: 'Never', _Ends.onDate: 'On a date', _Ends.after: 'After ${rule.count ?? 10} times'},
          value: ends,
          onChanged: (choice) => onChanged(switch (choice) {
            _Ends.never => rule.copyWith(clearEnd: true),
            _Ends.onDate => rule.copyWith(clearEnd: true, until: f.addMonths(startDate, 3)),
            _Ends.after => rule.copyWith(clearEnd: true, count: 10),
          }),
        ),
        if (ends == _Ends.onDate) ...[
          const SizedBox(height: Sp.m),
          PickerButton(
            icon: PhosphorIconsRegular.calendarBlank,
            label: f.shortWithYear(rule.until!, relativeTo: startDate),
            semanticsLabel: 'Last day it repeats',
            onTap: () async {
              final initial = f.dateTime(rule.until!);
              final picked = await showDatePicker(
                context: context,
                initialDate: DateTime(initial.year, initial.month, initial.day),
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
                helpText: 'Last day it repeats',
              );
              if (picked != null) {
                onChanged(rule.copyWith(clearEnd: true, until: _iso(picked)));
              }
            },
          ),
        ],
        if (ends == _Ends.after) ...[
          const SizedBox(height: Sp.m),
          Row(
            children: [
              CountStepper(
                value: rule.count!,
                min: 1,
                max: 999,
                label: 'Number of times',
                onChanged: (v) => onChanged(rule.copyWith(clearEnd: true, count: v)),
              ),
              const SizedBox(width: Sp.m),
              Text(rule.count == 1 ? 'time' : 'times', style: context.type.body(context.colors.ink)),
            ],
          ),
        ],
      ],
    );
  }

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// A number with minus and plus, each a 48 px target.
class CountStepper extends StatelessWidget {
  const CountStepper({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.label,
  });
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: label,
      value: '$value',
      increasedValue: value < max ? '${value + 1}' : null,
      decreasedValue: value > min ? '${value - 1}' : null,
      onIncrease: value < max ? () => onChanged(value + 1) : null,
      onDecrease: value > min ? () => onChanged(value - 1) : null,
      child: Container(
        decoration: BoxDecoration(color: c.well, borderRadius: BorderRadius.circular(Radii.control)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Fewer',
              onPressed: value > min ? () => onChanged(value - 1) : null,
              icon: Icon(PhosphorIconsRegular.minus, size: 18, color: value > min ? c.ink : c.ink3),
            ),
            ExcludeSemantics(
              child: SizedBox(
                width: 36,
                child: Text('$value', textAlign: TextAlign.center, style: context.type.bodyStrong(c.ink)),
              ),
            ),
            IconButton(
              tooltip: 'More',
              onPressed: value < max ? () => onChanged(value + 1) : null,
              icon: Icon(PhosphorIconsRegular.plus, size: 18, color: value < max ? c.ink : c.ink3),
            ),
          ],
        ),
      ),
    );
  }
}

class _Error extends StatelessWidget {
  const _Error(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(PhosphorIconsFill.warningOctagon, size: 18, color: c.bad),
        ),
        const SizedBox(width: Sp.s),
        Expanded(child: Text(message, style: context.type.body(c.bad))),
      ],
    );
  }
}

/// A plain error line under a field: icon and words in the bad color.
class FieldError extends StatelessWidget {
  const FieldError(this.message, {super.key});
  final String message;
  @override
  Widget build(BuildContext context) => _Error(message);
}
