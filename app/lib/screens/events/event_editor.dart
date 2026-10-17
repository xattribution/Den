import 'dart:math' as math;

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../design/parts/calendar_choice.dart';
import '../../design/parts/calendar_panel.dart';
import '../../design/parts/calendar_scope.dart';
import '../../design/parts/calendar_category.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/app_state.dart';
import '../../state/format.dart';
import '../calendar/calendar_time.dart';
import 'event_detail.dart';
import 'event_lookup.dart';
import 'event_words.dart';
import 'recurrence.dart';
import 'recurrence_editor.dart';

/// Adds an event, or edits one occurrence's event. New events take their day, time and person
/// from where the person tapped (`?date=`, `?time=`, `?who=`). Repeating events ask how far a
/// change reaches; rules Den can't express are kept exactly as they came.
class EventEditorScreen extends StatefulWidget {
  const EventEditorScreen({super.key, this.eventId, this.at, this.date, this.time, this.who});

  /// The event to edit; null adds one.
  final String? eventId;

  /// The occurrence being edited (its start, UTC ms).
  final int? at;

  /// For a new event: local date `YYYY-MM-DD`, time `HH:mm`, and a member id.
  final String? date;
  final String? time;
  final String? who;

  @override
  State<EventEditorScreen> createState() => _EventEditorScreenState();
}

class _EventEditorScreenState extends State<EventEditorScreen> {
  final _title = TextEditingController();
  final _location = TextEditingController();
  final _notes = TextEditingController();

  bool _loaded = false;
  Event? _event;
  Occurrence? _occ;

  bool _allDay = false;
  late String _startDate;
  late String _endDate;
  late int _startMin;
  late int _endMin;
  Recurrence? _repeat;
  Recurrence? _initialRepeat;
  String? _custom;

  /// Set when the person replaced a custom rule, so the old text is never written back.
  bool _replacedCustom = false;
  List<String> _assignees = [];
  String? _category;
  List<int> _reminders = [];
  List<Ride> _rides = [];
  bool _countdown = false;
  Audience _audience = Audience.everyone;

  bool _triedSave = false;
  bool _saving = false;
  String? _initialSignature;

  bool get _isNew => widget.eventId == null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final app = DenScope.read(context);
    final f = app.formats;
    if (_isNew) {
      final today = app.today;
      _startDate = widget.date != null && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(widget.date!) ? widget.date! : today;
      final asked = f.parseHhmm(widget.time);
      if (asked != null) {
        _startMin = asked;
      } else if (_startDate == today) {
        final now = f.minuteOfDay(DateTime.now().millisecondsSinceEpoch);
        _startMin = math.min(((now ~/ 30) + 1) * 30, 23 * 60);
      } else {
        _startMin = 9 * 60;
      }
      final end = _startMin + 60;
      _endDate = end >= 24 * 60 ? f.addDays(_startDate, 1) : _startDate;
      _endMin = end % (24 * 60);
      if (widget.who != null && app.den.member(widget.who!) != null) _assignees = [widget.who!];
    } else {
      final event = app.den.event(widget.eventId!);
      _event = event;
      if (event != null) {
        final occ = findOccurrence(app.den, event.id, widget.at) ?? occurrenceOf(event);
        _occ = occ;
        _title.text = occ.title;
        _location.text = occ.location;
        _notes.text = occ.notes;
        _allDay = occ.allDay;
        _assignees = [...occ.assignees];
        _category = event.category;
        _reminders = [...occ.reminders]..sort();
        _rides = [...occ.rides];
        _countdown = event.countdown;
        _audience = event.audience;
        _startDate = f.localDate(occ.start);
        if (occ.allDay) {
          _endDate = f.lastDate(occ.start, occ.end);
          _startMin = 9 * 60;
          _endMin = 10 * 60;
        } else {
          _endDate = f.localDate(occ.end);
          _startMin = f.minuteOfDay(occ.start);
          _endMin = f.minuteOfDay(occ.end);
        }
        switch (parseRrule(event.rrule, startDate: f.localDate(event.start), f: f)) {
          case SupportedRule(:final rule):
            _repeat = rule;
          case CustomRule(:final raw):
            _custom = raw;
          case null:
            break;
        }
        _initialRepeat = _repeat;
      } else {
        _startDate = app.today;
        _endDate = app.today;
        _startMin = 9 * 60;
        _endMin = 10 * 60;
      }
    }
    _initialSignature = _signature();
  }

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _notes.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ values

  int _startMs(Formats f) => _allDay ? f.startOf(_startDate) : f.msAt(_startDate, _startMin);
  int _endMs(Formats f) => _allDay ? f.startOf(f.addDays(_endDate, 1)) : f.msAt(_endDate, _endMin);

  String? _rrule(Formats f) {
    if (_custom != null) return _custom;
    if (_repeat == null) return null;
    if (!_isNew && !_replacedCustom && _repeat == _initialRepeat && _event?.rrule != null) return _event!.rrule;
    return toRrule(_repeat!, f);
  }

  String _signature() => [
    _title.text,
    _location.text,
    _notes.text,
    _allDay,
    _startDate,
    _endDate,
    _startMin,
    _endMin,
    _custom,
    _repeat.hashCode,
    _assignees.join(','),
    _category,
    _reminders.join(','),
    _rides.map((r) => '${r.leg}:${r.driver}').join(','),
    _countdown,
    _audience,
  ].join('|');

  bool get _dirty => _initialSignature != null && _signature() != _initialSignature;

  String? _timeError(Formats f) {
    if (_allDay) {
      return _endDate.compareTo(_startDate) < 0 ? 'It ends before it starts. Pick a later end date.' : null;
    }
    return _endMs(f) <= _startMs(f) ? 'It ends before it starts. Pick a later end time.' : null;
  }

  String? _repeatError() {
    final until = _repeat?.until;
    if (_custom == null && until != null && until.compareTo(_startDate) < 0) {
      return 'The repeat ends before the first day. Pick a later date.';
    }
    return null;
  }

  String? get _titleError => _triedSave && _title.text.trim().isEmpty ? 'Add a title.' : null;

  // ------------------------------------------------------------------ changes

  void _setStart({String? date, int? minutes}) {
    final f = DenScope.read(context).formats;
    setState(() {
      final oldStart = _startDate;
      if (_allDay) {
        final days = math.max(0, f.daysFrom(_startDate, _endDate));
        _startDate = date ?? _startDate;
        _endDate = f.addDays(_startDate, days);
      } else {
        final length = math.max(0, _endMs(f) - _startMs(f));
        _startDate = date ?? _startDate;
        _startMin = minutes ?? _startMin;
        final end = _startMs(f) + length;
        _endDate = f.localDate(end);
        _endMin = f.minuteOfDay(end);
      }
      if (_startDate != oldStart) _followStart(oldStart, f);
    });
  }

  /// Keeps a rule that was about the old start day about the new one: "every Friday" follows a
  /// move to Saturday, "on the 16th" follows a move to the 20th.
  void _followStart(String oldStart, Formats f) {
    final rule = _repeat;
    if (rule == null) return;
    final was = f.dateTime(oldStart);
    final now = f.dateTime(_startDate);
    switch (rule.frequency) {
      case RepeatFrequency.weekly:
        if (rule.weekdays.length == 1 && rule.weekdays.single == was.weekday % 7) {
          _repeat = rule.copyWith(weekdays: {now.weekday % 7});
        }
      case RepeatFrequency.monthly:
        if (rule.monthlyBy == MonthlyBy.day && rule.monthDay == was.day) {
          _repeat = rule.copyWith(monthDay: now.day);
        } else if (rule.monthlyBy == MonthlyBy.weekday &&
            rule.ordinalWeekday == was.weekday % 7 &&
            ordinalFor(oldStart, f).contains(rule.ordinal)) {
          final places = ordinalFor(_startDate, f);
          _repeat = rule.copyWith(
            ordinal: rule.ordinal == -1 && places.contains(-1) ? -1 : places.first,
            ordinalWeekday: now.weekday % 7,
          );
        }
      case RepeatFrequency.daily:
      case RepeatFrequency.yearly:
        break;
    }
  }

  Future<void> _pickDate({required bool start}) async {
    final f = DenScope.read(context).formats;
    final current = f.dateTime(start ? _startDate : _endDate);
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(current.year, current.month, current.day),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: start ? 'Starts' : 'Ends',
    );
    if (picked == null || !mounted) return;
    final iso =
        '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    if (start) {
      _setStart(date: iso);
    } else {
      setState(() => _endDate = iso);
    }
  }

  Future<void> _pickTime({required bool start}) async {
    final minutes = start ? _startMin : _endMin;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
      helpText: start ? 'Starts' : 'Ends',
    );
    if (picked == null || !mounted) return;
    final value = picked.hour * 60 + picked.minute;
    if (start) {
      _setStart(minutes: value);
    } else {
      setState(() => _endMin = value);
    }
  }

  // ------------------------------------------------------------------ save

  Future<void> _save() async {
    final app = DenScope.read(context);
    final den = app.den;
    final f = app.formats;
    setState(() => _triedSave = true);
    if (_titleError != null || _timeError(f) != null || _repeatError() != null || _saving) return;

    final title = _title.text.trim();
    final start = _startMs(f);
    final end = _endMs(f);
    final rrule = _rrule(f);

    if (_isNew) {
      setState(() => _saving = true);
      final error = await tryWrite(
        () => den.addEvent(
          title: title,
          start: start,
          end: end,
          allDay: _allDay,
          tz: den.family?.timezone,
          rrule: rrule,
          assignees: _assignees,
          category: _category,
          location: _location.text.trim(),
          notes: _notes.text.trim(),
          reminders: _reminders,
          rides: _rides,
          countdown: _countdown,
          audience: _audience,
        ),
      );
      if (!mounted) return;
      setState(() => _saving = false);
      if (error != null) {
        showNote(context, error);
        return;
      }
      _initialSignature = _signature();
      closeEditor(context, EditOutcome.saved);
      return;
    }

    final event = _event!;
    final occ = _occ!;
    final patch = <String, Object?>{
      if (title != occ.title) 'title': title,
      if (_location.text.trim() != occ.location) 'location': _location.text.trim(),
      if (_notes.text.trim() != occ.notes) 'notes': _notes.text.trim(),
      if (_allDay != occ.allDay) 'allDay': _allDay,
      if (start != occ.start) 'start': start,
      if (end != occ.end) 'end': end,
      if (rrule != event.rrule) 'rrule': rrule,
      if (!_sameList(_assignees, occ.assignees)) 'assignees': _assignees,
      if (_category != event.category) 'category': _category,
      if (!_sameList(_reminders, [...occ.reminders]..sort())) 'reminders': _reminders,
      if (!_sameRides(_rides, occ.rides))
        'rides': [
          for (final r in _rides) {'leg': r.leg, 'driver': r.driver},
        ],
      if (_countdown != event.countdown) 'countdown': _countdown,
      if (_audience != event.audience) 'audience': _audience.name,
    };
    if (patch.isEmpty) {
      closeEditor(context, EditOutcome.saved);
      return;
    }

    // Who can see it belongs to the whole event, so a change to it reaches every occurrence.
    var scope = EditScope.all;
    if (event.rrule != null && !patch.containsKey('audience')) {
      final chosen = await askEditScope(
        context,
        title: 'Change $title',
        allowOne: patch.keys.every(_perOccurrence.contains),
      );
      if (chosen == null || !mounted) return;
      scope = chosen;
    }
    setState(() => _saving = true);
    final error = await tryWrite(
      () => den.updateEvent(
        event.id,
        patch,
        scope: scope,
        // One and following address the occurrence by its place in the series; a change to all
        // events moves the series by however far this occurrence moved.
        occurrence: event.rrule == null ? null : (scope == EditScope.all ? occ.start : occ.seriesStart),
      ),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) {
      showNote(context, error);
      return;
    }
    _initialSignature = _signature();
    final moved = patch.containsKey('start') || scope == EditScope.following || patch.containsKey('rrule');
    closeEditor(context, moved ? EditOutcome.moved : EditOutcome.saved);
  }

  /// Fields one occurrence can change on its own and show as changed. (The engine also lets one
  /// occurrence change its category, but an occurrence doesn't report it back yet.)
  static const _perOccurrence = {
    'title',
    'notes',
    'location',
    'start',
    'end',
    'allDay',
    'assignees',
    'reminders',
    'rides',
  };

  static InputBorder _errorBorder(DenColors c) => OutlineInputBorder(
    borderRadius: const BorderRadius.all(Radius.circular(Radii.control)),
    borderSide: BorderSide(color: c.bad, width: 2),
  );

  static bool _sameList<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameRides(List<Ride> a, List<Ride> b) =>
      _sameList(a.map((r) => '${r.leg}:${r.driver}').toList(), b.map((r) => '${r.leg}:${r.driver}').toList());

  Future<bool> _confirmDiscard() async {
    final title = _title.text.trim();
    final c = context.colors;
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          _isNew ? 'Discard this new event?' : 'Discard your changes to ${title.isEmpty ? 'this event' : title}?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Keep editing')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: c.bad),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(_isNew ? 'Discard event' : 'Discard changes'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;

    if (!app.allows(DenAction.editEvents)) {
      return _Blocked(
        message: _isNew
            ? 'Adding events needs calendar access. A parent can turn it on for you in Family and devices.'
            : 'Changing events needs calendar access. A parent can turn it on for you in Family and devices.',
      );
    }
    if (!_isNew && _event == null) {
      return const _Blocked(message: 'This event was deleted, or it isn’t shared with this device.');
    }
    if (_event?.source.readOnly ?? false) {
      final label = _event!.source.label;
      return _Blocked(
        message: label == null || label.isEmpty
            ? 'This event comes from another calendar. Change it there.'
            : 'This event comes from $label’s calendar. Change it there.',
      );
    }

    final f = app.formats;
    final timeError = _timeError(f);
    final wide = MediaQuery.sizeOf(context).width >= panelBreakpoint;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) {
          _initialSignature = _signature();
          closeEditor(context, null);
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Sp.xs, Sp.s, Sp.l, Sp.s),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: wide ? 'Close' : 'Back',
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: Icon(wide ? PhosphorIconsRegular.x : PhosphorIconsRegular.arrowLeft),
                    ),
                    const SizedBox(width: Sp.xs),
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          _isNew ? 'New event' : 'Edit event',
                          style: context.type.title(c.ink),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    FilledButton(onPressed: _saving ? null : _save, child: Text(_isNew ? 'Add event' : 'Save changes')),
                  ],
                ),
              ),
              Divider(height: 1, color: c.rule),
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(Sp.l, Sp.l, Sp.l, Sp.xxxl),
                      children: [
                        ..._whatAndWhen(context, f, timeError),
                        const _Gap(),
                        ..._whoAndWhere(context),
                        const _Gap(),
                        ..._extras(context, f),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _whatAndWhen(BuildContext context, Formats f, String? timeError) {
    final c = context.colors;
    final today = context.app.today;
    Widget when(String label, {required bool start}) {
      final date = start ? _startDate : _endDate;
      final minutes = start ? _startMin : _endMin;
      final error = !start && timeError != null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FieldLabel(label),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: PickerButton(
                  icon: PhosphorIconsRegular.calendarBlank,
                  label: f.shortWithYear(date, relativeTo: today),
                  semanticsLabel: '$label on ${f.long(date)}',
                  error: error && _allDay,
                  onTap: () => _pickDate(start: start),
                ),
              ),
              if (!_allDay) ...[
                const SizedBox(width: Sp.s),
                Expanded(
                  flex: 2,
                  child: PickerButton(
                    icon: PhosphorIconsRegular.clock,
                    label: f.clock(minutes),
                    semanticsLabel: '$label at ${f.clock(minutes)}',
                    error: error,
                    onTap: () => _pickTime(start: start),
                  ),
                ),
              ],
            ],
          ),
        ],
      );
    }

    return [
      const FieldLabel('Title'),
      TextField(
        controller: _title,
        autofocus: _isNew,
        textCapitalization: TextCapitalization.sentences,
        style: context.type.body(c.ink),
        decoration: InputDecoration(
          hintText: 'What’s happening',
          enabledBorder: _titleError == null ? null : _errorBorder(c),
          focusedBorder: _titleError == null ? null : _errorBorder(c),
        ),
        onChanged: (_) => setState(() {}),
      ),
      if (_titleError != null) ...[const SizedBox(height: Sp.s), FieldError(_titleError!)],
      const SizedBox(height: Sp.l),
      _SwitchRow(
        label: 'All day',
        value: _allDay,
        onChanged: (v) => setState(() {
          _allDay = v;
          if (_endDate.compareTo(_startDate) < 0) _endDate = _startDate;
        }),
      ),
      const SizedBox(height: Sp.m),
      when('Starts', start: true),
      const SizedBox(height: Sp.m),
      when('Ends', start: false),
      if (timeError != null) ...[const SizedBox(height: Sp.s), FieldError(timeError)],
      const SizedBox(height: Sp.xl),
      RecurrenceEditor(
        value: _repeat,
        custom: _custom,
        startDate: _startDate,
        error: _repeatError(),
        onChanged: (rule) => setState(() => _repeat = rule),
        onReplaceCustom: () => setState(() {
          _custom = null;
          _repeat = null;
          _replacedCustom = true;
        }),
      ),
    ];
  }

  List<Widget> _whoAndWhere(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final categories = app.den.categories;
    return [
      const FieldLabel('Who'),
      Wrap(
        spacing: Sp.s,
        runSpacing: Sp.s,
        children: [
          _EveryoneChip(selected: _assignees.isEmpty, onTap: () => setState(() => _assignees = [])),
          for (final m in app.den.members)
            PersonChip(
              member: m,
              selected: _assignees.contains(m.id),
              onTap: () => setState(() {
                final chosen = {..._assignees};
                if (!chosen.remove(m.id)) chosen.add(m.id);
                _assignees = [
                  for (final member in app.den.members)
                    if (chosen.contains(member.id)) member.id,
                ];
              }),
            ),
        ],
      ),
      if (categories.isNotEmpty) ...[
        const SizedBox(height: Sp.xl),
        const FieldLabel('Category'),
        Wrap(
          spacing: Sp.s,
          runSpacing: Sp.s,
          children: [
            ChoiceTile(label: 'None', selected: _category == null, onTap: () => setState(() => _category = null)),
            for (final cat in categories)
              ChoiceTile(
                label: cat.name,
                icon: categoryIcon(cat.icon),
                selected: _category == cat.id,
                onTap: () => setState(() => _category = cat.id),
              ),
          ],
        ),
      ],
      const SizedBox(height: Sp.xl),
      const FieldLabel('Where'),
      TextField(
        controller: _location,
        textCapitalization: TextCapitalization.words,
        style: context.type.body(c.ink),
        decoration: const InputDecoration(hintText: 'Add a place'),
        onChanged: (_) => setState(() {}),
      ),
    ];
  }

  List<Widget> _extras(BuildContext context, Formats f) {
    final app = context.app;
    final c = context.colors;
    final me = app.me;
    final audiences = <Audience, String>{
      Audience.everyone: 'Everyone',
      if (me?.isParent ?? false) Audience.parents: 'Parents',
      Audience.justMe: 'Just me',
    };

    return [
      const FieldLabel(
        'Rides',
        info: InfoTip(
          'Add drop-off or pick-up when someone needs a ride. A ride with no driver shows on Today until someone takes it.',
        ),
      ),
      for (final ride in _rides) ...[_rideRow(context, ride), const SizedBox(height: Sp.s)],
      Wrap(
        spacing: Sp.s,
        runSpacing: Sp.s,
        children: [
          if (!_rides.any((r) => r.leg == 'to'))
            OutlinedButton.icon(
              onPressed: () => setState(() => _rides = [const Ride('to', null), ..._rides]),
              icon: const Icon(PhosphorIconsRegular.plus, size: 18),
              label: const Text('Add drop-off'),
            ),
          if (!_rides.any((r) => r.leg == 'from'))
            OutlinedButton.icon(
              onPressed: () => setState(() => _rides = [..._rides, const Ride('from', null)]),
              icon: const Icon(PhosphorIconsRegular.plus, size: 18),
              label: const Text('Add pick-up'),
            ),
        ],
      ),
      const SizedBox(height: Sp.xl),
      const FieldLabel('Reminders'),
      Wrap(
        spacing: Sp.s,
        runSpacing: Sp.s,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final minutes in _reminders)
            RemovableTile(
              label: reminderWords(minutes),
              removeLabel: 'Remove reminder ${reminderWords(minutes)}',
              onRemove: () => setState(() => _reminders = [..._reminders]..remove(minutes)),
            ),
          Builder(
            builder: (buttonContext) => OutlinedButton.icon(
              onPressed: () => _addReminder(buttonContext),
              icon: const Icon(PhosphorIconsRegular.bellSimple, size: 18),
              label: const Text('Add reminder'),
            ),
          ),
        ],
      ),
      const SizedBox(height: Sp.xl),
      _SwitchRow(
        label: 'Countdown',
        info: 'Shows the days left on Today and on the wall.',
        value: _countdown,
        onChanged: (v) => setState(() => _countdown = v),
      ),
      const SizedBox(height: Sp.xl),
      const FieldLabel('Who can see it'),
      if (_lockedAudience(app))
        Text(audienceWords(app, _event!.space), style: context.type.body(c.ink))
      else
        Align(
          alignment: Alignment.centerLeft,
          child: Segmented<Audience>(
            options: audiences,
            value: _audience,
            onChanged: (v) => setState(() => _audience = v),
          ),
        ),
      const SizedBox(height: Sp.xl),
      const FieldLabel('Notes'),
      TextField(
        controller: _notes,
        minLines: 3,
        maxLines: 8,
        textCapitalization: TextCapitalization.sentences,
        style: context.type.body(c.ink),
        decoration: const InputDecoration(hintText: 'Add notes'),
        onChanged: (_) => setState(() {}),
      ),
    ];
  }

  /// Someone else's private event stays theirs: a parent can edit it, but "Just me" would mean
  /// the parent, so who can see it isn't offered.
  bool _lockedAudience(AppState app) {
    final event = _event;
    if (event == null) return false;
    final owner = Space.memberOf(event.space);
    return owner != null && owner != app.me?.id;
  }

  Widget _rideRow(BuildContext context, Ride ride) {
    final app = context.app;
    final c = context.colors;
    final driver = app.memberById(ride.driver);
    return Row(
      children: [
        SizedBox(
          width: 72 * context.type.scale,
          child: Text(legWords(ride.leg), style: context.type.body(c.ink)),
        ),
        Expanded(
          child: Builder(
            builder: (buttonContext) => PickerButton(
              icon: PhosphorIconsRegular.steeringWheel,
              label: driver == null ? 'Nobody yet' : driver.name,
              semanticsLabel: '${legWords(ride.leg)} driver: ${driver?.name ?? 'nobody yet'}',
              onTap: () => _pickDriver(buttonContext, ride),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Remove ${legWords(ride.leg).toLowerCase()}',
          onPressed: () => setState(() => _rides = [..._rides]..remove(ride)),
          icon: Icon(PhosphorIconsRegular.x, size: 18, color: c.ink2),
        ),
      ],
    );
  }

  Future<void> _pickDriver(BuildContext buttonContext, Ride ride) async {
    final app = DenScope.read(context);
    final picked = await _menu<String>(buttonContext, [
      ('', 'Nobody yet'),
      for (final m in possibleDrivers(app)) (m.id, m.name),
    ]);
    if (picked == null || !mounted) return;
    setState(() {
      _rides = [
        for (final r in _rides)
          if (identical(r, ride)) Ride(r.leg, picked.isEmpty ? null : picked) else r,
      ];
    });
  }

  Future<void> _addReminder(BuildContext buttonContext) async {
    final picked = await _menu<int>(buttonContext, [
      for (final m in reminderPresets)
        if (!_reminders.contains(m)) (m, reminderWords(m)),
      (-1, 'Custom…'),
    ]);
    if (picked == null || !mounted) return;
    final minutes = picked == -1 ? await _customReminder() : picked;
    if (minutes == null || !mounted || _reminders.contains(minutes)) return;
    setState(() => _reminders = [..._reminders, minutes]..sort());
  }

  Future<int?> _customReminder() {
    return showDialog<int>(context: context, builder: (_) => const _CustomReminderDialog());
  }

  Future<T?> _menu<T>(BuildContext anchor, List<(T, String)> items) {
    final box = anchor.findRenderObject()! as RenderBox;
    final overlay = Overlay.of(anchor).context.findRenderObject()! as RenderBox;
    final topLeft = box.localToGlobal(Offset(0, box.size.height), ancestor: overlay);
    final position = RelativeRect.fromRect(topLeft & Size(box.size.width, 0), Offset.zero & overlay.size);
    return showMenu<T>(
      context: anchor,
      position: position,
      items: [for (final (value, label) in items) PopupMenuItem<T>(value: value, child: Text(label))],
    );
  }
}

/// Closes the editor with [outcome] for the page below.
void closeEditor(BuildContext context, EditOutcome? outcome) {
  if (context.canPop()) {
    context.pop(outcome);
  } else {
    context.go('/calendar');
  }
}

class _Gap extends StatelessWidget {
  const _Gap();
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Sp.xl),
    child: Divider(height: 1, color: context.colors.rule),
  );
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.label, required this.value, required this.onChanged, this.info});
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? info;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MergeSemantics(
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.control),
        onTap: () => onChanged(!value),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Targets.adult),
          child: Row(
            children: [
              Text(label, style: context.type.body(c.ink)),
              if (info != null) InfoTip(info!),
              const Spacer(),
              Switch(value: value, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}

class _EveryoneChip extends StatelessWidget {
  const _EveryoneChip({required this.selected, required this.onTap});
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? c.ink : c.well,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 14, 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(color: selected ? c.onInk : c.paper, shape: BoxShape.circle),
                    alignment: Alignment.center,
                    child: Icon(PhosphorIconsFill.usersThree, size: 18, color: selected ? c.ink : c.ink2),
                  ),
                  const SizedBox(width: Sp.s),
                  Text('Everyone', style: context.type.body(selected ? c.onInk : c.ink)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CustomReminderDialog extends StatefulWidget {
  const _CustomReminderDialog();
  @override
  State<_CustomReminderDialog> createState() => _CustomReminderDialogState();
}

class _CustomReminderDialogState extends State<_CustomReminderDialog> {
  final _amount = TextEditingController(text: '45');
  int _unit = 1;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _add() {
    final n = int.tryParse(_amount.text.trim());
    if (n == null || n < 0 || n > 999) {
      setState(() => _error = 'Enter a number from 0 to 999.');
      return;
    }
    Navigator.of(context).pop(n * _unit);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AlertDialog(
      title: const Text('Custom reminder'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 80,
                child: TextField(
                  controller: _amount,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  style: context.type.body(c.ink),
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: Sp.m),
              Text('before', style: context.type.body(c.ink)),
            ],
          ),
          const SizedBox(height: Sp.m),
          Segmented<int>(
            options: const {1: 'Minutes', 60: 'Hours', 1440: 'Days'},
            value: _unit,
            onChanged: (v) => setState(() => _unit = v),
          ),
          if (_error != null) ...[const SizedBox(height: Sp.s), FieldError(_error!)],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _add, child: const Text('Add reminder')),
      ],
    );
  }
}

/// The editor when it can't edit: no access, an imported event, or a missing one.
class _Blocked extends StatelessWidget {
  const _Blocked({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Sp.xs, Sp.s, Sp.l, Sp.s),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Back',
                    onPressed: () => closeEditor(context, null),
                    icon: const Icon(PhosphorIconsRegular.arrowLeft),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Sp.l),
              child: Text(message, style: context.type.body(c.ink)),
            ),
          ],
        ),
      ),
    );
  }
}
