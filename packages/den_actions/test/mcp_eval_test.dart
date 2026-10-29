/// Regressions for what an assistant found testing Den's MCP server end to end against a live
/// hub (MCP-EVAL, numbered as that report numbers them), where the fix is an action's.
@Timeout(Duration(minutes: 5))
library;

import 'package:den_actions/den_actions.dart';
import 'package:den_actions/times.dart';
import 'package:den_core/den_core.dart';

import 'support.dart';

void main() {
  annotateFailures();
  late Den den;
  late ActionRunner runner;
  late String alex;
  late String maya;
  late String leo;
  late String zoe;

  setUp(() async {
    den = await demoFamily();
    runner = standardRunner();
    alex = den.actor!.id;
    maya = idOf(den, 'Maya');
    leo = idOf(den, 'Leo');
    zoe = idOf(den, 'Zoe');
  });

  tearDown(() => den.close());

  ActionContext mcp({String? viewZone}) => ActionContext(den, member: alex, surface: Surface.mcp, caller: 'grok', viewZone: viewZone);
  ActionContext app() => ActionContext(den, member: alex, surface: Surface.app, caller: 'app');

  Future<ActionResult> call(String name, Map<String, Object?> args, {ActionContext? on, RunMode mode = RunMode.run}) =>
      runner.run(on ?? mcp(), name, args, mode: mode);

  /// [call], saying yes when it asks first.
  Future<ActionResult> yes(String name, Map<String, Object?> args, {ActionContext? on}) async {
    final first = await call(name, args, on: on);
    if (first.status != ActionStatus.needsConfirmation) return first;
    return call(name, {...args, 'confirm': (first.data['confirm'] as Map)['token']}, on: on);
  }

  String today() => den.todayDate();
  String zone() => den.family!.timezone;

  /// The first day at least [after] days from today that is ISO weekday [weekday].
  String next(int weekday, {int after = 1}) {
    var d = addDays(today(), after);
    while (weekdayOfDate(d) != weekday) {
      d = addDays(d, 1);
    }
    return d;
  }

  /// The next Soccer practice day (Tuesdays and Thursdays) at least [after] days away.
  String soccerDay({int after = 1}) {
    var d = addDays(today(), after);
    while (weekdayOfDate(d) != 2 && weekdayOfDate(d) != 4) {
      d = addDays(d, 1);
    }
    return d;
  }

  test('#1 add_from_text adds what a sentence says for the person it acts as, and fails saying why when it adds nothing', () async {
    final added = await call('add_from_text', {'text': 'Haircut for Leo next Friday at 3', 'include_unsure': true});
    expect(added.isError, isFalse, reason: added.text);
    final events = (added.data['added'] as List).cast<Map>().where((x) => x['type'] == RecordType.event);
    final event = den.event(events.single['id'] as String)!;
    expect(event.assignees, [leo]);
    expect(wallOf(zone(), event.start).hour, 15);

    final nothing = await call('add_from_text', {'text': 'zzzz qqqq'});
    expect(nothing.isError, isTrue, reason: nothing.text);
    expect(nothing.text, matches(RegExp('Nothing was added|nothing to add')));
    expect(nothing.receipt, isNull);
  });

  test('#2 undo with preview changes nothing, the receipt included', () async {
    final added = await call('add_items', {'list': 'Groceries', 'items': ['Butter']});
    final id = added.receipt!.id;
    final preview = await call('undo', {'receipt': id, 'preview': true});
    expect(preview.status, ActionStatus.preview, reason: preview.text);
    expect(den.lists.firstWhere((l) => l.list.title == 'Groceries').items.map((i) => i.text), contains('Butter'));
    final undone = await call('undo', {'receipt': id});
    expect(undone.isError, isFalse, reason: undone.text);
    expect(den.lists.firstWhere((l) => l.list.title == 'Groceries').items.map((i) => i.text), isNot(contains('Butter')));
  });

  test('#3 a series split by "this and following" is still used by name, with a date or without', () async {
    final split = next(2, after: 8);
    final changed = await yes('update_event', {
      'event': 'Soccer practice',
      'occurrence': split,
      'scope': 'following',
      'start': '${split}T16:30',
      'end': '${split}T18:00',
    });
    expect(changed.isError, isFalse, reason: changed.text);
    expect(changed.text, contains('from ${shortDate(split)} on'));
    expect(den.events.where((e) => e.title == 'Soccer practice'), hasLength(2));

    final later = await call('set_ride', {'event': 'Soccer practice', 'occurrence': addDays(split, 7), 'leg': 'to', 'driver': 'Priya'});
    expect(later.isError, isFalse, reason: later.text);
    expect(later.text, contains('4:30 PM'));
    final before = await call('set_ride', {'event': 'Soccer practice', 'occurrence': addDays(split, -5), 'leg': 'to', 'driver': 'Priya'});
    expect(before.isError, isFalse, reason: before.text);
    expect(before.text, contains('5:00 PM'));
    final nextOne = await call('set_ride', {'event': 'Soccer practice', 'leg': 'from', 'driver': 'me'});
    expect(nextOne.isError, isFalse, reason: nextOne.text);
    final moved = await call('update_event', {'event': 'Soccer practice', 'occurrence': addDays(split, 9), 'scope': 'one', 'location': 'Field 9'});
    expect(moved.isError, isFalse, reason: moved.text);
  });

  group('#4 approvals', () {
    test('whoever asked for a reward doesn\'t approve it', () async {
      final asked = await call('request_reward', {'reward': r'$5', 'person': 'Leo'});
      expect(asked.text, contains('a parent other than Alex needs to approve it'));
      final id = asked.data['request_id'] as String;
      final approve = await call('decide_reward_request', {'request': id, 'approve': true});
      expect(approve.isError, isTrue);
      expect(approve.code, 'permission_denied');
      expect(approve.text, contains('asked for this'));
      expect(den.points().pending.map((p) => p.id), contains(id));
    });

    test('a kid\'s connection never approves; one acting for nobody only reads', () async {
      final hub = await hubFor(den);
      final kid = connectionOn(hub, leo, label: 'Leo\'s helper');
      expect(runner.available(kid).map((s) => s.mcpName), isNot(contains('decide_reward_request')));
      final r = await runner.run(kid, 'decide_reward_request', {'request': 'Maya', 'approve': true});
      expect(r.code, 'permission_denied');
      hub.actAs(null);
      final nobody = connectionOn(hub, null);
      expect(runner.available(nobody).every((s) => s.readOnly), isTrue);
      final write = await runner.run(nobody, 'add_items', {'list': 'Groceries', 'items': ['Butter']});
      expect(write.code, 'permission_denied');
      await hub.close();
    });
  });

  test('#5 and #21 answers say which zone their times are in for someone who lives elsewhere; "me" is a person', () async {
    final away = mcp(viewZone: 'Pacific/Honolulu');
    final overview = await call('get_overview', {}, on: away);
    expect(overview.text, startsWith('Today in Chicago: ${longDate(today())}'));
    final events = await call('list_events', {}, on: away);
    expect(events.text, endsWith('Times are Chicago time.'));
    final history = await call('get_history', {'limit': 3}, on: away);
    expect(history.text, endsWith('Times are Honolulu time.'));
    expect(history.data['timezone'], 'Pacific/Honolulu');
    expect(((history.data['entries'] as List).first as Map)['when_local'], contains('-10:00'));

    final asked = await call('get_history', {'limit': 1, 'timezone': 'Europe/London'});
    expect(asked.text, endsWith('Times are London time.'));
    final plain = await call('list_events', {});
    expect(plain.text, isNot(contains('Times are')));
    final bad = await call('get_history', {'timezone': 'Mars/Olympus'});
    expect(bad.data['field'], 'timezone');

    final family = await call('get_family', {}, on: away);
    expect(family.text, contains('"me" means Alex'));
    expect(family.text, contains('lives in Honolulu time'));
  });

  group('#6 rides', () {
    test('a kid doesn\'t drive', () async {
      final r = await call('set_ride', {'event': 'Swim lesson', 'leg': 'to', 'driver': 'Maya'});
      expect(r.isError, isTrue);
      expect(r.text, contains('Maya can\'t drive'));
      final made = await call('create_event', {
        'title': 'Carpool',
        'start': '${addDays(today(), 3)}T08:00',
        'rides': [
          {'leg': 'to', 'driver': 'Leo'},
        ],
      });
      expect(made.isError, isTrue);
    });

    test('someone driving two places at once is said, and is a gap', () async {
      final d = soccerDay(after: 2);
      await call('create_event', {
        'title': 'Piano',
        'start': '${d}T17:00',
        'people': ['Maya'],
        'location': 'Music school',
        'rides': [
          {'leg': 'to', 'driver': 'Alex'},
        ],
      });
      final r = await call('set_ride', {'event': 'Soccer practice', 'occurrence': d, 'leg': 'to', 'driver': 'Alex'});
      expect(r.isError, isFalse, reason: r.text);
      expect(r.text, contains('Note: Alex is driving two places at once'));
      final overview = await call('get_overview', {'date': d});
      expect(overview.text, contains('Needs someone: Alex is driving two places at once'));
      expect((overview.data['gaps'] as List).cast<Map>().map((g) => g['kind']), contains('driver_busy'));
    });

    test('a driver who is the only one going is told', () async {
      final r = await call('create_event', {
        'title': 'Physio',
        'start': '${addDays(today(), 4)}T10:00',
        'people': ['Priya'],
        'rides': [
          {'leg': 'to', 'driver': 'Priya'},
        ],
      });
      expect(r.text, contains('Priya is the only one going'));
    });
  });

  group('#7 chore dates', () {
    test('a day still to come asks a parent first; a kid can\'t', () async {
      final d = addDays(today(), 10);
      final counts = <String, int>{};
      for (final cd in den.choresOn(d)) {
        counts.update(cd.chore.title, (n) => n + 1, ifAbsent: () => 1);
      }
      final title = counts.entries.firstWhere((e) => e.value == 1).key;
      final asks = await call('complete_chore', {'chore': title, 'date': d});
      expect(asks.status, ActionStatus.needsConfirmation, reason: asks.text);
      expect(asks.text, contains('ahead'));
      final done = await yes('complete_chore', {'chore': title, 'date': d});
      expect(done.isError, isFalse, reason: done.text);

      final hub = await hubFor(den);
      final kid = connectionOn(hub, leo);
      final early = await runner.run(kid, 'complete_chore', {'chore': 'Make bed', 'date': addDays(today(), 3)});
      expect(early.isError, isTrue);
      expect(early.text, contains('hasn\'t come yet'));
      await hub.close();
    });

    test('a one-time chore on a day that passed says it will show as late', () async {
      final r = await call('create_chore', {'title': 'Return the drill', 'once': addDays(today(), -3), 'owner': 'Alex'});
      expect(r.text, contains('has passed, so it shows as late'));
    });
  });

  test('#8 and #9: who the stars went to, and "already done" with nothing written', () async {
    await call('complete_chore', {'chore': "Zoe's make bed", 'done': false});
    final done = await call('complete_chore', {'chore': "Zoe's make bed", 'person': 'Leo'});
    expect(done.isError, isFalse, reason: done.text);
    expect(done.text, contains('by Leo'));
    expect(done.text, contains('go to Zoe, whose chore it is'));
    expect(done.data['stars_to'], zoe);
    final again = await call('complete_chore', {'chore': "Zoe's make bed", 'person': 'Leo'});
    expect(again.isError, isFalse, reason: again.text);
    expect(again.text, contains('was already done by Leo at'));
    expect(again.receipt, isNull);
    final undone = await call('complete_chore', {'chore': 'Make bed for Zoe', 'done': false});
    expect(undone.receipt, isNotNull);
    final stillNot = await call('complete_chore', {'chore': 'Make bed for Zoe', 'done': false});
    expect(stillNot.text, contains('isn\'t done'));
    expect(stillNot.receipt, isNull);
  });

  group('#10 duplicates', () {
    test('a list, a category, a reward or someone\'s chore of a name the family has asks first', () async {
      final list = await call('create_list', {'title': 'groceries'});
      expect(list.status, ActionStatus.needsConfirmation);
      expect(list.text, contains('There\'s already a list called Groceries'));
      final category = await call('save_category', {'name': 'sports'});
      expect(category.status, ActionStatus.needsConfirmation);
      final reward = await call('save_reward', {'title': 'later bedtime', 'cost': 5});
      expect(reward.status, ActionStatus.needsConfirmation);
      final chore = await call('create_chore', {'title': 'make bed', 'owner': 'Leo'});
      expect(chore.status, ActionStatus.needsConfirmation);
      final another = await call('create_chore', {'title': 'Make bed', 'owner': 'Alex'});
      expect(another.status, ActionStatus.done, reason: 'someone else\'s chore of that name is fine');
      final tapped = await call('create_list', {'title': 'GROCERIES'}, on: app(), mode: RunMode.confirmed);
      expect(tapped.status, ActionStatus.done);
      expect(tapped.data['warnings'], [contains('There\'s already a list called Groceries')]);
    });

    test('an item already on the list isn\'t added again, whatever its case; its quantity says how many', () async {
      final once = await call('add_items', {'list': 'Groceries', 'items': ['Oat milk', 'oat milk', 'Oat milk ']});
      expect(once.data['items'], hasLength(1));
      final again = await call('add_items', {'list': 'Groceries', 'items': ['OAT MILK']});
      expect(again.receipt, isNull);
      expect(again.text, contains('Oat milk is already on Groceries; to get more, change its quantity'));
      expect(den.lists.firstWhere((l) => l.list.title == 'Groceries').items.where((i) => sameName(i.text, 'oat milk')), hasLength(1));
    });
  });

  test('#11 stars below zero, or a lot at once, ask first; the app says so', () async {
    final balance = den.points().totals[leo]!;
    final below = await call('adjust_points', {'person': 'Leo', 'delta': -(balance + 9), 'reason': 'Typo'});
    expect(below.status, ActionStatus.needsConfirmation);
    expect(below.text, contains('leaves -9'));
    final lots = await call('adjust_points', {'person': 'Leo', 'delta': 10000, 'reason': 'Typo'});
    expect(lots.status, ActionStatus.needsConfirmation);
    expect(lots.text, contains('is a lot'));
    final small = await call('adjust_points', {'person': 'Leo', 'delta': 2, 'reason': 'Helped'});
    expect(small.status, ActionStatus.done);
    expect(adjustmentWarning(den, leo, -1), isNull);
    final tapped = await call('adjust_points', {'person': 'Leo', 'delta': -(balance + 11), 'reason': 'Broke a window'}, on: app(), mode: RunMode.confirmed);
    expect(tapped.status, ActionStatus.done);
    expect(tapped.data['warnings'], ['Leo is below zero now.']);
  });

  test('#12 a time the clocks skip or repeat is said, and an hour across the fall-back reads right', () async {
    final skipped = await call('create_event', {'title': 'Night feed', 'start': '2027-03-14T02:30'});
    expect(skipped.text, contains('2:30 AM doesn\'t happen on Sun, Mar 14, 2027'));
    expect(skipped.text, contains('3:30 AM'));
    final twice = await call('create_event', {'title': 'Night owl', 'start': '2026-11-01T01:30'});
    expect(twice.text, contains('happens twice'));
    expect(twice.text, contains('1:30 AM CDT–1:30 AM CST'));
  });

  test('#13 search forgives a typo and leaves out removed things unless asked', () async {
    final r = await call('search', {'query': 'socer'});
    expect(r.text, contains('Soccer practice'));
    final gone = await call('create_event', {'title': 'Garage sale', 'start': '${addDays(today(), 5)}T09:00'});
    await call('undo', {'receipt': gone.receipt!.id});
    expect((await call('search', {'query': 'garage sale'})).text, startsWith('Nothing matches'));
    expect((await call('search', {'query': 'garage sale', 'include_removed': true})).text, contains('removed event Garage sale'));
  });

  test('#14 a line says who can see what it lists', () async {
    final day = addDays(today(), 5);
    await call('create_event', {'title': 'Surprise planning', 'start': '${day}T20:00', 'who_can_see': 'parents'});
    final r = await call('get_overview', {'date': day});
    expect(r.text, contains('Surprise planning (for everyone; parents only)'));
  });

  test('#15 a change to one occurrence, or removing one, says which day', () async {
    final d = soccerDay(after: 2);
    final changed = await call('update_event', {'event': 'Soccer practice', 'occurrence': d, 'scope': 'one', 'location': 'Field 2'});
    expect(changed.text, contains('on ${shortDate(d)} only'));
    final removed = await call('delete_event', {'event': 'Soccer practice', 'occurrence': d, 'scope': 'one'});
    expect(removed.text, startsWith('Removed Soccer practice on ${shortDate(d)} only'));
  });

  test('#16 retiring a reward declines what waits on it, and asking for it says it was retired', () async {
    expect(den.points().pending.single.member, maya);
    final retired = await call('save_reward', {'reward': r'$5', 'active': false});
    expect(retired.text, contains('Declined what Maya asked for'));
    expect(den.points().pending, isEmpty);
    final ask = await call('request_reward', {'reward': r'$5', 'person': 'Leo'});
    expect(ask.isError, isTrue);
    expect(ask.text, contains(r'$5 was retired'));
  });

  test('#17 a cancelled occurrence and a paused chore say so', () async {
    final d = soccerDay(after: 2);
    await call('delete_event', {'event': 'Soccer practice', 'occurrence': d, 'scope': 'one'});
    final ride = await call('set_ride', {'event': 'Soccer practice', 'occurrence': d, 'leg': 'to', 'driver': 'Alex'});
    expect(ride.isError, isTrue);
    expect(ride.text, contains('was cancelled'));
    await call('update_chore', {'chore': 'Bring in the mail', 'active': false});
    final paused = await call('complete_chore', {'chore': 'Bring in the mail'});
    expect(paused.text, contains('Bring in the mail is paused'));
  });

  group('#18 and #19 dates', () {
    test('relative dates and times read as den_capture reads them', () {
      // Wednesday, October 28, 2026; the week starts on Sunday.
      const wed = '2026-10-28';
      expect(relativeDate('Friday', wed), '2026-10-30');
      expect(relativeDate('this friday', wed), '2026-10-30');
      expect(relativeDate('next Friday', wed), '2026-11-06');
      expect(relativeDate('next Monday', wed, weekStart: 1), '2026-11-02');
      expect(relativeDate('last friday', wed), '2026-10-23');
      expect(relativeDate('wednesday', wed), wed);
      expect(relativeDate('in 2 weeks', wed), '2026-11-11');
      expect(relativeDate('someday', wed), isNull);
      expect(clockMinutes('3pm'), 15 * 60);
      expect(clockMinutes('3:30 p.m.'), 15 * 60 + 30);
      expect(clockMinutes('3'), 15 * 60);
      expect(clockMinutes('9'), 9 * 60);
      expect(clockMinutes('noon'), 12 * 60);
      expect(relativeWall('next friday 3pm', wed), DateTime.utc(2026, 11, 6, 15));
      expect(relativeWall('tomorrow at 9:30', wed), DateTime.utc(2026, 10, 29, 9, 30));
    });

    test('an event can start "next Friday 3pm", and one in another year says the year and that it\'s over', () async {
      final r = await call('create_event', {'title': 'Haircut', 'start': 'next friday 3pm', 'people': ['Zoe']});
      expect(r.isError, isFalse, reason: r.text);
      final event = den.event((r.data['event'] as Map)['id'] as String)!;
      expect(event.start, utcOfWall(zone(), relativeWall('next friday 3pm', today())!));
      final old = await call('create_event', {'title': 'New Year brunch', 'start': '2025-01-01T10:00'});
      expect(old.text, contains('Wed, Jan 1, 2025'));
      expect(old.text, contains('already over'));
      final chores = await call('list_chores', {'date': 'tomorrow'});
      expect(chores.data['date'], addDays(today(), 1));
    });
  });

  test('#20 a goal someone reached is said, in points and the overview', () async {
    final points = await call('get_points', {});
    expect(points.text, matches(RegExp(r'(Maya|Leo) reached First to 25 stars \(\d+ stars\)')));
    expect((points.data['reached'] as List), isNotEmpty);
    final overview = await call('get_overview', {});
    expect(overview.text, contains('reached First to 25 stars ('));
    expect((overview.data['reached'] as List).cast<Map>().first['message'], contains('reached'));
  });

  test('#22 and #23: one star, and the limits are in the schema', () async {
    final day = await call('list_chores', {});
    expect(day.text, isNot(matches(RegExp(r'\b1 stars'))));
    expect(day.text, contains('1 star'));
    final end = ((runner.spec('list_events')!.inputSchema['properties'] as Map)['end'] as Map)['description'] as String;
    expect(end, contains('400 days'));
    final long = await call('list_events', {'start': today(), 'end': addDays(today(), 800)});
    expect(long.text, contains('at most 400 days'));
  });

  test('chores of one name are told apart by whose they are', () async {
    final hers = await call('list_chores', {'chore': "Maya's make bed"});
    expect(((hers.data['definitions'] as List).single as Map)['owner_rule'], {'kind': 'member', 'id': maya});
    final his = await call('list_chores', {'chore': 'make bed for Leo'});
    expect(((his.data['definitions'] as List).single as Map)['owner_rule'], {'kind': 'member', 'id': leo});
    final ambiguous = await call('list_chores', {'chore': 'Make bed'});
    expect(ambiguous.isError, isTrue);
    expect(ambiguous.text, contains('Make bed (Maya, id'));
    expect(ambiguous.text, contains('Make bed (Leo, id'));
    final hub = await hubFor(den);
    final kid = connectionOn(hub, zoe);
    final own = await runner.run(kid, 'list_chores', {'chore': 'Make bed'});
    expect(((own.data['definitions'] as List).single as Map)['owner_rule'], {'kind': 'member', 'id': zoe});
    await hub.close();
  });

  test('outputs stay open, so a field such as an item\'s calendar can be added later', () {
    void open(Object? schema, String where) {
      if (schema is Map) {
        expect(schema['additionalProperties'], isNot(false), reason: where);
        for (final e in schema.entries) {
          open(e.value, '$where.${e.key}');
        }
      } else if (schema is List) {
        for (final v in schema) {
          open(v, where);
        }
      }
    }

    for (final s in runner.specs) {
      open(s.outputSchema, s.mcpName);
    }
  });
}
