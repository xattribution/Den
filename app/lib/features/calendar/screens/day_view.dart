import 'dart:async';
import 'dart:math' as math;

import 'package:den_core/den_core.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_state.dart';
import '../../../app/format.dart';
import '../../../design/avatar.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../state/calendar_models.dart';
import '../state/day_layout.dart';
import '../state/event_actions.dart';
import '../words/block_words.dart';
import '../words/calendar_time.dart';
import '../widgets/calendar_parts.dart';
import '../widgets/day_list.dart';
import '../widgets/event_block.dart';
import '../widgets/event_look.dart';

/// One day as a time grid. On a phone it's one column, events side by side where they overlap;
/// with room ([perPerson]) it's a column per person who has something that day, plus Everyone.
/// Events are solid blocks in their person's color with the kind's pictogram; all-day events sit
/// above the grid. Today shows an ink now line.
///
/// Tap an empty time to add an event there; press and hold an event to move it, or drag its
/// bottom edge to change when it ends. The change says itself in place, with Undo. Repeating
/// events ask how far a change reaches.
class DayView extends StatefulWidget {
  const DayView({super.key, required this.date, this.now, this.perPerson = false, this.person});

  /// Local date, `YYYY-MM-DD`.
  final String date;

  /// UTC milliseconds to treat as now (tests); defaults to the clock.
  final int? now;

  /// A column per person (the iPad); otherwise one column.
  final bool perPerson;

  /// Only this person's events (and everyone's); null for all.
  final String? person;

  @override
  State<DayView> createState() => _DayViewState();
}

/// A column of the day: a person, everyone (null member), or on a phone the whole family.
class _Column {
  _Column(this.member, {this.everyone = false});
  final Member? member;
  final bool everyone;
  final List<Occurrence> allDay = [];
  final List<Occurrence> timed = [];
}

class _Drag {
  _Drag({required this.occ, required this.resize, required this.startMin, required this.endMin});
  final Occurrence occ;
  final bool resize;
  final int startMin;
  final int endMin;
  int delta = 0;
  bool committing = false;

  int get newStart => resize ? startMin : startMin + delta;
  int get newEnd => endMin + delta;
}

class _DayViewState extends State<DayView> {
  ScrollController? _scroll;
  Timer? _tick;
  _Drag? _drag;
  double _dragOrigin = 0;

  /// The last change, shown above the grid with Undo, or why it didn't go through.
  (String, ActionResult?)? _done;
  String? _error;

  static const int _snap = 15;

  int get _now => widget.now ?? DateTime.now().millisecondsSinceEpoch;

  double _hourHeight(BuildContext context) {
    final text = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.6);
    return (64 * context.text.scale * text).roundToDouble();
  }

  @override
  void initState() {
    super.initState();
    if (widget.now == null) {
      _tick = Timer.periodic(const Duration(minutes: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scroll ??= ScrollController(initialScrollOffset: _initialOffset());
  }

  @override
  void didUpdateWidget(DayView old) {
    super.didUpdateWidget(old);
    if (old.date != widget.date) {
      _done = null;
      _error = null;
      if (_scroll?.hasClients ?? false) {
        final target = _initialOffset();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll?.hasClients ?? false) {
            _scroll!.jumpTo(target.clamp(0, _scroll!.position.maxScrollExtent));
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _scroll?.dispose();
    super.dispose();
  }

  /// Opens on the morning, an hour before now on today, or just before the first event.
  double _initialOffset() {
    final app = DenScope.read(context);
    final f = app.formats;
    final date = widget.date;
    final dayStart = f.startOf(date);
    final dayEnd = f.startOf(f.addDays(date, 1));
    var minute = 7 * 60;
    if (f.localDate(_now) == date) {
      minute = math.max(0, f.minuteOfDay(_now) - 60);
    } else {
      final firstTimed = app.den
          .occurrences(dayStart, dayEnd)
          .where((o) => !o.allDay && o.start >= dayStart)
          .map((o) => f.minuteOfDay(o.start))
          .fold<int?>(null, (a, b) => a == null || b < a ? b : a);
      if (firstTimed != null) minute = math.min(minute, math.max(0, firstTimed - 30));
    }
    // A little above the hour, so its label isn't cut off at the top.
    return math.max(0, minute / 60 * _hourHeight(context) - Sp.m);
  }

  List<_Column> _columns(AppState app, List<Occurrence> occurrences, int dayStart, int dayEnd) {
    final members = app.den.members;
    bool forEveryone(Occurrence o) =>
        o.forEveryone || (members.isNotEmpty && members.every((m) => o.assignees.contains(m.id)));
    bool spansDay(Occurrence o) => o.allDay || (o.start <= dayStart && o.end >= dayEnd);

    if (!widget.perPerson) {
      final all = _Column(null);
      for (final occ in occurrences) {
        (spansDay(occ) ? all.allDay : all.timed).add(occ);
      }
      return [all];
    }
    final everyone = _Column(null, everyone: true);
    final byMember = {for (final m in members) m.id: _Column(m)};
    for (final occ in occurrences) {
      final targets = forEveryone(occ) ? [everyone] : occ.assignees.map((id) => byMember[id]).whereType<_Column>();
      for (final column in targets) {
        (spansDay(occ) ? column.allDay : column.timed).add(occ);
      }
    }
    return [
      if (everyone.allDay.isNotEmpty || everyone.timed.isNotEmpty) everyone,
      for (final m in members)
        if (byMember[m.id]!.allDay.isNotEmpty || byMember[m.id]!.timed.isNotEmpty) byMember[m.id]!,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final f = app.formats;
    final c = context.colors;
    final date = widget.date;
    final dayStart = f.startOf(date);
    final dayEnd = f.startOf(f.addDays(date, 1));
    final occurrences = context
        .view(OccurrencesModel(dayStart, dayEnd))
        .where((o) => showsFor(o, widget.person))
        .toList();
    final columns = _columns(app, occurrences, dayStart, dayEnd);
    final empty = occurrences.isEmpty;
    final canAdd = app.allows(DenAction.editEvents);
    final hourHeight = _hourHeight(context);
    final scaler = MediaQuery.textScalerOf(context);
    final gutter = (scaler.scale(52 * context.text.scale)).roundToDouble();
    final minColumn = widget.perPerson ? 140.0 : 0.0;
    final shown = columns.isEmpty ? [_Column(null)] : columns;

    final done = _done;
    final note = _error != null
        ? ErrorLine(message: _error!)
        : done != null
            ? UndoLine(message: done.$1, onUndo: done.$2 == null ? null : () => _undo(done.$2!))
            : empty
                ? _EmptyNote(date: date, canAdd: canAdd)
                : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final natural = gutter + shown.length * minColumn;
        final width = math.max(natural, constraints.maxWidth);
        final columnWidth = (width - gutter) / shown.length;
        final allDayLines = shown.fold<int>(0, (n, col) => math.max(n, col.allDay.length));

        final body = SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DenReveal(
                visible: note != null,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.s),
                  child: note ?? const SizedBox.shrink(),
                ),
              ),
              if (widget.perPerson && columns.isNotEmpty) ...[
                _Header(columns: shown, gutter: gutter, columnWidth: columnWidth),
                Container(height: 1, color: c.line),
              ],
              if (allDayLines > 0) ...[
                _AllDayRow(columns: shown, gutter: gutter, columnWidth: columnWidth, date: date),
                Container(height: 1, color: c.line),
              ],
              Expanded(
                child: SingleChildScrollView(
                  controller: _scroll,
                  child: SizedBox(
                    height: hourHeight * 24 + Sp.l,
                    child: _grid(context, app, f, shown, gutter, columnWidth, hourHeight, dayStart, dayEnd, canAdd),
                  ),
                ),
              ),
            ],
          ),
        );
        return natural > constraints.maxWidth
            ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: body)
            : body;
      },
    );
  }

  Widget _grid(
    BuildContext context,
    AppState app,
    Formats f,
    List<_Column> columns,
    double gutter,
    double columnWidth,
    double hourHeight,
    int dayStart,
    int dayEnd,
    bool canAdd,
  ) {
    final c = context.colors;
    final date = widget.date;
    final labelStyle = context.text.caption(c.ink2);
    final labelHeight = (MediaQuery.textScalerOf(context).scale(labelStyle.fontSize!) * 1.3).ceilToDouble();
    final now = _now;
    final isToday = f.localDate(now) == date;
    double y(int minute) => minute / 60 * hourHeight;

    final children = <Widget>[
      for (var h = 1; h < 24; h++) ...[
        Positioned(
          top: y(h * 60),
          left: gutter,
          right: 0,
          child: Container(height: 1, color: c.line),
        ),
        Positioned(
          top: y(h * 60) - labelHeight / 2,
          left: 0,
          width: gutter - Sp.s,
          child: ExcludeSemantics(
            child: Text(f.hourLabel(h), style: labelStyle, textAlign: TextAlign.right, maxLines: 1, softWrap: false),
          ),
        ),
      ],
      if (widget.perPerson)
        for (var i = 0; i < columns.length; i++)
          Positioned(
            top: 0,
            bottom: 0,
            left: gutter + i * columnWidth,
            child: Container(width: 1, color: c.line),
          ),
    ];

    for (var i = 0; i < columns.length; i++) {
      final column = columns[i];
      final left = gutter + i * columnWidth;
      if (canAdd) {
        children.add(
          Positioned(
            top: 0,
            bottom: 0,
            left: left + 1,
            width: columnWidth - 1,
            child: Semantics(
              onTapHint: 'Add an event',
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTapUp: (details) {
                  final minute = ((details.localPosition.dy / hourHeight * 60) ~/ 30 * 30).clamp(0, 23 * 60 + 30);
                  final member = column.member ?? (widget.person == null ? null : app.memberById(widget.person));
                  final who = member == null ? '' : '&who=${member.id}';
                  context.push('/event/new?date=$date&time=${f.hhmm(minute)}$who');
                },
              ),
            ),
          ),
        );
      }

      final slots = layoutDay([
        for (final occ in column.timed)
          DaySlot(
            occ,
            occ.start <= dayStart ? 0 : f.minuteOfDay(occ.start),
            occ.end >= dayEnd
                ? 24 * 60
                : math.max(f.minuteOfDay(occ.end), (occ.start <= dayStart ? 0 : f.minuteOfDay(occ.start))),
          ),
      ]);
      // On a phone the blocks stop a gutter short of the edge, like everything else on the page.
      final laneWidthBase = columnWidth - (widget.perPerson ? 1 + Sp.xs : Sp.xs + DenLayout.gutter);
      for (final slot in slots) {
        final occ = slot.item;
        final drag = _drag;
        final dragging = drag != null && drag.occ.event.id == occ.event.id && drag.occ.start == occ.start;
        final startMin = dragging ? drag.newStart : slot.start;
        final endMin = dragging ? drag.newEnd : slot.end;
        final laneWidth = laneWidthBase / slot.lanes;
        final editable = app.allows(DenAction.editEvents) &&
            !occ.event.source.readOnly &&
            occ.start >= dayStart &&
            occ.end <= dayEnd;
        children.add(
          Positioned(
            top: y(startMin) + 1,
            height: math.max(y(endMin) - y(startMin) - 2, (24 * context.text.scale).roundToDouble()),
            left: left + (widget.perPerson ? 2 : Sp.xs) + slot.lane * laneWidth,
            width: laneWidth * slot.span - 2,
            child: _Block(
              column: column.member,
              occ: occ,
              startMin: startMin,
              endMin: endMin,
              dragging: dragging,
              onTap: () => openEvent(context, occ),
              onMoveStart: editable ? (dy) => _startDrag(occ, slot, resize: false, dy: dy) : null,
              onResizeStart: editable ? (dy) => _startDrag(occ, slot, resize: true, dy: dy) : null,
              onDragUpdate: editable ? (dy) => _updateDrag(dy, hourHeight) : null,
              onDragEnd: editable ? _endDrag : null,
            ),
          ),
        );
      }
    }

    if (isToday) {
      final top = y(f.minuteOfDay(now));
      children.addAll([
        Positioned(
          top: top - 1,
          left: gutter,
          right: 0,
          child: IgnorePointer(child: Container(height: 2, color: c.ink)),
        ),
        Positioned(
          top: top - 5,
          left: gutter - 5,
          child: IgnorePointer(
            child: Semantics(
              label: 'Now, ${f.time(now)}',
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: c.ink, shape: BoxShape.circle),
              ),
            ),
          ),
        ),
      ]);
    }

    return Stack(clipBehavior: Clip.none, children: children);
  }

  void _startDrag(Occurrence occ, DaySlot<Occurrence> slot, {required bool resize, required double dy}) {
    if (_drag?.committing ?? false) return;
    HapticFeedback.selectionClick();
    setState(() {
      _drag = _Drag(occ: occ, resize: resize, startMin: slot.start, endMin: slot.end);
      _dragOrigin = dy;
    });
  }

  void _updateDrag(double dy, double hourHeight) {
    final drag = _drag;
    if (drag == null || drag.committing) return;
    var delta = (((dy - _dragOrigin) / hourHeight * 60) / _snap).round() * _snap;
    if (drag.resize) {
      delta = delta.clamp(drag.startMin + _snap - drag.endMin, 24 * 60 - drag.endMin);
    } else {
      delta = delta.clamp(-drag.startMin, 24 * 60 - drag.endMin);
    }
    if (delta != drag.delta) {
      HapticFeedback.selectionClick();
      setState(() => drag.delta = delta);
    }
  }

  Future<void> _endDrag() async {
    final drag = _drag;
    if (drag == null || drag.committing) return;
    if (drag.delta == 0) {
      setState(() => _drag = null);
      return;
    }
    drag.committing = true;
    final app = DenScope.read(context);
    final f = app.formats;
    final occ = drag.occ;
    final shift = drag.delta * 60000;
    final newStart = drag.resize ? occ.start : occ.start + shift;
    final newEnd = occ.end + shift;
    var scope = EditScope.all;
    if (occ.isRepeating) {
      final chosen = await askScope(context, occ, verb: drag.resize ? 'Change' : 'Move');
      if (!mounted) return;
      if (chosen == null) {
        setState(() => _drag = null);
        return;
      }
      scope = chosen;
    }
    if (!mounted) return;
    final actions = context.actions;
    // One and following address the occurrence by its place in the series; all events move by
    // however far this occurrence moved.
    final anchor = !occ.isRepeating ? null : (scope == EditScope.all ? occ.start : occ.seriesStart);
    final error = await tryWrite(() async {
      final result = await EventActions(actions).update(occ.event, {'start': newStart, 'end': newEnd}, scope: scope, occurrence: anchor);
      if (!result.isError && mounted) {
        final message = drag.resize
            ? '${occ.title} now ends at ${f.time(newEnd)}'
            : '${occ.title} moved to ${f.time(newStart)}';
        _done = (message, result.receipt?.undoable ?? false ? result : null);
      }
      return result;
    });
    if (!mounted) return;
    setState(() {
      _drag = null;
      _error = error;
      if (error != null) _done = null;
    });
  }

  Future<void> _undo(ActionResult result) async {
    final receipt = result.receipt;
    if (receipt == null) return;
    final actions = context.actions;
    final error = await tryWrite(() => actions.undo(receipt));
    if (!mounted) return;
    setState(() {
      _error = error;
      _done = null;
    });
  }
}

/// Asks, in place of a dialog's jargon, how far a change to a repeating event reaches.
Future<EditScope?> askScope(BuildContext context, Occurrence occ, {String verb = 'Change'}) {
  final f = DenScope.read(context).formats;
  final (question, all) = scopeQuestion(f, occ, verb: verb);
  return showDialog<EditScope>(
    context: context,
    builder: (dialogContext) {
      final c = dialogContext.colors;
      return Dialog(
        insetPadding: const EdgeInsets.all(Sp.l),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(Sp.l),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(header: true, child: Text(question, style: dialogContext.text.rowTitle(c.ink))),
                const SizedBox(height: Sp.l),
                CalendarPill(label: 'Just this one', edge: true, onTap: () => Navigator.of(dialogContext).pop(EditScope.one)),
                const SizedBox(height: Sp.s),
                CalendarPill(label: all, primary: true, onTap: () => Navigator.of(dialogContext).pop(EditScope.all)),
                const SizedBox(height: Sp.s),
                Row(
                  children: [
                    TextButton(onPressed: () => Navigator.of(dialogContext).pop(EditScope.following), child: const Text('From this one on')),
                    const Spacer(),
                    TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _EmptyNote extends StatelessWidget {
  const _EmptyNote({required this.date, required this.canAdd});
  final String date;
  final bool canAdd;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Wrap(
      spacing: Sp.m,
      runSpacing: Sp.s,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(canAdd ? 'Nothing on the calendar. Tap a time to add something.' : 'Nothing on the calendar.', style: context.text.control(c.ink2)),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.columns, required this.gutter, required this.columnWidth});
  final List<_Column> columns;
  final double gutter;
  final double columnWidth;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final c = context.colors;
    final members = app.den.members;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        SizedBox(width: gutter),
        for (final column in columns)
          SizedBox(
            width: columnWidth,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Sp.s, Sp.s, Sp.xs, Sp.s),
              child: Row(
                children: [
                  if (column.member == null)
                    SizedBox(width: 26, height: 26, child: Center(child: _Dots(members: members)))
                  else
                    DenAvatar(column.member!, size: 26),
                  const SizedBox(width: Sp.s),
                  Expanded(child: Text(column.member?.name ?? 'Everyone', style: context.text.label(c.ink), maxLines: 2)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.members});
  final List<Member> members;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Wrap(
      spacing: 2,
      runSpacing: 2,
      children: [
        for (final m in members.take(4))
          Container(width: 8, height: 8, decoration: BoxDecoration(color: c.marker(m.marker), shape: BoxShape.circle)),
      ],
    );
  }
}

class _AllDayRow extends StatelessWidget {
  const _AllDayRow({required this.columns, required this.gutter, required this.columnWidth, required this.date});
  final List<_Column> columns;
  final double gutter;
  final double columnWidth;
  final String date;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: gutter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, Sp.s + 2, Sp.s, 0),
            child: Text('All day', style: context.text.caption(c.ink2), textAlign: TextAlign.right),
          ),
        ),
        for (final column in columns)
          SizedBox(
            width: columnWidth,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Sp.xs, vertical: Sp.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final occ in column.allDay)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Sp.xs),
                      child: EventCell(occ: occ, date: date, onTap: () => openEvent(context, occ)),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// An event in the grid: a solid block in its person's color, the pictogram, the title and,
/// when it fits, the time. Press and hold to move it; drag the bottom edge to change when it
/// ends. While it moves it shows its new time and an ink edge.
class _Block extends StatelessWidget {
  const _Block({
    required this.occ,
    required this.startMin,
    required this.endMin,
    required this.dragging,
    required this.onTap,
    required this.onMoveStart,
    required this.onResizeStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    this.column,
  });

  final Occurrence occ;
  final int startMin;
  final int endMin;
  final bool dragging;
  final VoidCallback onTap;
  final ValueChanged<double>? onMoveStart;
  final ValueChanged<double>? onResizeStart;
  final ValueChanged<double>? onDragUpdate;
  final VoidCallback? onDragEnd;

  /// The person whose column it sits in, on iPad: it takes their color.
  final Member? column;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final f = app.formats;
    final c = context.colors;
    final look = EventLook.of(app, occ, c, column: column);
    final titleStyle = context.text.meta(look.ink).bold;
    final timeStyle = context.text.caption(look.ink);
    final scaler = MediaQuery.textScalerOf(context);
    final lineHeight = (scaler.scale(titleStyle.fontSize!) * 1.35).ceilToDouble();
    final span = '${f.clock(startMin)} to ${f.clock(endMin % (24 * 60))}';
    final canMove = onMoveStart != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight;
        final lines = math.max(1, ((h - 8) / lineHeight).floor());
        final showTime = lines >= 2;
        final oneLine = lines == 1;
        final titleLines = math.min(2, showTime ? lines - 1 : lines);
        final showIcon = constraints.maxWidth >= 96;
        // Times never truncate: the whole span where it fits, otherwise when it starts (the
        // block's height already shows how long).
        final room = constraints.maxWidth - Sp.s - Sp.xs - (showIcon ? 22 : 0);
        final spanPainter = TextPainter(text: TextSpan(text: span, style: timeStyle), textDirection: TextDirection.ltr, textScaler: scaler, maxLines: 1)
          ..layout();
        final timeText = spanPainter.width <= room ? span : f.clock(startMin);
        spanPainter.dispose();
        final content = Container(
          decoration: BoxDecoration(
            color: look.fill,
            borderRadius: BorderRadius.circular(10),
            border: dragging ? Border.all(color: c.ink, width: 2) : null,
          ),
          clipBehavior: Clip.antiAlias,
          padding: const EdgeInsets.fromLTRB(Sp.s, 3, Sp.xs, 3),
          child: Row(
            crossAxisAlignment: oneLine ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            children: [
              if (showIcon) ...[
                Padding(
                  padding: EdgeInsets.only(top: oneLine ? 0 : 2),
                  child: Icon(look.icon, size: 16, color: look.ink),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: oneLine
                    ? Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: occ.title, style: titleStyle),
                            TextSpan(text: '  ${f.clock(startMin)}', style: timeStyle),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(occ.title, style: titleStyle, maxLines: titleLines, overflow: TextOverflow.ellipsis),
                          if (showTime) Text(timeText, style: timeStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ),
              ),
            ],
          ),
        );

        return Semantics(
          button: true,
          label: '${occ.title}, $span, ${look.who}',
          hint: canMove ? 'Press and hold to move' : null,
          excludeSemantics: true,
          child: MouseRegion(
            cursor: canMove ? SystemMouseCursors.grab : SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onTap,
              onLongPressStart: canMove ? (d) => onMoveStart!(d.globalPosition.dy) : null,
              onLongPressMoveUpdate: canMove ? (d) => onDragUpdate!(d.globalPosition.dy) : null,
              onLongPressEnd: canMove ? (_) => onDragEnd!() : null,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  content,
                  if (canMove && lines > 2)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 4,
                      child: IgnorePointer(
                        child: Center(
                          child: Container(
                            width: 18,
                            height: 3,
                            decoration: BoxDecoration(color: look.ink, borderRadius: BorderRadius.circular(2)),
                          ),
                        ),
                      ),
                    ),
                  if (onResizeStart != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 14,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeUpDown,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          // Measure from where the finger landed, not where the drag was recognized.
                          dragStartBehavior: DragStartBehavior.down,
                          onVerticalDragStart: (d) => onResizeStart!(d.globalPosition.dy),
                          onVerticalDragUpdate: (d) => onDragUpdate!(d.globalPosition.dy),
                          onVerticalDragEnd: (_) => onDragEnd!(),
                          onVerticalDragCancel: onDragEnd,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
