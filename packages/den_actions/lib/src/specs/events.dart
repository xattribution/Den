import 'package:den_core/den_core.dart';

import '../context.dart';
import '../input.dart';
import '../recurrence.dart';
import '../resolve.dart';
import '../schema.dart';
import '../shapes.dart';
import '../spec.dart';
import '../times.dart';

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
      'driver': S.string('Who drives: a name or member id, or "nobody" while nobody has said yes.'),
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
        description: 'Adds an event to the family calendar.',
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
            'Fields left out stay as they are.',
        input: S.input({
          'event': S.string('The event\'s title or id.'),
          'occurrence': S.time('Which occurrence of a repeating event: its start, or its date.'),
          'scope': S.string('How far the change reaches on a repeating event (default all).', oneOf: ['one', 'following', 'all']),
          ..._eventFields,
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
        confirm: Confirm.client,
        confirmWhen: _touchesSeries,
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
        engine: const {'deleteEvent'},
        example: const {'event': 'Dinner at Grandma\'s'},
        run: _delete,
      ),
    ];

/// Whether an update or removal reaches more than one occurrence of a repeating event.
bool _touchesSeries(ActionContext c, ActionInput a) {
  final e = c.event(a.str('event', required: true)!);
  return e.rrule != null && a.str('scope') != 'one';
}

int _at(ActionInput a, String key, {required bool allDay, required String zone, bool end = false}) {
  if (allDay) {
    final date = toolDate(a.raw[key], zone, key);
    return midnightIn(zone, end ? addDays(date, 1) : date);
  }
  return toolInstant(a.raw[key], zone, key);
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

List<Ride>? _rides(ActionContext c, ActionInput a) => a.objects('rides') == null
    ? null
    : [
        for (final r in a.objects('rides')!)
          Ride(
            r['leg']! as String,
            switch ('${r['driver'] ?? ''}'.trim().toLowerCase()) {
              '' || 'nobody' || 'none' || 'no one' => null,
              _ => c.people.one('${r['driver']}'),
            },
          ),
      ];

/// One line about an event: "Dentist, Tue, Oct 20, 3:00 PM–4:00 PM, for Zoe".
String describeEvent(ActionContext c, Event e) {
  final occurrences = c.occurrences(e.start, e.end > e.start ? e.end : e.start + 1);
  final first = occurrences.where((o) => o.event.id == e.id).firstOrNull;
  final when = first == null ? shortDate(dateIn(c.zone, e.start)) : c.when(first);
  final who = e.assignees.isEmpty ? 'everyone' : c.people.names(e.assignees);
  return '${e.title}, $when, for $who${e.rrule == null ? '' : ', repeating ${e.rrule}'}';
}

Future<ActionResult> _create(ActionContext c, ActionInput a) async {
  final title = a.str('title', required: true)!.trim();
  final allDay = a.flag('all_day') ?? false;
  final tz = _zone(a);
  final zone = tz ?? c.zone;
  final start = _at(a, 'start', allDay: allDay, zone: zone);
  final end = a.has('end')
      ? _at(a, 'end', allDay: allDay, zone: zone, end: true)
      : allDay
          ? midnightIn(zone, addDays(dateIn(zone, start), 1))
          : start + Duration.millisecondsPerHour;
  if (end < start) throw ActionError('The end is before the start.', field: 'end');
  final rule = _rule(a);
  final category = a.str('category')?.trim();
  final id = await c.den.addEvent(
    title: title,
    start: start,
    end: end,
    allDay: allDay,
    tz: tz,
    rrule: rule == null || rule.isEmpty ? null : rule,
    assignees: c.people.many(a.raw['people'], 'people'),
    category: category == null || category.isEmpty ? null : c.category(category),
    location: a.str('location') ?? '',
    notes: a.str('notes') ?? '',
    reminders: a.ints('reminders') ?? const [],
    rides: _rides(c, a) ?? const [],
    countdown: a.flag('countdown') ?? false,
    space: c.space(a.raw['who_can_see']),
  );
  final e = c.den.event(id)!;
  return ActionResult('Added ${describeEvent(c, e)} [event $id].', {'event': c.wire.event(e)});
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
  final e = c.event(a.str('event', required: true)!);
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
  final rides = _rides(c, a);
  final patch = <String, Object?>{
    if (a.has('title')) 'title': a.str('title')!.trim(),
    if (a.present('location')) 'location': a.str('location') ?? '',
    if (a.present('notes')) 'notes': a.str('notes') ?? '',
    if (a.present('people')) 'assignees': c.people.many(a.raw['people'], 'people'),
    if (a.present('category')) 'category': category == null || category.isEmpty ? null : c.category(category),
    if (a.has('reminders')) 'reminders': a.ints('reminders'),
    'allDay': ?allDay,
    'tz': ?tz,
    if (rides != null) 'rides': [for (final r in rides) {'leg': r.leg, 'driver': r.driver}],
    if (a.has('countdown')) 'countdown': a.flag('countdown'),
    if (a.has('start')) 'start': _at(a, 'start', allDay: targetAllDay, zone: zone),
    if (a.has('end')) 'end': _at(a, 'end', allDay: targetAllDay, zone: zone, end: true),
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
  if (patch.isEmpty) throw ActionError('Nothing to change: give a field such as title, start or location.');
  await c.den.updateEvent(e.id, patch, scope: scope, occurrence: occurrence);
  final after = c.den.event(e.id);
  final how = e.rrule == null
      ? ''
      : ' (${scope == EditScope.one ? 'that occurrence' : scope == EditScope.following ? 'that and following occurrences' : 'every occurrence'})';
  return ActionResult(
    after == null ? 'Changed ${e.title}$how.' : 'Changed ${describeEvent(c, after)}$how [event ${e.id}].',
    {'ok': true, 'event': after == null ? null : c.wire.event(after), 'scope': scope.name, 'occurrence': occurrence},
  );
}

Future<ActionResult> _delete(ActionContext c, ActionInput a) async {
  final e = editableEvent(c, a, 'remove');
  final (scope, occurrence) = eventScope(c, e, a);
  await c.den.deleteEvent(e.id, scope: scope, occurrence: occurrence);
  final what = e.rrule == null || scope == EditScope.all
      ? e.title
      : '${scope == EditScope.one ? 'one occurrence of' : 'this and following occurrences of'} ${e.title}';
  return ActionResult('Removed $what.', {'ok': true, 'event_id': e.id, 'scope': scope.name, 'occurrence': occurrence});
}
