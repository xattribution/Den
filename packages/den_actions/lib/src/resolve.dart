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
/// unique name that starts with or contains the query. Throws [ActionError] listing the choices.
T pick<T>(
  String query,
  List<T> items, {
  required String Function(T) id,
  required String Function(T) name,
  required String kind,
  String Function(T)? describe,
}) {
  final q = _norm(query);
  final byId = items.firstWhereOrNull((i) => id(i) == query.trim());
  if (byId != null) return byId;
  for (final test in <bool Function(String)>[
    (n) => n == q,
    (n) => n.startsWith(q),
    (n) => n.contains(q),
  ]) {
    final found = items.where((i) => test(_norm(name(i)))).toList();
    if (found.length == 1) return found.single;
    if (found.length > 1) {
      final label = describe ?? (T i) => '${name(i)} (id ${id(i)})';
      throw ActionError('More than one $kind matches "$query": ${found.map(label).join('; ')}. Use the id.');
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

/// Reads an action's time input: ISO 8601 with an offset, ISO without (in [zone]), or a local date
/// (midnight starting it). Throws [ActionError].
int toolInstant(Object? value, String zone, String field) {
  try {
    return parseInstant(value, zone, allowDate: true);
  } on FormatException {
    throw ActionError('"$field" must be a time like 2026-10-20T15:00 or a date like 2026-10-20.');
  }
}

/// Reads an action's date input (a local date, or the date of a time). Throws [ActionError].
String toolDate(Object? value, String zone, String field) {
  if (value is String) {
    final t = value.trim().toLowerCase();
    final today = dateIn(zone, DateTime.now().millisecondsSinceEpoch);
    if (t == 'today') return today;
    if (t == 'tomorrow') return addDays(today, 1);
    if (t == 'yesterday') return addDays(today, -1);
  }
  try {
    return parseDateLike(value, zone);
  } on FormatException {
    throw ActionError('"$field" must be a date like 2026-10-20.');
  }
}
