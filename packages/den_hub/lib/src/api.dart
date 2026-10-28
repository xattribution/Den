import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:shelf/shelf.dart';

import 'access.dart';
import 'api_writes.dart';
import 'context.dart';
import 'http_util.dart';
import 'log.dart';
import 'privacy.dart';
import 'times.dart';
import 'wire.dart';

/// One authenticated API call: who is calling, what they may read, and how to answer.
class Call {
  /// Creates a call.
  Call(this.hub, this.request, this.access, this.readable, this.wire);

  /// Shared hub context.
  final HubContext hub;

  /// The HTTP request.
  final Request request;

  /// The caller's token.
  final Access access;

  /// Spaces the caller may read.
  final Set<String> readable;

  /// The serializer for this family.
  final Wire wire;

  /// The hub's engine.
  Den get den => hub.den;

  /// The family's time zone.
  String get zone => wire.zone;

  /// Query parameters.
  Map<String, String> get query => request.url.queryParameters;

  /// Whether the caller may read records in [space].
  bool canSee(String space) => readable.contains(space);
}

/// The `/api/v1` REST API from docs/hub-api.md.
class RestApi {
  /// Creates the API over [hub].
  RestApi(this.hub);

  /// Shared hub context.
  final HubContext hub;

  /// Adds every `/api/v1` route except hub setup and linking.
  void register(Routes routes) {
    final writes = RestWrites(this);
    routes
      ..add('GET', '/api/v1/members', (r, _) => _call(r, Scope.read, _members))
      ..add('GET', '/api/v1/today', (r, _) => _call(r, Scope.read, _today))
      ..add('GET', '/api/v1/events', (r, _) => _call(r, Scope.read, _events))
      ..add('POST', '/api/v1/events', (r, _) => _call(r, Scope.calendar, writes.createEvent))
      ..add('PATCH', '/api/v1/events/<id>', (r, p) => _call(r, Scope.calendar, (c) => writes.updateEvent(c, p['id']!)))
      ..add('DELETE', '/api/v1/events/<id>', (r, p) => _call(r, Scope.calendar, (c) => writes.deleteEvent(c, p['id']!)))
      ..add('GET', '/api/v1/chores', (r, _) => _call(r, Scope.read, _chores))
      ..add('POST', '/api/v1/chores/<id>/complete',
          (r, p) => _call(r, Scope.chores, (c) => writes.completeChore(c, p['id']!)))
      ..add('POST', '/api/v1/chores/<id>/steps/<step>',
          (r, p) => _call(r, Scope.chores, (c) => writes.checkStep(c, p['id']!, p['step']!)))
      ..add('GET', '/api/v1/lists', (r, _) => _call(r, Scope.read, _lists))
      ..add('POST', '/api/v1/lists/<id>/items', (r, p) => _call(r, Scope.lists, (c) => writes.addItems(c, p['id']!)))
      ..add('PATCH', '/api/v1/items/<id>', (r, p) => _call(r, Scope.lists, (c) => writes.updateItem(c, p['id']!)))
      ..add('DELETE', '/api/v1/items/<id>', (r, p) => _call(r, Scope.lists, (c) => writes.deleteItem(c, p['id']!)))
      ..add('GET', '/api/v1/points', (r, _) => _call(r, Scope.read, _points))
      ..add('POST', '/api/v1/points/adjust', (r, _) => _call(r, Scope.points, writes.adjustPoints))
      ..add('GET', '/api/v1/history', (r, _) => _call(r, Scope.read, _history))
      ..add('GET', '/api/v1/search', (r, _) => _call(r, Scope.read, _search));
  }

  /// Authenticates [request], checks [scope], then runs [body] with the token's member acting.
  Future<Response> _call(Request request, Scope scope, FutureOr<Response> Function(Call call) body) async {
    final access = authenticate(request, scope);
    try {
      return await hub.gate.run(access.member, access.label, () async {
        final call = Call(hub, request, access, access.readable(hub.den), Wire(hub.den));
        return body(call);
      });
    } on ApiError {
      rethrow;
    } on PermissionDenied catch (e) {
      throw ApiError.denied(e.message);
    } on InvalidInput catch (e) {
      throw ApiError.invalid(e.message);
    }
  }

  /// The caller's access for [request], requiring [scope]. Throws `503`, `401` or `403`, and
  /// `429` once a client has sent too many tokens that don't work.
  Access authenticate(Request request, Scope scope) {
    if (!hub.ready) throw ApiError.notReady();
    hub.checkFailures(request);
    final access = accessForToken(hub.den, bearerToken(request.headers['authorization']));
    if (access == null) {
      hub.failed(request);
      throw ApiError.unauthorized();
    }
    if (!access.has(scope)) throw ApiError.scope(scope.name);
    return access;
  }

  // ------------------------------------------------------------------ reads

  Response _members(Call c) {
    final connection = c.access.connection;
    return jsonResponse({
      'hub': c.wire.hub(hub.config.name),
      'family': c.wire.family(),
      'token': {
        'label': connection.label,
        'member': connection.member,
        'scopes': [for (final s in Scope.values) if (connection.scopes.contains(s)) s.name],
        ...c.wire.instant('expires', connection.expires),
      },
      'members': [for (final m in c.den.members) Wire.member(m)],
      'categories': [for (final cat in c.den.categories) Wire.category(cat)],
    });
  }

  String _date(Call c, String name) {
    final raw = c.query[name];
    if (raw == null || raw.isEmpty) return c.den.todayDate();
    if (!isDate(raw.trim())) throw ApiError.invalid('"$name" must be a date like 2026-10-17.', field: name);
    return raw.trim();
  }

  List<ChoreDay> _choresFor(Call c, String date) =>
      [for (final cd in c.den.choresOn(date)) if (c.canSee(cd.chore.space)) cd]..sortChoresInPlace();

  Response _today(Call c) {
    final date = _date(c, 'date');
    final view = c.den.today(date: date);
    final events = [for (final o in view.events) if (c.canSee(o.event.space)) o];
    Wire.sortOccurrences(events);
    final chores = _choresFor(c, date);
    final visible = {for (final o in events) Wire.uidOf(o)};
    return jsonResponse({
      'date': date,
      'timezone': c.zone,
      'events': [for (final o in events) c.wire.occurrence(o)],
      'chores': [for (final cd in chores) c.wire.choreDay(cd)],
      'chore_summary': Wire.choreSummary(chores),
      'lists': [for (final l in view.lists) if (c.canSee(l.list.space)) Wire.list(l)],
      'gaps': [
        for (final g in visibleGaps(c.den, view.gaps, c.readable))
          if (g.occurrences.every((o) => visible.contains(Wire.uidOf(o)))) c.wire.gap(g),
      ],
    });
  }

  int _instantParam(Call c, String name, int fallback) {
    final raw = c.query[name];
    if (raw == null || raw.trim().isEmpty) return fallback;
    try {
      return parseInstant(raw, c.zone, allowDate: true);
    } on FormatException {
      throw ApiError.invalid('"$name" must be a time or a date.', field: name);
    }
  }

  Response _events(Call c) {
    final start = _instantParam(c, 'start', c.den.dayStart(c.den.todayDate()));
    final end = _instantParam(c, 'end', start + 7 * Duration.millisecondsPerDay);
    if (end < start) throw ApiError.invalid('"end" is before "start".', field: 'end');
    if (end - start > 400 * Duration.millisecondsPerDay) {
      throw ApiError.invalid('The window can be at most 400 days.', field: 'end');
    }
    final member = c.query['member'];
    if (member != null && member.isNotEmpty && c.den.member(member) == null) {
      throw ApiError.invalid('There\'s nobody with that id in the family.', field: 'member');
    }
    final everyone = queryBool(c.request, 'include_everyone', false);
    final limit = queryInt(c.request, 'limit', 2000, min: 1, max: 2000);
    final all = [
      for (final o in c.den.occurrences(start, end))
        if (c.canSee(o.event.space) &&
            (member == null ||
                member.isEmpty ||
                o.assignees.contains(member) ||
                (everyone && o.assignees.isEmpty)))
          o,
    ];
    Wire.sortOccurrences(all);
    return jsonResponse({
      ...c.wire.instant('start', start),
      ...c.wire.instant('end', end),
      'timezone': c.zone,
      'truncated': all.length > limit,
      'events': [for (final o in all.take(limit)) c.wire.occurrence(o)],
    });
  }

  Response _chores(Call c) {
    final date = _date(c, 'date');
    final member = c.query['member'];
    final chores = [
      for (final cd in _choresFor(c, date))
        if (member == null || member.isEmpty || cd.owner == member) cd,
    ];
    return jsonResponse({
      'date': date,
      'timezone': c.zone,
      'chores': [for (final cd in chores) c.wire.choreDay(cd)],
      'summary': Wire.choreSummary(chores),
    });
  }

  Response _lists(Call c) {
    final lists = [for (final l in c.den.lists) if (c.canSee(l.list.space)) l];
    return jsonResponse({
      'lists': [for (final l in lists) Wire.list(l)],
      'stores': storesOf(lists),
    });
  }

  Response _points(Call c) {
    final recent = queryInt(c.request, 'recent', 50, min: 0, max: 200);
    return jsonResponse(c.wire.points(visiblePoints(c.den, c.den.points(), c.readable), recent: recent));
  }

  Response _history(Call c) {
    final limit = queryInt(c.request, 'limit', 50, min: 1, max: 200);
    final q = c.query['q'];
    final member = c.query['member'];
    final type = c.query['type'];
    final entries = c.den.history(
      query: q == null || q.isEmpty ? null : q,
      member: member == null || member.isEmpty ? null : member,
      type: type == null || type.isEmpty ? null : type,
      limit: limit + 200,
    );
    return jsonResponse({
      'entries': [for (final h in entries.where((h) => c.canSee(h.space)).take(limit)) c.wire.history(h)],
    });
  }

  Response _search(Call c) {
    final q = c.query['q']?.trim() ?? '';
    if (q.isEmpty || q.length > 200) throw ApiError.invalid('"q" must be 1 to 200 characters.', field: 'q');
    final limit = queryInt(c.request, 'limit', 50, min: 1, max: 100);
    final hits = [
      for (final h in c.den.search(q, limit: limit + 50))
        if (searchHitVisible(c.den, h, c.readable)) h,
    ];
    return jsonResponse({
      'results': [for (final h in hits.take(limit)) c.wire.searchHit(h)],
    });
  }
}

/// Whether a search hit belongs to a space in [readable].
bool searchHitVisible(Den den, SearchHit hit, Set<String> readable) {
  String? space;
  switch (hit.type) {
    case RecordType.member:
      space = Space.family;
    case RecordType.event:
      space = den.event(hit.id)?.space;
    case RecordType.chore:
      space = den.chore(hit.id)?.space;
    case RecordType.list:
      space = den.list(hit.id)?.list.space;
    case RecordType.item:
      for (final l in den.lists) {
        if (l.items.any((i) => i.id == hit.id)) space = l.list.space;
      }
  }
  if (space == null) {
    for (final h in den.history(type: hit.type, limit: 500)) {
      if (h.rid == hit.id) {
        space = h.space;
        break;
      }
    }
  }
  return space != null && readable.contains(space);
}

extension on List<ChoreDay> {
  void sortChoresInPlace() => Wire.sortChores(this);
}

/// Logs an unexpected error without its message.
void logUnexpected(HubLog log, String where, Object error, StackTrace stack) =>
    log.error('$where failed: ${describeError(error, stack)}');
