@Timeout(Duration(seconds: 180))
library;

import 'package:den_actions/den_actions.dart';
import 'package:den_core/den_core.dart';

import 'support.dart';

void main() {
  annotateFailures();
  late Den den;
  late ActionRunner runner;
  late String alex;

  setUp(() async {
    den = await demoFamily();
    runner = standardRunner();
    alex = den.actor!.id;
  });

  tearDown(() => den.close());

  ActionContext on(Surface surface, [String caller = 'claude']) =>
      ActionContext(den, member: alex, surface: surface, caller: caller);

  ListState list(String title) => den.lists.firstWhere((l) => l.list.title == title);

  test('removing a list asks first, and only the same caller\'s yes with the same input goes ahead', () async {
    final mcp = on(Surface.mcp);
    final first = await runner.run(mcp, 'delete_list', {'list': 'Meal plan'});
    expect(first.status, ActionStatus.needsConfirmation, reason: first.text);
    expect(first.text, startsWith('Remove the list Meal plan and its 7 items?'));
    expect(first.isError, isFalse);
    final token = (first.data['confirm'] as Map)['token'] as String;
    expect(((first.data['preview'] as Map)['changes'] as List).single, containsPair('verb', 'removed'));
    expect(den.lists.any((l) => l.list.title == 'Meal plan'), isTrue);

    final stranger = await runner.run(on(Surface.mcp, 'someone else'), 'delete_list', {'list': 'Meal plan', 'confirm': token});
    expect(stranger.status, ActionStatus.needsConfirmation);
    expect(stranger.text, contains('didn\'t match'));
    final otherList = await runner.run(mcp, 'delete_list', {'list': 'Groceries', 'confirm': token});
    expect(otherList.status, ActionStatus.needsConfirmation);
    expect(den.lists.any((l) => l.list.title == 'Groceries'), isTrue);

    final yes = await runner.run(mcp, 'delete_list', {'list': 'Meal plan', 'confirm': token});
    expect(yes.status, ActionStatus.done, reason: yes.text);
    expect(yes.receipt, isNotNull);
    expect(den.lists.any((l) => l.list.title == 'Meal plan'), isFalse);
    final again = await runner.run(mcp, 'undo', {'receipt': yes.receipt!.id});
    expect(again.isError, isFalse, reason: again.text);
    expect(list('Meal plan').items, hasLength(7));
  });

  test('the app and a tapped yes run at once; a series edit asks on MCP but one occurrence doesn\'t', () async {
    final app = await runner.run(on(Surface.app), 'delete_chore', {'chore': 'Return library books'}, mode: RunMode.confirmed);
    expect(app.status, ActionStatus.done, reason: app.text);
    final tapped = await runner.run(on(Surface.assistant), 'delete_list', {'list': 'Meal plan'}, mode: RunMode.confirmed);
    expect(tapped.status, ActionStatus.done, reason: tapped.text);
    final series = await runner.run(on(Surface.mcp), 'update_event', {'event': 'Soccer practice', 'location': 'Field 5'});
    expect(series.status, ActionStatus.needsConfirmation);
    expect(series.text, startsWith('Change every occurrence of Soccer practice?'));
    final once = await runner.run(on(Surface.mcp), 'update_event', {'event': 'Dentist', 'location': 'Suite 2'});
    expect(once.status, ActionStatus.done, reason: once.text);
  });

  test('the assistant asks before changing someone else\'s chore, not before reading', () async {
    final assistant = on(Surface.assistant);
    final asks = await runner.run(assistant, 'update_chore', {'chore': 'Feed the cat', 'points': 2});
    expect(asks.status, ActionStatus.needsConfirmation);
    expect(den.chores.firstWhere((c) => c.title == 'Feed the cat').points, 1);
    final read = await runner.run(assistant, 'get_overview', {});
    expect(read.status, ActionStatus.done);
  });

  test('older names still work and answer as the action they became', () async {
    final app = on(Surface.app);
    final checked = await runner.run(app, 'check_item', {'item': 'Eggs', 'list': 'Groceries'});
    expect(checked.isError, isFalse, reason: checked.text);
    expect((checked.data['item'] as Map)['checked'], isTrue);
    final cleared = await runner.run(app, 'clear_checked', {'list': 'Groceries'});
    expect(cleared.text, 'Cleared 4 checked items from Groceries.');
    final week = await runner.run(app, 'get_week', {});
    expect(week.data['days'], hasLength(7));
    final today = await runner.run(app, 'get_today', {});
    expect(today.data['date'], den.todayDate());
    final step = await runner.run(app, 'check_step', {'chore': 'Dishes', 'step': 'Clear the table', 'checked': true});
    expect(step.isError, isFalse, reason: step.text);
    final goal = await runner.run(app, 'create_goal', {'title': 'Reading', 'target': 30});
    expect(goal.data['goal_id'], isA<String>());
  });

  test('undo takes back a receipt, the last one by default, and an undo can itself be undone', () async {
    final app = on(Surface.app);
    final added = await runner.run(app, 'add_items', {'list': 'Groceries', 'items': ['Butter']});
    final undone = await runner.run(app, 'undo', {});
    expect(undone.isError, isFalse, reason: undone.text);
    expect(undone.text, 'Undid: Added Butter to Groceries.');
    expect(list('Groceries').items.map((i) => i.text), isNot(contains('Butter')));
    final twice = await runner.run(app, 'undo', {'receipt': added.receipt!.id});
    expect(twice.code, 'not_found');
    final redo = await runner.run(app, 'undo', {'receipt': undone.receipt!.id});
    expect(redo.isError, isFalse, reason: redo.text);
    expect(list('Groceries').items.map((i) => i.text), contains('Butter'));
    final notMine = await runner.run(on(Surface.app, 'another app'), 'undo', {'receipt': redo.receipt!.id});
    expect(notMine.code, 'not_found');
  });

  test('undo puts back a removed record by type and id', () async {
    final app = on(Surface.app);
    final removed = await runner.run(app, 'delete_chore', {'chore': 'Return library books'}, mode: RunMode.confirmed);
    final id = removed.data['chore_id'] as String;
    final back = await runner.run(app, 'undo', {'type': 'chore', 'id': id});
    expect(back.isError, isFalse, reason: back.text);
    expect(back.text, 'Put back Return library books.');
    expect(den.chore(id), isNotNull);
  });

  test('items: checked, changed, moved and removed in one call each', () async {
    final app = on(Surface.app);
    final r = await runner.run(app, 'update_items', {
      'list': 'Groceries',
      'items': [
        {'item': 'Bananas', 'checked': true},
        {'item': 'Milk', 'qty': '2 gal', 'store': 'Costco', 'move': 'top'},
      ],
    });
    expect(r.isError, isFalse, reason: r.text);
    expect(r.text, 'Checked off Bananas on Groceries; changed and moved Milk on Groceries.');
    expect(list('Groceries').items.first.text, 'Milk');
    expect(list('Groceries').items.first.qty, '2 gal');
    final removed = await runner.run(app, 'remove_items', {'list': 'Groceries', 'items': ['Milk', 'Bananas']});
    expect(removed.data['removed'], 2);
    final many = await runner.run(on(Surface.mcp), 'remove_items', {'list': 'Groceries', 'items': ['Eggs', 'Toothpaste', 'AA batteries', 'Paper towels', 'Strawberries', 'Chicken thighs']});
    expect(many.status, ActionStatus.needsConfirmation);
    expect(many.text, startsWith('Remove 6 items from Groceries?'));
  });

  test('rides: who drives the next soccer practice home', () async {
    final r = await runner.run(on(Surface.app), 'set_ride', {'event': 'Soccer practice', 'leg': 'from', 'driver': 'me'});
    expect(r.isError, isFalse, reason: r.text);
    expect(r.text, startsWith('Alex is picking up Leo from Soccer practice on '));
    final rides = ((r.data['occurrence'] as Map)['rides'] as List).cast<Map>();
    expect(rides.firstWhere((x) => x['leg'] == 'from')['driver'], alex);
  });

  test('rides: the app and an assistant each taking a leg at once both count', () async {
    final hub = await hubFor(den);
    final priya = idOf(den, 'Priya');
    final rosa = idOf(den, 'Grandma Rosa');
    final hubRunner = standardRunner();
    final soccer = den.events.firstWhere((e) => e.title == 'Soccer practice');
    Map<String, String?> legs(Den d, int at) => {
          for (final r in d.occurrences(at, at + 1).firstWhere((o) => o.event.id == soccer.id).rides) r.leg: r.driver,
        };

    // Alex picks Leo up from the next practice in the app; Priya's assistant, on the hub, hands
    // the drive there to Grandma Rosa. Neither has heard of the other's yet.
    final mine = await runner.run(on(Surface.app), 'set_ride', {'event': 'Soccer practice', 'leg': 'from', 'driver': 'me'});
    expect(mine.isError, isFalse, reason: mine.text);
    expect(mine.text, startsWith('Alex is picking up Leo from Soccer practice on '));
    final at = (mine.data['occurrence'] as Map)['occurrence'] as int;
    final theirs = await hubRunner.run(connectionOn(hub, priya, label: 'Assistant'), 'set_ride', {'event': 'Soccer practice', 'leg': 'to', 'driver': 'Grandma Rosa'});
    expect(theirs.isError, isFalse, reason: theirs.text);
    expect(theirs.text, startsWith('Grandma Rosa is driving Leo to Soccer practice on '));
    expect(((theirs.data['occurrence'] as Map)['rides'] as List).cast<Map>(), [
      {'leg': 'to', 'driver': rosa},
      {'leg': 'from', 'driver': null},
    ], reason: 'the same output, as the hub sees it before hearing of Alex\'s');

    // Each wrote its own leg, after the whole list older versions read.
    final written = [for (final c in den.changesSince({})) if (mine.receipt!.changes.contains(c.id)) c];
    expect([for (final c in written) c.fields.keys.where((k) => k.startsWith('patch.')).toList()], [
      ['patch.rides'],
      ['patch.drivers.from'],
    ]);
    expect(den.historyOf(mine.receipt!.changes), hasLength(1), reason: 'one change to the people reading History');

    await hub.ingest(den.changesSince({}));
    await den.ingest(hub.changesSince({}));
    expect(legs(den, at), {'to': rosa, 'from': alex});
    expect(legs(hub, at), {'to': rosa, 'from': alex});
    await hub.close();
  });

  test('people: details change here, roles only in the app; feeds only from the public web', () async {
    final app = on(Surface.app);
    final role = await runner.run(app, 'save_member', {'member': 'Leo', 'role': 'parent'});
    expect(role.code, 'permission_denied');
    final color = await runner.run(app, 'save_member', {'member': 'Leo', 'color': Marker.values.last.name});
    expect((color.data['member'] as Map)['marker'], Marker.values.last.name);
    final picture = await runner.run(app, 'save_member', {'member': 'Leo', 'picture': 'rocket'});
    expect((picture.data['member'] as Map)['picture'], 'rocket');
    final unknown = await runner.run(app, 'save_member', {'member': 'Leo', 'picture': 'dragon'});
    expect(unknown.isError, isTrue);
    final next = Marker.next(den.members.map((m) => m.marker)).name;
    final added = await runner.run(app, 'save_member', {'name': 'Grandpa Joe', 'role': 'adult'});
    final joe = added.data['member'] as Map;
    expect(joe['picture'], Picture.initial);
    expect(joe['marker'], next, reason: 'a new person gets the next color nobody has');
    for (final url in ['http://school.example.org/cal.ics', 'https://192.168.1.10/cal.ics', 'https://nas.local/cal.ics', 'https://intranet/cal.ics']) {
      final feed = await runner.run(app, 'save_calendar_feed', {'url': url}, mode: RunMode.confirmed);
      expect(feed.isError, isTrue, reason: url);
      expect(feed.data['field'], 'url');
    }
    final ok = await runner.run(app, 'save_calendar_feed', {'url': 'webcal://school.example.org/cal.ics'}, mode: RunMode.confirmed);
    expect((ok.data['feed'] as Map)['url'], 'https://school.example.org/cal.ics');
  });

  test('family colors: a parent picks the pack for everyone, and people keep their colors', () async {
    final leo = den.members.firstWhere((m) => m.name == 'Leo');
    final app = await runner.run(on(Surface.app), 'update_family_settings', {'colors': 'deep'});
    expect(app.isError, isFalse, reason: app.text);
    expect(app.text, 'Set the family\'s colors to deep.');
    expect((app.data['family'] as Map)['colors'], 'deep');
    expect(den.family!.colors, ColorPack.deep);
    expect(den.member(leo.id)!.marker, leo.marker, reason: 'Leo keeps his place in the pack');
    final mcp = await runner.run(on(Surface.mcp), 'update_family_settings', {'colors': 'soft'}, mode: RunMode.confirmed);
    expect(mcp.isError, isFalse, reason: mcp.text);
    expect(den.family!.colors, ColorPack.soft);
    final unknown = await runner.run(on(Surface.app), 'update_family_settings', {'colors': 'neon'});
    expect(unknown.isError, isTrue);
    final family = await runner.run(on(Surface.mcp), 'get_family', const {});
    expect((family.data['family'] as Map)['colors'], 'soft');
  });

  test('pictures: from the pack or an initial, never a photo; photos show as "photo:<id>"', () async {
    final app = on(Surface.app);
    final mine = await runner.run(app, 'set_picture', {'picture': 'owl'});
    expect((mine.data['member'] as Map)['picture'], 'owl', reason: mine.text);
    final leo = await runner.run(on(Surface.mcp), 'set_picture', {'person': 'Leo', 'picture': 'initial'});
    expect((leo.data['member'] as Map)['picture'], Picture.initial, reason: leo.text);
    final photo = await runner.run(on(Surface.mcp), 'set_picture', {'person': 'Leo', 'picture': 'photo:abcdefghijklmnop'});
    expect(photo.isError, isTrue);
    expect(runner.spec('set_picture')!.engine, {'setPicture'});
    final nobody = ActionContext(den, surface: Surface.mcp, caller: 'automation');
    expect(runner.available(nobody).map((s) => s.mcpName), isNot(contains('set_picture')), reason: 'nobody has an own picture');
    expect(runner.available(on(Surface.mcp)).map((s) => s.mcpName), contains('set_picture'));
    expect(notExposed['setPhoto'], contains('can\'t add one'));
    final family = await runner.run(on(Surface.mcp), 'get_family', const {});
    final members = (family.data['members'] as List).cast<Map<String, Object?>>();
    expect(members.first.keys, containsAll(['picture', 'until']));
  });

  test('a kid whose parents turned off "Rewards need my OK" gets what they can afford at once', () async {
    final maya = idOf(den, 'Maya');
    final reward = den.points().rewards.firstWhere((r) => r.needsApproval);
    final waits = await runner.run(on(Surface.app), 'request_reward', {'reward': reward.title, 'person': 'Maya'});
    expect(waits.data['status'], 'requested', reason: waits.text);
    await den.updateFamily({'oversight.$maya.${OversightSetting.rewardsNeedOk}': false});
    final now = await runner.run(on(Surface.app), 'request_reward', {'reward': reward.title, 'person': 'Maya'});
    expect(now.data['status'], 'approved', reason: now.text);
  });

  test('what the app\'s editors change: steps keep their ids, a rotation its first day, a list its pictogram', () async {
    final app = on(Surface.app);
    final dishes = den.chores.firstWhere((c) => c.title == 'Dishes');
    final steps = [
      {'id': 'clear', 'text': 'Clear the whole table'},
      {'text': 'Dry the pans'},
    ];
    final changed = await runner.run(app, 'update_chore', {'chore': dishes.id, 'steps': steps});
    expect(changed.isError, isFalse, reason: changed.text);
    final after = den.chore(dishes.id)!;
    expect(after.steps.first.id, 'clear');
    expect(after.steps.first.text, 'Clear the whole table');
    expect(after.steps.first.icon, 'dishes', reason: 'a step given by id keeps the pictogram it leaves out');
    expect(after.steps.last.id, isNot(anyOf('', 'clear', 'load', 'wipe')));
    final leo = den.members.firstWhere((m) => m.name == 'Leo').id;
    final maya = den.members.firstWhere((m) => m.name == 'Maya').id;
    final turns = await runner.run(app, 'update_chore', {
      'chore': dishes.id,
      'rotation': [leo, maya],
      'rotate_every': 'day',
      'rotation_start': '2026-11-02',
    });
    expect(turns.isError, isFalse, reason: turns.text);
    final owner = den.chore(dishes.id)!.owner as OwnerRotation;
    expect([owner.ids, owner.every, owner.anchor], [
      [leo, maya],
      'day',
      '2026-11-02',
    ]);
    final made = await runner.run(app, 'create_list', {'title': 'Trip', 'need_by': '2026-12-01'});
    final id = (made.data['list'] as Map)['id'] as String;
    await runner.run(app, 'update_list', {'list': id, 'kind': 'packing'});
    expect(den.list(id)!.list.icon, 'packing');
    final soccer = den.events.firstWhere((e) => e.title == 'Soccer practice');
    await runner.run(app, 'update_list', {'list': id, 'event': soccer.id});
    expect([den.list(id)!.list.lifecycle, den.list(id)!.list.needBy], [ListLifecycle.event, isNull]);
  });

  test('add_from_text adds what it reads and leaves what is already there', () async {
    final r = await runner.run(on(Surface.app), 'add_from_text', {'text': 'milk, eggs, 2 lb apples from Costco'});
    expect(r.isError, isFalse, reason: r.text);
    final added = (r.data['added'] as List).cast<Map>();
    expect(added.map((a) => '${a['title']}'.toLowerCase()), contains('apples'));
    expect((r.data['left'] as List).length, greaterThanOrEqualTo(1));
    expect(r.receipt, isNotNull);
  });
}
