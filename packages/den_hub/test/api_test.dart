@Timeout(Duration(seconds: 90))
library;

import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'support/test.dart';

import 'support/fixture.dart';

void main() {
  late HubFixture f;
  late String all;
  late String readOnly;

  setUpAll(() async {
    f = await HubFixture.start();
    all = await f.token(scopes: {Scope.admin}, label: 'Home Assistant');
    readOnly = await f.token(scopes: {Scope.read}, label: 'Reader');
  });

  tearDownAll(() => f.stop());

  String eventId(String title) => f.phone.events.firstWhere((e) => e.title == title).id;
  String choreId(String title, [String? owner]) => f.phone.chores
      .firstWhere((c) => c.title == title && (owner == null || (c.owner is OwnerMember && (c.owner as OwnerMember).id == f.id(owner))))
      .id;
  String listId(String title) => f.phone.lists.firstWhere((l) => l.list.title == title).list.id;

  group('conventions', () {
    test('/health needs no token and carries no family data', () async {
      final r = await f.call('GET', '/health');
      expect(r.status, 200);
      expect(r.body, {
        'ok': true,
        'version': hubVersion,
        'api': 1,
        'device': f.hubDen.deviceId,
        'name': 'Kitchen hub',
        'ready': true,
      });
    });

    test('no token, a bad token and a revoked token get 401 with WWW-Authenticate', () async {
      for (final token in [null, 'den_nope']) {
        final r = await f.call('GET', '/api/v1/members', token: token);
        expect(r.status, 401);
        expect(r.headers['www-authenticate'], 'Bearer');
        expect(r.error['code'], 'unauthorized');
        expect(r.error['message'], isA<String>());
      }
      final doomed = await f.token(label: 'Doomed');
      expect((await f.call('GET', '/api/v1/members', token: doomed)).status, 200);
      final id = f.phone.connections.firstWhere((c) => c.label == 'Doomed').id;
      await f.phone.revokeConnection(id);
      await f.toHub();
      expect((await f.call('GET', '/api/v1/members', token: doomed)).status, 401);
    });

    test('an expired token gets 401', () async {
      final old = await f.token(label: 'Old', expires: DateTime.now().millisecondsSinceEpoch - 1000);
      expect((await f.call('GET', '/api/v1/members', token: old)).status, 401);
    });

    test('a missing scope is 403 insufficient_scope naming it', () async {
      final r = await f.call('POST', '/api/v1/lists/${listId('Groceries')}/items', token: readOnly, body: {'text': 'Milk'});
      expect(r.status, 403);
      expect(r.error['code'], 'insufficient_scope');
      expect(r.error['details'], {'scope': 'lists'});
    });

    test('unknown routes are 404 not_found; wrong methods are 405 with Allow', () async {
      final missing = await f.call('GET', '/api/v1/nothing', token: all);
      expect(missing.status, 404);
      expect(missing.error['code'], 'not_found');
      final wrong = await f.call('PUT', '/api/v1/events', token: all);
      expect(wrong.status, 405);
      expect(wrong.error['code'], 'method_not_allowed');
      expect(wrong.headers['allow'], 'GET, POST');
    });

    test('bodies over 256 KiB are 413; malformed JSON is 400', () async {
      final big = await f.call('POST', '/api/v1/events', token: all, body: '{"title": "${'x' * 300000}"}');
      expect(big.status, 413);
      expect(big.error['code'], 'too_large');
      final bad = await f.call('POST', '/api/v1/events', token: all, body: '{not json');
      expect(bad.status, 400);
      expect(bad.error['code'], 'invalid_input');
    });
  });

  group('members', () {
    test('family, token, members in order without sign-in secrets, categories', () async {
      final r = await f.call('GET', '/api/v1/members', token: all);
      expect(r.status, 200);
      final body = r.body;
      expect(body['hub'], {'device': f.hubDen.deviceId, 'name': 'Kitchen hub', 'version': hubVersion});
      expect((body['family'] as Map)['timezone'], 'America/Chicago');
      // A token acts as the parent who made it (MCP eval #4).
      expect(body['token'], {'label': 'Home Assistant', 'member': f.id('Alex'), 'scopes': ['admin'], 'expires': null, 'expires_ms': null});
      final members = (body['members'] as List).cast<Map<String, Object?>>();
      expect(members.map((m) => m['name']), ['Alex', 'Priya', 'Maya', 'Leo', 'Zoe', 'Grandma Rosa']);
      expect(members.first.keys.toSet(), {'id', 'name', 'role', 'tier', 'marker', 'picture', 'animal', 'birthday', 'until', 'grants', 'order'});
      expect(r.text, isNot(contains('salt')));
      expect(r.text, isNot(contains('hash')));
      expect((body['categories'] as List).length, 6);
    });
  });

  group('events', () {
    test('a window of occurrences with every field, private ones only for who may read them', () async {
      final start = f.phone.dayStart(f.phone.todayDate());
      final r = await f.call('GET', '/api/v1/events?start=$start&end=${start + 14 * 86400000}', token: all);
      expect(r.status, 200);
      final events = (r.body['events'] as List).cast<Map<String, Object?>>();
      expect(r.body['timezone'], 'America/Chicago');
      expect(r.body['truncated'], isFalse);
      final soccer = events.firstWhere((e) => e['title'] == 'Soccer practice');
      expect(soccer['recurring'], isTrue);
      expect(soccer['uid'], '${soccer['event_id']}@${soccer['occurrence']}');
      expect(soccer['start_ms'], soccer['occurrence']);
      expect(soccer['start'], matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d-0[56]:00$')));
      expect(soccer['rides'], [{'leg': 'to', 'driver': f.id('Priya')}, {'leg': 'from', 'driver': null}]);
      expect(soccer['source'], {'kind': 'manual', 'label': null});
      expect(soccer['audience'], 'everyone');
      expect(events.any((e) => e['title'] == 'Anniversary dinner' && e['audience'] == 'parents'), isTrue);

      final leo = await f.token(scopes: {Scope.read, Scope.calendar}, member: f.id('Leo'), label: 'Leo');
      final kid = await f.call('GET', '/api/v1/events?start=$start&end=${start + 14 * 86400000}', token: leo);
      expect((kid.body['events'] as List).any((e) => (e as Map)['title'] == 'Anniversary dinner'), isFalse);
      final hidden = await f.call('PATCH', '/api/v1/events/${eventId('Anniversary dinner')}', token: leo, body: {'title': 'x'});
      expect(hidden.status, 404);
      expect(hidden.error['details'], {'type': 'event', 'id': eventId('Anniversary dinner')});
    });

    test('filters by member, limits, and refuses windows over 400 days', () async {
      final leo = f.id('Leo');
      final r = await f.call('GET', '/api/v1/events?member=$leo&limit=1', token: all);
      final events = (r.body['events'] as List).cast<Map<String, Object?>>();
      expect(events, hasLength(1));
      expect(events.single['assignees'], contains(leo));
      final tooLong = await f.call('GET', '/api/v1/events?start=2026-01-01&end=2027-03-01', token: all);
      expect(tooLong.status, 400);
      expect(tooLong.error['details'], {'field': 'end'});
    });

    test('create, change one occurrence, and delete', () async {
      final created = await f.call('POST', '/api/v1/events', token: all, body: {
        'title': 'Piano',
        'start': '2026-11-03T16:00:00',
        'end': '2026-11-03T16:45:00',
        'rrule': 'FREQ=WEEKLY;BYDAY=TU',
        'assignees': [f.id('Maya')],
        'reminders': [30],
      });
      expect(created.status, 201);
      final event = (created.body['event'] as Map).cast<String, Object?>();
      expect(event['start'], '2026-11-03T16:00:00-06:00');
      expect(event['rrule'], 'FREQ=WEEKLY;BYDAY=TU');
      expect(event['read_only'], isFalse);
      final id = event['id'] as String;
      final second = (event['start_ms'] as int) + 7 * 86400000;

      final noOccurrence = await f.call('PATCH', '/api/v1/events/$id?scope=one', token: all, body: {'location': 'Studio B'});
      expect(noOccurrence.status, 400);
      expect(noOccurrence.error['details'], {'field': 'occurrence'});
      final notOne = await f.call('PATCH', '/api/v1/events/$id?scope=one&occurrence=${second + 60000}', token: all, body: {'location': 'x'});
      expect(notOne.error['details'], {'field': 'occurrence'});

      final moved = await f.call('PATCH', '/api/v1/events/$id?scope=one&occurrence=$second',
          token: all, body: {'start': '2026-11-10T17:00:00-06:00', 'end': '2026-11-10T17:45:00-06:00', 'location': 'Studio B'});
      expect(moved.status, 200);
      expect(moved.body, {'ok': true});
      final window = await f.call('GET', '/api/v1/events?start=2026-11-10&end=2026-11-11', token: all);
      final piano = (window.body['events'] as List).cast<Map<String, Object?>>().firstWhere((e) => e['event_id'] == id);
      expect(piano['edited'], isTrue);
      expect(piano['occurrence'], second);
      expect(piano['start'], '2026-11-10T17:00:00-06:00');
      expect(piano['location'], 'Studio B');

      final gone = await f.call('DELETE', '/api/v1/events/$id', token: all);
      expect(gone.status, 200);
      expect(f.hubDen.event(id), isNull);
    });

    test('all-day events take local dates', () async {
      final r = await f.call('POST', '/api/v1/events', token: all, body: {'title': 'Field trip', 'all_day': true, 'start': '2026-11-05'});
      final event = (r.body['event'] as Map).cast<String, Object?>();
      expect(event['start_date'], '2026-11-05');
      expect(event['end_date'], '2026-11-06');
      expect(event['start'], '2026-11-05T00:00:00-06:00');
    });

    test('imported events are read-only', () async {
      final id = await f.hubDen.addEvent(
        title: 'Picture day',
        start: DateTime.utc(2026, 11, 2, 14).millisecondsSinceEpoch,
        end: DateTime.utc(2026, 11, 2, 15).millisecondsSinceEpoch,
        source: const EventSource('ics', 'uid-1', 'School'),
      );
      final r = await f.call('PATCH', '/api/v1/events/$id', token: all, body: {'title': 'Mine now'});
      expect(r.status, 409);
      expect(r.error['code'], 'read_only');
      expect((await f.call('DELETE', '/api/v1/events/$id', token: all)).status, 409);
    });
  });

  group('chores', () {
    test('a day of chores with steps and a summary, sorted by due time', () async {
      final r = await f.call('GET', '/api/v1/chores', token: all);
      expect(r.status, 200);
      final chores = (r.body['chores'] as List).cast<Map<String, Object?>>();
      final dueTimes = [for (final c in chores) c['due_time'] as String? ?? '99:99'];
      expect(dueTimes, [...dueTimes]..sort());
      final dishes = chores.firstWhere((c) => c['title'] == 'Dishes');
      expect((dishes['owner_rule'] as Map)['kind'], 'rotation');
      expect(dishes['step_count'], 3);
      expect(dishes['points_available'], 2);
      expect(dishes['completion_id'], '${dishes['id']}@${r.body['date']}');
      final summary = (r.body['summary'] as Map).cast<String, Object?>();
      expect(summary['total'], chores.length);
      expect((summary['anyone'] as Map)['total'], chores.where((c) => c['owner'] == null).length);
    });

    test('a kid-scoped token completes its own chore but not someone else\'s', () async {
      final leo = await f.token(scopes: {Scope.read, Scope.chores}, member: f.id('Leo'), label: 'Leo tablet');
      final date = f.phone.todayDate();
      final maya = await f.call('POST', '/api/v1/chores/${choreId('Make bed', 'Maya')}/complete', token: leo, body: {'date': date});
      expect(maya.status, 403);
      expect(maya.error['code'], 'permission_denied');
      final own = await f.call('POST', '/api/v1/chores/${choreId('Make bed', 'Leo')}/complete', token: leo, body: {'date': date});
      expect(own.status, 200);
      final chore = (own.body['chore'] as Map).cast<String, Object?>();
      expect(chore['done'], isTrue);
      expect(chore['done_by'], f.id('Leo'));
      final naming = await f.call('POST', '/api/v1/chores/${choreId('Make bed', 'Leo')}/complete',
          token: leo, body: {'date': date, 'member': f.id('Maya')});
      expect(naming.status, 403);
    });

    test('a member-less token may name who did it; steps check and complete', () async {
      final date = f.phone.todayDate();
      final mail = choreId('Bring in the mail');
      final r = await f.call('POST', '/api/v1/chores/$mail/complete', token: all, body: {'member': f.id('Zoe')});
      expect((r.body['chore'] as Map)['done_by'], f.id('Zoe'));
      final dishes = choreId('Dishes');
      final owner = f.hubDen.choresOn(date).firstWhere((c) => c.chore.id == dishes).owner!;
      await f.call('POST', '/api/v1/chores/$dishes/complete', token: all, body: {'done': false});
      for (final step in ['clear', 'load', 'wipe']) {
        final s = await f.call('POST', '/api/v1/chores/$dishes/steps/$step', token: all, body: {'member': owner});
        expect(s.status, 200);
      }
      final after = (await f.call('GET', '/api/v1/chores', token: all)).body['chores'] as List;
      final day = after.cast<Map<String, Object?>>().firstWhere((c) => c['id'] == dishes);
      expect(day['done'], isTrue);
      expect(day['steps_done'], 3);
      expect((day['steps'] as List).first, containsPair('checked_by', owner));
      final unknown = await f.call('POST', '/api/v1/chores/$dishes/steps/nope', token: all, body: {});
      expect(unknown.status, 404);
    });

    test('a chore not on that date is 404', () async {
      final trash = choreId('Take out the trash');
      var d = f.phone.todayDate();
      while (DateTime.parse(d).weekday == DateTime.thursday) {
        d = DateTime.parse(d).add(const Duration(days: 1)).toIso8601String().substring(0, 10);
      }
      final r = await f.call('POST', '/api/v1/chores/$trash/complete', token: all, body: {'date': d});
      expect(r.status, 404);
    });
  });

  group('lists', () {
    test('lists with items and stores; add, check, move and remove items', () async {
      final groceries = listId('Groceries');
      final r = await f.call('GET', '/api/v1/lists', token: all);
      final lists = (r.body['lists'] as List).cast<Map<String, Object?>>();
      final g = lists.firstWhere((l) => l['id'] == groceries);
      expect(g['kind'], 'shopping');
      expect((g['open_by_store'] as Map)['Costco'], isA<int>());
      expect(r.body['stores'], containsAll(['Costco', 'Target']));

      final one = await f.call('POST', '/api/v1/lists/$groceries/items', token: all, body: {'text': 'Butter', 'store': 'Costco'});
      expect(one.status, 201);
      final butter = (one.body['item'] as Map).cast<String, Object?>();
      expect(butter['text'], 'Butter');
      final many = await f.call('POST', '/api/v1/lists/$groceries/items', token: all, body: {
        'items': [{'text': 'Rice'}, {'text': 'Beans', 'qty': '2 cans'}],
      });
      expect((many.body['items'] as List).map((i) => (i as Map)['text']), ['Rice', 'Beans']);
      final tooLong = await f.call('POST', '/api/v1/lists/$groceries/items', token: all, body: {'text': 'x' * 201});
      expect(tooLong.error['details'], {'field': 'text'});

      final alex = await f.token(scopes: {Scope.read, Scope.lists}, member: f.id('Alex'), label: 'Alex script');
      final checked = await f.call('PATCH', '/api/v1/items/${butter['id']}', token: alex, body: {'checked': true});
      expect((checked.body['item'] as Map)['checked'], isTrue);
      expect((checked.body['item'] as Map)['checked_by'], f.id('Alex'));

      final top = await f.call('PATCH', '/api/v1/items/${butter['id']}', token: all, body: {'move': {'after': null}});
      expect(top.status, 200);
      final ordered = f.hubDen.list(groceries)!.items;
      expect(ordered.first.id, butter['id']);

      final removed = await f.call('DELETE', '/api/v1/items/${butter['id']}', token: all);
      expect(removed.body, {'ok': true});
      expect((await f.call('DELETE', '/api/v1/items/${butter['id']}', token: all)).status, 404);
    });
  });

  group('actions', () {
    test('GET /api/v1/actions lists what the token may run, with schemas', () async {
      final r = await f.call('GET', '/api/v1/actions', token: readOnly);
      expect(r.status, 200, reason: r.text);
      final actions = (r.body['actions'] as List).cast<Map<String, Object?>>();
      expect(actions.every((a) => a['effect'] == 'read'), isTrue);
      final overview = actions.firstWhere((a) => a['name'] == 'get_overview');
      expect(overview['scopes'], ['read']);
      expect((overview['input_schema'] as Map)['type'], 'object');
      final writer = await f.call('GET', '/api/v1/actions', token: all);
      expect((writer.body['actions'] as List).map((a) => (a as Map)['name']), contains('add_from_text'));
    });

    test('a Shortcut adds what someone said with add_from_text', () async {
      final shortcut = await f.token(scopes: {Scope.lists}, member: f.id('Priya'), label: 'Siri');
      final r = await f.call('POST', '/api/v1/actions/add_from_text', token: shortcut, body: {'text': 'we need oat milk and coffee filters'});
      expect(r.status, 200, reason: r.text);
      expect(r.body['status'], 'done');
      final added = (((r.body['result'] as Map)['added']) as List).cast<Map>();
      expect(added.map((a) => '${a['title']}'.toLowerCase()), containsAll(['oat milk', 'coffee filters']));
      expect((r.body['receipt'] as Map)['tool'], 'add_from_text');
      expect(f.hubDen.history(type: 'item').first.via, 'Siri');
      final undo = await f.call('POST', '/api/v1/actions/undo', token: shortcut, body: {});
      expect(undo.status, 200, reason: undo.text);
      final items = f.hubDen.lists.expand((l) => l.items).map((i) => i.text.toLowerCase());
      expect(items, isNot(contains('coffee filters')));
    });

    test('preview, a two-step confirmation, idempotent retries and errors', () async {
      final preview = await f.call('POST', '/api/v1/actions/add_items?preview=1',
          token: all, body: {'list': 'Groceries', 'items': ['Flour']});
      expect(preview.body['status'], 'preview');
      expect(f.hubDen.lists.expand((l) => l.items).any((i) => i.text == 'Flour'), isFalse);

      final ask = await f.call('POST', '/api/v1/actions/delete_list', token: all, body: {'list': 'Meal plan'});
      expect(ask.status, 200);
      expect(ask.body['status'], 'needs_confirmation');
      final token = ((ask.body['result'] as Map)['confirm'] as Map)['token'];
      final yes = await f.call('POST', '/api/v1/actions/delete_list', token: all, body: {'list': 'Meal plan', 'confirm': token});
      expect(yes.body['status'], 'done', reason: yes.text);

      final once = await f.call('POST', '/api/v1/actions/adjust_points',
          token: all, body: {'person': 'Zoe', 'delta': 2, 'reason': 'Fed the fish'}, headers: {'idempotency-key': 'zoe-fish-1'});
      final twice = await f.call('POST', '/api/v1/actions/adjust_points',
          token: all, body: {'person': 'Zoe', 'delta': 2, 'reason': 'Fed the fish'}, headers: {'idempotency-key': 'zoe-fish-1'});
      expect(twice.body, once.body);
      expect(twice.headers['idempotent-replayed'], 'true');
      final other = await f.call('POST', '/api/v1/actions/adjust_points',
          token: all, body: {'person': 'Zoe', 'delta': 3, 'reason': 'Fed the fish'}, headers: {'idempotency-key': 'zoe-fish-1'});
      expect(other.status, 409);

      final bad = await f.call('POST', '/api/v1/actions/adjust_points', token: all, body: {'person': 'Zoe', 'delta': 'two', 'reason': 'x'});
      expect(bad.status, 400);
      expect(bad.error['details'], {'field': 'delta'});
      final scope = await f.call('POST', '/api/v1/actions/adjust_points', token: readOnly, body: {'person': 'Zoe', 'delta': 1, 'reason': 'x'});
      expect(scope.status, 403);
      expect(scope.error['code'], 'insufficient_scope');
      final missing = await f.call('POST', '/api/v1/actions/nope', token: all, body: {});
      expect(missing.status, 404);
      final leo = await f.token(scopes: {Scope.admin}, member: f.id('Leo'), label: 'Leo REST');
      final denied = await f.call('POST', '/api/v1/actions/create_event', token: leo, body: {'title': 'Party', 'start': '2026-11-20'});
      expect(denied.status, 403);
      expect(denied.error['code'], 'permission_denied');
    });
  });

  group('points, history and search', () {
    test('points summary and adjustments', () async {
      final r = await f.call('GET', '/api/v1/points?recent=5', token: all);
      expect(r.body['enabled'], isTrue);
      expect((r.body['totals'] as Map).keys, containsAll([f.id('Maya'), f.id('Leo'), f.id('Alex')]));
      expect((r.body['recent'] as List).length, lessThanOrEqualTo(5));
      expect((r.body['rewards'] as List), isNotEmpty);
      final before = (r.body['totals'] as Map)[f.id('Leo')] as int;
      final adjusted = await f.call('POST', '/api/v1/points/adjust',
          token: all, body: {'member': f.id('Leo'), 'delta': 5, 'reason': 'Helped carry the groceries'});
      expect(adjusted.status, 201);
      expect(adjusted.body['balance'], before + 5);
      expect((adjusted.body['adjustment'] as Map)['id'], isA<String>());
      expect((adjusted.body['adjustment'] as Map)['by'], f.id('Alex'), reason: 'the token acts as the parent who made it');
      final zero = await f.call('POST', '/api/v1/points/adjust', token: all, body: {'member': f.id('Leo'), 'delta': 0, 'reason': 'x'});
      expect(zero.error['details'], {'field': 'delta'});
    });

    test('history shows the token label as via, filtered to readable spaces', () async {
      await f.call('POST', '/api/v1/lists/${listId('Groceries')}/items', token: all, body: {'text': 'Lemons'});
      final r = await f.call('GET', '/api/v1/history?type=item&limit=5', token: all);
      final entry = ((r.body['entries'] as List).first as Map).cast<String, Object?>();
      expect(entry['via'], 'Home Assistant');
      expect(entry['device'], f.hubDen.deviceId);
      expect(entry['actor'], f.id('Alex'), reason: 'the token acts as the parent who made it');
      expect(entry['hlc'], startsWith('${entry['when_ms']}'.padLeft(13, '0')));
      final leo = await f.token(member: f.id('Leo'), label: 'Leo reader');
      final kid = await f.call('GET', '/api/v1/history?limit=200', token: leo);
      expect((kid.body['entries'] as List).every((e) => (e as Map)['space'] != 'p'), isTrue);
    });

    test('search finds records and hides private ones', () async {
      final r = await f.call('GET', '/api/v1/search?q=Anniversary', token: all);
      expect((r.body['results'] as List).any((h) => (h as Map)['type'] == 'event'), isTrue);
      final leo = await f.token(member: f.id('Leo'), label: 'Leo search');
      final kid = await f.call('GET', '/api/v1/search?q=Anniversary', token: leo);
      expect(kid.body['results'], isEmpty);
      expect((await f.call('GET', '/api/v1/search', token: all)).error['details'], {'field': 'q'});
    });

    test('today brings events, chores, lists and gaps together', () async {
      final r = await f.call('GET', '/api/v1/today', token: all);
      expect(r.body['date'], f.phone.todayDate());
      expect((r.body['events'] as List).any((e) => (e as Map)['title'] == 'Swim lesson'), isTrue);
      expect((r.body['lists'] as List).any((l) => (l as Map)['title'] == 'Groceries'), isTrue);
      final gaps = (r.body['gaps'] as List).cast<Map<String, Object?>>();
      expect(gaps.any((g) => g['kind'] == 'no_driver'), isTrue);
      expect((r.body['chore_summary'] as Map)['total'], (r.body['chores'] as List).length);
    });
  });
}
