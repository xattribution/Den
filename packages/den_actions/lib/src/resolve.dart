import 'package:collection/collection.dart';
import 'package:den_core/den_core.dart';

import 'times.dart';

/// An action was called in a way the caller can fix; [message] says how. [code] is the REST
/// API's error code (docs/hub-api.md, "Errors").
class ActionError implements Exception {
  /// Input the caller can fix: `invalid_input`, naming [field] when one field is at fault.
  ActionError(this.message, {this.code = 'invalid_input', this.field, this.details});

  /// Nothing by that id or name: `not_found`.
  ActionError.notFound(this.message, {String? type, String? id})
      : code = 'not_found',
        field = null,
        details = type == null ? null : {'type': type, 'id': ?id};

  /// The person may not do this: `permission_denied`.
  ActionError.denied(this.message)
      : code = 'permission_denied',
        field = null,
        details = null;

  /// The record comes from elsewhere and changes there: `read_only`.
  ActionError.readOnly(this.message)
      : code = 'read_only',
        field = null,
        details = null;

  /// Written for people (and models).
  final String message;

  /// Stable and machine-readable.
  final String code;

  /// The input at fault, when it's one.
  final String? field;

  /// More, for the REST API's `error.details`.
  final Map<String, Object?>? details;

  @override
  String toString() => message;
}

String _norm(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Finds one of [items] by id or name: an exact id, an exact name (ignoring case), then a
/// unique name that starts with or contains the query. When several match, each of [narrow]
/// in turn may settle it (keeping those of one person, or of one date); one that keeps exactly
/// one wins, and one that keeps several narrows what the next one sees. Throws [ActionError]
/// listing the choices.
T pick<T>(
  String query,
  List<T> items, {
  required String Function(T) id,
  required String Function(T) name,
  required String kind,
  String Function(T)? describe,
  List<List<T> Function(List<T> found)> narrow = const [],
}) {
  final q = _norm(query);
  final byId = items.firstWhereOrNull((i) => id(i) == query.trim());
  if (byId != null) return byId;
  for (final test in <bool Function(String)>[
    (n) => n == q,
    (n) => n.startsWith(q),
    (n) => n.contains(q),
  ]) {
    var found = items.where((i) => test(_norm(name(i)))).toList();
    if (found.length == 1) return found.single;
    for (final settle in narrow) {
      if (found.length < 2) break;
      final kept = settle(found);
      if (kept.length == 1) return kept.single;
      if (kept.isNotEmpty) found = kept;
    }
    if (found.length > 1) {
      final label = describe ?? (T i) => '${name(i)} (id ${id(i)})';
      throw ActionError('More than one $kind matches "$query": ${found.map(label).join('; ')}. Use the id, or say whose '
          'it is or which day.');
    }
  }
  if (items.isEmpty) throw ActionError('There are no ${kind}s to choose from.');
  final shown = items.take(40).map((i) => '${name(i)} (id ${id(i)})').join('; ');
  throw ActionError('There\'s no $kind called "$query". Choices: $shown${items.length > 40 ? '; ...' : ''}.');
}

/// Reads person names or ids against the family.
class People {
  /// Creates a resolver over [den]'s members; "me" is [me].
  People(this.den, this.me);

  /// The hub's engine.
  final Den den;

  /// The calling token's member, if any.
  final String? me;

  /// A member id from a name or id; "me" is the token's member.
  String one(String query) {
    final q = _norm(query);
    if (q == 'me' || q == 'myself' || q == 'i') {
      if (me == null) throw ActionError('This connection doesn\'t belong to one person, so "me" means nobody. Name someone.');
      return me!;
    }
    return pick(query, den.members, id: (m) => m.id, name: (m) => m.name, kind: 'person').id;
  }

  /// Member ids from a list of names or ids.
  List<String> many(Object? value, String field) {
    if (value == null) return const [];
    if (value is String) return [one(value)];
    if (value is! List) throw ActionError('"$field" must be a list of names.');
    return {for (final v in value) one('$v')}.toList();
  }

  /// The member's name, or "someone".
  String name(String? id) => id == null ? 'anyone' : den.member(id)?.name ?? 'someone';

  /// Names joined for people.
  String names(Iterable<String> ids) => joinNames([for (final id in ids) name(id)]);
}

/// Reads an action's time input: ISO 8601 with an offset, ISO without (in [zone]), a local date
/// (midnight starting it), or words relative to [today] ("next Friday 3pm", "tomorrow at 9",
/// "Friday"; see [relativeWall]). A wall-clock time the clocks skip or repeat that day is
/// told to [note]. Throws [ActionError].
int toolInstant(Object? value, String zone, String field, {String? today, int weekStart = 0, void Function(String)? note}) {
  void check(DateTime? wall, int at) {
    if (wall == null || note == null) return;
    final said = wallNote(zone, wall, at);
    if (said != null) note(said);
  }

  try {
    final at = parseInstant(value, zone, allowDate: true);
    check(localWallOf(value), at);
    return at;
  } on FormatException {
    if (value is String) {
      final wall = relativeWall(value, today ?? dateIn(zone, DateTime.now().millisecondsSinceEpoch), weekStart: weekStart);
      if (wall != null) {
        final at = utcOfWall(zone, wall);
        check(wall, at);
        return at;
      }
    }
    throw ActionError('"$field" must be a time like 2026-10-20T15:00, a date like 2026-10-20, or words like '
        '"next Friday 3pm".', field: field);
  }
}

/// Reads an action's date input: a local date, the date of a time, or words relative to
/// [today] ("today", "tomorrow", "yesterday", "Friday", "next Friday", "in 3 days"). Throws
/// [ActionError].
String toolDate(Object? value, String zone, String field, {String? today, int weekStart = 0}) {
  if (value is String) {
    final day = relativeDate(value, today ?? dateIn(zone, DateTime.now().millisecondsSinceEpoch), weekStart: weekStart);
    if (day != null) return day;
  }
  try {
    return parseDateLike(value, zone);
  } on FormatException {
    throw ActionError('"$field" must be a date like 2026-10-20, or words like "tomorrow" or "next Friday".', field: field);
  }
}
