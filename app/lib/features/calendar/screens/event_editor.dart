import 'dart:math' as math;

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../words/block_words.dart';
import '../state/calendar_models.dart';
import '../../linked/state/link_actions.dart';
import '../state/event_actions.dart';
import '../words/calendar_time.dart';
import '../widgets/calendar_parts.dart';
import '../widgets/field_editors.dart';

/// Adds an event, in a sheet: the title, when, who and how often, which is all most events
/// need; where, rides, reminders, who can see it and notes wait under "More options". It takes
/// its day, time and person from where the person tapped (`?date=`, `?time=`, `?who=`). "Add
/// event" sits at the bottom, in reach of the thumb. Changing an event happens on its own page,
/// in place.
class EventEditorScreen extends StatefulWidget {
  const EventEditorScreen({super.key, this.date, this.time, this.who, this.link, this.moreOptions = false});

  /// Local date `YYYY-MM-DD`, time `HH:mm`, and a member id.
  final String? date;
  final String? time;
  final String? who;

  /// A linked family whose calendar the new event goes on (they let this family change it).
  final String? link;

  /// Opens with More options showing (screenshots).
  final bool moreOptions;

  @override
  State<EventEditorScreen> createState() => _EventEditorScreenState();
}

class _EventEditorScreenState extends State<EventEditorScreen> {
  final _title = TextEditingController();
  final _place = TextEditingController();
  final _notes = TextEditingController();

  bool _loaded = false;
  late int _start;
  late int _end;
  bool _allDay = false;
  List<String> _who = const [];
  String? _rrule;
  List<int> _reminders = const [];
  List<Ride> _rides = const [];
  Audience _audience = Audience.everyone;
  late bool _more = widget.moreOptions;

  bool _tried = false;
  bool _saving = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final app = DenScope.read(context);
    final f = app.formats;
    final today = app.today;
    final date = widget.date != null && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(widget.date!) ? widget.date! : today;
    var minute = f.parseHhmm(widget.time);
    if (minute == null) {
      if (date == today) {
        final now = f.minuteOfDay(DateTime.now().millisecondsSinceEpoch);
        minute = math.min(((now ~/ 30) + 1) * 30, 23 * 60);
      } else {
        minute = 9 * 60;
      }
    }
    _start = f.msAt(date, minute);
    _end = _start + 3600000;
    if (widget.who != null && app.den.member(widget.who!) != null) _who = [widget.who!];
  }

  @override
  void dispose() {
    _title.dispose();
    _place.dispose();
    _notes.dispose();
    super.dispose();
  }

  String? get _titleError => _tried && _title.text.trim().isEmpty ? 'Add a title, like “Soccer practice”.' : null;

  Future<void> _add() async {
    setState(() => _tried = true);
    if (_titleError != null || _saving) return;
    final app = DenScope.read(context);
    final events = EventActions(app.actions);
    setState(() => _saving = true);
    final link = widget.link;
    final error = await tryWrite(
      () => link != null
          ? LinkActions(app.den).addEvent(
              link: link,
              title: _title.text.trim(),
              start: _start,
              end: _end,
              allDay: _allDay,
              tz: app.den.family?.timezone,
              rrule: _rrule,
              location: _place.text.trim(),
              notes: _notes.text.trim(),
              reminders: _reminders,
            )
          : events.create({
        'title': _title.text.trim(),
        'start': _start,
        'end': _end,
        'allDay': _allDay,
        'tz': app.den.family?.timezone,
        'rrule': _rrule,
        'assignees': _who,
        'location': _place.text.trim(),
        'notes': _notes.text.trim(),
        'reminders': _reminders,
        'rides': _rides,
        'audience': _audience,
      }),
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = error;
    });
    if (error == null) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final f = app.formats;
    final c = context.colors;
    final t = context.text;
    final canAdd = app.allows(DenAction.editEvents);
    final me = app.me;
    final date = f.localDate(_start);

    Widget rule() => const RowRule(indent: 36);
    Widget row(IconData icon, String label, Widget child) => Padding(
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
                Text(label, style: t.rowTitle(c.ink)),
                const SizedBox(height: Sp.s + 2),
                child,
              ],
            ),
          ),
        ],
      ),
    );

    final more = <Widget>[
      row(
        PhosphorIconsBold.mapPin,
        'Where',
        TextField(
          controller: _place,
          textCapitalization: TextCapitalization.words,
          style: t.body(c.ink),
          decoration: InputDecoration(hintText: 'Add a place', fillColor: c.bg),
        ),
      ),
      if (widget.link == null) ...[
      rule(),
      row(
        PhosphorIconsBold.car,
        'Rides',
        Wrap(
          spacing: Sp.s,
          runSpacing: Sp.xs,
          children: [
            for (final (leg, label) in [('to', 'Someone drives there'), ('from', 'Someone picks up')])
              ChoiceChipPill(
                label: label,
                selected: _rides.any((r) => r.leg == leg),
                onTap: () => setState(() {
                  _rides =
                      _rides.any((r) => r.leg == leg)
                            ? [
                                for (final r in _rides)
                                  if (r.leg != leg) r,
                              ]
                            : [..._rides, Ride(leg, null)]
                        ..sort((a, b) => a.leg == 'to' ? -1 : (b.leg == 'to' ? 1 : 0));
                }),
              ),
          ],
        ),
      ),
      ],
      rule(),
      row(
        PhosphorIconsBold.bellSimple,
        'Reminder',
        ReminderChips(value: _reminders, onChanged: (v) => setState(() => _reminders = v)),
      ),
      if (widget.link == null) ...[
      rule(),
      row(
        PhosphorIconsBold.eye,
        'Who can see it',
        Wrap(
          spacing: Sp.s,
          runSpacing: Sp.xs,
          children: [
            for (final (value, label) in [
              (Audience.everyone, 'Everyone'),
              if (me?.isParent ?? false) (Audience.parents, 'Parents'),
              (Audience.justMe, 'Just me'),
            ])
              ChoiceChipPill(
                label: label,
                selected: _audience == value,
                onTap: () => setState(() => _audience = value),
              ),
          ],
        ),
      ),
      ],
      rule(),
      row(
        PhosphorIconsBold.notepad,
        'Notes',
        TextField(
          controller: _notes,
          minLines: 2,
          maxLines: 6,
          textCapitalization: TextCapitalization.sentences,
          style: t.body(c.ink),
          decoration: InputDecoration(hintText: 'Add notes', fillColor: c.bg),
        ),
      ),
    ];

    final form = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _title,
          inputFormatters: [LengthLimitingTextInputFormatter(200)],
          autofocus: canAdd,
          enabled: canAdd,
          textCapitalization: TextCapitalization.sentences,
          style: t.body(c.ink),
          onChanged: (_) {
            if (_tried) setState(() {});
          },
          // What's missing says so under the field, in red words with a red edge (the theme's
          // error style), never a box.
          decoration: InputDecoration(hintText: 'What’s happening', errorText: _titleError, errorMaxLines: 3),
        ),
        const SizedBox(height: Sp.l),
        GroupCard(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                row(
                  PhosphorIconsBold.clock,
                  'When',
                  WhenEditor(
                    start: _start,
                    end: _end,
                    allDay: _allDay,
                    onChanged: (s, e, a) => setState(() {
                      _start = s;
                      _end = e;
                      _allDay = a;
                    }),
                  ),
                ),
                if (widget.link == null) ...[
                  rule(),
                  row(
                    PhosphorIconsBold.usersThree,
                    'Who',
                    PeopleToggles(
                      people: app.den.members,
                      selected: _who,
                      onChanged: (ids) => setState(() => _who = ids),
                    ),
                  ),
                ],
                rule(),
                row(
                  PhosphorIconsBold.repeat,
                  'Repeats',
                  RepeatChips(
                    rrule: _rrule,
                    date: date,
                    seriesStart: date,
                    onChanged: (r) => setState(() => _rrule = r),
                  ),
                ),
                rule(),
                DenPressable(
                  onTap: () => setState(() => _more = !_more),
                  scale: false,
                  shape: const RoundedRectangleBorder(),
                  toggled: _more,
                  semanticLabel: 'More options',
                  child: ExcludeSemantics(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 56),
                      child: Row(
                        children: [
                          Icon(_more ? PhosphorIconsBold.caretUp : PhosphorIconsBold.caretDown, size: 22, color: c.ink),
                          const SizedBox(width: 14),
                          Expanded(child: Text('More options', style: t.body(c.ink))),
                        ],
                      ),
                    ),
                  ),
                ),
                DenReveal(
                  visible: _more,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [rule(), ...more]),
                ),
              ],
          ),
        ),
      ],
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(DenLayout.gutter + 4, 0, DenLayout.gutter, Sp.m),
          child: Row(
            children: [
              Expanded(
                child: Semantics(header: true, child: Text('New event', style: t.sheetTitle(c.ink))),
              ),
              TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Cancel')),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: DenLayout.gutter),
            child: form,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(DenLayout.gutter, Sp.m, DenLayout.gutter, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[
                ErrorState(message: _error!, actionLabel: 'Try again', onAction: _add),
                const SizedBox(height: Sp.s),
              ],
              if (!canAdd) ...[
                NoticeLine(
                  message: tidyLine('Adding events needs calendar access. A parent can turn it on for you in Family.'),
                  icon: PhosphorIconsBold.lockSimple,
                ),
                const SizedBox(height: Sp.s),
              ],
              CalendarPill(
                label: _saving ? 'Adding…' : 'Add event',
                primary: true,
                onTap: canAdd && !_saving ? _add : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
