import 'dart:async';

import 'package:collection/collection.dart';
import 'package:den_core/den_core.dart';

import '../access.dart';
import '../context.dart';
import '../times.dart';
import '../wire.dart';
import 'resolve.dart';

/// What a tool answers: words for people, and the same facts as JSON.
class ToolResult {
  /// Creates a result.
  const ToolResult(this.text, this.data, {this.isError = false});

  /// A failed call, explained.
  factory ToolResult.error(String message) => ToolResult(message, {'error': message}, isError: true);

  /// Human-readable text content.
  final String text;

  /// `structuredContent`.
  final Map<String, Object?> data;

  /// Whether the call failed.
  final bool isError;
}

/// One call's view of the family: what the caller may read, and helpers to find things by name.
class ToolContext {
  /// Creates the context for one call.
  ToolContext(this.hub, this.access) : readable = access.readable(hub.den), wire = Wire(hub.den);

  /// Shared hub context.
  final HubContext hub;

  /// The caller.
  final Access access;

  /// Spaces the caller may read.
  final Set<String> readable;

  /// Serializer.
  final Wire wire;

  /// The hub's engine.
  Den get den => hub.den;

  /// The family's zone.
  String get zone => wire.zone;

  /// Name resolution for people.
  late final People people = People(den, access.member);

  /// Today in the family's zone.
  String get today => den.todayDate();

  /// Events the caller may read.
  List<Event> get events => [for (final e in den.events) if (readable.contains(e.space)) e];

  /// Chores the caller may read.
  List<Chore> get chores => [for (final c in den.chores) if (readable.contains(c.space)) c];

  /// Lists the caller may read.
  List<ListState> get lists => [for (final l in den.lists) if (readable.contains(l.list.space)) l];

  /// A list by title or id.
  ListState list(String query) =>
      pick(query, lists, id: (l) => l.list.id, name: (l) => l.list.title, kind: 'list');

  /// A chore by title or id; [owner] narrows chores that share a title.
  Chore chore(String query, {String? owner, String? date}) {
    final all = chores;
    if (owner != null) {
      final day = date ?? today;
      final owned = [
        for (final c in all)
          if (_norm(c.title) == _norm(query) &&
              den.choresOn(day).any((cd) => cd.chore.id == c.id && cd.owner == owner))
            c,
      ];
      if (owned.length == 1) return owned.single;
    }
    return pick(
      query,
      all,
      id: (c) => c.id,
      name: (c) => c.title,
      kind: 'chore',
      describe: (c) => '${c.title} (${_ownerText(c)}, id ${c.id})',
    );
  }

  String _ownerText(Chore c) => switch (c.owner) {
        OwnerMember(:final id) => people.name(id),
        OwnerAnyone() => 'anyone',
        final OwnerRotation r => 'rotating ${people.names(r.ids)}',
      };

  static String _norm(String s) => s.trim().toLowerCase();

  /// An event by title or id.
  Event event(String query) => pick(
        query,
        events,
        id: (e) => e.id,
        name: (e) => e.title,
        kind: 'event',
        describe: (e) => '${e.title} (${shortDate(dateIn(zone, e.start))}, id ${e.id})',
      );

  /// A category by name or id.
  String category(String query) =>
      pick(query, den.categories, id: (c) => c.id, name: (c) => c.name, kind: 'category').id;

  /// A reward by title or id.
  Reward reward(String query) =>
      pick(query, den.points().rewards, id: (r) => r.id, name: (r) => r.title, kind: 'reward');

  /// The space for a "who can see it" input: everyone, parents, just me, or a person's name.
  String space(Object? value) {
    if (value == null) return Space.family;
    final v = '$value'.trim().toLowerCase();
    String space;
    if (v == 'everyone' || v == 'family' || v == 'f') {
      space = Space.family;
    } else if (v == 'parents' || v == 'p') {
      space = Space.parents;
    } else if (v == 'just me' || v == 'me' || v == 'private') {
      final me = access.member;
      if (me == null) throw ToolError('This connection doesn\'t belong to one person; name whose private item it is.');
      space = Space.member(me);
    } else {
      space = Space.member(people.one('$value'));
    }
    if (!readable.contains(space)) throw ToolError('This connection can\'t see that, so it can\'t put things there.');
    return space;
  }

  /// "Tue, Oct 20, 5:30 PM–6:30 PM".
  String when(Occurrence o) {
    final date = dateIn(zone, o.start);
    if (o.allDay) {
      final last = addDays(dateIn(zone, o.end), -1);
      return last.compareTo(date) > 0 ? '${shortDate(date)} to ${shortDate(last)}, all day' : '${shortDate(date)}, all day';
    }
    final start = clockText(wallOf(zone, o.start));
    if (o.end <= o.start) return '${shortDate(date)}, $start';
    return '${shortDate(date)}, $start–${clockText(wallOf(zone, o.end))}';
  }

  /// One line for an occurrence.
  String occurrenceLine(Occurrence o) {
    final who = o.assignees.isEmpty ? 'everyone' : people.names(o.assignees);
    final at = o.location.isEmpty ? '' : ' at ${o.location}';
    return '- ${when(o)}: ${o.title} ($who)$at [event ${o.event.id}${o.isRepeating ? ', occurrence ${Wire.occurrenceKey(o)}' : ''}]';
  }

  /// One line for a chore on a day.
  String choreLine(ChoreDay cd) {
    final who = cd.owner == null ? 'anyone' : people.name(cd.owner);
    final state = cd.done
        ? 'done${cd.doneBy == null ? '' : ' by ${people.name(cd.doneBy)}'}'
        : cd.late
            ? 'late'
            : 'not done';
    final due = cd.chore.dueTime == null ? '' : ', due ${clockText(wallOfDate(cd.date).add(Duration(minutes: _minutes(cd.chore.dueTime!))))}';
    final steps = cd.stepCount == 0 ? '' : ', ${cd.stepsDone} of ${cd.stepCount} steps';
    final points = cd.pointsAvailable == 0 ? '' : ', ${cd.pointsAvailable} stars';
    final day = cd.date == today ? '' : ' (${shortDate(cd.date)})';
    return '- ${cd.chore.title}$day for $who: $state$due$steps$points [chore ${cd.chore.id}]';
  }

  static int _minutes(String hhmm) => int.parse(hhmm.substring(0, 2)) * 60 + int.parse(hhmm.substring(3));

  /// Chores on [date] the caller may read, in display order.
  List<ChoreDay> choresOn(String date) {
    final list = [for (final cd in den.choresOn(date)) if (readable.contains(cd.chore.space)) cd];
    Wire.sortChores(list);
    return list;
  }

  /// Occurrences in [start, end) the caller may read, in order.
  List<Occurrence> occurrences(int start, int end) {
    final list = [for (final o in den.occurrences(start, end)) if (readable.contains(o.event.space)) o];
    Wire.sortOccurrences(list);
    return list;
  }

  /// Finds an item by text or id, in [list] when given.
  (ListState, Item) item(String query, {ListState? list}) {
    final pool = [
      for (final l in list == null ? lists : [list])
        for (final i in l.items) (l, i),
    ];
    final found = pick(
      query,
      pool,
      id: (p) => p.$2.id,
      name: (p) => p.$2.text,
      kind: 'item',
      describe: (p) => '${p.$2.text} on ${p.$1.list.title} (id ${p.$2.id})',
    );
    return found;
  }

  /// The occurrence of [event] on or at [value] (a time or a date), as its original start.
  int occurrenceOf(Event event, Object? value) {
    final text = '$value'.trim();
    final exact = int.tryParse(text);
    final starts = <int, Occurrence>{};
    final from = exact ?? toolInstant(value, zone, 'occurrence');
    for (final o in den.occurrences(from - 2 * Duration.millisecondsPerDay, from + 2 * Duration.millisecondsPerDay)) {
      if (o.event.id == event.id) starts[Wire.occurrenceKey(o)] = o;
    }
    if (exact != null && starts.containsKey(exact)) return exact;
    final at = toolInstant(value, zone, 'occurrence');
    final match = starts.entries.firstWhereOrNull((e) => e.key == at || e.value.start == at);
    if (match != null) return match.key;
    if (isDate(text)) {
      final onDay = starts.entries.where((e) => dateIn(zone, e.value.start) == text).toList();
      if (onDay.length == 1) return onDay.single.key;
    }
    final near = starts.values.map(when).join('; ');
    throw ToolError('${event.title} doesn\'t happen at "$value".${near.isEmpty ? '' : ' Nearby: $near.'}');
  }
}

/// Reads tool arguments, explaining type problems as [ToolError]s.
class Args {
  /// Wraps the `arguments` object.
  Args(this.raw);

  /// The raw arguments.
  final Map<String, Object?> raw;

  /// Whether [key] was given (and isn't null).
  bool has(String key) => raw[key] != null;

  /// A string argument.
  String? str(String key, {bool required = false, int max = 5000}) {
    final v = raw[key];
    if (v == null) {
      if (required) throw ToolError('"$key" is required.');
      return null;
    }
    if (v is! String && v is! num) throw ToolError('"$key" must be text.');
    final s = '$v';
    if (required && s.trim().isEmpty) throw ToolError('"$key" can\'t be empty.');
    if (s.length > max) throw ToolError('"$key" is too long ($max characters at most).');
    return s;
  }

  /// An integer argument.
  int? integer(String key, {bool required = false, int? min, int? max}) {
    final v = raw[key];
    if (v == null) {
      if (required) throw ToolError('"$key" is required.');
      return null;
    }
    final n = v is int ? v : (v is double && v == v.roundToDouble() ? v.toInt() : (v is String ? int.tryParse(v) : null));
    if (n == null) throw ToolError('"$key" must be a whole number.');
    if (min != null && n < min) throw ToolError('"$key" must be at least $min.');
    if (max != null && n > max) throw ToolError('"$key" must be at most $max.');
    return n;
  }

  /// A boolean argument.
  bool? flag(String key) {
    final v = raw[key];
    if (v == null) return null;
    if (v is bool) return v;
    if (v == 'true') return true;
    if (v == 'false') return false;
    throw ToolError('"$key" must be true or false.');
  }

  /// A list argument.
  List<Object?>? list(String key) {
    final v = raw[key];
    if (v == null) return null;
    if (v is! List) throw ToolError('"$key" must be a list.');
    return v;
  }
}

/// A tool the MCP server offers.
class Tool {
  /// Creates a tool.
  const Tool({
    required this.name,
    required this.title,
    required this.description,
    required this.properties,
    this.required = const [],
    required this.scope,
    required this.readOnly,
    this.destructive = false,
    this.idempotent = false,
    required this.run,
  });

  /// Tool name.
  final String name;

  /// Human-readable title.
  final String title;

  /// What it does, for the model.
  final String description;

  /// JSON Schema properties of the arguments.
  final Map<String, Object?> properties;

  /// Required argument names.
  final List<String> required;

  /// The scope a token needs to call it.
  final Scope scope;

  /// Changes nothing.
  final bool readOnly;

  /// May overwrite or remove things.
  final bool destructive;

  /// Calling it twice with the same arguments does no more than once.
  final bool idempotent;

  /// Runs the call with the caller acting.
  final FutureOr<ToolResult> Function(ToolContext c, Args a) run;

  /// The `tools/list` entry.
  Map<String, Object?> toJson() => {
        'name': name,
        'title': title,
        'description': description,
        'inputSchema': {
          'type': 'object',
          'properties': properties,
          if (required.isNotEmpty) 'required': required,
          'additionalProperties': false,
        },
        'annotations': {
          'title': title,
          'readOnlyHint': readOnly,
          'destructiveHint': readOnly ? false : destructive,
          'idempotentHint': readOnly || idempotent,
          'openWorldHint': false,
        },
      };
}

/// JSON Schema for a string.
Map<String, Object?> sString(String description, {List<String>? oneOf}) =>
    {'type': 'string', 'description': description, 'enum': ?oneOf};

/// JSON Schema for an integer.
Map<String, Object?> sInt(String description, {int? min, int? max}) =>
    {'type': 'integer', 'description': description, 'minimum': ?min, 'maximum': ?max};

/// JSON Schema for a boolean.
Map<String, Object?> sBool(String description) => {'type': 'boolean', 'description': description};

/// JSON Schema for an array.
Map<String, Object?> sList(Map<String, Object?> items, String description, {int? max}) =>
    {'type': 'array', 'items': items, 'description': description, 'maxItems': ?max};

/// JSON Schema for a time input.
Map<String, Object?> sTime(String description) => sString(
      '$description ISO 8601 with an offset (2026-10-20T15:00:00-05:00), without one (read in the '
      'family\'s time zone), or a date (2026-10-20).',
    );

/// JSON Schema for a person input.
Map<String, Object?> sPerson(String description) => sString('$description A name or member id; "me" is this connection\'s person.');
