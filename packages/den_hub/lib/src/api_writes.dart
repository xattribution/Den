import 'package:collection/collection.dart';
import 'package:den_actions/den_actions.dart';
import 'package:den_actions/times.dart';
import 'package:den_core/den_core.dart';
import 'package:shelf/shelf.dart';

import 'api.dart';
import 'body.dart';
import 'http_util.dart';

/// The older `/api/v1` writes, as Home Assistant and scripts use them: each reads its request
/// as it always has (ids, field names, errors naming the field), runs the den_actions action it
/// stands for, and answers in its own shape.
class RestWrites {
  /// Creates the writes for [api].
  RestWrites(this.api);

  /// The API these belong to.
  final RestApi api;

  /// Runs action [name] for [c] (the person already acting), as a yes to anything it would ask.
  Future<ActionResult> _act(Call c, String name, Map<String, Object?> args) async {
    final result = await api.runner.run(api.actionContext(c.access), name, args, mode: RunMode.confirmed);
    if (result.isError) throw RestApi.errorOf(result);
    return result;
  }

  // ------------------------------------------------------------------ events

  Event _visibleEvent(Call c, String id) {
    final e = c.den.event(id);
    if (e == null || !c.canSee(e.space)) throw ApiError.notFound(type: 'event', id: id);
    return e;
  }

  /// A REST time as the action takes it: UTC milliseconds for a time; for an all-day event a
  /// local date, the last day for an end (REST ends are exclusive, the action's are the last day).
  Object _when(Body b, String key, {required bool allDay, required String zone, bool end = false}) {
    try {
      if (allDay) {
        final date = parseDateLike(b[key], zone);
        return end ? addDays(date, -1) : date;
      }
      return parseInstant(b[key], zone);
    } on FormatException {
      throw ApiError.invalid(
        allDay ? '"$key" must be a date like 2026-10-20.' : '"$key" must be a time like 2026-10-20T15:00:00-05:00.',
        field: key,
      );
    }
  }

  int _ms(Object when, String zone, {bool end = false}) =>
      when is int ? when : midnightIn(zone, end ? addDays(when as String, 1) : when as String);

  String? _zoneField(Body b) {
    final tz = b.string('tz', max: 64);
    if (tz != null && !isZone(tz)) throw ApiError.invalid('Den doesn\'t know the time zone "$tz".', field: 'tz');
    return tz;
  }

  String? _rule(Body b, String key) {
    final rule = b.string(key, max: 500, nullable: true);
    if (rule != null && rule.trim().isNotEmpty && !RecurrenceRule.isValid(rule)) {
      throw ApiError.invalid('"$rule" isn\'t a repeat rule Den understands.', field: key);
    }
    return rule == null || rule.trim().isEmpty ? null : rule;
  }

  List<String>? _members(Call c, Body b, String key) {
    final ids = b.strings(key);
    if (ids == null) return null;
    for (final id in ids) {
      if (c.den.member(id) == null) throw ApiError.invalid('There\'s nobody with the id "$id" in the family.', field: key);
    }
    return ids.toSet().toList();
  }

  List<Map<String, Object?>>? _rides(Call c, Body b) {
    final raw = b['rides'];
    if (raw == null) {
      if (b.has('rides')) throw ApiError.invalid('"rides" must be a list.', field: 'rides');
      return null;
    }
    if (raw is! List || raw.length > 4) throw ApiError.invalid('"rides" must be a list of up to 4 legs.', field: 'rides');
    return [
      for (final r in raw)
        if (r is Map && (r['leg'] == 'to' || r['leg'] == 'from') && (r['driver'] == null || c.den.member('${r['driver']}') != null))
          {'leg': r['leg'], 'driver': r['driver'] ?? 'nobody'}
        else
          throw ApiError.invalid('Each ride is {"leg": "to" or "from", "driver": a member id or null}.', field: 'rides'),
    ];
  }

  String? _category(Call c, Body b) {
    final id = b.string('category', max: 80, nullable: true);
    if (id != null && c.den.category(id) == null) throw ApiError.invalid('There\'s no category with that id.', field: 'category');
    return id;
  }

  /// A REST space (`f`, `p`, `m:<member id>`) as a "who can see it" input.
  String _audience(Call c, Body b) {
    final space = b.string('space', max: 82) ?? Space.family;
    final valid = space == Space.family ||
        space == Space.parents ||
        (Space.isMember(space) && c.den.member(Space.memberOf(space)!) != null);
    if (!valid) throw ApiError.invalid('"space" must be "f", "p" or "m:<member id>".', field: 'space');
    if (!c.canSee(space)) throw ApiError.denied('This token can\'t see that space, so it can\'t write there.');
    return space == Space.family
        ? 'everyone'
        : space == Space.parents
            ? 'parents'
            : space;
  }

  /// `POST /api/v1/events`.
  Future<Response> createEvent(Call c) async {
    final b = Body(await readJsonObject(c.request, required: true));
    final title = b.string('title', required: true, min: 1, max: 200)!.trim();
    final allDay = b.flag('all_day', fallback: false)!;
    final tz = _zoneField(b) ?? c.zone;
    if (!b.has('start')) throw ApiError.invalid('"start" is required.', field: 'start');
    final start = _when(b, 'start', allDay: allDay, zone: tz);
    final end = b.has('end') && b['end'] != null ? _when(b, 'end', allDay: allDay, zone: tz, end: true) : null;
    if (end != null && _ms(end, tz, end: true) < _ms(start, tz)) {
      throw ApiError.invalid('The end is before the start.', field: 'end');
    }
    final rides = _rides(c, b);
    final result = await _act(c, 'create_event', {
      'title': title,
      'start': start,
      'end': ?end,
      'all_day': allDay,
      'tz': tz,
      'repeat': ?_rule(b, 'rrule'),
      'people': _members(c, b, 'assignees') ?? const <String>[],
      'category': ?_category(c, b),
      'location': b.string('location', max: 300) ?? '',
      'notes': b.string('notes', max: 5000) ?? '',
      'reminders': b.ints('reminders', min: 0, maxValue: 40320) ?? const <int>[],
      'rides': ?rides,
      'countdown': b.flag('countdown', fallback: false)!,
      'who_can_see': _audience(c, b),
    });
    return jsonResponse({'event': result.data['event']}, status: 201);
  }

  (EditScope, int?) _scope(Call c, Event e) {
    final raw = c.query['scope'] ?? 'all';
    final scope = EditScope.values.firstWhereOrNull((s) => s.name == raw);
    if (scope == null) throw ApiError.invalid('"scope" must be one, following or all.', field: 'scope');
    final occurrenceRaw = c.query['occurrence'];
    int? occurrence;
    if (occurrenceRaw != null && occurrenceRaw.trim().isNotEmpty) {
      try {
        occurrence = parseInstant(occurrenceRaw, zoneOfEvent(e, c.zone));
      } on FormatException {
        throw ApiError.invalid('"occurrence" must be the occurrence\'s "occurrence" value.', field: 'occurrence');
      }
    }
    if (e.rrule == null) return (EditScope.all, null);
    if (scope != EditScope.all && occurrence == null) {
      throw ApiError.invalid('Say which occurrence with "occurrence".', field: 'occurrence');
    }
    if (occurrence != null && !isOccurrenceOf(e, c.zone, occurrence)) {
      throw ApiError.invalid('That isn\'t an occurrence of this event.', field: 'occurrence');
    }
    return (scope, occurrence);
  }

  /// `PATCH /api/v1/events/{id}`.
  Future<Response> updateEvent(Call c, String id) async {
    final e = _visibleEvent(c, id);
    if (e.source.readOnly) throw ApiError.readOnly();
    final (scope, occurrence) = _scope(c, e);
    final b = Body(await readJsonObject(c.request));
    final allDay = b.flag('all_day');
    final tz = _zoneField(b);
    final zone = tz ?? zoneOfEvent(e, c.zone);
    final targetAllDay = allDay ?? e.allDay;
    if (allDay != null && allDay != e.allDay && !b.has('start')) {
      throw ApiError.invalid('Switching all-day needs a "start" in the new form.', field: 'start');
    }
    final args = <String, Object?>{};
    if (b.has('title')) args['title'] = b.string('title', min: 1, max: 200)!.trim();
    if (b.has('notes')) args['notes'] = b.string('notes', max: 5000, nullable: true) ?? '';
    if (b.has('location')) args['location'] = b.string('location', max: 300, nullable: true) ?? '';
    if (b.has('category')) args['category'] = _category(c, b) ?? '';
    if (allDay != null) args['all_day'] = allDay;
    if (tz != null) args['tz'] = tz;
    if (b.has('rrule')) {
      if (scope == EditScope.one && e.rrule != null) {
        throw ApiError.invalid('A repeat rule can\'t change for one occurrence.', field: 'rrule');
      }
      args['repeat'] = _rule(b, 'rrule') ?? 'none';
    }
    if (b.has('assignees')) args['people'] = _members(c, b, 'assignees') ?? const <String>[];
    if (b.has('reminders')) args['reminders'] = b.ints('reminders', min: 0, maxValue: 40320) ?? const <int>[];
    if (b.has('rides')) args['rides'] = _rides(c, b) ?? const <Map<String, Object?>>[];
    if (b.has('countdown')) args['countdown'] = b.flag('countdown')!;
    if (b.has('start') && b['start'] != null) args['start'] = _when(b, 'start', allDay: targetAllDay, zone: zone);
    if (b.has('end') && b['end'] != null) args['end'] = _when(b, 'end', allDay: targetAllDay, zone: zone, end: true);
    final start = args['start'], end = args['end'];
    if (start != null && end != null && _ms(end, zone, end: true) < _ms(start, zone)) {
      throw ApiError.invalid('The end is before the start.', field: 'end');
    }
    if (args.isNotEmpty) {
      await _act(c, 'update_event', {
        'event': id,
        'scope': scope.name,
        'occurrence': ?occurrence,
        ...args,
      });
    }
    return jsonResponse({'ok': true});
  }

  /// `DELETE /api/v1/events/{id}`.
  Future<Response> deleteEvent(Call c, String id) async {
    final e = _visibleEvent(c, id);
    if (e.source.readOnly) throw ApiError.readOnly();
    final (scope, occurrence) = _scope(c, e);
    await _act(c, 'delete_event', {'event': id, 'scope': scope.name, 'occurrence': ?occurrence});
    return jsonResponse({'ok': true});
  }

  // ------------------------------------------------------------------ chores

  Chore _visibleChore(Call c, String id) {
    final chore = c.den.chore(id);
    if (chore == null || !c.canSee(chore.space)) throw ApiError.notFound(type: 'chore', id: id);
    return chore;
  }

  String _date(Call c, Body b) {
    final raw = b['date'];
    if (raw == null) return c.den.todayDate();
    if (raw is! String || !isDate(raw.trim())) throw ApiError.invalid('"date" must be a date like 2026-10-17.', field: 'date');
    return raw.trim();
  }

  /// Who to credit: the token's member by default, a member id, or `"nobody"` for null.
  String? _credit(Call c, Body b) {
    if (!b.has('member')) return null;
    final who = b['member'];
    if (who == null) return 'nobody';
    if (who is! String || c.den.member(who) == null) {
      throw ApiError.invalid('There\'s nobody with that id in the family.', field: 'member');
    }
    return who;
  }

  void _scheduled(Call c, Chore chore, String date) {
    final day = c.den.choresOn(date).firstWhereOrNull((cd) => cd.chore.id == chore.id && cd.date == date);
    if (day == null) {
      throw ApiError.notFound(type: 'chore', id: chore.id, message: '${chore.title} isn\'t on $date.');
    }
  }

  /// `POST /api/v1/chores/{id}/complete`.
  Future<Response> completeChore(Call c, String id) async {
    final chore = _visibleChore(c, id);
    final b = Body(await readJsonObject(c.request));
    final date = _date(c, b);
    final done = b.flag('done', fallback: true)!;
    final who = _credit(c, b);
    _scheduled(c, chore, date);
    final result = await _act(c, 'complete_chore', {'chore': id, 'date': date, 'done': done, 'person': ?who});
    return jsonResponse({'chore': result.data['chore']});
  }

  /// `POST /api/v1/chores/{id}/steps/{stepId}`.
  Future<Response> checkStep(Call c, String id, String stepId) async {
    final chore = _visibleChore(c, id);
    if (!chore.steps.any((s) => s.id == stepId)) throw ApiError.notFound(type: 'step', id: stepId);
    final b = Body(await readJsonObject(c.request));
    final date = _date(c, b);
    final checked = b.flag('checked', fallback: true)!;
    final who = _credit(c, b);
    _scheduled(c, chore, date);
    final result = await _act(c, 'complete_chore', {'chore': id, 'step': stepId, 'date': date, 'done': checked, 'person': ?who});
    return jsonResponse({'chore': result.data['chore']});
  }

  // ------------------------------------------------------------------ lists

  ListState _visibleList(Call c, String id) {
    final l = c.den.list(id);
    if (l == null || !c.canSee(l.list.space)) throw ApiError.notFound(type: 'list', id: id);
    return l;
  }

  void _visibleItem(Call c, String id) {
    for (final l in c.den.lists) {
      if (!c.canSee(l.list.space)) continue;
      if (l.items.any((i) => i.id == id)) return;
    }
    throw ApiError.notFound(type: 'item', id: id);
  }

  Map<String, Object?> _itemInput(Body b, {String prefix = ''}) {
    try {
      return {
        'text': b.string('text', required: true, min: 1, max: 200)!.trim(),
        'qty': b.string('qty', max: 40, nullable: true),
        'store': b.string('store', max: 60, nullable: true),
        'to_groceries': b.flag('to_groceries', fallback: false)!,
      };
    } on ApiError catch (e) {
      final f = e.details?['field'];
      throw ApiError.invalid(e.message, field: f == null ? null : '$prefix$f');
    }
  }

  /// `POST /api/v1/lists/{id}/items`.
  Future<Response> addItems(Call c, String listId) async {
    _visibleList(c, listId);
    final b = Body(await readJsonObject(c.request, required: true));
    if (b.has('items')) {
      final raw = b['items'];
      if (raw is! List || raw.isEmpty || raw.length > 100) {
        throw ApiError.invalid('"items" must hold 1 to 100 items.', field: 'items');
      }
      final inputs = [
        for (var i = 0; i < raw.length; i++)
          if (raw[i] is Map)
            _itemInput(Body((raw[i] as Map).cast<String, Object?>()), prefix: 'items[$i].')
          else
            throw ApiError.invalid('Each item is an object with "text".', field: 'items[$i]'),
      ];
      final result = await _act(c, 'add_items', {'list': listId, 'items': inputs});
      return jsonResponse({'items': result.data['items']}, status: 201);
    }
    final result = await _act(c, 'add_items', {
      'list': listId,
      'items': [_itemInput(b)],
    });
    return jsonResponse({'item': (result.data['items'] as List).single}, status: 201);
  }

  /// `PATCH /api/v1/items/{id}`.
  Future<Response> updateItem(Call c, String id) async {
    _visibleItem(c, id);
    final b = Body(await readJsonObject(c.request));
    final entry = <String, Object?>{'item': id};
    if (b.has('text')) entry['text'] = b.string('text', min: 1, max: 200)!.trim();
    if (b.has('qty')) entry['qty'] = b.string('qty', max: 40, nullable: true) ?? '';
    if (b.has('store')) entry['store'] = b.string('store', max: 60, nullable: true) ?? '';
    final checked = b.flag('checked');
    if (checked != null) entry['checked'] = checked;
    final move = b.object('move');
    if (b.has('move') && move == null) throw ApiError.invalid('"move" must be an object.', field: 'move');
    if (move != null) entry.addAll(_move(c, id, move));
    final result = await _act(c, 'update_items', {
      'items': [entry],
    });
    return jsonResponse({'item': result.data['item']});
  }

  Map<String, Object?> _move(Call c, String id, Map<String, Object?> move) {
    final hasAfter = move.containsKey('after'), hasBefore = move.containsKey('before');
    final after = move['after'], before = move['before'];
    if ((after != null && after is! String) || (before != null && before is! String) || (!hasAfter && !hasBefore)) {
      throw ApiError.invalid('"move" is {"after": item id or null, "before": item id or null}.', field: 'move');
    }
    final list = c.den.lists.firstWhere((l) => l.items.any((i) => i.id == id));
    final others = list.items.where((i) => i.id != id).toList();
    for (final n in [after, before]) {
      if (n != null && !others.any((i) => i.id == n)) {
        throw ApiError.invalid('Neighbors must be other items on the same list.', field: 'move');
      }
    }
    if (hasAfter && after == null && !hasBefore) return {'move': 'top'};
    if (hasBefore && before == null && !hasAfter) return {'move': 'bottom'};
    return {'after': ?after, 'before': ?before};
  }

  /// `DELETE /api/v1/items/{id}`.
  Future<Response> deleteItem(Call c, String id) async {
    _visibleItem(c, id);
    await _act(c, 'remove_items', {
      'items': [id],
    });
    return jsonResponse({'ok': true});
  }

  // ------------------------------------------------------------------ points

  /// `POST /api/v1/points/adjust`.
  Future<Response> adjustPoints(Call c) async {
    final b = Body(await readJsonObject(c.request, required: true));
    final member = b.string('member', required: true, min: 1, max: 80)!;
    if (c.den.member(member) == null) throw ApiError.invalid('There\'s nobody with that id in the family.', field: 'member');
    final delta = b.integer('delta', required: true, min: -10000, max: 10000)!;
    if (delta == 0) throw ApiError.invalid('"delta" can\'t be zero.', field: 'delta');
    final reason = b.string('reason', required: true, min: 1, max: 200)!.trim();
    final result = await _act(c, 'adjust_points', {'person': member, 'delta': delta, 'reason': reason});
    final made = c.den.historyOf(result.receipt?.changes ?? const []).firstOrNull;
    return jsonResponse({
      'adjustment': {'id': made?.rid, 'member': member, 'delta': delta, 'reason': reason, 'by': c.access.member},
      'balance': result.data['balance'],
    }, status: 201);
  }
}
