/// MCP offers exactly den_actions' specs, filtered by the caller's scopes and permissions; every
/// schema works for every provider; every example answers as its output schema says; and every
/// tool is also a REST action.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';

import 'package:den_actions/den_actions.dart';
import 'package:den_assistant/den_assistant.dart' show checkPortableSchema, geminiSchemaFor, jsonSchemaFor;
import 'package:den_core/den_core.dart';
import 'support/test.dart';

import 'support/fixture.dart';

void main() {
  late HubFixture f;
  final specs = [for (final s in allActions()) if (s.surfaces.contains(Surface.mcp)) s];

  setUpAll(() async {
    f = await HubFixture.start();
    // What the examples expect of the demo family (as den_actions' tests set it up).
    final phone = f.phone;
    final alex = phone.actor!.id;
    for (final m in phone.members) {
      if (m.id != alex) await phone.adjustPoints(m.id, 100, 'Demo stars');
    }
    final maya = f.id('Maya');
    if (!phone.points().pending.any((p) => p.member == maya)) {
      await phone.requestReward(phone.points().rewards.firstWhere((r) => r.needsApproval).id, member: maya);
    }
    await phone.addSubscription(url: 'https://calendar.invalid/school.ics', label: 'School calendar');
    await f.toHub();
  });
  tearDownAll(() => f.stop());

  Future<Map<String, Object?>> rpc(String token, String session, String method, [Map<String, Object?>? params]) async {
    final r = await f.call('POST', '/mcp',
        token: token, body: {'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': ?params}, headers: {'mcp-session-id': session});
    expect(r.status, 200, reason: r.text);
    return (r.body['result'] as Map).cast<String, Object?>();
  }

  Future<String> open(String token) async {
    final r = await f.call('POST', '/mcp', token: token, body: {
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {'protocolVersion': '2025-11-25'},
    });
    return r.headers['mcp-session-id']!;
  }

  Future<List<Map<String, Object?>>> list(String token) async {
    final result = await rpc(token, await open(token), 'tools/list');
    return (result['tools'] as List).cast<Map<String, Object?>>();
  }

  test('an admin parent\'s tools/list is every MCP spec, with its schemas and hints', () async {
    final token = await f.token(scopes: {Scope.admin}, member: f.id('Alex'), label: 'Parity parent');
    final tools = await list(token);
    expect(tools.map((t) => t['name']), [for (final s in specs) s.mcpName]);
    for (var i = 0; i < specs.length; i++) {
      expect(tools[i], jsonDecode(jsonEncode(specs[i].toolJson())), reason: specs[i].mcpName);
      final hints = tools[i]['annotations'] as Map;
      expect(hints.keys, containsAll(['readOnlyHint', 'destructiveHint', 'idempotentHint', 'openWorldHint']));
      expect(hints['openWorldHint'], isFalse);
    }
  });

  test('a kid sees only what can() allows, and a hidden tool is refused', () async {
    final leo = f.hubDen.member(f.id('Leo'))!;
    final token = await f.token(scopes: {Scope.admin}, member: leo.id, label: 'Parity kid');
    final names = (await list(token)).map((t) => t['name']).toSet();
    final allowed = {
      for (final s in specs)
        if (s.needs.isEmpty || s.needs.any((a) => can(leo, a))) s.mcpName,
    };
    expect(names, allowed);
    expect(names, containsAll(['get_overview', 'complete_chore', 'swap_chore', 'update_items', 'request_reward', 'undo']));
    expect(names, isNot(contains('add_items')));
    expect(names, isNot(contains('adjust_points')));
    expect(names, isNot(contains('save_member')));
    final session = await open(token);
    final refused = await rpc(token, session, 'tools/call', {
      'name': 'add_items',
      'arguments': {'list': 'Groceries', 'items': ['Popcorn']},
    });
    expect(refused['isError'], isTrue);
    expect(((refused['content'] as List).single as Map)['text'], startsWith('Den didn\'t allow that: Leo can\'t'));
    // A token acts as the parent who made it (MCP eval #4): what that parent may do, within its scopes.
    final automation = await f.token(scopes: {Scope.admin}, label: 'Parity automation');
    final auto = (await list(automation)).map((t) => t['name']).toSet();
    expect(auto, containsAll(['add_items', 'save_member']));
    final lists = await f.token(scopes: {Scope.lists}, label: 'Parity lists');
    expect((await list(lists)).map((t) => t['name']), isNot(contains('save_member')));
    final reader = await f.token(scopes: {Scope.read}, member: f.id('Alex'), label: 'Parity reader');
    final read = await list(reader);
    expect(read.every((t) => (t['annotations'] as Map)['readOnlyHint'] == true), isTrue);
  });

  test('every input schema is in the subset Claude, OpenAI, Gemini and Grok all take', () {
    final openAiName = RegExp(r'^[a-zA-Z0-9_-]{1,64}$');
    final geminiName = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]{0,63}$');
    for (final s in specs) {
      expect(checkPortableSchema(s.inputSchema), isEmpty, reason: s.mcpName);
      expect(s.mcpName, matches(openAiName));
      expect(s.mcpName, matches(geminiName));
      final text = jsonEncode(s.inputSchema);
      for (final word in ['anyOf', 'oneOf', 'allOf', r'$ref', 'format', 'default']) {
        expect(text, isNot(contains('"$word"')), reason: '${s.mcpName} uses $word');
      }
      expect(jsonSchemaFor(s.inputSchema)['type'], 'object');
      geminiSchemaFor(s.inputSchema);
      expect(s.outputSchema['type'], 'object', reason: 'MCP\'s outputSchema is an object');
    }
  });

  test('every example runs over MCP for an admin parent, and its answer fits its output schema', () async {
    final token = await f.token(scopes: {Scope.admin}, member: f.id('Alex'), label: 'Parity examples');
    final session = await open(token);
    for (final s in specs) {
      var result = await rpc(token, session, 'tools/call', {'name': s.mcpName, 'arguments': s.example});
      final confirm = (result['structuredContent'] as Map?)?['confirm'];
      if (confirm is Map) {
        result = await rpc(token, session, 'tools/call', {
          'name': s.mcpName,
          'arguments': {...s.example, 'confirm': confirm['token']},
        });
      }
      final text = ((result['content'] as List).single as Map)['text'];
      expect(result['isError'], isFalse, reason: '${s.mcpName}: $text');
      final structured = result['structuredContent'];
      expect(schemaProblems(s.outputSchema, structured), isEmpty, reason: s.mcpName);
      if (!s.readOnly) expect((structured as Map)['receipt'], isA<Map>(), reason: '${s.mcpName} returns a receipt');
    }
  });

  test('every MCP tool is a REST action too', () async {
    final token = await f.token(scopes: {Scope.admin}, member: f.id('Alex'), label: 'Parity REST');
    final r = await f.call('GET', '/api/v1/actions', token: token);
    expect(r.status, 200, reason: r.text);
    final names = [for (final a in (r.body['actions'] as List).cast<Map>()) a['name']];
    expect(names, containsAll([for (final s in specs) s.mcpName]));
    for (final s in specs) {
      expect(s.surfaces, contains(Surface.rest), reason: s.mcpName);
    }
  });
}
