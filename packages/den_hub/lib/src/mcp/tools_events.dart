import 'package:den_core/den_core.dart';

import '../recurrence.dart';
import '../times.dart';
import 'resolve.dart';
import 'tool.dart';

final Map<String, Object?> _eventFields = {
  'title': sString('What it is.'),
  'start': sTime('When it starts; for all-day events, the first day.'),
  'end': sTime('When it ends (default an hour after the start); for all-day events, the last day.'),
  'all_day': sBool('A whole-day event.'),
  'location': sString('Where.'),
  'notes': sString('Notes.'),
  'people': sList(sString('A name or member id.'), 'Who it is for; empty means everyone.'),
  'category': sString('A category name or id.'),
  'repeat': sString('An RFC 5545 RRULE without DTSTART, such as FREQ=WEEKLY;BYDAY=TU, or "none".'),
  'reminders': sList(sInt('Minutes before.', min: 0, max: 40320), 'Reminders, in minutes before the start.', max: 10),
};

/// Event tools: create, update and delete.
List<Tool> eventTools() => [
      Tool(
        name: 'create_event',
        title: 'Add an event',
        description: 'Adds an event to the family calendar.',
        properties: {
          ..._eventFields,
          'who_can_see': sString('"everyone" (default), "parents", "just me", or a person\'s name for their private item.'),
          'countdown': sBool('Show a countdown to it.'),
        },
        required: ['title', 'start'],
        scope: Scope.calendar,
        readOnly: false,
        run: _create,
      ),
      Tool(
        name: 'update_event',
        title: 'Change an event',
        description: 'Changes an event, one occurrence of a repeating event, or this and following occurrences. '
            'Fields left out stay as they are.',
        properties: {
          'event': sString('The event\'s title or id.'),
          'occurrence': sTime('Which occurrence of a repeating event: its start, or its date.'),
          'scope': sString('How far the change reaches on a repeating event (default all).', oneOf: ['one', 'following', 'all']),
          ..._eventFields,
        },
        required: ['event'],
        scope: Scope.calendar,
        readOnly: false,
        destructive: true,
        idempotent: true,
        run: _update,
      ),
      Tool(
        name: 'delete_event',
        title: 'Remove an event',
        description: 'Removes an event, one occurrence of a repeating event, or this and following occurrences.',
        properties: {
          'event': sString('The event\'s title or id.'),
          'occurrence': sTime('Which occurrence of a repeating event: its start, or its date.'),
          'scope': sString('How far it reaches on a repeating event (default all).', oneOf: ['one', 'following', 'all']),
        },
        required: ['event'],
        scope: Scope.calendar,
        readOnly: false,
        destructive: true,
        idempotent: true,
        run: _delete,
      ),
    ];

int _at(Args a, String key, {required bool allDay, required String zone, bool end = false}) {
  if (allDay) {
    final date = toolDate(a.raw[key], zone, key);
    return midnightIn(zone, end ? addDays(date, 1) : date);
  }
  return toolInstant(a.raw[key], zone, key);
}

String? _rule(Args a) {
  final rule = a.str('repeat', max: 500)?.trim();
  if (rule == null) return null;
  if (rule.isEmpty || rule.toLowerCase() == 'none') return '';
  final text = rule.toUpperCase().startsWith('RRULE:') ? rule.substring(6) : rule;
  if (!RecurrenceRule.isValid(text)) throw ToolError('"$rule" isn\'t a repeat rule Den understands, such as FREQ=WEEKLY;BYDAY=TU.');
  return text;
}

String _describe(ToolContext c, Event e) {
  final occurrences = c.occurrences(e.start, e.end > e.start ? e.end : e.start + 1);
  final first = occurrences.where((o) => o.event.id == e.id).firstOrNull;
  final when = first == null ? shortDate(dateIn(c.zone, e.start)) : c.when(first);
  final who = e.assignees.isEmpty ? 'everyone' : c.people.names(e.assignees);
  return '${e.title}, $when, for $who${e.rrule == null ? '' : ', repeating ${e.rrule}'}';
}

Future<ToolResult> _create(ToolContext c, Args a) async {
  final title = a.str('title', required: true, max: 200)!.trim();
  final allDay = a.flag('all_day') ?? false;
  final start = _at(a, 'start', allDay: allDay, zone: c.zone);
  final end = a.has('end')
      ? _at(a, 'end', allDay: allDay, zone: c.zone, end: true)
      : allDay
          ? midnightIn(c.zone, addDays(dateIn(c.zone, start), 1))
          : start + Duration.millisecondsPerHour;
  if (end < start) throw ToolError('The end is before the start.');
  final rule = _rule(a);
  final id = await c.den.addEvent(
    title: title,
    start: start,
    end: end,
    allDay: allDay,
    rrule: rule == null || rule.isEmpty ? null : rule,
    assignees: c.people.many(a.raw['people'], 'people'),
    category: a.has('category') ? c.category(a.str('category')!) : null,
    location: a.str('location', max: 300) ?? '',
    notes: a.str('notes') ?? '',
    reminders: [for (final r in a.list('reminders') ?? const []) if (r is int) r],
    countdown: a.flag('countdown') ?? false,
    space: c.space(a.raw['who_can_see']),
  );
  final e = c.den.event(id)!;
  return ToolResult('Added ${_describe(c, e)} [event $id].', {'event': c.wire.event(e)});
}

(EditScope, int?) _scope(ToolContext c, Event e, Args a) {
  final raw = a.str('scope') ?? 'all';
  final scope = EditScope.values.where((s) => s.name == raw).firstOrNull;
  if (scope == null) throw ToolError('"scope" must be one, following or all.');
  if (e.rrule == null) return (EditScope.all, null);
  if (!a.has('occurrence')) {
    if (scope == EditScope.all) return (scope, null);
    throw ToolError('${e.title} repeats; say which occurrence with "occurrence" (its date or start).');
  }
  final occurrence = c.occurrenceOf(e, a.raw['occurrence']);
  if (!isOccurrenceOf(e, c.zone, occurrence)) throw ToolError('That isn\'t an occurrence of ${e.title}.');
  return (scope, occurrence);
}

Future<ToolResult> _update(ToolContext c, Args a) async {
  final e = c.event(a.str('event', required: true)!);
  if (e.source.readOnly) {
    throw ToolError('${e.title} comes from the subscribed calendar "${e.source.label ?? 'a feed'}"; change it there.');
  }
  final (scope, occurrence) = _scope(c, e, a);
  final zone = zoneOfEvent(e, c.zone);
  final allDay = a.flag('all_day');
  final targetAllDay = allDay ?? e.allDay;
  final patch = <String, Object?>{
    if (a.has('title')) 'title': a.str('title', max: 200)!.trim(),
    if (a.has('location')) 'location': a.str('location', max: 300),
    if (a.has('notes')) 'notes': a.str('notes'),
    if (a.raw.containsKey('people')) 'assignees': c.people.many(a.raw['people'], 'people'),
    if (a.has('category')) 'category': a.str('category')!.isEmpty ? null : c.category(a.str('category')!),
    if (a.has('reminders')) 'reminders': [for (final r in a.list('reminders')!) if (r is int) r],
    'allDay': ?allDay,
    if (a.has('start')) 'start': _at(a, 'start', allDay: targetAllDay, zone: zone),
    if (a.has('end')) 'end': _at(a, 'end', allDay: targetAllDay, zone: zone, end: true),
  };
  if (allDay != null && allDay != e.allDay && !a.has('start')) throw ToolError('Switching all-day needs a "start" too.');
  final rule = _rule(a);
  if (rule != null) {
    if (scope == EditScope.one) throw ToolError('A repeat rule can\'t change for one occurrence.');
    patch['rrule'] = rule.isEmpty ? null : rule;
  }
  if (patch.isEmpty) throw ToolError('Nothing to change: give a field such as title, start or location.');
  await c.den.updateEvent(e.id, patch, scope: scope, occurrence: occurrence);
  final after = c.den.event(e.id);
  final how = e.rrule == null ? '' : ' (${scope == EditScope.one ? 'that occurrence' : scope == EditScope.following ? 'that and following occurrences' : 'every occurrence'})';
  return ToolResult(
    after == null ? 'Changed ${e.title}$how.' : 'Changed ${_describe(c, after)}$how [event ${e.id}].',
    {'ok': true, 'event': after == null ? null : c.wire.event(after), 'scope': scope.name, 'occurrence': occurrence},
  );
}

Future<ToolResult> _delete(ToolContext c, Args a) async {
  final e = c.event(a.str('event', required: true)!);
  if (e.source.readOnly) {
    throw ToolError('${e.title} comes from the subscribed calendar "${e.source.label ?? 'a feed'}"; remove it there.');
  }
  final (scope, occurrence) = _scope(c, e, a);
  await c.den.deleteEvent(e.id, scope: scope, occurrence: occurrence);
  final what = e.rrule == null || scope == EditScope.all
      ? e.title
      : '${scope == EditScope.one ? 'one occurrence of' : 'this and following occurrences of'} ${e.title}';
  return ToolResult('Removed $what.', {'ok': true, 'event_id': e.id, 'scope': scope.name, 'occurrence': occurrence});
}
