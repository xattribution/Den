import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/app_state.dart';
import '../../../app/navigation.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/sheet.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../../../platform/capabilities.dart';
import '../state/calendar_models.dart';
import '../state/event_actions.dart';
import '../state/event_lookup.dart';
import '../words/block_words.dart';
import '../words/calendar_time.dart';
import '../words/event_words.dart';
import '../words/recurrence.dart';
import '../widgets/calendar_parts.dart';
import '../widgets/event_block.dart';
import '../widgets/event_look.dart';
import '../widgets/field_editors.dart';
import '../widgets/scope_card.dart';

/// The part of an event open for changing, in place.
enum DetailField { title, when, who, place, remind, notes, more }

/// One occurrence of an event, to look at and change in place: a solid block in its person's
/// color with the kind's pictogram, the title (tap it to rename) and when; then the details as
/// rows that open where they are (when and how often, who, rides, where, reminders, notes), and
/// "More options" for what isn't set yet. Who drives is two taps: the driver, then a person.
///
/// A change to a repeating event asks, right there, whether it's for this one or all of them;
/// a one-tap action (I'll drive) is for this one. Every change says what it did, with Undo.
/// On a phone it's a page; on iPad a form sheet ([inSheet]).
class EventDetailScreen extends StatefulWidget {
  const EventDetailScreen({super.key, required this.eventId, this.at, this.inSheet = false, this.from, this.open});

  final String eventId;

  /// The occurrence's start, UTC ms.
  final int? at;
  final bool inSheet;

  /// Where it was opened from (`today`, `calendar`), for the back button's words.
  final String? from;

  /// A part to open at once (screenshots of editing in place).
  final DetailField? open;

  @override
  State<EventDetailScreen> createState() => _EventDetailScreenState();
}

/// A change to a repeating event waiting for "just this one or all of them".
class _Pending {
  _Pending(this.patch, this.message);
  final Map<String, Object?> patch;
  final String message;
}

/// What the last change did, so Undo can take it back and the page can find the occurrence
/// again afterwards.
class _Done {
  _Done(this.message, this.result, {required this.id, required this.at});
  final String message;
  final ActionResult? result;
  final String id;
  final int? at;
}

class _EventDetailScreenState extends State<EventDetailScreen> {
  late String _id = widget.eventId;
  late int? _at = widget.at;
  late DetailField? _open = widget.open;
  _Pending? _pending;
  _Done? _done;
  _Done? _deleted;
  String? _error;
  VoidCallback? _retry;
  bool _busy = false;

  final _title = TextEditingController();
  final _place = TextEditingController();
  final _notes = TextEditingController();

  /// The time being changed in place, before Done.
  (int, int, bool)? _when;

  @override
  void dispose() {
    _title.dispose();
    _place.dispose();
    _notes.dispose();
    super.dispose();
  }

  /// For the parts of the page built outside this class.
  void _set(VoidCallback change) => setState(change);

  bool _prefilled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_prefilled) return;
    _prefilled = true;
    final open = widget.open;
    final occ = open == null ? null : _occurrence(DenScope.read(context).den);
    if (occ == null) return;
    _open = null;
    _opening(open!, occ);
  }

  Occurrence? _occurrence(Den den) {
    final event = den.event(_id);
    if (event == null) return null;
    return findOccurrence(den, _id, _at) ?? occurrenceOf(event);
  }

  // ------------------------------------------------------------ opening and closing parts

  void _toggle(DetailField field, Occurrence occ) => setState(() => _opening(field, occ));

  /// Opens [field] (or closes it when it's open), its words ready to change.
  void _opening(DetailField field, Occurrence occ) {
    if (_open == field) {
      _open = null;
      return;
    }
    _open = field;
    _error = null;
    switch (field) {
      case DetailField.title:
        _title.text = _value(occ, 'title') as String;
      case DetailField.place:
        _place.text = _value(occ, 'location') as String;
      case DetailField.notes:
        _notes.text = _value(occ, 'notes') as String;
      case DetailField.when:
        _when = (_value(occ, 'start') as int, _value(occ, 'end') as int, _value(occ, 'allDay') as bool);
      default:
        break;
    }
  }

  /// A field as it will be once the waiting change goes through.
  Object? _value(Occurrence occ, String key) {
    final pending = _pending?.patch;
    if (pending != null && pending.containsKey(key)) return pending[key];
    return switch (key) {
      'title' => occ.title,
      'location' => occ.location,
      'notes' => occ.notes,
      'start' => occ.start,
      'end' => occ.end,
      'allDay' => occ.allDay,
      'assignees' => occ.assignees,
      _ => null,
    };
  }

  // ------------------------------------------------------------ changes

  /// A change to fields one occurrence can hold on its own: on a repeating event it waits for
  /// "just this one or all of them"; otherwise it goes through now.
  void _propose(Occurrence occ, Map<String, Object?> patch, String message) {
    if (occ.isRepeating) {
      setState(() {
        _pending = _Pending({
          ...?_pending?.patch,
          ...patch,
        }, _pending == null ? message : 'Changed ${_value(occ, 'title')}');
        _open = null;
        _error = null;
      });
      return;
    }
    _write(occ, patch, EditScope.all, message);
  }

  Future<void> _write(Occurrence occ, Map<String, Object?> patch, EditScope scope, String message) async {
    if (_busy) return;
    final event = occ.event;
    final actions = context.actions;
    final before = (_id, _at);
    setState(() => _busy = true);
    ActionResult? result;
    final error = await tryWrite(() async {
      result = await EventActions(actions).update(
        event,
        patch,
        scope: scope,
        occurrence: event.rrule == null ? null : (scope == EditScope.all ? occ.start : occ.seriesStart),
      );
      return result;
    });
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (error != null) {
        _error = error;
        _retry = () => _write(occ, patch, scope, message);
        return;
      }
      _error = null;
      _retry = null;
      _pending = null;
      _open = null;
      _done = _Done(message, result, id: before.$1, at: before.$2);
      _relocate(title: (patch['title'] as String?) ?? occ.title, start: (patch['start'] as int?) ?? occ.start);
    });
  }

  /// After a change, finds the occurrence again: it may have moved, or (from this one on) become
  /// a new series of its own.
  void _relocate({required String title, required int start}) {
    final den = DenScope.read(context).den;
    final here = den.occurrences(start - 1, start + 1).where((o) => o.start == start).toList();
    final same = here.where((o) => o.event.id == _id);
    final match = same.isNotEmpty ? same.first : here.where((o) => o.title == title).firstOrNull;
    if (match != null) {
      _id = match.event.id;
      _at = match.start;
    } else if (den.event(_id) != null) {
      _at = start;
    }
  }

  Future<void> _undo(_Done done) async {
    final receipt = done.result?.receipt;
    if (receipt == null || _busy) return;
    final actions = context.actions;
    setState(() => _busy = true);
    final error = await tryWrite(() => actions.undo(receipt));
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (error != null) {
        _error = error;
        _retry = () => _undo(done);
        return;
      }
      _error = null;
      _done = null;
      _deleted = null;
      _id = done.id;
      _at = done.at;
    });
  }

  Future<void> _ride(Occurrence occ, Ride ride, String? driver, String message) async {
    if (_busy) return;
    final actions = context.actions;
    final before = (_id, _at);
    setState(() => _busy = true);
    ActionResult? result;
    final error = await tryWrite(() async => result = await EventActions(actions).setRide(occ, ride.leg, driver));
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (error != null) {
        _error = error;
        _retry = () => _ride(occ, ride, driver, message);
        return;
      }
      _error = null;
      _done = _Done(message, result, id: before.$1, at: before.$2);
    });
  }

  Future<void> _pickDriver(Occurrence occ, Ride ride, String forWhom) async {
    final app = DenScope.read(context);
    final picked = await showPeoplePicker(
      context,
      title: ride.leg == 'from' ? 'Who’s picking up $forWhom?' : 'Who’s driving $forWhom there?',
      people: possibleDrivers(app),
      current: ride.driver,
      anyoneLabel: 'Nobody yet',
      anyoneCurrent: ride.driver == null,
    );
    if (picked == null || !mounted) return;
    final driver = picked.anyone ? null : picked.member;
    if (driver == ride.driver) return;
    await _ride(occ, ride, driver, _rideWords(app, ride.leg, driver, forWhom));
  }

  static String _rideWords(AppState app, String leg, String? driver, String forWhom) {
    final there = leg != 'from';
    if (driver == null) return there ? 'Nobody is driving $forWhom there now' : 'Nobody is picking up $forWhom now';
    final mine = driver == app.me?.id;
    final name = mine ? 'You’re' : '${app.memberById(driver)?.name ?? 'Someone'} is';
    return there ? '$name driving $forWhom there' : '$name picking up $forWhom';
  }

  Future<void> _more(Occurrence occ) async {
    final app = DenScope.read(context);
    final f = app.formats;
    final (_, all) = scopeQuestion(f, occ, verb: 'Delete');
    final choice = await showDenSheet<EditScope>(
      context,
      builder: (sheet) {
        final c = sheet.colors;
        Widget row(String label, EditScope scope) => _SheetRow(
          icon: PhosphorIconsBold.trash,
          label: label,
          color: c.destructive,
          onTap: () => Navigator.of(sheet).pop(scope),
        );
        return Padding(
          padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.s),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, Sp.xs, 4, Sp.l),
                child: Semantics(header: true, child: Text(tidyLine(occ.title), style: sheet.text.sheetTitle(c.ink))),
              ),
              GroupCard(
                child: Column(
                  children: occ.isRepeating
                      ? ruled([
                          row('Delete just this one', EditScope.one),
                          row('Delete this one and the rest', EditScope.following),
                          row(all == 'All of them' ? 'Delete all of them' : 'Delete e${all.substring(1)}', EditScope.all),
                        ], indent: 36)
                      : [row('Delete ${occ.title}', EditScope.all)],
                ),
              ),
            ],
          ),
        );
      },
    );
    if (choice == null || !mounted) return;
    await _delete(occ, choice);
  }

  Future<void> _delete(Occurrence occ, EditScope scope) async {
    final actions = context.actions;
    final f = DenScope.read(context).formats;
    final before = (_id, _at);
    setState(() => _busy = true);
    ActionResult? result;
    final error = await tryWrite(
      () async => result = await EventActions(
        actions,
      ).delete(occ.event, scope: scope, occurrence: occ.isRepeating ? occ.seriesStart : null),
    );
    if (!mounted) return;
    final day = f.short(f.localDate(occ.start));
    setState(() {
      _busy = false;
      if (error != null) {
        _error = error;
        _retry = () => _delete(occ, scope);
        return;
      }
      _error = null;
      _deleted = _Done(
        switch (scope) {
          EditScope.one => 'Deleted ${occ.title} on $day',
          EditScope.following => 'Deleted ${occ.title} from $day on',
          EditScope.all => 'Deleted ${occ.title}',
        },
        result,
        id: before.$1,
        at: before.$2,
      );
    });
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final c = context.colors;
    final deleted = _deleted;
    final occ = deleted == null ? _occurrence(app.den) : null;

    final List<Widget> children;
    if (deleted != null) {
      children = [
        DoneRow(
          message: deleted.message,
          onUndo: deleted.result?.receipt?.undoable ?? false ? () => _undo(deleted) : null,
        ),
        const SizedBox(height: Sp.l),
        Align(
          alignment: Alignment.centerLeft,
          child: CalendarPill(label: 'Back to the calendar', onTap: () => _leave(context)),
        ),
      ];
    } else if (occ == null) {
      children = [
        Text(
          tidyLine('This event was deleted, or it isn’t shared with this device.'),
          style: context.text.body(c.ink2),
        ),
        const SizedBox(height: Sp.l),
        Align(
          alignment: Alignment.centerLeft,
          child: CalendarPill(label: 'Open the calendar', onTap: () => context.go('/calendar')),
        ),
      ];
    } else {
      children = _content(context, app, occ);
    }

    final top = _TopBar(
      inSheet: widget.inSheet,
      back: switch (widget.from) {
        'today' => 'Today',
        'calendar' => 'Calendar',
        _ => 'Back',
      },
      onBack: () => _leave(context),
      onMore: occ != null && _canEdit(app, occ) ? () => _more(occ) : null,
    );

    final body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: DenLayout.gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          top,
          const SizedBox(height: Sp.l),
          ...children,
        ],
      ),
    );

    if (widget.inSheet) {
      return SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: Sp.s),
        child: body,
      );
    }
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.only(top: Sp.s, bottom: Sp.xxl + bottom),
          children: [body],
        ),
      ),
    );
  }

  void _leave(BuildContext context) => closePage(context);

  static bool _canEdit(AppState app, Occurrence occ) => app.allows(DenAction.editEvents) && !occ.event.source.readOnly;

  List<Widget> _content(BuildContext context, AppState app, Occurrence occ) {
    final f = app.formats;
    final c = context.colors;
    final event = occ.event;
    final canEdit = _canEdit(app, occ);
    final look = EventLook.of(app, occ, c);
    final today = app.today;
    final pending = _pending;
    final done = _done;

    final start = _value(occ, 'start') as int;
    final end = _value(occ, 'end') as int;
    final allDay = _value(occ, 'allDay') as bool;
    final first = f.localDate(start);
    final last = f.lastDate(start, end);
    final shown = Occurrence(
      event: event,
      start: start,
      end: end,
      title: _value(occ, 'title') as String,
      location: _value(occ, 'location') as String,
      notes: _value(occ, 'notes') as String,
      assignees: _value(occ, 'assignees') as List<String>,
      allDay: allDay,
      rides: occ.rides,
      reminders: occ.reminders,
    );
    final whenLine = first == last
        ? '${f.relative(first, today)}, ${allDay ? 'all day' : f.occurrenceSpan(shown, today: today)}'
        : f.occurrenceSpan(shown, today: today);

    final notes = <Widget>[
      if (event.source.readOnly) _sourceNote(context, app, event.source),
      if (!event.source.readOnly && !app.allows(DenAction.editEvents))
        const NoticeLine(
          message: 'Changing events needs calendar access. A parent can turn it on for you in Family.',
          icon: PhosphorIconsBold.lockSimple,
        ),
      const OfflineNote(),
    ];

    final scope = pending == null
        ? null
        : ScopeCard(
            occ: occ,
            onPick: (s) => _write(occ, pending.patch, s, pending.message),
            onCancel: () => setState(() => _pending = null),
          );
    final status = _error != null
        ? (_open == DetailField.title
              ? null
              : ErrorState(
                  message: _error!,
                  actionLabel: 'Try again',
                  onAction: _retry ?? () => setState(() => _error = null),
                ))
        : done != null
        ? DoneRow(message: done.message, onUndo: done.result?.receipt?.undoable ?? false ? () => _undo(done) : null)
        : null;

    return [
      _Hero(
        occ: occ,
        look: look,
        title: shown.title,
        whenLine: whenLine,
        editing: _open == DetailField.title,
        controller: _title,
        onEdit: canEdit ? () => _toggle(DetailField.title, occ) : null,
        onDone: () {
          final title = _title.text.trim();
          if (title.isEmpty || title == shown.title) {
            setState(() => _open = null);
            return;
          }
          _propose(occ, {'title': title}, 'Renamed it $title');
        },
      ),
      // A rename that didn't go through says why right under the field it was typed in.
      if (_error != null && _open == DetailField.title)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, Sp.s, 0, 0),
          child: ErrorState(
            message: _error!,
            actionLabel: 'Try again',
            onAction: _retry ?? () => setState(() => _error = null),
          ),
        ),
      for (final n in notes)
        Padding(
          padding: const EdgeInsets.only(top: Sp.m),
          child: n,
        ),
      const SizedBox(height: Sp.l),
      _Details(state: this, occ: occ, shown: shown, canEdit: canEdit),
      DenReveal(
        visible: scope != null,
        child: Padding(
          padding: const EdgeInsets.only(top: Sp.l),
          child: scope ?? const SizedBox.shrink(),
        ),
      ),
      DenReveal(
        visible: status != null,
        child: Padding(padding: const EdgeInsets.fromLTRB(4, Sp.m, 0, 0), child: status ?? const SizedBox.shrink()),
      ),
      _Provenance(event),
    ];
  }

  Widget _sourceNote(BuildContext context, AppState app, EventSource source) {
    final label = source.label;
    final String from;
    if (source.kind == 'device') {
      // A phone calendar: its name, and the phone it lives on (the device id leads the ref).
      final ref = source.ref ?? '';
      final phone = ref.contains('/') ? app.den.device(ref.substring(0, ref.indexOf('/')))?.name : null;
      final name = label == null || label.isEmpty ? 'a phone calendar' : label;
      from = phone == null || phone.isEmpty ? 'From $name on a phone.' : 'From $name on $phone.';
    } else {
      from = label == null || label.isEmpty ? 'From another calendar.' : 'From $label’s calendar.';
    }
    return NoticeLine(message: '$from Change it there.', icon: PhosphorIconsBold.calendarCheck);
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.inSheet, required this.back, required this.onBack, required this.onMore});

  final bool inSheet;
  final String back;
  final VoidCallback onBack;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final more = onMore == null
        ? null
        : RoundButton(
            icon: PhosphorIconsBold.dotsThree,
            label: 'More',
            onTap: onMore,
            fill: context.colors.card,
            color: context.colors.ink,
            size: Targets.adult,
          );
    if (inSheet) {
      return Row(
        children: [
          ?more,
          const Spacer(),
          CalendarPill(label: 'Done', onTap: onBack),
        ],
      );
    }
    return Row(
      children: [
        CalendarPill(label: back, icon: PhosphorIconsBold.caretLeft, semanticLabel: 'Back', onTap: onBack),
        const Spacer(),
        ?more,
      ],
    );
  }
}

/// The event's block at the top: the pictogram, the title (tap to rename it right there) and
/// when. It's where the list's block lands.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.occ,
    required this.look,
    required this.title,
    required this.whenLine,
    required this.editing,
    required this.controller,
    required this.onEdit,
    required this.onDone,
  });

  final Occurrence occ;
  final EventLook look;
  final String title;
  final String whenLine;
  final bool editing;
  final TextEditingController controller;
  final VoidCallback? onEdit;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final t = context.text;
    final titleStyle = t.screenTitle(look.ink).copyWith(fontSize: 28 * t.scale);
    final heading = Semantics(
      header: true,
      button: onEdit != null,
      hint: onEdit == null ? null : 'Tap to rename',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onEdit,
        child: Text(tidyLine(title), style: titleStyle),
      ),
    );
    final field = Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            // As long as a title may be, so a rename never fails for its length.
            inputFormatters: [LengthLimitingTextInputFormatter(200)],
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => onDone(),
            cursorColor: look.fill,
            style: t.sheetTitle(look.fill).copyWith(fontSize: 22 * t.scale),
            decoration: InputDecoration(
              filled: true,
              fillColor: look.ink,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              border: const OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(Radii.input)),
                borderSide: BorderSide.none,
              ),
              enabledBorder: const OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(Radii.input)),
                borderSide: BorderSide.none,
              ),
              focusedBorder: const OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(Radii.input)),
                borderSide: BorderSide.none,
              ),
              semanticCounterText: '',
              labelText: null,
              hintText: 'Title',
              hintStyle: t.sheetTitle(look.fill).copyWith(fontSize: 22 * t.scale),
            ),
          ),
        ),
        const SizedBox(width: Sp.s),
        DenPressable(
          onTap: onDone,
          shape: StadiumBorder(side: BorderSide(color: look.ink, width: 2)),
          semanticLabel: 'Done',
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Sp.l, vertical: Sp.s),
              child: Center(widthFactor: 1, child: Text('Done', style: t.label(look.ink))),
            ),
          ),
        ),
      ],
    );

    return Hero(
      tag: eventHeroTag(occ),
      flightShuttleBuilder: (_, animation, _, _, _) => BlockFlight(animation: animation, color: look.fill),
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          decoration: BoxDecoration(color: look.fill, borderRadius: BorderRadius.circular(BlockFlight.heroRadius)),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(look.icon, size: 34, color: look.ink),
                  const Spacer(),
                  if (look.everyone) FamilyDots(family: look.family),
                ],
              ),
              const SizedBox(height: 14),
              DenCrossfade(
                child: editing
                    ? KeyedSubtree(key: const ValueKey('field'), child: field)
                    : KeyedSubtree(key: const ValueKey('title'), child: heading),
              ),
              const SizedBox(height: 14),
              Text(tidyLine(whenLine), style: t.body(look.ink)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The details in one card, each a row that opens where it is.
class _Details extends StatelessWidget {
  const _Details({required this.state, required this.occ, required this.shown, required this.canEdit});

  final _EventDetailScreenState state;
  final Occurrence occ;

  /// The occurrence as it will be once a waiting change goes through.
  final Occurrence shown;
  final bool canEdit;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final f = app.formats;
    final c = context.colors;
    final t = context.text;
    final event = occ.event;
    final open = state._open;
    final today = app.today;
    final date = f.localDate(shown.start);
    final weekStart = app.den.family?.weekStart ?? 0;
    final repeat =
        describeRrule(event.rrule, f, startDate: f.localDate(event.start), weekStart: weekStart) ?? 'Just this once';
    final people = app.den.members;
    final named = [for (final id in shown.assignees) ?app.memberById(id)];
    final everyone = named.isEmpty || named.length == people.length;
    final forWhom = everyone ? 'everyone' : joinNames([for (final m in named) m.name]);
    final reminders = [...occ.reminders]..sort();
    final audience = event.audience;

    final timeLine = shown.allDay
        ? (f.localDate(shown.start) == f.lastDate(shown.start, shown.end)
              ? '${weekdayLong(f, date)}, all day'
              : f.occurrenceSpan(shown, today: today))
        : f.localDate(shown.start) == f.localDate(shown.end) || shown.end <= shown.start
        ? '${weekdayLong(f, date)}, ${f.occurrenceSpan(shown, today: today)}'
        : f.occurrenceSpan(shown, today: today);

    final rows = <Widget>[];
    void add(Widget row) {
      if (rows.isNotEmpty) rows.add(const RowRule(indent: 36));
      rows.add(row);
    }

    // When, and how often.
    add(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Row(
            icon: PhosphorIconsBold.clock,
            title: timeLine,
            detail: repeat,
            onTap: canEdit ? () => state._toggle(DetailField.when, occ) : null,
            open: open == DetailField.when,
          ),
          DenReveal(
            visible: open == DetailField.when,
            child: Padding(
              padding: const EdgeInsets.only(left: 36, bottom: Sp.l),
              child: open != DetailField.when || state._when == null
                  ? const SizedBox.shrink()
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        WhenEditor(
                          start: state._when!.$1,
                          end: state._when!.$2,
                          allDay: state._when!.$3,
                          onChanged: (s, e, a) => state._set(() => state._when = (s, e, a)),
                        ),
                        const SizedBox(height: Sp.m),
                        Text('Repeats', style: t.meta(c.ink2)),
                        const SizedBox(height: Sp.xs),
                        RepeatChips(
                          rrule: event.rrule,
                          date: f.localDate(occ.start),
                          seriesStart: f.localDate(event.start),
                          onChanged: (rule) => state._write(
                            occ,
                            {'rrule': rule},
                            // A new rule starts from this one; the ones before stay as they were.
                            event.rrule == null ? EditScope.all : EditScope.following,
                            rule == null
                                ? 'Now just this once'
                                : 'Now ${(describeRrule(rule, f, startDate: f.localDate(occ.start), weekStart: weekStart) ?? 'repeating').toLowerCase()}',
                          ),
                        ),
                        const SizedBox(height: Sp.l),
                        CalendarPill(
                          label: 'Done',
                          primary: true,
                          onTap: () {
                            final (s, e, a) = state._when!;
                            if (s == shown.start && e == shown.end && a == shown.allDay) {
                              state._set(() => state._open = null);
                              return;
                            }
                            state._propose(
                              occ,
                              {'start': s, 'end': e, if (a != occ.allDay) 'allDay': a},
                              a
                                  ? 'Moved to ${f.short(f.localDate(s))}, all day'
                                  : 'Moved to ${f.relative(f.localDate(s), today)}, ${f.time(s)}',
                            );
                          },
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );

    // Who.
    add(
      Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.m),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const RowGlyph(PhosphorIconsBold.usersThree),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tidyLine(everyone ? 'Everyone' : joinNames([for (final m in named) m.name])),
                    style: t.rowTitle(c.ink),
                  ),
                  const SizedBox(height: 10),
                  PeopleToggles(
                    people: people,
                    selected: everyone ? const [] : [for (final m in named) m.id],
                    enabled: canEdit,
                    onChanged: (ids) {
                      final names = ids.isEmpty
                          ? 'everyone'
                          : joinNames([for (final id in ids) app.memberById(id)?.name ?? '']);
                      state._propose(occ, {'assignees': ids}, 'Now for $names');
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    // Rides.
    if (occ.rides.isNotEmpty) {
      add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Sp.s),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(padding: EdgeInsets.only(top: 10), child: RowGlyph(PhosphorIconsBold.car)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  children: [
                    for (final ride in occ.rides) _RideLine(state: state, occ: occ, ride: ride, forWhom: forWhom),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Where.
    if (shown.location.isNotEmpty || open == DetailField.place) {
      add(
        open == DetailField.place
            ? _FieldRow(
                icon: PhosphorIconsBold.mapPin,
                controller: state._place,
                hint: 'Add a place',
                onDone: () {
                  final place = state._place.text.trim();
                  if (place == shown.location) {
                    state._set(() => state._open = null);
                    return;
                  }
                  state._propose(occ, {'location': place}, place.isEmpty ? 'Took the place off' : 'Now at $place');
                },
              )
            : _PlaceRow(place: shown.location, onEdit: canEdit ? () => state._toggle(DetailField.place, occ) : null),
      );
    }

    // Reminders.
    if (reminders.isNotEmpty || open == DetailField.remind) {
      add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Row(
              icon: PhosphorIconsBold.bellSimple,
              title: reminders.isEmpty ? 'No reminder' : joinNames([for (final m in reminders) reminderWords(m)]),
              onTap: canEdit ? () => state._toggle(DetailField.remind, occ) : null,
              open: open == DetailField.remind,
              regular: true,
            ),
            DenReveal(
              visible: open == DetailField.remind,
              child: Padding(
                padding: const EdgeInsets.only(left: 36, bottom: Sp.l),
                child: ReminderChips(
                  value: reminders,
                  onChanged: (value) => state._write(
                    occ,
                    {'reminders': value},
                    EditScope.all,
                    value.isEmpty
                        ? 'No reminder now'
                        : 'Reminder ${joinNames([for (final m in value) reminderWords(m)]).toLowerCase()}',
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Notes.
    if (shown.notes.isNotEmpty || open == DetailField.notes) {
      add(
        open == DetailField.notes
            ? _FieldRow(
                icon: PhosphorIconsBold.notepad,
                controller: state._notes,
                hint: 'Add notes',
                multiline: true,
                onDone: () {
                  final notes = state._notes.text.trim();
                  if (notes == shown.notes) {
                    state._set(() => state._open = null);
                    return;
                  }
                  state._propose(occ, {'notes': notes}, notes.isEmpty ? 'Took the notes off' : 'Saved the notes');
                },
              )
            : _Row(
                icon: PhosphorIconsBold.notepad,
                title: shown.notes,
                onTap: canEdit ? () => state._toggle(DetailField.notes, occ) : null,
                regular: true,
              ),
      );
    }

    // Who can see it, when it isn't everyone.
    if (audience != Audience.everyone) {
      add(
        _Row(
          icon: PhosphorIconsBold.eyeSlash,
          title: app.seenBy(event.space),
          detail: 'Who can see it',
          onTap: canEdit ? () => state._toggle(DetailField.more, occ) : null,
        ),
      );
    }

    // More options: what isn't set yet.
    final missing = <Widget>[
      if (shown.location.isEmpty && open != DetailField.place)
        NavRow(
          chevron: false,
          icon: PhosphorIconsBold.mapPin,
          label: 'Add a place',
          onTap: () => state._toggle(DetailField.place, occ),
        ),
      if (!occ.rides.any((r) => r.leg == 'to'))
        NavRow(
          chevron: false,
          icon: PhosphorIconsBold.car,
          label: 'Someone drives there',
          onTap: () => state._propose(occ, {
            'rides': [const Ride('to', null), ...occ.rides],
          }, 'Added a ride there'),
        ),
      if (!occ.rides.any((r) => r.leg == 'from'))
        NavRow(
          chevron: false,
          icon: PhosphorIconsBold.car,
          label: 'Someone picks up',
          onTap: () => state._propose(occ, {
            'rides': [...occ.rides, const Ride('from', null)],
          }, 'Added a ride home'),
        ),
      if (reminders.isEmpty && open != DetailField.remind)
        NavRow(
          chevron: false,
          icon: PhosphorIconsBold.bellSimple,
          label: 'Add a reminder',
          onTap: () => state._toggle(DetailField.remind, occ),
        ),
      if (shown.notes.isEmpty && open != DetailField.notes)
        NavRow(
          chevron: false,
          icon: PhosphorIconsBold.notepad,
          label: 'Add notes',
          onTap: () => state._toggle(DetailField.notes, occ),
        ),
      _AudienceRow(state: state, occ: occ),
    ];
    if (canEdit) {
      add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Row(
              icon: open == DetailField.more ? PhosphorIconsBold.caretUp : PhosphorIconsBold.caretDown,
              title: 'More options',
              onTap: () => state._toggle(DetailField.more, occ),
              open: open == DetailField.more,
              regular: true,
            ),
            DenReveal(
              visible: open == DetailField.more,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final row in missing) ...[const RowRule(indent: 36), row],
                ],
              ),
            ),
          ],
        ),
      );
    }

    return GroupCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows));
  }
}

/// A detail row: an ink glyph, a bold line and a quiet one. Tap to open it in place.
class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.title,
    this.detail,
    this.onTap,
    this.open = false,
    this.regular = false,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final VoidCallback? onTap;
  final bool open;

  /// The line in regular weight (a reminder, notes), not bold.
  final bool regular;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 64),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Sp.m),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RowGlyph(icon),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tidyLine(title), style: regular ? t.body(c.ink) : t.rowTitle(c.ink)),
                    if (detail != null) ...[const SizedBox(height: 2), Text(tidyLine(detail!), style: t.meta(c.ink2))],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (onTap == null) return Semantics(container: true, child: content);
    return DenPressable(
      onTap: onTap,
      scale: false,
      shape: const RoundedRectangleBorder(),
      toggled: open,
      semanticLabel: [title, ?detail].join(', '),
      child: ExcludeSemantics(child: content),
    );
  }
}

/// Who can see it, as three plain choices.
class _AudienceRow extends StatelessWidget {
  const _AudienceRow({required this.state, required this.occ});

  final _EventDetailScreenState state;
  final Occurrence occ;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final c = context.colors;
    final event = occ.event;
    final me = app.me;
    final owner = Space.memberOf(event.space);
    // Someone else's private event stays theirs: "Just me" would mean the parent.
    final locked = owner != null && owner != me?.id;
    final options = <(Audience, String)>[
      (Audience.everyone, 'Everyone'),
      if (me?.isParent ?? false) (Audience.parents, 'Parents'),
      (Audience.justMe, 'Just me'),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.m),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RowGlyph(PhosphorIconsBold.eye, color: c.ink2),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Who can see it', style: context.text.body(c.ink)),
                const SizedBox(height: Sp.s),
                if (locked)
                  Text(app.seenBy(event.space), style: context.text.meta(c.ink2))
                else
                  Wrap(
                    spacing: Sp.s,
                    runSpacing: Sp.xs,
                    children: [
                      for (final (value, label) in options)
                        ChoiceChipPill(
                          label: label,
                          selected: event.audience == value,
                          onTap: event.audience == value
                              ? null
                              : () => state._write(
                                  occ,
                                  {'audience': value},
                                  EditScope.all,
                                  'Now ${label == 'Everyone' ? 'everyone' : label.toLowerCase()} can see it',
                                ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One ride leg: "There" or "Home", and who drives. Tap the driver to pick someone else (two
/// taps); with nobody driving, "I'll drive" takes it for this day in one.
class _RideLine extends StatelessWidget {
  const _RideLine({required this.state, required this.occ, required this.ride, required this.forWhom});

  final _EventDetailScreenState state;
  final Occurrence occ;
  final Ride ride;
  final String forWhom;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final c = context.colors;
    final t = context.text;
    final me = app.me;
    final driver = app.memberById(ride.driver);
    final canChange = canTakeRide(app) && !occ.event.source.readOnly;
    final canPick = app.allows(DenAction.editEvents) && !occ.event.source.readOnly;
    final there = ride.leg != 'from';
    final label = there ? 'There' : 'Home';

    final Widget value;
    if (ride.driver == null) {
      // Nobody yet: one tap takes it ("I'll drive"); a parent can also tap "Nobody yet" to pick
      // someone else. Without the right to change it, it just says so.
      value = Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Sp.s,
        runSpacing: Sp.xs,
        children: [
          if (!canPick)
            Text('Nobody is driving', style: t.body(c.ink2))
          else
            Semantics(
              button: true,
              label: '$label: nobody yet. Pick who drives',
              excludeSemantics: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => state._pickDriver(occ, ride, forWhom),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: Targets.adult),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Nobody yet', style: t.body(c.ink2)),
                      const SizedBox(width: 2),
                      Icon(PhosphorIconsBold.caretRight, size: 14, color: c.ink2),
                    ],
                  ),
                ),
              ),
            ),
          if (canChange)
            CalendarPill(
              label: there ? 'I’ll drive' : 'I’ll pick up',
              primary: true,
              onTap: () =>
                  state._ride(occ, ride, me!.id, _EventDetailScreenState._rideWords(app, ride.leg, me.id, forWhom)),
            ),
        ],
      );
    } else {
      final name = ride.driver == me?.id ? 'You' : (driver?.name ?? 'Someone');
      value = Semantics(
        button: canPick,
        label: '$label: $name drives${canPick ? '. Change who' : ''}',
        excludeSemantics: true,
        child: DenPressable(
          onTap: canPick ? () => state._pickDriver(occ, ride, forWhom) : null,
          scale: true,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: Targets.adult),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (driver != null) ...[DenAvatar(driver, size: 26), const SizedBox(width: Sp.s)],
                  Text(name, style: t.rowTitle(c.ink)),
                  if (canPick) ...[
                    const SizedBox(width: 2),
                    Icon(PhosphorIconsBold.caretRight, size: 14, color: c.ink2),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }
    // The leg's name and who drives share a line while they fit; at large text the driver (and
    // the button) move under the name instead of squeezing it.
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: Targets.adult, minWidth: double.infinity),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: Sp.xs,
        spacing: Sp.s,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: Targets.adult),
            child: Align(
              alignment: Alignment.centerLeft,
              widthFactor: 1,
              child: Text(label, style: t.body(c.ink)),
            ),
          ),
          value,
        ],
      ),
    );
  }
}

/// Where: the place in bold (tap it to change it) and Directions, which opens Maps.
class _PlaceRow extends StatelessWidget {
  const _PlaceRow({required this.place, required this.onEdit});

  final String place;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: Sp.s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(padding: EdgeInsets.only(top: 8), child: RowGlyph(PhosphorIconsBold.mapPin)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  button: onEdit != null,
                  hint: onEdit == null ? null : 'Tap to change the place',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onEdit,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 36, minWidth: double.infinity),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(tidyLine(place), style: context.text.rowTitle(c.ink)),
                      ),
                    ),
                  ),
                ),
                Semantics(
                  link: true,
                  hint: 'Opens in Maps',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _open(context, place),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: Targets.adult),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        widthFactor: 1,
                        child: Text('Directions', style: context.text.meta(c.ink2).bold),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Future<void> _open(BuildContext context, String location) async {
    final uri = Capabilities.apple
        ? Uri.https('maps.apple.com', '/', {'q': location})
        : Uri.https('www.google.com', '/maps/search/', {'api': '1', 'query': location});
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      opened = false;
    }
    if (!opened) {
      await Clipboard.setData(ClipboardData(text: location));
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Couldn’t open a maps app. The address is copied, so you can paste it.')),
        );
      }
    }
  }
}

/// A detail being typed in place: the field (17, so iOS doesn't zoom) and Done.
class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.icon,
    required this.controller,
    required this.hint,
    required this.onDone,
    this.multiline = false,
  });

  final IconData icon;
  final TextEditingController controller;
  final String hint;
  final VoidCallback onDone;
  final bool multiline;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.m),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 14), child: RowGlyph(icon)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  minLines: 1,
                  maxLines: multiline ? 6 : 1,
                  textCapitalization: multiline ? TextCapitalization.sentences : TextCapitalization.words,
                  textInputAction: multiline ? TextInputAction.newline : TextInputAction.done,
                  onSubmitted: multiline ? null : (_) => onDone(),
                  style: context.text.body(c.ink),
                  decoration: InputDecoration(
                    hintText: hint,
                    fillColor: c.bg,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  ),
                ),
                const SizedBox(height: Sp.s),
                CalendarPill(label: 'Done', primary: true, onTap: onDone),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetRow extends StatelessWidget {
  const _SheetRow({required this.icon, required this.label, required this.color, required this.onTap});

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => DenPressable(
    onTap: onTap,
    scale: false,
    shape: const RoundedRectangleBorder(),
    semanticLabel: label,
    child: ExcludeSemantics(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Row(
          children: [
            RowGlyph(icon, color: color),
            const SizedBox(width: 14),
            Expanded(child: Text(tidyLine(label), style: context.text.body(color))),
          ],
        ),
      ),
    ),
  );
}

class _Provenance extends StatelessWidget {
  const _Provenance(this.event);
  final Event event;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final f = app.formats;
    final c = context.colors;
    final rec = event.rec;
    final today = app.today;
    String on(Hlc hlc) => f.monthDay(f.localDate(hlc.millis), relativeTo: today);
    final added = app.memberById(rec.createdBy)?.name;
    final changed = app.memberById(rec.updatedBy)?.name;
    final parts = [
      if (added != null) 'Added by $added, ${on(rec.created)}',
      if (changed != null && rec.updated != rec.created) 'Changed by $changed, ${on(rec.updated)}',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, Sp.l, 4, 0),
      child: Text(keepUnits(parts.join('. ')), style: context.text.meta(c.ink2)),
    );
  }
}
