import 'package:den_core/den_core.dart';

import '../context.dart';
import '../input.dart';
import '../recurrence.dart';
import '../resolve.dart';
import '../schema.dart';
import '../shapes.dart';
import '../spec.dart';
import '../times.dart';
import '../wire.dart';

final Map<String, Object?> _eventFields = {
  'title': S.string('What it is.', maxLength: 200),
  'start': S.time('When it starts; for all-day events, the first day.'),
  'end': S.time('When it ends (default an hour after the start); for all-day events, the last day.'),
  'all_day': S.boolean('A whole-day event.'),
  'tz': S.string('The IANA time zone its times are in (default the family\'s), such as America/Chicago.', maxLength: 64),
  'location': S.string('Where.', maxLength: 300),
  'notes': S.string('Notes.', maxLength: 5000),
  'people': S.people('Who it is for; empty means everyone.'),
  'category': S.string('A category name or id; empty for none.'),
  'repeat': S.string('An RFC 5545 RRULE without DTSTART, such as FREQ=WEEKLY;BYDAY=TU, or "none".', maxLength: 500),
  'reminders': S.array(S.integer('Minutes before.', min: 0, max: 40320), 'Reminders, in minutes before the start.', maxItems: 10),
  'rides': S.array(
    S.object({
      'leg': S.string('Driving there or picking up.', oneOf: ['to', 'from']),
      'driver': S.string('Who drives: a parent or adult, by name or member id, or "nobody" while nobody has said yes.'),
    }, required: ['leg']),
    'Rides it needs, each with its driver.',
    maxItems: 4,
  ),
  'countdown': S.boolean('Show a countdown to it.'),
};

const String _whoCanSee = '"everyone" (default), "parents", "just me", or a person\'s name for their private item.';

/// The output of an action that answers with one event.
final Map<String, Object?> eventOutput = {'event': {...eventShape, 'type': ['object', 'null']}};

/// Calendar actions: add, change and remove events.
List<ActionSpec> eventActions() => [
      ActionSpec(
        name: 'events.create',
        mcpName: 'create_event',
        title: 'Add an event',
        description: 'Adds an event to the family calendar. Says so when the time is already past, or one the clocks '
            'skip or repeat that day.',
        input: S.input({..._eventFields, 'who_can_see': S.string(_whoCanSee)}, required: ['title', 'start']),
        output: S.output(eventOutput),
        scopes: const {Scope.calendar},
        needs: const [DenAction.editEvents],
        effect: Effect.write,
        engine: const {'addEvent'},
        example: const {'title': 'Piano lesson', 'start': '2026-11-03T16:00', 'people': ['Maya'], 'repeat': 'FREQ=WEEKLY;BYDAY=TU'},
        run: _create,
      ),
      ActionSpec(
        name: 'events.update',
        mcpName: 'update_event',
        title: 'Change an event',
        description: 'Changes an event, one occurrence of a repeating event, or this and following occurrences. '
            'Fields left out stay as they are. When events share a name (a repeat split by an earlier "this and '
            'following"), the one with the occurrence named is meant.',
        input: S.input({
          'event': S.string('The event\'s title or id.'),
          'occurrence': S.time('Which occurrence of a repeating event: its start, or its date.'),
          'scope': S.string('How far the change reaches on a repeating event (default all).', oneOf: ['one', 'following', 'all']),
          ..._eventFields,
          'who_can_see': S.string('Move the whole event: "everyone", "parents" or "just me".'),
        }, required: ['event']),
        output: S.output({
          ...eventOutput,
          'ok': Out.flag('It worked.'),
          'scope': Out.str('one, following or all.'),
          'occurrence': Out.intOrNull('The occurrence changed, UTC ms.'),
        }),
        scopes: const {Scope.calendar},
        needs: const [DenAction.editEvents],
        effect: Effect.destructive,
        idempotent: true,
        confirm: Confirm.server,
        confirmWhen: _touchesSeries,
        ask: _askUpdate,
        engine: const {'updateEvent'},
        example: const {'event': 'Dentist', 'location': 'Bright Smiles Dental, Suite 2'},
        run: _update,
      ),
      ActionSpec(
        name: 'events.delete',
        mcpName: 'delete_event',
        title: 'Remove an event',
        description: 'Removes an event, one occurrence of a repeating event, or this and following occurrences.',
        input: S.input({
          'event': S.string('The event\'s title or id.'),
          'occurrence': S.time('Which occurrence of a repeating event: its start, or its date.'),
          'scope': S.string('How far it reaches on a repeating event (default all).', oneOf: ['one', 'following', 'all']),
        }, required: ['event']),
        output: S.output({
          'ok': Out.flag('It worked.'),
          'event_id': Out.str('The event.'),
          'scope': Out.str('one, following or all.'),
          'occurrence': Out.intOrNull('The occurrence removed, UTC ms.'),
        }),
        scopes: const {Scope.calendar},
        needs: const [DenAction.editEvents],
        effect: Effect.destructive,
        idempotent: true,
        confirm: Confirm.server,
        confirmWhen: _touchesSeries,
        ask: _askDelete,
        engine: const {'deleteEvent'},
        example: const {'event': 'Dinner at Grandma\'s'},
        run: _delete,
      ),
      ActionSpec(
        name: 'events.ride',
        mcpName: 'set_ride',
        title: 'Drive or pick someone up',
        description: 'Says who drives to an event or picks up from it, for one occurrence ("I\'ll drive Leo to '
            'soccer Tuesday"), or that nobody does yet. Only a parent or an adult drives; Den says so when the '
            'driver then has two rides at once.',
        input: S.input({
          'event': S.string('The event\'s title or id.'),
          'occurrence': S.time('Which occurrence of a repeating event: its start, or its date (default the next one).'),
          'leg': S.string('Driving there (to) or picking up (from).', oneOf: ['to', 'from']),
          'driver': S.person('Who drives (a parent or adult), or "nobody".'),
        }, required: ['event', 'leg', 'driver']),
        output: S.output({'occurrence': occurrenceShape}),
        scopes: const {Scope.calendar},
        needs: const [DenAction.editEvents],
        effect: Effect.write,
        idempotent: true,
        engine: const {'claimRide'},
        example: const {'event': 'Swim lesson', 'leg': 'to', 'driver': 'Alex'},
        run: _ride,
      ),
    ];

/// The event a call names, told apart by the occurrence it names when several share a name.
Event _named(ActionContext c, ActionInput a) => c.event(a.str('event', required: true)!, at: a.raw['occurrence']);

String _askUpdate(ActionContext c, ActionInput a) {
  final e = _named(c, a);
  return a.str('scope') == 'following'
      ? 'Change this and every later occurrence of ${e.title}?'
      : 'Change every occurrence of ${e.title}?';
}

String _askDelete(ActionContext c, ActionInput a) {
  final e = _named(c, a);
  return a.str('scope') == 'following'
      ? 'Remove this and every later occurrence of ${e.title}?'
      : 'Remove ${e.title} and every one of its occurrences?';
}

/// The occurrence of [e] whose original start is [key].
Occurrence? _occurrence(ActionContext c, Event e, int key) => c.den
    .occurrences(key - 2 * Duration.millisecondsPerDay, key + 2 * Duration.millisecondsPerDay)
    .where((o) => o.event.id == e.id && Wire.occurrenceKey(o) == key)
    .firstOrNull;

/// Refuses a [driver] who may not drive (a kid or a guest, as the app offers rides only to
/// parents and adults); a note when they'd be driving only themselves ([going] is who it's for).
String? driverNote(ActionContext c, String driver, List<String> going) {
  final m = c.den.member(driver);
  if (m == null) return null;
  if (!canDrive(m)) {
    final drivers = [for (final x in c.den.members) if (canDrive(x)) x.name];
    throw ActionError('${m.name} can\'t drive: in Den, parents and adults drive. Name ${joinNames(drivers)}, or "nobody".',
        field: 'driver');
  }
  if (going.length == 1 && going.single == driver) {
    return '${m.name} is the only one going, so ${m.name} is driving themselves.';
  }
  return null;
}

Future<ActionResult> _ride(ActionContext c, ActionInput a) async {
  final e = editableEvent(c, a, 'change');
  final int occurrence;
  if (e.rrule == null) {
    occurrence = e.start;
  } else if (a.has('occurrence')) {
    occurrence = c.occurrenceOf(e, a.raw['occurrence']);
  } else {
    final now = c.den.now();
    final next = c
        .occurrences(now - 6 * Duration.millisecondsPerHour, now + 400 * Duration.millisecondsPerDay)
        .where((o) => o.event.id == e.id)
        .firstOrNull;
    if (next == null) throw ActionError('${e.title} doesn\'t happen again; say which occurrence.', field: 'occurrence');
    occurrence = Wire.occurrenceKey(next);
  }
  final leg = a.str('leg', required: true)!;
  final name = a.str('driver', required: true)!;
  final nobody = const {'nobody', 'no one', 'none', 'noone'}.contains(name.trim().toLowerCase());
  final driver = nobody ? null : c.people.one(name);
  final note = driver == null ? null : driverNote(c, driver, _occurrence(c, e, occurrence)?.assignees ?? e.assignees);
  await c.den.claimRide(e.id, occurrence: occurrence, leg: leg, driver: driver);
  final o = _occurrence(c, e, occurrence)!;
  final who = o.assignees.isEmpty ? '' : ' ${c.people.names(o.assignees)}';
  final what = leg == 'to' ? 'driving$who to ${o.title}' : 'picking up$who from ${o.title}';
  return ActionResult(
    driver == null ? 'Nobody is $what on ${c.when(o)} yet.' : '${c.people.name(driver)} is $what on ${c.when(o)}.',
    {
      'occurrence': c.wire.occurrence(o),
      if (note != null) 'warnings': [note],
    },
  );
}

/// The audience a "who can see it" input moves a record to: everyone, parents, or the caller
/// alone. The engine doesn't move things into someone else's private space.
String audienceFor(ActionContext c, Object? value) {
  final space = c.space(value);
  if (space == Space.family) return Audience.everyone.name;
  if (space == Space.parents) return Audience.parents.name;
  if (c.member != null && space == Space.member(c.member!)) return Audience.justMe.name;
  throw ActionError('Den can move it to everyone, parents, or just you; not into someone else\'s own space.', field: 'who_can_see');
}

/// Whether an update or removal reaches more than one occurrence of a repeating event.
bool _touchesSeries(ActionContext c, ActionInput a) {
  final e = _named(c, a);
  return e.rrule != null && a.str('scope') != 'one';
}

/// A start or end input in [zone]. A wall-clock time the clocks skip or repeat that day is
/// added to [notes].
int _at(ActionContext c, ActionInput a, String key,
    {required bool allDay, required String zone, bool end = false, List<String>? notes}) {
  if (allDay) {
    final date = c.date(a.raw[key], key);
    return midnightIn(zone, end ? addDays(date, 1) : date);
  }
  return c.instant(a.raw[key], key, zoneName: zone, note: notes?.add);
}

String? _rule(ActionInput a) {
  final rule = a.str('repeat')?.trim();
  if (rule == null) return null;
  if (rule.isEmpty || rule.toLowerCase() == 'none') return '';
  final text = rule.toUpperCase().startsWith('RRULE:') ? rule.substring(6) : rule;
  if (!RecurrenceRule.isValid(text)) {
    throw ActionError('"$rule" isn\'t a repeat rule Den understands, such as FREQ=WEEKLY;BYDAY=TU.', field: 'repeat');
  }
  return text;
}

String? _zone(ActionInput a) {
  final tz = a.str('tz')?.trim();
  if (tz == null || tz.isEmpty) return null;
  if (!isZone(tz)) throw ActionError('Den doesn\'t know the time zone "$tz".', field: 'tz');
  return tz;
}

/// The rides given, each driver one who may drive; notes about them go to [notes].
List<Ride>? _rides(ActionContext c, ActionInput a, List<String> going, List<String> notes) {
  final raw = a.objects('rides');
  if (raw == null) return null;
  final out = <Ride>[];
  for (final r in raw) {
    final name = '${r['driver'] ?? ''}'.trim();
    String? driver;
    if (!const {'', 'nobody', 'none', 'no one'}.contains(name.toLowerCase())) {
      driver = c.people.one(name);
      final note = driverNote(c, driver, going);
      if (note != null && !notes.contains(note)) notes.add(note);
    }
    out.add(Ride(r['leg']! as String, driver));
  }
  return out;
}

/// One line about an event: "Dentist, Tue, Oct 20, 3:00 PM–4:00 PM, for Zoe"; a repeating one
/// by its next occurrence; with [at] (an original start), that one occurrence as it is now.
String describeEvent(ActionContext c, Event e, {int? at}) {
  Occurrence? first;
  var next = false;
  if (at != null) {
    first = _occurrence(c, e, at);
  } else {
    if (e.rrule != null) {
      final now = c.den.now();
      first = c
          .occurrences(now - 6 * Duration.millisecondsPerHour, now + 400 * Duration.millisecondsPerDay)
          .where((o) => o.event.id == e.id)
          .firstOrNull;
      next = first != null && first.seriesStart != e.start;
    }
    first ??= c.occurrences(e.start, e.end > e.start ? e.end : e.start + 1).where((o) => o.event.id == e.id).firstOrNull;
  }
  final when = first == null ? c.day(dateIn(c.zone, at ?? e.start)) : c.when(first);
  final assignees = first?.assignees ?? e.assignees;
  final who = assignees.isEmpty ? 'everyone' : c.people.names(assignees);
  final seen = c.audienceText(e.space);
  return '${first?.title ?? e.title}, ${next ? 'next ' : ''}$when, for $who${seen.isEmpty ? '' : ' ($seen)'}'
      '${e.rrule == null || at != null ? '' : ', repeating ${e.rrule}'}';
}

/// A note for an event that is already over when it's added.
List<String> _pastNotes(ActionContext c, int start, int end) {
  if (end > c.den.now()) return const [];
  return ['That is already over (${c.day(dateIn(c.zone, start))}); check the date if that isn\'t what was meant.'];
}

Future<ActionResult> _create(ActionContext c, ActionInput a) async {
  final title = a.str('title', required: true)!.trim();
  final allDay = a.flag('all_day') ?? false;
  final tz = _zone(a);
  final zone = tz ?? c.zone;
  final notes = <String>[];
  final start = _at(c, a, 'start', allDay: allDay, zone: zone, notes: notes);
  final end = a.has('end')
      ? _at(c, a, 'end', allDay: allDay, zone: zone, end: true, notes: notes)
      : allDay
          ? midnightIn(zone, addDays(dateIn(zone, start), 1))
          : start + Duration.millisecondsPerHour;
  if (end < start) throw ActionError('The end is before the start.', field: 'end');
  final rule = _rule(a);
  final category = a.str('category')?.trim();
  final people = c.people.many(a.raw['people'], 'people');
  final id = await c.den.addEvent(
    title: title,
    start: start,
    end: end,
    allDay: allDay,
    tz: tz,
    rrule: rule == null || rule.isEmpty ? null : rule,
    assignees: people,
    category: category == null || category.isEmpty ? null : c.category(category),
    location: a.str('location') ?? '',
    notes: a.str('notes') ?? '',
    reminders: a.ints('reminders') ?? const [],
    rides: _rides(c, a, people, notes) ?? const [],
    countdown: a.flag('countdown') ?? false,
    space: c.space(a.raw['who_can_see']),
  );
  final e = c.den.event(id)!;
  if (rule == null || rule.isEmpty) notes.addAll(_pastNotes(c, start, end));
  return ActionResult('Added ${describeEvent(c, e)} [event $id].', {
    'event': c.wire.event(e),
    if (notes.isNotEmpty) 'warnings': notes,
  });
}

/// The scope and occurrence an edit of [e] addresses.
(EditScope, int?) eventScope(ActionContext c, Event e, ActionInput a) {
  final raw = a.str('scope') ?? 'all';
  final scope = EditScope.values.where((s) => s.name == raw).firstOrNull;
  if (scope == null) throw ActionError('"scope" must be one, following or all.', field: 'scope');
  if (e.rrule == null) return (EditScope.all, null);
  if (!a.has('occurrence')) {
    if (scope == EditScope.all) return (scope, null);
    throw ActionError('${e.title} repeats; say which occurrence with "occurrence" (its date or start).', field: 'occurrence');
  }
  final occurrence = c.occurrenceOf(e, a.raw['occurrence']);
  if (!isOccurrenceOf(e, c.zone, occurrence)) {
    throw ActionError('That isn\'t an occurrence of ${e.title}.', field: 'occurrence');
  }
  return (scope, occurrence);
}

/// An event the caller may change: not one from a subscribed calendar.
Event editableEvent(ActionContext c, ActionInput a, String verb) {
  final e = _named(c, a);
  if (e.source.readOnly) {
    throw ActionError.readOnly('${e.title} comes from the subscribed calendar "${e.source.label ?? 'a feed'}"; $verb it there.');
  }
  return e;
}

Future<ActionResult> _update(ActionContext c, ActionInput a) async {
  final e = editableEvent(c, a, 'change');
  final (scope, occurrence) = eventScope(c, e, a);
  final tz = _zone(a);
  final zone = tz ?? zoneOfEvent(e, c.zone);
  final allDay = a.flag('all_day');
  final targetAllDay = allDay ?? e.allDay;
  final category = a.str('category')?.trim();
  final notes = <String>[];
  final people = a.present('people') ? c.people.many(a.raw['people'], 'people') : null;
  final rides = _rides(c, a, people ?? e.assignees, notes);
  final patch = <String, Object?>{
    if (a.has('title')) 'title': a.str('title')!.trim(),
    if (a.present('location')) 'location': a.str('location') ?? '',
    if (a.present('notes')) 'notes': a.str('notes') ?? '',
    'assignees': ?people,
    if (a.present('category')) 'category': category == null || category.isEmpty ? null : c.category(category),
    if (a.has('reminders')) 'reminders': a.ints('reminders'),
    'allDay': ?allDay,
    'tz': ?tz,
    if (rides != null) 'rides': [for (final r in rides) {'leg': r.leg, 'driver': r.driver}],
    if (a.has('countdown')) 'countdown': a.flag('countdown'),
    if (a.has('start')) 'start': _at(c, a, 'start', allDay: targetAllDay, zone: zone, notes: notes),
    if (a.has('end')) 'end': _at(c, a, 'end', allDay: targetAllDay, zone: zone, end: true, notes: notes),
  };
  if (allDay != null && allDay != e.allDay && !a.has('start')) {
    throw ActionError('Switching all-day needs a "start" too.', field: 'start');
  }
  if (patch['start'] is int && patch['end'] is int && (patch['end'] as int) < (patch['start'] as int)) {
    throw ActionError('The end is before the start.', field: 'end');
  }
  final rule = _rule(a);
  if (rule != null) {
    if (scope == EditScope.one) throw ActionError('A repeat rule can\'t change for one occurrence.', field: 'repeat');
    patch['rrule'] = rule.isEmpty ? null : rule;
  }
  if (a.has('who_can_see')) patch['audience'] = audienceFor(c, a.raw['who_can_see']);
  if (patch.isEmpty) throw ActionError('Nothing to change: give a field such as title, start or location.');
  final had = {for (final x in c.den.events) x.id};
  await c.den.updateEvent(e.id, patch, scope: scope, occurrence: occurrence);
  // "This and following" ends the series just before the occurrence and starts a new event there.
  final split = scope == EditScope.following ? c.den.events.where((x) => !had.contains(x.id)).firstOrNull : null;
  final after = split ?? c.den.event(e.id);
  final String said;
  if (after == null) {
    said = 'Changed ${e.title}.';
  } else if (e.rrule != null && scope == EditScope.one && occurrence != null) {
    said = 'Changed ${e.title} on ${c.day(dateIn(c.zone, occurrence))} only, now ${describeEvent(c, after, at: occurrence)} '
        '[event ${e.id}, occurrence $occurrence].';
  } else if (split != null) {
    said = 'Changed ${e.title} from ${c.day(dateIn(c.zone, occurrence!))} on, now ${describeEvent(c, split)} '
        '[event ${split.id}]. The occurrences before stay as they were [event ${e.id}].';
  } else {
    said = 'Changed ${describeEvent(c, after)}${e.rrule == null ? '' : ' (every occurrence)'} [event ${after.id}].';
  }
  return ActionResult(said, {
    'ok': true,
    'event': after == null ? null : c.wire.event(after),
    'scope': scope.name,
    'occurrence': occurrence,
    if (notes.isNotEmpty) 'warnings': notes,
  });
}

Future<ActionResult> _delete(ActionContext c, ActionInput a) async {
  final e = editableEvent(c, a, 'remove');
  final (scope, occurrence) = eventScope(c, e, a);
  await c.den.deleteEvent(e.id, scope: scope, occurrence: occurrence);
  final on = occurrence == null ? '' : c.day(dateIn(c.zone, occurrence));
  final what = e.rrule == null || scope == EditScope.all
      ? e.title
      : scope == EditScope.one
          ? '${e.title} on $on only'
          : '${e.title} from $on on';
  return ActionResult(
    'Removed $what${occurrence == null ? '' : ' [event ${e.id}, occurrence $occurrence]'}.',
    {'ok': true, 'event_id': e.id, 'scope': scope.name, 'occurrence': occurrence},
  );
}
