@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';

import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'support/test.dart';

import 'support/fixture.dart';

void main() {
  late HubFixture f;
  setUpAll(() async => f = await HubFixture.start());
  tearDownAll(() => f.stop());

  Future<(ApiResult, String?)> rpc(String token, Map<String, Object?> message,
      {String? session, Map<String, String>? headers}) async {
    final r = await f.call('POST', '/mcp',
        token: token,
        body: {'jsonrpc': '2.0', ...message},
        headers: {'mcp-session-id': ?session, ...?headers});
    return (r, r.headers['mcp-session-id']);
  }

  Future<String> initialize(String token, [String version = '2025-11-25']) async {
    final (r, session) = await rpc(token, {
      'id': 1,
      'method': 'initialize',
      'params': {'protocolVersion': version, 'capabilities': {}, 'clientInfo': {'name': 'test', 'version': '1'}},
    });
    expect(r.status, 200);
    expect(session, isNotNull);
    await rpc(token, {'method': 'notifications/initialized'}, session: session);
    return session!;
  }

  Map<String, Object?> result(ApiResult r) => (r.body['result'] as Map).cast<String, Object?>();
  String text(Map<String, Object?> res) => ((res['content'] as List).single as Map)['text'] as String;

  test('initialize negotiates the protocol version and opens a session', () async {
    final token = await f.token(scopes: {Scope.admin}, label: 'Claude');
    for (final v in ['2025-11-25', '2025-06-18']) {
      final (r, _) = await rpc(token, {'id': 1, 'method': 'initialize', 'params': {'protocolVersion': v}});
      expect(result(r)['protocolVersion'], v);
      expect((result(r)['serverInfo'] as Map)['name'], 'den-hub');
      expect(result(r)['capabilities'], {
        'tools': {'listChanged': false},
        'resources': {'subscribe': false, 'listChanged': false},
        'prompts': {'listChanged': false},
      });
      expect(result(r).containsKey('resultType'), isFalse, reason: 'earlier versions keep their shapes');
    }
    final (old, _) = await rpc(token, {'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '1999-01-01'}});
    expect(result(old)['protocolVersion'], '2025-11-25');
    final (asksNew, _) = await rpc(token, {'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2026-07-28'}});
    expect(result(asksNew)['protocolVersion'], '2025-11-25', reason: 'initialize always means the session-based protocol');
    final session = await initialize(token);
    final (note, _) = await rpc(token, {'method': 'notifications/initialized'}, session: session);
    expect(note.status, 202);
    final (ping, _) = await rpc(token, {'id': 2, 'method': 'ping'}, session: session);
    expect(ping.body, {'jsonrpc': '2.0', 'id': 2, 'result': {}});
    expect((await rpc(token, {'id': 3, 'method': 'ping'})).$1.status, 400);
    expect((await rpc(token, {'id': 3, 'method': 'ping'}, session: 'nope')).$1.status, 404);
    final (badVersion, _) =
        await rpc(token, {'id': 3, 'method': 'ping'}, session: session, headers: {'mcp-protocol-version': '1999-01-01'});
    expect(badVersion.status, 400);
  });

  test('401 points OAuth clients at the resource metadata; foreign origins are refused', () async {
    final r = await f.call('POST', '/mcp', body: {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'});
    expect(r.status, 401);
    expect(r.headers['www-authenticate'],
        'Bearer resource_metadata="http://127.0.0.1:${f.hub.port}/.well-known/oauth-protected-resource/mcp", '
        'scope="read calendar chores lists points"');
    final bad = await f.call('POST', '/mcp', token: 'den_not_a_token', body: {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'});
    expect(bad.status, 401);
    expect(bad.headers['www-authenticate'], endsWith(', error="invalid_token"'));
    final token = await f.token(scopes: {Scope.read}, label: 'Origin test');
    expect((await rpc(token, {'id': 1, 'method': 'ping'}, headers: {'origin': 'http://evil.example'})).$1.status, 403);
    final port = f.hub.port;
    final (rebound, _) = await rpc(token, {'id': 1, 'method': 'initialize'},
        headers: {'origin': 'http://evil.example:$port', 'host': 'evil.example:$port'});
    expect(rebound.status, 403);
    final (claude, _) = await rpc(token, {'id': 1, 'method': 'initialize'}, headers: {'origin': 'https://claude.ai'});
    expect(claude.status, 200);
    expect(claude.headers['access-control-allow-origin'], 'https://claude.ai');
  });

  test('tools/list carries schemas and annotations, filtered by scope', () async {
    final admin = await f.token(scopes: {Scope.admin}, label: 'All tools');
    final session = await initialize(admin);
    final (r, _) = await rpc(admin, {'id': 2, 'method': 'tools/list'}, session: session);
    final tools = (result(r)['tools'] as List).cast<Map<String, Object?>>();
    // A token acts as the parent who made it (MCP eval #4): with admin, everything that parent may.
    expect(tools.map((t) => t['name']).toSet(), {
      'get_overview', 'get_family', 'list_events', 'list_chores', 'get_lists', 'get_points', 'search', 'get_history',
      'create_event', 'update_event', 'delete_event', 'set_ride',
      'create_chore', 'update_chore', 'delete_chore', 'complete_chore', 'swap_chore',
      'create_list', 'update_list', 'delete_list', 'add_items', 'update_items', 'remove_items',
      'adjust_points', 'save_goal', 'delete_goal', 'save_reward', 'request_reward', 'decide_reward_request',
      'add_from_text', 'undo', 'save_category', 'delete_category',
      'update_family_settings', 'save_member', 'set_picture', 'save_calendar_feed', 'remove_calendar_feed',
    });
    Map<String, Object?> tool(String name) => tools.firstWhere((t) => t['name'] == name);
    expect((tool('create_event')['inputSchema'] as Map)['required'], ['title', 'start']);
    expect(tool('create_event')['annotations'], containsPair('readOnlyHint', false));
    expect(tool('delete_event')['annotations'], containsPair('destructiveHint', true));
    expect(tool('get_overview')['annotations'], containsPair('readOnlyHint', true));
    expect(tool('complete_chore')['annotations'], containsPair('idempotentHint', true));
    expect((tool('get_lists')['outputSchema'] as Map)['type'], 'object');
    final reader = await f.token(scopes: {Scope.read}, label: 'Reader tools');
    final s2 = await initialize(reader);
    final (r2, _) = await rpc(reader, {'id': 2, 'method': 'tools/list'}, session: s2);
    final names = (result(r2)['tools'] as List).map((t) => (t as Map)['name']);
    expect(names, contains('get_overview'));
    expect(names, isNot(contains('add_items')));
    expect(names, isNot(contains('get_today')), reason: 'older names work but aren\'t listed');
  });

  test('tools/call reads and writes by name, refuses what the member may not do', () async {
    final leo = await f.token(scopes: {Scope.read, Scope.lists, Scope.chores}, member: f.id('Leo'), label: 'Leo assistant');
    final session = await initialize(leo);
    Future<Map<String, Object?>> call(String name, Map<String, Object?> args) async => result((await rpc(
            leo, {'id': 9, 'method': 'tools/call', 'params': {'name': name, 'arguments': args}},
            session: session))
        .$1);

    final today = await call('get_today', {});
    expect(today['isError'], isFalse);
    expect(text(today), contains('Events'));
    expect((today['structuredContent'] as Map)['date'], f.phone.todayDate());

    final checked = await call('check_item', {'item': 'milk', 'list': 'groceries'});
    expect(checked['isError'], isFalse, reason: text(checked));
    expect(((checked['structuredContent'] as Map)['item'] as Map)['checked_by'], f.id('Leo'));
    expect(f.hubDen.history(type: 'item').first.via, 'Leo assistant');

    final notAllowed = await call('add_items', {'list': 'groceries', 'items': ['Popcorn']});
    expect(notAllowed['isError'], isTrue);
    expect(text(notAllowed), startsWith("Den didn't allow that"));

    final missing = await call('list_lists', {'list': 'Grocery run'});
    expect(missing['isError'], isTrue);
    expect(text(missing), contains('Groceries'));

    final refused = await call('complete_chore', {'chore': 'Make bed', 'person': 'Maya'});
    expect(refused['isError'], isTrue);
    expect(text(refused), startsWith('Den didn\'t allow that'));

    final own = await call('complete_chore', {'chore': 'Make bed'});
    expect(own['isError'], isFalse, reason: text(own));
    expect(((own['structuredContent'] as Map)['chore'] as Map)['done_by'], f.id('Leo'));

    final noScope = await call('create_event', {'title': 'Party', 'start': '2026-11-01'});
    expect(noScope['isError'], isTrue);
    expect(text(noScope), contains('"calendar" scope'));
  });

  test('only someone who sets points can give a chore stars through a tool', () async {
    final rosa = await f.token(scopes: {Scope.read, Scope.chores}, member: f.id('Grandma Rosa'), label: 'Rosa assistant');
    final session = await initialize(rosa);
    Future<Map<String, Object?>> call(String name, Map<String, Object?> args) async => result((await rpc(
            rosa, {'id': 9, 'method': 'tools/call', 'params': {'name': name, 'arguments': args}},
            session: session))
        .$1);

    final priced = await call('create_chore', {'title': 'Water the tomatoes', 'points': 5});
    expect(priced['isError'], isTrue);
    expect(text(priced), startsWith('Den didn\'t allow that'));
    expect(text(priced), contains('stars'));

    final plain = await call('create_chore', {'title': 'Water the tomatoes'});
    expect(plain['isError'], isFalse, reason: text(plain));
    final raised = await call('update_chore', {'chore': 'Water the tomatoes', 'points': 3});
    expect(raised['isError'], isTrue);
    expect(text(raised), startsWith('Den didn\'t allow that'));
    final renamed = await call('update_chore', {'chore': 'Water the tomatoes', 'title': 'Water the garden'});
    expect(renamed['isError'], isFalse, reason: text(renamed));
  });

  test('creating an event with local times, and an unknown tool', () async {
    final token = await f.token(scopes: {Scope.admin}, label: 'Planner');
    final session = await initialize(token);
    final (r, _) = await rpc(token, {
      'id': 5,
      'method': 'tools/call',
      'params': {
        'name': 'create_event',
        'arguments': {'title': 'Haircut', 'start': '2026-11-12T10:00', 'people': ['Zoe', 'Priya']},
      },
    }, session: session);
    final event = ((result(r)['structuredContent'] as Map)['event'] as Map).cast<String, Object?>();
    expect(event['start'], '2026-11-12T10:00:00-06:00');
    expect(event['assignees'], [f.id('Zoe'), f.id('Priya')]);
    final (unknown, _) = await rpc(token, {'id': 6, 'method': 'tools/call', 'params': {'name': 'nope'}}, session: session);
    expect((unknown.body['error'] as Map)['code'], -32602);
    final (resource, _) = await rpc(token, {'id': 7, 'method': 'resources/read', 'params': {'uri': 'den://nowhere'}}, session: session);
    expect((resource.body['error'] as Map)['code'], -32002, reason: 'resource not found, as earlier versions say it');
    final (lists, _) = await rpc(token, {'id': 8, 'method': 'resources/read', 'params': {'uri': 'den://lists'}}, session: session);
    expect(((lists.body['result'] as Map)['contents'] as List).single, containsPair('uri', 'den://lists'));
    expect((lists.body['result'] as Map).containsKey('ttlMs'), isFalse);
  });

  test('stdio carries the same protocol, one JSON message per line', () async {
    final token = await f.token(scopes: {Scope.read, Scope.lists}, label: 'Desktop assistant');
    final input = StreamController<List<int>>();
    final lines = <String>[];
    final done = serveMcpStdio(f.hub.mcp, () => accessForToken(f.hubDen, token), input.stream, lines.add);
    void send(Object message) => input.add(utf8.encode('${jsonEncode(message)}\n'));
    send({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18'}});
    send({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
    send({
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/call',
      'params': {'name': 'check_item', 'arguments': {'item': 'Paper towels'}},
    });
    send({
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'tools/call',
      'params': {'name': 'adjust_points', 'arguments': {'person': 'Leo', 'delta': 3, 'reason': 'x'}},
    });
    input.add(utf8.encode('not json\n'));
    await input.close();
    await done;
    final out = [for (final l in lines) (jsonDecode(l) as Map).cast<String, Object?>()];
    expect(out, hasLength(4));
    expect((out[0]['result'] as Map)['protocolVersion'], '2025-06-18');
    expect((out[1]['result'] as Map)['isError'], isFalse, reason: '${out[1]}');
    expect(text((out[2]['result'] as Map).cast<String, Object?>()), contains('"points" scope'));
    expect((out[3]['error'] as Map)['code'], -32700);
  });
}
