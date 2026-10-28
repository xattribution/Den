@Timeout(Duration(seconds: 90))
library;

import 'dart:async';
import 'dart:convert';

import 'package:async/async.dart';
import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:http/http.dart' as http;

import 'support/fixture.dart';
import 'support/test.dart';

/// MCP 2026-07-28: requests that stand alone, with their version and the client's capabilities
/// in `_meta` and mirrored in headers; discovery, caching hints, a yes asked through the client,
/// resources, prompts and subscriptions. The earlier, session-based protocol is in mcp_test.dart.
void main() {
  late HubFixture f;
  setUpAll(() async => f = await HubFixture.start());
  tearDownAll(() => f.stop());

  Map<String, Object?> request(String method,
          {Map<String, Object?> params = const {}, Object? id = 1, Map<String, Object?> capabilities = const {}, String version = '2026-07-28'}) =>
      {
        'jsonrpc': '2.0',
        'id': ?id,
        'method': method,
        'params': {
          ...params,
          '_meta': {
            McpMeta.protocolVersion: version,
            McpMeta.clientInfo: {'name': 'test', 'version': '1'},
            McpMeta.clientCapabilities: capabilities,
          },
        },
      };

  Future<ApiResult> send(String token, Map<String, Object?> body, {Map<String, String>? headers, bool mirror = true}) =>
      f.call('POST', '/mcp', token: token, body: body, headers: {if (mirror) ...mcpRequestHeaders(body), ...?headers});

  Future<ApiResult> modern(String token, String method,
          {Map<String, Object?> params = const {}, Object? id = 1, Map<String, Object?> capabilities = const {}, Map<String, String>? headers}) =>
      send(token, request(method, params: params, id: id, capabilities: capabilities), headers: headers);

  Map<String, Object?> result(ApiResult r) => (r.body['result'] as Map).cast<String, Object?>();
  Map<String, Object?> error(ApiResult r) => (r.body['error'] as Map).cast<String, Object?>();
  String text(Map<String, Object?> res) => ((res['content'] as List).single as Map)['text'] as String;

  test('server/discover names the versions, capabilities and server, cacheable by anyone', () async {
    final token = await f.token(scopes: {Scope.read}, label: 'Discover');
    final r = await modern(token, 'server/discover');
    expect(r.status, 200, reason: r.text);
    final res = result(r);
    expect(res['resultType'], 'complete');
    expect(res['supportedVersions'], containsAll(['2026-07-28', '2025-11-25', '2025-06-18']));
    expect((res['capabilities'] as Map).keys, containsAll(['tools', 'resources', 'prompts']));
    expect(((res['_meta'] as Map)[McpMeta.serverInfo] as Map)['name'], 'den-hub');
    expect(res['instructions'], contains('Den'));
    expect(res['ttlMs'], greaterThan(0));
    expect(res['cacheScope'], 'public');
    expect(r.headers['mcp-session-id'], isNull, reason: 'no sessions at 2026-07-28');
  });

  test('the headers must match the body', () async {
    final token = await f.token(scopes: {Scope.read}, label: 'Headers');
    final list = request('tools/list');
    final noVersion = await send(token, list, mirror: false, headers: {'mcp-method': 'tools/list'});
    expect(noVersion.status, 400);
    expect(error(noVersion)['code'], -32020);
    final otherVersion = await send(token, list, headers: {'mcp-protocol-version': '2025-11-25'});
    expect(otherVersion.status, 400);
    expect(error(otherVersion)['code'], -32020);
    final otherMethod = await send(token, list, headers: {'mcp-method': 'tools/call'});
    expect(error(otherMethod)['code'], -32020);
    final noMethod = await send(token, list, mirror: false, headers: {'mcp-protocol-version': '2026-07-28'});
    expect(error(noMethod)['code'], -32020);

    final call = request('tools/call', params: {'name': 'get_family', 'arguments': <String, Object?>{}});
    final noName = await send(token, call, mirror: false, headers: {'mcp-protocol-version': '2026-07-28', 'mcp-method': 'tools/call'});
    expect(noName.status, 400);
    expect(error(noName)['code'], -32020);
    final otherName = await send(token, call, headers: {'mcp-name': 'get_overview'});
    expect(error(otherName)['code'], -32020);
    final encoded = await send(token, call, headers: {'mcp-name': '=?base64?${base64.encode(utf8.encode('get_family'))}?='});
    expect(encoded.status, 200, reason: encoded.text);
    expect(result(encoded)['isError'], isFalse);
    expect(encodeMcpHeader('Grocery run'), 'Grocery run');
    expect(decodeMcpHeader(encodeMcpHeader(' padded ')), ' padded ');
    expect(decodeMcpHeader(encodeMcpHeader('den://lists/Épicerie')), 'den://lists/Épicerie');
  });

  test('versions Den doesn\'t speak, missing capabilities, unknown methods and notifications', () async {
    final token = await f.token(scopes: {Scope.read}, label: 'Errors');
    final old = await send(token, request('tools/list', version: '1900-01-01'));
    expect(old.status, 400);
    expect(error(old)['code'], -32022);
    expect((error(old)['data'] as Map)['requested'], '1900-01-01');
    expect((error(old)['data'] as Map)['supported'], contains('2026-07-28'));

    final bare = request('tools/list');
    ((bare['params'] as Map)['_meta'] as Map).remove(McpMeta.clientCapabilities);
    final noCapabilities = await send(token, bare);
    expect(noCapabilities.status, 400);
    expect(error(noCapabilities)['code'], -32602);

    final unknown = await modern(token, 'tasks/list');
    expect(unknown.status, 404);
    expect(error(unknown)['code'], -32601);

    final note = await modern(token, 'notifications/whatever', id: null);
    expect(note.status, 202);

    final ping = await modern(token, 'ping', headers: {'mcp-session-id': 'left-over'});
    expect(ping.status, 200, reason: 'session headers are ignored');
    expect(result(ping)['resultType'], 'complete');
    expect(ping.headers['mcp-session-id'], isNull);
  });

  test('lists say how long to keep them, and for whom', () async {
    final token = await f.token(scopes: {Scope.read}, label: 'Lists');
    final tools = result(await modern(token, 'tools/list'));
    expect(tools['resultType'], 'complete');
    expect(tools['ttlMs'], McpServer.listTtlMs);
    expect(tools['cacheScope'], 'private');
    expect((tools['tools'] as List).map((t) => (t as Map)['name']), contains('get_overview'));
  });

  test('a change that needs a yes asks through the client when it can show a form', () async {
    final token = await f.token(scopes: {Scope.admin}, label: 'Asks first');
    const forms = {
      'elicitation': {'form': <String, Object?>{}},
    };
    Future<ApiResult> call(String name, Map<String, Object?> args, {Map<String, Object?> capabilities = const {}, Map<String, Object?> extra = const {}}) =>
        modern(token, 'tools/call', params: {'name': name, 'arguments': args, ...extra}, capabilities: capabilities);
    bool exists(String title) => f.hubDen.lists.any((l) => l.list.title == title);

    expect(result(await call('create_list', {'title': 'Camping gear'}))['isError'], isFalse);
    expect(exists('Camping gear'), isTrue);

    // A client that can't show a form gets the question as the result, and Den's two-step.
    final twoStep = result(await call('delete_list', {'list': 'Camping gear'}));
    expect(twoStep['resultType'], 'complete');
    expect(text(twoStep), contains('"confirm"'));
    expect(((twoStep['structuredContent'] as Map)['confirm'] as Map)['token'], isA<String>());

    final asked = result(await call('delete_list', {'list': 'Camping gear'}, capabilities: forms));
    expect(asked['resultType'], 'input_required');
    final ask = ((asked['inputRequests'] as Map)['confirm'] as Map).cast<String, Object?>();
    expect(ask['method'], 'elicitation/create');
    final askParams = (ask['params'] as Map).cast<String, Object?>();
    expect(askParams['mode'], 'form');
    expect(askParams['message'], contains('Camping gear'));
    expect((((askParams['requestedSchema'] as Map)['properties'] as Map)['confirm'] as Map)['type'], 'boolean');
    expect(asked.containsKey('ttlMs'), isFalse, reason: 'an interim result isn\'t cacheable');
    final state = asked['requestState'] as String;

    final no = result(await call('delete_list', {'list': 'Camping gear'}, capabilities: forms, extra: {
      'requestState': state,
      'inputResponses': {
        'confirm': {'action': 'decline'},
      },
    }));
    expect(no['resultType'], 'complete');
    expect(no['isError'], isTrue);
    expect(text(no), contains('Nothing changed'));
    expect(exists('Camping gear'), isTrue);

    final forged = result(await call('delete_list', {'list': 'Camping gear'}, capabilities: forms, extra: {
      'requestState': 'c_made_up',
      'inputResponses': {
        'confirm': {
          'action': 'accept',
          'content': {'confirm': true},
        },
      },
    }));
    expect(forged['resultType'], 'input_required', reason: 'a state Den didn\'t hand out only asks again');
    expect(exists('Camping gear'), isTrue);

    final other = result(await call('delete_list', {'list': 'Meal plan'}, capabilities: forms, extra: {
      'requestState': forged['requestState'],
      'inputResponses': {
        'confirm': {
          'action': 'accept',
          'content': {'confirm': true},
        },
      },
    }));
    expect(other['resultType'], 'input_required', reason: 'a yes for one list is no yes for another');
    expect(exists('Meal plan'), isTrue);

    final yes = result(await call('delete_list', {'list': 'Camping gear'}, capabilities: forms, extra: {
      'requestState': forged['requestState'],
      'inputResponses': {
        'confirm': {
          'action': 'accept',
          'content': {'confirm': true},
        },
      },
    }));
    expect(yes['resultType'], 'complete');
    expect(yes['isError'], isFalse, reason: text(yes));
    expect(exists('Camping gear'), isFalse);
  });

  test('resources: the day, the lists and one list, as the token\'s member sees them', () async {
    final token = await f.token(scopes: {Scope.read}, label: 'Resources');
    final listed = result(await modern(token, 'resources/list'));
    expect(listed['cacheScope'], 'private');
    final uris = (listed['resources'] as List).map((r) => (r as Map)['uri']).toList();
    expect(uris, containsAll(['den://today', 'den://week', 'den://family', 'den://lists', 'den://chores', 'den://points']));
    final templates = result(await modern(token, 'resources/templates/list'));
    expect((templates['resourceTemplates'] as List).map((t) => (t as Map)['uriTemplate']),
        containsAll(['den://lists/{list}', 'den://days/{date}', 'den://people/{person}/today']));

    final groceries = await modern(token, 'resources/read', params: {'uri': 'den://lists/Groceries'});
    expect(groceries.status, 200, reason: groceries.text);
    final content = ((result(groceries)['contents'] as List).single as Map).cast<String, Object?>();
    expect(content['uri'], 'den://lists/Groceries');
    expect(content['mimeType'], 'application/json');
    final lists = (jsonDecode(content['text'] as String) as Map)['lists'] as List;
    expect(lists.map((l) => (l as Map)['title']), ['Groceries']);
    expect(result(groceries)['ttlMs'], 0);

    final today = await modern(token, 'resources/read', params: {'uri': 'den://today'});
    final day = jsonDecode((((result(today)['contents'] as List).single) as Map)['text'] as String) as Map;
    expect(day['date'], f.phone.todayDate());

    final missing = await modern(token, 'resources/read', params: {'uri': 'den://nowhere'});
    expect(error(missing)['code'], -32602);
    final noList = await modern(token, 'resources/read', params: {'uri': 'den://lists/Nope'});
    expect(error(noList)['code'], -32602);

    final listsOnly = await f.token(scopes: {Scope.lists}, label: 'No reading');
    expect(result(await modern(listsOnly, 'resources/list'))['resources'], isEmpty);
  });

  test('prompts are offered when their tools are, and filled with what the person gives', () async {
    final writer = await f.token(scopes: {Scope.read, Scope.lists}, label: 'Prompts');
    final names = (result(await modern(writer, 'prompts/list'))['prompts'] as List).map((p) => (p as Map)['name']);
    expect(names, containsAll(['whats_today', 'plan_week', 'shopping_list', 'chores_left']));
    final reader = await f.token(scopes: {Scope.read}, label: 'Prompts, read only');
    final readerNames = (result(await modern(reader, 'prompts/list'))['prompts'] as List).map((p) => (p as Map)['name']);
    expect(readerNames, contains('plan_week'));
    expect(readerNames, isNot(contains('shopping_list')));

    final got = result(await modern(writer, 'prompts/get', params: {
      'name': 'shopping_list',
      'arguments': {'meals': 'tacos on Tuesday'},
    }));
    final message = ((got['messages'] as List).single as Map).cast<String, Object?>();
    expect(message['role'], 'user');
    expect((message['content'] as Map)['text'], allOf(contains('tacos on Tuesday'), contains('Groceries'), contains('add_items')));
    final missing = await modern(writer, 'prompts/get', params: {'name': 'shopping_list', 'arguments': <String, Object?>{}});
    expect(error(missing)['code'], -32602);
    final unknown = await modern(writer, 'prompts/get', params: {'name': 'nope'});
    expect(error(unknown)['code'], -32602);
  });

  test('subscriptions/listen says when a subscribed resource changes', () async {
    final token = await f.token(scopes: {Scope.read}, label: 'Listener');
    final body = request('subscriptions/listen', id: 'sub-1', params: {
      'notifications': {
        'toolsListChanged': true,
        'resourceSubscriptions': ['den://lists', 'den://nowhere'],
      },
    });
    final client = http.Client();
    addTearDown(client.close);
    final req = http.Request('POST', f.base.resolve('/mcp'))
      ..headers.addAll({'authorization': 'Bearer $token', 'content-type': 'application/json', ...mcpRequestHeaders(body)})
      ..body = jsonEncode(body);
    final res = await client.send(req);
    expect(res.statusCode, 200);
    expect(res.headers['content-type'], startsWith('text/event-stream'));
    final events = StreamQueue(res.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((l) => l.startsWith('data:'))
        .map((l) => (jsonDecode(l.substring(5)) as Map).cast<String, Object?>()));
    final ack = await events.next.timeout(const Duration(seconds: 10));
    expect(ack['method'], 'notifications/subscriptions/acknowledged');
    final ackParams = (ack['params'] as Map).cast<String, Object?>();
    expect(ackParams['notifications'], {
      'resourceSubscriptions': ['den://lists'],
    });
    expect((ackParams['_meta'] as Map)[McpMeta.subscriptionId], 'sub-1');

    // Let the hub take its first look at the lists, then change one.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final groceries = f.phone.lists.firstWhere((l) => l.list.title == 'Groceries').list.id;
    await f.phone.addItem(groceries, text: 'Basil');
    await f.toHub();
    final updated = await events.next.timeout(const Duration(seconds: 10));
    expect(updated['method'], 'notifications/resources/updated');
    final updatedParams = (updated['params'] as Map).cast<String, Object?>();
    expect(updatedParams['uri'], 'den://lists');
    expect((updatedParams['_meta'] as Map)[McpMeta.subscriptionId], 'sub-1');
    await events.cancel(immediate: true);
  });

  test('stdio serves 2026-07-28 requests too', () async {
    final token = await f.token(scopes: {Scope.read}, label: 'Stdio, modern');
    final input = StreamController<List<int>>();
    final lines = <String>[];
    final done = serveMcpStdio(f.hub.mcp, () => accessForToken(f.hubDen, token), input.stream, lines.add);
    input.add(utf8.encode('${jsonEncode(request('server/discover'))}\n'));
    input.add(utf8.encode('${jsonEncode(request('subscriptions/listen', id: 7))}\n'));
    input.add(utf8.encode('${jsonEncode(request('tools/list', version: '1900-01-01', id: 8))}\n'));
    await input.close();
    await done;
    final out = [for (final l in lines) (jsonDecode(l) as Map).cast<String, Object?>()];
    expect(out, hasLength(4));
    expect((out[0]['result'] as Map)['supportedVersions'], contains('2026-07-28'));
    expect(out[1]['method'], 'notifications/subscriptions/acknowledged');
    expect(out[2]['id'], 7);
    expect((out[2]['result'] as Map)['resultType'], 'complete');
    expect((out[3]['error'] as Map)['code'], -32022);
  });
}
