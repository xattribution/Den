import 'dart:async';
import 'dart:math' as math;

import 'package:den_core/den_core.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../widgets/event_line.dart';
import '../../../design/feedback.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../app/app_state.dart';
import '../../../app/format.dart';
import '../words/calendar_time.dart';
import '../state/day_layout.dart';

/// One day as a time grid with a column per person who has something that day (the family
/// columns, turned on their side), plus an Everyone column for family events. All-day events
/// sit above the grid. Today shows a graphite now line.
///
/// Tap an empty slot to add an event there; press and hold an event to move it, or drag its
/// bottom edge to change when it ends. Repeating events ask how far the change reaches.
class DayView extends StatefulWidget {
  const DayView({super.key, required this.date, this.now});

  /// Local date, `YYYY-MM-DD`.
  final String date;

  /// UTC milliseconds to treat as now (tests); defaults to the clock.
  final int? now;

  @override
  State<DayView> createState() => _DayViewState();
}

/// A column of the day: a person, or everyone (null member).
class _Column {
  _Column(this.member);
  final Member? member;
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

  static const int _snap = 15;

  int get _now => widget.now ?? DateTime.now().millisecondsSinceEpoch;

  double _hourHeight(BuildContext context) => (56 * context.type.scale).roundToDouble();

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
    if (old.date != widget.date && (_scroll?.hasClients ?? false)) {
      final target = _initialOffset();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll?.hasClients ?? false) {
          _scroll!.jumpTo(target.clamp(0, _scroll!.position.maxScrollExtent));
        }
      });
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
    // A little above the hour, so its label isn't cut off under the header.
    return math.max(0, minute / 60 * _hourHeight(context) - Sp.m);
  }

  List<_Column> _columns(AppState app, List<Occurrence> occurrences, int dayStart, int dayEnd) {
    final members = app.den.members;
    bool forEveryone(Occurrence o) =>
        o.forEveryone || (members.isNotEmpty && members.every((m) => o.assignees.contains(m.id)));
    bool spansDay(Occurrence o) => o.allDay || (o.start <= dayStart && o.end >= dayEnd);

    final everyone = _Column(null);
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
    final app = context.app;
    final f = app.formats;
    final c = context.colors;
    final date = widget.date;
    final dayStart = f.startOf(date);
    final dayEnd = f.startOf(f.addDays(date, 1));
    final occurrences = app.den.occurrences(dayStart, dayEnd);
    final columns = _columns(app, occurrences, dayStart, dayEnd);
    final empty = columns.isEmpty;
    final canAdd = app.allows(DenAction.editEvents);
    final scale = context.type.scale;
    final hourHeight = _hourHeight(context);
    final gutter = (56 * scale).roundToDouble();
    final minColumn = (76 * scale).roundToDouble();
    final shown = empty ? [_Column(null)] : columns;

    return LayoutBuilder(
      builder: (context, constraints) {
        final natural = gutter + shown.length * minColumn;
        final width = math.max(natural, constraints.maxWidth);
        final columnWidth = (width - gutter) / shown.length;
        final lineHeight = CalendarEventLine.lineHeight(context);
        final allDayLines = shown.fold<int>(0, (n, col) => math.max(n, col.allDay.length));

        final body = SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!empty) ...[
                _Header(columns: shown, gutter: gutter, columnWidth: columnWidth),
                Divider(height: 1, color: c.rule),
              ],
              if (empty)
                _EmptyDay(date: date, canAdd: canAdd)
              else if (allDayLines > 0) ...[
                _AllDayRow(
                  columns: shown,
                  gutter: gutter,
                  columnWidth: columnWidth,
                  lines: allDayLines,
                  lineHeight: lineHeight,
                ),
                Divider(height: 1, color: c.rule),
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
    final labelStyle = context.type.meta(c.ink2);
    final labelHeight = (labelStyle.fontSize! * 1.3).ceilToDouble();
    final now = _now;
    final isToday = f.localDate(now) == date;
    double y(int minute) => minute / 60 * hourHeight;

    final children = <Widget>[
      for (var h = 1; h < 24; h++) ...[
        Positioned(
          top: y(h * 60),
          left: gutter,
          right: 0,
          child: Container(height: 1, color: c.rule),
        ),
        Positioned(
          top: y(h * 60) - labelHeight / 2,
          left: 0,
          width: gutter - Sp.s,
          child: ExcludeSemantics(
            child: Text(f.hourLabel(h), style: labelStyle, textAlign: TextAlign.right),
          ),
        ),
      ],
      for (var i = 0; i < columns.length; i++)
        Positioned(
          top: 0,
          bottom: 0,
          left: gutter + i * columnWidth,
          child: Container(width: 1, color: c.rule),
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
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapUp: (details) {
                final minute = ((details.localPosition.dy / hourHeight * 60) ~/ 30 * 30).clamp(0, 23 * 60 + 30);
                final who = column.member == null ? '' : '&who=${column.member!.id}';
                context.push('/event/new?date=$date&time=${f.hhmm(minute)}$who');
              },
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
      final laneWidthBase = columnWidth - 1;
      for (final slot in slots) {
        final occ = slot.item;
        final drag = _drag;
        final dragging = drag != null && drag.occ.event.id == occ.event.id && drag.occ.start == occ.start;
        final startMin = dragging ? drag.newStart : slot.start;
        final endMin = dragging ? drag.newEnd : slot.end;
        final laneWidth = laneWidthBase / slot.lanes;
        final editable =
            app.allows(DenAction.editEvents) &&
            !occ.event.source.readOnly &&
            occ.start >= dayStart &&
            occ.end <= dayEnd;
        children.add(
          Positioned(
            top: y(startMin) + 1,
            height: math.max(y(endMin) - y(startMin) - 2, (22 * context.type.scale).roundToDouble()),
            left: left + 1 + slot.lane * laneWidth + 1,
            width: laneWidth * slot.span - 2,
            child: _Block(
              occ: occ,
              startMin: startMin,
              endMin: endMin,
              dragging: dragging,
              onTap: () => context.push('/event/${occ.event.id}?at=${occ.start}'),
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
    final den = app.den;
    final f = app.formats;
    final occ = drag.occ;
    final shift = drag.delta * 60000;
    final newStart = drag.resize ? occ.start : occ.start + shift;
    final newEnd = occ.end + shift;
    var scope = EditScope.all;
    if (occ.isRepeating) {
      final chosen = await askEditScope(context, title: '${drag.resize ? 'Change' : 'Move'} ${occ.title}');
      if (!mounted) return;
      if (chosen == null) {
        setState(() => _drag = null);
        return;
      }
      scope = chosen;
    }
    final messenger = ScaffoldMessenger.of(context);
    // One and following address the occurrence by its place in the series; all events move by
    // however far this occurrence moved.
    int? anchor(int allStart) => !occ.isRepeating ? null : (scope == EditScope.all ? allStart : occ.seriesStart);
    final error = await tryWrite(
      () => den.updateEvent(
        occ.event.id,
        {'start': newStart, 'end': newEnd},
        scope: scope,
        occurrence: anchor(occ.start),
      ),
    );
    if (!mounted) return;
    setState(() => _drag = null);
    if (error != null) {
      showNote(context, error);
      return;
    }
    final message = drag.resize
        ? '${occ.title} now ends at ${f.time(newEnd)}.'
        : '${occ.title} moved to ${f.time(newStart)}.';
    if (scope == EditScope.following) {
      // The series was split in two; there's no single change to take back.
      messenger.hideCurrentSnackBar();
      return;
    }
    showUndoOn(messenger, message, () {
      tryWrite(
        () => den.updateEvent(
          occ.event.id,
          {'start': occ.start, 'end': occ.end},
          scope: scope,
          occurrence: anchor(newStart),
        ),
      );
    });
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.columns, required this.gutter, required this.columnWidth});
  final List<_Column> columns;
  final double gutter;
  final double columnWidth;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final narrow = columnWidth < 112;
    final members = app.den.members;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        SizedBox(width: gutter),
        for (final column in columns)
          Container(
            width: columnWidth,
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: c.rule)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Sp.s, Sp.s, Sp.xs, Sp.s),
                  child: _who(context, column.member, narrow),
                ),
                SizedBox(
                  height: 3,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final marker
                          in column.member == null ? members.map((m) => m.marker) : [column.member!.marker])
                        Expanded(child: ColoredBox(color: c.marker(marker))),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _who(BuildContext context, Member? member, bool narrow) {
    final c = context.colors;
    final size = 26 * context.type.scale;
    final avatar = member == null
        ? Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: c.well, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Icon(PhosphorIconsFill.usersThree, size: size * 0.6, color: c.ink2),
          )
        : DenAvatar(member, size: size);
    final name = member?.name ?? 'Everyone';
    if (narrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          avatar,
          const SizedBox(height: Sp.xs),
          Text(
            name,
            style: context.type.meta(c.ink).copyWith(fontWeight: FontWeight.w700),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      );
    }
    return Row(
      children: [
        avatar,
        const SizedBox(width: Sp.s),
        Flexible(
          child: Text(name, style: context.type.bodyStrong(c.ink), overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}

class _AllDayRow extends StatelessWidget {
  const _AllDayRow({
    required this.columns,
    required this.gutter,
    required this.columnWidth,
    required this.lines,
    required this.lineHeight,
  });
  final List<_Column> columns;
  final double gutter;
  final double columnWidth;
  final int lines;
  final double lineHeight;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: lines * lineHeight + Sp.s * 2,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: gutter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Sp.xs, Sp.s, Sp.s, 0),
              child: Text('All day', style: context.type.meta(c.ink2), textAlign: TextAlign.right),
            ),
          ),
          for (final column in columns)
            Container(
              width: columnWidth,
              padding: const EdgeInsets.symmetric(horizontal: Sp.xs, vertical: Sp.s),
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: c.rule)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final occ in column.allDay)
                    CalendarEventLine(
                      occ: occ,
                      height: lineHeight,
                      onTap: () => context.push('/event/${occ.event.id}?at=${occ.start}'),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyDay extends StatelessWidget {
  const _EmptyDay({required this.date, required this.canAdd});
  final String date;
  final bool canAdd;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.rule)),
      ),
      child: EmptyLine(
        message: 'Nothing on the calendar.',
        actionLabel: canAdd ? 'Add event' : null,
        onAction: () => context.push('/event/new?date=$date'),
      ),
    );
  }
}

/// An event in the grid: the person bar on the left, the title, and the time when it fits.
/// Press and hold to move it; drag the bottom edge to change when it ends.
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

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final f = app.formats;
    final c = context.colors;
    final titleStyle = context.type.meta(c.ink).copyWith(fontWeight: FontWeight.w700);
    final timeStyle = context.type.meta(c.ink2);
    final lineHeight = (titleStyle.fontSize! * 1.3).ceilToDouble();
    final span = '${f.clock(startMin)} to ${f.clock(endMin % (24 * 60))}';
    final canMove = onMoveStart != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight;
        final lines = math.max(1, ((h - 6) / lineHeight).floor());
        final showTime = lines >= 2;
        final oneLine = lines == 1;
        final titleLines = math.min(2, showTime ? lines - 1 : lines);
        // Narrow columns show when it starts; the block's height already shows how long.
        final timeText = constraints.maxWidth >= 150 ? span : f.clock(startMin);
        final content = Container(
          decoration: BoxDecoration(
            color: c.well,
            borderRadius: BorderRadius.circular(Radii.control),
            border: Border.all(color: dragging ? c.ink : c.rule, width: dragging ? 2 : 1),
            boxShadow: dragging
                ? [BoxShadow(color: c.ink.withValues(alpha: 0.18), blurRadius: 24, offset: const Offset(0, 8))]
                : null,
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PersonBar(markers: app.markersFor(occ.assignees), width: 3, minHeight: 0),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Sp.xs + 2, 2, Sp.xs, 2),
                  child: oneLine
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(text: occ.title, style: titleStyle),
                                TextSpan(text: '  ${f.clock(startMin)}', style: timeStyle),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(occ.title, style: titleStyle, maxLines: titleLines, overflow: TextOverflow.ellipsis),
                            if (showTime)
                              Text(timeText, style: timeStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ],
                        ),
                ),
              ),
            ],
          ),
        );

        final grip = canMove && lines > titleLines + (showTime ? 1 : 0)
            ? Positioned(
                left: 0,
                right: 0,
                bottom: 3,
                child: IgnorePointer(
                  child: Center(child: Container(width: 16, height: 2, color: dragging ? c.ink : c.rule)),
                ),
              )
            : null;

        return Semantics(
          button: true,
          label: '${occ.title}, $span',
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
                  ?grip,
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
