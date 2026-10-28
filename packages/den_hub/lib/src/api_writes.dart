import 'package:collection/collection.dart';
import 'package:den_actions/den_actions.dart';
import 'package:den_actions/times.dart';
import 'package:den_core/den_core.dart';
import 'package:shelf/shelf.dart';

import 'api.dart';
import 'body.dart';
import 'http_util.dart';

/// The `/api/v1` writes.
class RestWrites {
  /// Creates the writes for [api].
  RestWrites(this.api);

  /// The API these belong to.
  final RestApi api;

  // ------------------------------------------------------------------ events

  Event _visibleEvent(Call c, String id) {
    final e = c.den.event(id);
    if (e == null || !c.canSee(e.space)) throw ApiError.notFound(type: 'event', id: id);
    return e;
  }

  int _when(Body b, String key, {required bool allDay, required String zone}) {
    try {
      if (allDay) return midnightIn(zone, parseDateLike(b[key], zone));
      return parseInstant(b[key], zone);
    } on FormatException {
      throw ApiError.invalid(
        allDay ? '"$key" must be a date like 2026-10-20.' : '"$key" must be a time like 2026-10-20T15:00:00-05:00.',
        field: key,
      );
    }
  }

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

  List<Ride>? _rides(Call c, Body b) {
    final raw = b['rides'];
    if (raw == null) {
      if (b.has('rides')) throw ApiError.invalid('"rides" must be a list.', field: 'rides');
      return null;
    }
    if (raw is! List || raw.length > 4) throw ApiError.invalid('"rides" must be a list of up to 4 legs.', field: 'rides');
    return [
      for (final r in raw)
        if (r is Map && (r['leg'] == 'to' || r['leg'] == 'from') && (r['driver'] == null || c.den.member('${r['driver']}') != null))
          Ride(r['leg'] as String, r['driver'] as String?)
        else
          throw ApiError.invalid('Each ride is {"leg": "to" or "from", "driver": a member id or null}.', field: 'rides'),
    ];
  }

  String? _category(Call c, Body b) {
    final id = b.string('category', max: 80, nullable: true);
    if (id != null && c.den.category(id) == null) throw ApiError.invalid('There\'s no category with that id.', field: 'category');
    return id;
  }

  String _space(Call c, Body b) {
    final space = b.string('space', max: 82) ?? Space.family;
    final valid = space == Space.family ||
        space == Space.parents ||
        (Space.isMember(space) && c.den.member(Space.memberOf(space)!) != null);
    if (!valid) throw ApiError.invalid('"space" must be "f", "p" or "m:<member id>".', field: 'space');
    if (!c.canSee(space)) throw ApiError.denied('This token can\'t see that space, so it can\'t write there.');
    return space;
  }

  /// `POST /api/v1/events`.
  Future<Response> createEvent(Call c) async {
    final b = Body(await readJsonObject(c.request, required: true));
    final title = b.string('title', required: true, min: 1, max: 200)!.trim();
    final allDay = b.flag('all_day', fallback: false)!;
    final tz = _zoneField(b) ?? c.zone;
    if (!b.has('start')) throw ApiError.invalid('"start" is required.', field: 'start');
    final start = _when(b, 'start', allDay: allDay, zone: tz);
    final end = b.has('end') && b['end'] != null
        ? _when(b, 'end', allDay: allDay, zone: tz)
        : allDay
            ? midnightIn(tz, addDays(dateIn(tz, start), 1))
            : start + Duration.millisecondsPerHour;
    if (end < start) throw ApiError.invalid('The end is before the start.', field: 'end');
    final space = _space(c, b);
    final id = await c.den.addEvent(
      title: title,
      start: start,
      end: end,
      allDay: allDay,
      tz: tz,
      rrule: _rule(b, 'rrule'),
      assignees: _members(c, b, 'assignees') ?? const [],
      category: _category(c, b),
      location: b.string('location', max: 300) ?? '',
      notes: b.string('notes', max: 5000) ?? '',
      reminders: b.ints('reminders', min: 0, maxValue: 40320) ?? const [],
      rides: _rides(c, b) ?? const [],
      countdown: b.flag('countdown', fallback: false)!,
      space: space,
    );
    return jsonResponse({'event': c.wire.event(c.den.event(id)!)}, status: 201);
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
    final patch = <String, Object?>{};
    final allDay = b.flag('all_day');
    final tz = _zoneField(b);
    final zone = tz ?? zoneOfEvent(e, c.zone);
    final targetAllDay = allDay ?? e.allDay;
    if (allDay != null && allDay != e.allDay && !b.has('start')) {
      throw ApiError.invalid('Switching all-day needs a "start" in the new form.', field: 'start');
    }
    if (b.has('title')) patch['title'] = b.string('title', min: 1, max: 200)!.trim();
    if (b.has('notes')) patch['notes'] = b.string('notes', max: 5000, nullable: true) ?? '';
    if (b.has('location')) patch['location'] = b.string('location', max: 300, nullable: true) ?? '';
    if (b.has('category')) patch['category'] = _category(c, b);
    if (allDay != null) patch['allDay'] = allDay;
    if (tz != null) patch['tz'] = tz;
    if (b.has('rrule')) {
      if (scope == EditScope.one && e.rrule != null) {
        throw ApiError.invalid('A repeat rule can\'t change for one occurrence.', field: 'rrule');
      }
      patch['rrule'] = _rule(b, 'rrule');
    }
    if (b.has('assignees')) patch['assignees'] = _members(c, b, 'assignees') ?? const <String>[];
    if (b.has('reminders')) patch['reminders'] = b.ints('reminders', min: 0, maxValue: 40320) ?? const <int>[];
    if (b.has('rides')) patch['rides'] = [for (final r in _rides(c, b) ?? const <Ride>[]) {'leg': r.leg, 'driver': r.driver}];
    if (b.has('countdown')) patch['countdown'] = b.flag('countdown')!;
    if (b.has('start') && b['start'] != null) patch['start'] = _when(b, 'start', allDay: targetAllDay, zone: zone);
    if (b.has('end') && b['end'] != null) patch['end'] = _when(b, 'end', allDay: targetAllDay, zone: zone);
    if (patch['start'] is int && patch['end'] is int && (patch['end'] as int) < (patch['start'] as int)) {
      throw ApiError.invalid('The end is before the start.', field: 'end');
    }
    if (patch.isNotEmpty) await c.den.updateEvent(id, patch, scope: scope, occurrence: occurrence);
    return jsonResponse({'ok': true});
  }

  /// `DELETE /api/v1/events/{id}`.
  Future<Response> deleteEvent(Call c, String id) async {
    final e = _visibleEvent(c, id);
    if (e.source.readOnly) throw ApiError.readOnly();
    final (scope, occurrence) = _scope(c, e);
    await c.den.deleteEvent(id, scope: scope, occurrence: occurrence);
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

  String? _credit(Call c, Body b) {
    if (!b.has('member')) return c.access.member;
    final who = b['member'];
    if (who == null) return null;
    if (who is! String || c.den.member(who) == null) {
      throw ApiError.invalid('There\'s nobody with that id in the family.', field: 'member');
    }
    return who;
  }

  ChoreDay _scheduled(Call c, Chore chore, String date) {
    final day = c.den.choresOn(date).firstWhereOrNull((cd) => cd.chore.id == chore.id && cd.date == date);
    if (day == null) {
      throw ApiError.notFound(type: 'chore', id: chore.id, message: '${chore.title} isn\'t on $date.');
    }
    return day;
  }

  Response _choreResponse(Call c, String id, String date) {
    final day = c.den.choresOn(date).firstWhereOrNull((cd) => cd.chore.id == id && cd.date == date);
    if (day == null) throw ApiError.notFound(type: 'chore', id: id);
    return jsonResponse({'chore': c.wire.choreDay(day)});
  }

  /// `POST /api/v1/chores/{id}/complete`.
  Future<Response> completeChore(Call c, String id) async {
    final chore = _visibleChore(c, id);
    final b = Body(await readJsonObject(c.request));
    final date = _date(c, b);
    final done = b.flag('done', fallback: true)!;
    final who = _credit(c, b);
    _scheduled(c, chore, date);
    if (who == c.access.member) {
      await c.den.setChoreDone(id, date, done);
    } else {
      await c.den.setChoreDoneBy(id, date, done, who);
    }
    return _choreResponse(c, id, date);
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
    if (who == c.access.member) {
      await c.den.setStep(id, date, stepId, checked);
    } else {
      await c.den.setStepBy(id, date, stepId, checked, who);
    }
    return _choreResponse(c, id, date);
  }

  // ------------------------------------------------------------------ lists

  ListState _visibleList(Call c, String id) {
    final l = c.den.list(id);
    if (l == null || !c.canSee(l.list.space)) throw ApiError.notFound(type: 'list', id: id);
    return l;
  }

  (ListState, Item) _visibleItem(Call c, String id) {
    for (final l in c.den.lists) {
      if (!c.canSee(l.list.space)) continue;
      final item = l.items.firstWhereOrNull((i) => i.id == id);
      if (item != null) return (l, item);
    }
    throw ApiError.notFound(type: 'item', id: id);
  }

  Item _itemNow(Call c, String listId, String itemId) =>
      c.den.list(listId)?.items.firstWhereOrNull((i) => i.id == itemId) ?? (throw ApiError.notFound(type: 'item', id: itemId));

  ({String text, String? qty, String? store, bool toGroceries}) _itemInput(Body b, {String prefix = ''}) {
    String field(String k) => '$prefix$k';
    try {
      return (
        text: b.string('text', required: true, min: 1, max: 200)!.trim(),
        qty: b.string('qty', max: 40, nullable: true),
        store: b.string('store', max: 60, nullable: true),
        toGroceries: b.flag('to_groceries', fallback: false)!,
      );
    } on ApiError catch (e) {
      final f = e.details?['field'];
      throw ApiError.invalid(e.message, field: f == null ? null : field('$f'));
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
      final ids = <String>[];
      for (final input in inputs) {
        ids.add(await c.den.addItem(listId, text: input.text, qty: input.qty, store: input.store, toGroceries: input.toGroceries));
      }
      return jsonResponse({
        'items': [for (final id in ids) Wire.item(_itemNow(c, listId, id))],
      }, status: 201);
    }
    final input = _itemInput(b);
    final id = await c.den.addItem(listId, text: input.text, qty: input.qty, store: input.store, toGroceries: input.toGroceries);
    return jsonResponse({'item': Wire.item(_itemNow(c, listId, id))}, status: 201);
  }

  /// `PATCH /api/v1/items/{id}`.
  Future<Response> updateItem(Call c, String id) async {
    final (list, item) = _visibleItem(c, id);
    final b = Body(await readJsonObject(c.request));
    final fields = <String, Object?>{};
    if (b.has('text')) fields['text'] = b.string('text', min: 1, max: 200)!.trim();
    if (b.has('qty')) fields['qty'] = b.string('qty', max: 40, nullable: true);
    if (b.has('store')) fields['store'] = b.string('store', max: 60, nullable: true);
    final checked = b.flag('checked');
    final move = b.object('move');
    if (b.has('move') && move == null) throw ApiError.invalid('"move" must be an object.', field: 'move');
    if (fields.isNotEmpty) await c.den.updateItem(id, fields);
    if (checked != null && checked != item.checked) await c.den.setItemChecked(id, checked);
    if (move != null) await _move(c, list.list.id, id, move);
    return jsonResponse({'item': Wire.item(_itemNow(c, list.list.id, id))});
  }

  Future<void> _move(Call c, String listId, String id, Map<String, Object?> move) async {
    final hasAfter = move.containsKey('after'), hasBefore = move.containsKey('before');
    final after = move['after'], before = move['before'];
    if ((after != null && after is! String) || (before != null && before is! String) || (!hasAfter && !hasBefore)) {
      throw ApiError.invalid('"move" is {"after": item id or null, "before": item id or null}.', field: 'move');
    }
    final others = (c.den.list(listId)?.items ?? const <Item>[]).where((i) => i.id != id).toList();
    for (final n in [after, before]) {
      if (n != null && !others.any((i) => i.id == n)) {
        throw ApiError.invalid('Neighbors must be other items on the same list.', field: 'move');
      }
    }
    String? a = after as String?, z = before as String?;
    if (hasAfter && after == null && !hasBefore) z = others.firstOrNull?.id;
    if (hasBefore && before == null && !hasAfter) a = others.lastOrNull?.id;
    if (a == null && z == null) return;
    await c.den.moveItem(id, after: a, before: z);
  }

  /// `DELETE /api/v1/items/{id}`.
  Future<Response> deleteItem(Call c, String id) async {
    _visibleItem(c, id);
    await c.den.removeItem(id);
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
    if (!(c.den.family?.pointsEnabled ?? true)) throw ApiError.invalid('Points are turned off for this family.');
    final before = {
      for (final l in c.den.points().recent)
        if (l.source == PointsSource.adjustment) l.ref,
    };
    await c.den.adjustPoints(member, delta, reason);
    final summary = c.den.points();
    final line = summary.recent.firstWhereOrNull((l) =>
        l.source == PointsSource.adjustment && !before.contains(l.ref) && l.member == member && l.delta == delta);
    return jsonResponse({
      'adjustment': {'id': line?.ref, 'member': member, 'delta': delta, 'reason': reason, 'by': c.access.member},
      'balance': summary.totals[member] ?? 0,
    }, status: 201);
  }
}
