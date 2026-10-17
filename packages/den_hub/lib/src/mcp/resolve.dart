import 'package:collection/collection.dart';
import 'package:den_core/den_core.dart';

import '../times.dart';

/// A tool call went wrong in a way the model can fix; [message] says how.
class ToolError implements Exception {
  /// Creates the error.
  ToolError(this.message);

  /// Written for people (and models).
  final String message;

  @override
  String toString() => message;
}

String _norm(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Finds one of [items] by id or name: an exact id, an exact name (ignoring case), then a
/// unique name that starts with or contains the query. Throws [ToolError] listing the choices.
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
      throw ToolError('More than one $kind matches "$query": ${found.map(label).join('; ')}. Use the id.');
    }
  }
  if (items.isEmpty) throw ToolError('There are no ${kind}s to choose from.');
  final shown = items.take(40).map((i) => '${name(i)} (id ${id(i)})').join('; ');
  throw ToolError('There\'s no $kind called "$query". Choices: $shown${items.length > 40 ? '; ...' : ''}.');
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
      if (me == null) throw ToolError('This connection doesn\'t belong to one person, so "me" means nobody. Name someone.');
      return me!;
    }
    return pick(query, den.members, id: (m) => m.id, name: (m) => m.name, kind: 'person').id;
  }

  /// Member ids from a list of names or ids.
  List<String> many(Object? value, String field) {
    if (value == null) return const [];
    if (value is String) return [one(value)];
    if (value is! List) throw ToolError('"$field" must be a list of names.');
    return {for (final v in value) one('$v')}.toList();
  }

  /// The member's name, or "someone".
  String name(String? id) => id == null ? 'anyone' : den.member(id)?.name ?? 'someone';

  /// Names joined for people.
  String names(Iterable<String> ids) => joinNames([for (final id in ids) name(id)]);
}

/// Reads a tool's time input: ISO 8601 with an offset, ISO without (in [zone]), or a local date
/// (midnight starting it). Throws [ToolError].
int toolInstant(Object? value, String zone, String field) {
  try {
    return parseInstant(value, zone, allowDate: true);
  } on FormatException {
    throw ToolError('"$field" must be a time like 2026-10-20T15:00 or a date like 2026-10-20.');
  }
}

/// Reads a tool's date input (a local date, or the date of a time). Throws [ToolError].
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
    throw ToolError('"$field" must be a date like 2026-10-20.');
  }
}
