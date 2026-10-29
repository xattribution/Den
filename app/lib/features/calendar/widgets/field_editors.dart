import 'dart:math' as math;

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../app/format.dart';
import '../../../app/words.dart';
import '../../../design/avatar.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets/switch_line.dart' show DenSwitch;
import '../../../design/words.dart';
import '../state/calendar_models.dart';
import '../words/calendar_time.dart';
import '../words/recurrence.dart';

/// A choice among a few, as a 40 pill in a 44 target: ink when chosen, the page gray on a card
/// otherwise. The label never wraps.
class ChoiceChipPill extends StatelessWidget {
  const ChoiceChipPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.wrap = false,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  /// A description rather than a choice's name (a rule from another app): it may wrap.
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: DenPressable(
        onTap: onTap,
        color: selected ? c.primary : c.bg,
        selected: selected,
        semanticLabel: label,
        child: ExcludeSemantics(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Text(
                label,
                style: context.text.meta(selected ? c.onPrimary : c.ink).bold,
                maxLines: wrap ? null : 1,
                softWrap: wrap,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A round 44 button with a 1.5 line edge: the − and + of a time, the ‹ and › of a day.
class StepButton extends StatelessWidget {
  const StepButton({super.key, required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DenPressable(
      onTap: onTap,
      shape: CircleBorder(side: BorderSide(color: c.line, width: 1.5)),
      semanticLabel: label,
      child: SizedBox.square(
        dimension: Targets.adult,
        child: Icon(icon, size: 20, color: onTap == null ? c.ink3 : c.ink),
      ),
    );
  }
}

/// When something happens, changed in place: the day, the start and the end, each with a step
/// back and a step forward (a day; 15 minutes), and all day. The start keeps the length; the
/// end never goes before the start.
class WhenEditor extends StatelessWidget {
  const WhenEditor({super.key, required this.start, required this.end, required this.allDay, required this.onChanged});

  /// UTC ms. For all-day events, the first day's midnight and the midnight after the last.
  final int start;
  final int end;
  final bool allDay;
  final void Function(int start, int end, bool allDay) onChanged;

  static const int _step = 15;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final f = app.formats;
    final c = context.colors;
    final today = app.today;
    final date = f.localDate(start);
    final length = math.max(0, end - start);

    void moveDays(int by) {
      final newDate = f.addDays(date, by);
      if (allDay) {
        final days = math.max(1, f.daysFrom(date, f.lastDate(start, end)) + 1);
        onChanged(f.startOf(newDate), f.startOf(f.addDays(newDate, days)), true);
      } else {
        final s = f.msAt(newDate, f.minuteOfDay(start));
        onChanged(s, s + length, false);
      }
    }

    void moveStart(int minutes) {
      final s = f.msAt(date, (f.minuteOfDay(start) + minutes).clamp(0, 24 * 60 - _step));
      onChanged(s, s + length, false);
    }

    void moveEnd(int minutes) {
      final e = end + minutes * 60000;
      if (e <= start) return;
      onChanged(start, e, false);
    }

    void setAllDay(bool on) {
      if (on) {
        onChanged(f.startOf(date), f.startOf(f.addDays(date, 1)), true);
      } else {
        final s = f.msAt(date, 9 * 60);
        onChanged(s, s + 3600000, false);
      }
    }

    // A label, then − value +. The label sits beside the stepper while both fit and above it at
    // large text; the value takes what room is left and wraps at a space ("Tue, Oct" / "20")
    // before anything overflows.
    Widget line(
      String label,
      String value,
      String what,
      VoidCallback? back,
      VoidCallback? forward, {
      bool days = false,
    }) {
      final scaler = MediaQuery.textScalerOf(context);
      final labelWidth = math.max(56.0, scaler.scale(56));
      final wanted = scaler.scale(days ? 136 : 96);
      return LayoutBuilder(
        builder: (context, box) {
          final inline = labelWidth + Sp.s + Targets.adult * 2 + wanted <= box.maxWidth;
          final valueWidth = inline ? wanted : math.min(wanted, box.maxWidth - Targets.adult * 2);
          final stepper = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              StepButton(
                icon: days ? PhosphorIconsBold.caretLeft : PhosphorIconsBold.minus,
                label: days ? 'A day earlier' : '$what 15 minutes earlier',
                onTap: back,
              ),
              SizedBox(
                width: valueWidth,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Sp.s),
                  child: Text(keepUnits(value), textAlign: TextAlign.center, style: context.text.rowTitle(c.ink)),
                ),
              ),
              StepButton(
                icon: days ? PhosphorIconsBold.caretRight : PhosphorIconsBold.plus,
                label: days ? 'A day later' : '$what 15 minutes later',
                onTap: forward,
              ),
            ],
          );
          final name = Text(label, style: context.text.meta(c.ink2));
          if (inline) {
            return Row(
              children: [
                SizedBox(width: labelWidth, child: name),
                const SizedBox(width: Sp.s),
                stepper,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              name,
              const SizedBox(height: Sp.xs),
              stepper,
            ],
          );
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        line('Day', f.shortWithYear(date, relativeTo: today), 'Day', () => moveDays(-1), () => moveDays(1), days: true),
        if (!allDay) ...[
          const SizedBox(height: Sp.s),
          line('Starts', f.time(start), 'Start', () => moveStart(-_step), () => moveStart(_step)),
          const SizedBox(height: Sp.s),
          line(
            'Ends',
            f.time(end),
            'End',
            end - _step * 60000 > start ? () => moveEnd(-_step) : null,
            () => moveEnd(_step),
          ),
        ],
        const SizedBox(height: Sp.xs),
        MergeSemantics(
          child: Row(
            children: [
              Expanded(child: Text('All day', style: context.text.body(c.ink))),
              DenSwitch(value: allDay, onChanged: setAllDay),
            ],
          ),
        ),
      ],
    );
  }
}

/// How often it repeats, as a few plain choices: just once, every week, every two weeks, every
/// month (on the same weekday of the month). A rule that isn't one of these shows as its own
/// chosen pill first, so nothing is lost by looking.
class RepeatChips extends StatelessWidget {
  const RepeatChips({
    super.key,
    required this.rrule,
    required this.date,
    required this.seriesStart,
    required this.onChanged,
  });

  /// The rule now; null for once.
  final String? rrule;

  /// The occurrence's local date, which the choices repeat from.
  final String date;

  /// The series' first local date, for reading [rrule].
  final String seriesStart;
  final ValueChanged<String?> onChanged;

  /// The choices for an event on [date], with the rule each one writes.
  static List<(String, String?)> presets(Formats f, String date) {
    final weekday = f.dateTime(date).weekday % 7;
    final weekly = Recurrence(frequency: RepeatFrequency.weekly, weekdays: {weekday});
    final monthly = Recurrence.starting(RepeatFrequency.monthly, date, f).copyWith(monthlyBy: MonthlyBy.weekday);
    return [
      ('Just once', null),
      ('Every week', toRrule(weekly, f)),
      ('Every 2 weeks', toRrule(weekly.copyWith(interval: 2), f)),
      ('Every month', toRrule(monthly, f)),
    ];
  }

  static bool _same(Recurrence a, Recurrence b) =>
      a.frequency == b.frequency &&
      a.interval == b.interval &&
      a.until == null &&
      a.count == null &&
      switch (a.frequency) {
        RepeatFrequency.weekly => a.weekdays.length == b.weekdays.length && a.weekdays.containsAll(b.weekdays),
        RepeatFrequency.monthly =>
          a.monthlyBy == b.monthlyBy &&
              (a.monthlyBy == MonthlyBy.day
                  ? a.monthDay == b.monthDay
                  : a.ordinal == b.ordinal && a.ordinalWeekday == b.ordinalWeekday),
        _ => true,
      };

  /// Which preset [rrule] is, or -1 for none of them.
  static int chosen(Formats f, String? rrule, String date, String seriesStart) {
    final options = presets(f, date);
    if (rrule == null) return 0;
    final parsed = parseRrule(rrule, startDate: seriesStart, f: f);
    if (parsed is! SupportedRule) return -1;
    for (var i = 1; i < options.length; i++) {
      final preset = parseRrule(options[i].$2, startDate: date, f: f);
      if (preset is SupportedRule && _same(parsed.rule, preset.rule)) return i;
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final f = app.formats;
    final options = presets(f, date);
    final index = chosen(f, rrule, date, seriesStart);
    final own = index == -1
        ? describeRrule(rrule, f, startDate: seriesStart, weekStart: app.den.family?.weekStart ?? 0)
        : null;
    return Wrap(
      spacing: Sp.s,
      runSpacing: Sp.xs,
      children: [
        if (own != null) ChoiceChipPill(label: own, selected: true, onTap: null, wrap: true),
        for (final (i, (label, rule)) in options.indexed)
          ChoiceChipPill(label: label, selected: i == index, onTap: i == index ? null : () => onChanged(rule)),
      ],
    );
  }
}

/// When to be reminded: none, or any of a few times before.
class ReminderChips extends StatelessWidget {
  const ReminderChips({super.key, required this.value, required this.onChanged});

  final List<int> value;
  final ValueChanged<List<int>> onChanged;

  static const List<int> choices = [15, 30, 60, 1440];

  @override
  Widget build(BuildContext context) {
    final extra = [
      for (final m in value)
        if (!choices.contains(m)) m,
    ];
    return Wrap(
      spacing: Sp.s,
      runSpacing: Sp.xs,
      children: [
        ChoiceChipPill(
          label: 'No reminder',
          selected: value.isEmpty,
          onTap: value.isEmpty ? null : () => onChanged(const []),
        ),
        for (final m in [...extra, ...choices])
          ChoiceChipPill(
            label: reminderWords(m),
            selected: value.contains(m),
            onTap: () {
              final next = {...value};
              if (!next.remove(m)) next.add(m);
              onChanged(next.toList()..sort());
            },
          ),
      ],
    );
  }
}

/// Who it's for, as the family's faces to tap: on is their picture in their ring, off a dashed
/// ring in their color. Everyone on is everyone. The last one on stays on.
class PeopleToggles extends StatelessWidget {
  const PeopleToggles({
    super.key,
    required this.people,
    required this.selected,
    required this.onChanged,
    this.enabled = true,
  });

  final List<Member> people;

  /// Who is on; empty means everyone.
  final List<String> selected;

  /// The new list, empty when everyone is on.
  final ValueChanged<List<String>> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final everyone = selected.isEmpty;
    bool on(Member m) => everyone || selected.contains(m.id);
    return Wrap(
      spacing: 10,
      runSpacing: Sp.s,
      children: [
        // Read only, it shows who is in it; the dashed rings are an offer to add someone.
        for (final m in people.where((p) => enabled || on(p)))
          _PersonToggle(
            member: m,
            on: on(m),
            onTap: !enabled
                ? null
                : () {
                    final chosen = {
                      for (final p in people)
                        if (on(p)) p.id,
                    };
                    if (chosen.contains(m.id)) {
                      if (chosen.length == 1) return;
                      chosen.remove(m.id);
                    } else {
                      chosen.add(m.id);
                    }
                    onChanged(
                      chosen.length == people.length
                          ? const []
                          : [
                              for (final p in people)
                                if (chosen.contains(p.id)) p.id,
                            ],
                    );
                  },
            ink: c.ink,
          ),
      ],
    );
  }
}

class _PersonToggle extends StatelessWidget {
  const _PersonToggle({required this.member, required this.on, required this.onTap, required this.ink});

  final Member member;
  final bool on;
  final VoidCallback? onTap;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = c.marker(member.marker);
    final face = on
        ? DenAvatar(member, size: 40)
        : CustomPaint(
            painter: _DashedRing(color),
            child: SizedBox.square(
              dimension: 40,
              child: Center(
                child: Text(
                  member.name.characters.isEmpty ? '' : member.name.characters.first.toUpperCase(),
                  textScaler: TextScaler.noScaling,
                  style: context.text.rowTitle(c.ink2),
                ),
              ),
            ),
          );
    return Semantics(
      toggled: on,
      button: true,
      label: member.name,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: Targets.adult),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: DenMotion.fade,
                child: KeyedSubtree(key: ValueKey(on), child: face),
              ),
              const SizedBox(height: 4),
              Text(member.name, style: context.text.caption(on ? c.ink : c.ink2), maxLines: 1, softWrap: false),
            ],
          ),
        ),
      ),
    );
  }
}

/// A 2 pt dashed circle in a person's color: someone who isn't in it yet.
class _DashedRing extends CustomPainter {
  _DashedRing(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final radius = size.width / 2 - 1;
    const dashes = 16;
    const sweep = math.pi * 2 / dashes;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: radius);
    for (var i = 0; i < dashes; i++) {
      canvas.drawArc(rect, i * sweep, sweep * 0.55, false, paint);
    }
  }

  @override
  bool shouldRepaint(_DashedRing old) => old.color != color;
}
