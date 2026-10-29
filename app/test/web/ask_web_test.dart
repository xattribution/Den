@TestOn('browser')
library;

import 'dart:convert';

import 'package:den_app/app/app_state.dart';
import 'package:den_app/features/assistant/state/ask_session.dart';
import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'ask_e2e_app.dart' show PageOriginLink;

/// Ask in the browser: the conversation, the Claude adapter and the hub's two helper endpoints,
/// compiled for the web the way the Home Screen app is. Everything goes to the page's own origin,
/// which the hub's Content-Security-Policy allows and nothing else.
void main() {
  test('the helper asks the hub at the page\'s own origin and shows what it says', () async {
    tzdata.initializeTimeZones();
    final den = await createDemoFamily();
    await den.updateFamily({'assistant': const AssistantPolicy(enabled: true).toJson()});
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      final body = switch (request.url.path) {
        '/api/v1/assistant' => {
            'provider': 'anthropic',
            'speaker': 'Claude',
            'models': [
              {'model': 'claude-haiku-5-5', 'size': 'small'},
            ],
            'you': {'allowed': true},
            'this_month': {'month': '2026-10', 'stopped': false},
          },
        _ => {
            'id': 'msg_web',
            'type': 'message',
            'role': 'assistant',
            'model': 'claude-haiku-5-5',
            'content': [
              {'type': 'text', 'text': 'Zoe has her swim lesson at 4:30 PM.'},
            ],
            'stop_reason': 'end_turn',
            'usage': {'input_tokens': 900, 'output_tokens': 12},
          },
      };
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    });
    final session = AskSession(app: AppState(den), link: PageOriginLink(client));
    addTearDown(session.dispose);

    await session.peek();
    expect(session.gate, isNull);
    expect(session.speaker, 'Claude');
    await session.ask("What's on today?");
    expect(session.exchanges.single.problem, isNull);
    expect(session.exchanges.single.answer, 'Zoe has her swim lesson at 4:30 PM.');
    expect([for (final r in requests) '${r.method} ${r.url.path}'], [
      'GET /api/v1/assistant',
      'POST /api/v1/assistant/model',
    ], reason: 'what the hub said as Ask opened counts for the first question');
    expect(requests.every((r) => r.url.origin == Uri.base.origin), isTrue, reason: 'same origin only');
    expect(requests.last.headers['x-den-provider'], 'anthropic');
    expect(jsonDecode(requests.last.body)['messages'].toString(), contains("What's on today?"));
  });
}
