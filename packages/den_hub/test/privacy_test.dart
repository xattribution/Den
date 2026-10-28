@Timeout(Duration(seconds: 60))
library;

import 'package:den_core/den_core.dart';
import 'support/test.dart';

import 'support/fixture.dart';

void main() {
  test('a member-less token honors the oversight policy: no private titles in points, gaps or stores', () async {
    final f = await HubFixture.start();
    addTearDown(f.stop);
    final leo = f.id('Leo');
    final phone = f.phone;
    final today = phone.todayDate();
    final project = await phone.addChore(
      title: 'Secret science project',
      owner: OwnerMember(leo),
      schedule: ChoreSchedule.once(today),
      points: 5,
      space: Space.member(leo),
    );
    await phone.setChoreDoneBy(project, today, true, leo);
    await phone.addChore(
      title: 'Wrap the hidden gift',
      owner: const OwnerAnyone(),
      schedule: ChoreSchedule.once(today),
      space: Space.member(leo),
    );
    await phone.addChore(title: 'Water the plants', owner: const OwnerAnyone(), schedule: ChoreSchedule.once(today));
    final wishlist = await phone.addList(title: 'Leo wishlist', kind: ListKind.shopping, space: Space.member(leo));
    await phone.addItem(wishlist, text: 'Telescope', store: 'Stargazer Shop');
    await f.toHub();
    final token = await f.token(scopes: {Scope.read}, label: 'Home Assistant');

    Future<String> rest(String path, [String? as]) async => (await f.call('GET', path, token: as ?? token)).text;
    Future<String> mcp(String tool, [String? as]) async {
      final who = as ?? token;
      final init = await f.call('POST', '/mcp', token: who, body: {
        'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-11-25'},
      });
      final session = init.headers['mcp-session-id']!;
      final r = await f.call('POST', '/mcp', token: who, headers: {'mcp-session-id': session}, body: {
        'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call', 'params': {'name': tool, 'arguments': <String, Object?>{}},
      });
      return r.text;
    }

    // Parents may see Leo's "Just me" things, so a parent-level token does too.
    expect(await rest('/api/v1/points?recent=200'), contains('Secret science project'));
    expect(await rest('/api/v1/today'), contains('Wrap the hidden gift is up for grabs'));
    expect(await rest('/api/v1/lists'), contains('Stargazer Shop'));

    await phone.updateFamily({
      'oversight': {leo: {'parentsSeePrivate': false}},
    });
    await f.toHub();
    const private = ['Secret science project', 'Wrap the hidden gift', 'Telescope', 'Stargazer Shop', 'Leo wishlist'];
    final seen = {
      'GET /api/v1/points': await rest('/api/v1/points?recent=200'),
      'GET /api/v1/today': await rest('/api/v1/today'),
      'GET /api/v1/lists': await rest('/api/v1/lists'),
      'GET /api/v1/chores': await rest('/api/v1/chores'),
      'GET /api/v1/search': await rest('/api/v1/search?q=secret'),
      'GET /api/v1/history': await rest('/api/v1/history?limit=200'),
      'get_today': await mcp('get_today'),
      'get_points': await mcp('get_points'),
      'list_chores': await mcp('list_chores'),
      'list_lists': await mcp('list_lists'),
    };
    for (final e in seen.entries) {
      for (final title in private) {
        expect(e.value, isNot(contains(title)), reason: '${e.key} must not show "$title"');
      }
    }
    expect(seen['GET /api/v1/today'], contains('Water the plants is up for grabs'), reason: 'gaps the token may see stay');
    expect(seen['get_today'], contains('Water the plants is up for grabs'));

    // Leo's own token still sees what is his.
    final mine = await f.token(scopes: {Scope.read}, member: leo, label: 'Leo speaker');
    expect(await rest('/api/v1/points?recent=200', mine), contains('Secret science project'));
    expect(await rest('/api/v1/lists', mine), contains('Stargazer Shop'));
  });
}
