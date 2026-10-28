import 'package:den_assistant/den_assistant.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('Anthropic request', () {
    test('caches the tools and the cached system blocks, and the conversation', () {
      final model = AnthropicChatModel(endpoint: const ModelEndpoint.direct(apiKey: 'k'));
      final body = model.body(sampleRequest());
      expect(body['model'], 'claude-haiku-5-5');
      expect(body['max_tokens'], 1000);
      expect(body['cache_control'], {'type': 'ephemeral'});
      expect(at(body, ['tools', 0, 'name']), 'add_items');
      expect(at(body, ['tools', 0, 'description']), 'Adds items to a list.');
      expect(at(body, ['tools', 0, 'input_schema']), addItems.input);
      expect((at(body, ['tools', 0]) as Map).containsKey('cache_control'), isFalse);
      expect(at(body, ['tools', 1]), {
        'name': 'get_today',
        'description': 'Reads today.',
        'input_schema': {'type': 'object', 'properties': <String, Object?>{}},
        'cache_control': {'type': 'ephemeral'},
      });
      expect(body['system'], [
        {'type': 'text', 'text': 'Static rules', 'cache_control': {'type': 'ephemeral'}},
        {'type': 'text', 'text': 'Family facts', 'cache_control': {'type': 'ephemeral'}},
        {'type': 'text', 'text': 'Now: 3:42 PM.'},
      ]);
      expect(body.containsKey('tool_choice'), isFalse);
      expect(body['messages'], [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'Add eggs to groceries'},
          ],
        },
      ]);
    });

    test('uses at most three explicit breakpoints, with the TTL asked for', () {
      final model = AnthropicChatModel(endpoint: const ModelEndpoint.direct(apiKey: 'k'), cacheTtl: '1h');
      final body = model.body(ModelRequest(
        system: const [
          SystemBlock('a', cache: true),
          SystemBlock('b', cache: true),
          SystemBlock('c', cache: true),
        ],
        messages: const [UserMessage('hi')],
        tools: const [getToday],
      ));
      expect(at(body, ['tools', 0, 'cache_control']), {'type': 'ephemeral', 'ttl': '1h'});
      expect(at(body, ['system', 0, 'cache_control']), {'type': 'ephemeral', 'ttl': '1h'});
      expect(at(body, ['system', 1, 'cache_control']), {'type': 'ephemeral', 'ttl': '1h'});
      expect((at(body, ['system', 2]) as Map).containsKey('cache_control'), isFalse);
      expect(body['cache_control'], {'type': 'ephemeral', 'ttl': '1h'});
    });

    test('sends Claude\'s turn back unchanged, then the results and the next words in one turn', () {
      final model = AnthropicChatModel(endpoint: const ModelEndpoint.direct(apiKey: 'k'));
      final fixture = fixtureJson('anthropic/tool_use.json');
      final previous = AnthropicChatModel.parse(200, fixture, model: model.model);
      final body = model.body(sampleRequest(messages: [
        const UserMessage('Add eggs and 2 milk to groceries'),
        previous.message,
        ToolResultsMessage([
          ToolResult(callId: previous.toolCalls.single.id, name: 'add_items', content: '{"done":true}'),
        ]),
        const UserMessage('Thanks!'),
      ]));
      final messages = body['messages'] as List;
      expect(messages, hasLength(3));
      expect(at(messages, [1, 'role']), 'assistant');
      expect(at(messages, [1, 'content']), fixture['content']);
      expect(at(messages, [1, 'content', 0, 'signature']), 'EqQBCkYIBxgCKkDenFixtureSignatureForThinking');
      expect(at(messages, [2]), {
        'role': 'user',
        'content': [
          {'type': 'tool_result', 'tool_use_id': 'toolu_01A09q90qw90lq917835lq9', 'content': '{"done":true}'},
          {'type': 'text', 'text': 'Thanks!'},
        ],
      });
    });

    test('writes another provider\'s turn as tool_use blocks, and marks errors', () {
      final model = AnthropicChatModel(endpoint: const ModelEndpoint.direct(apiKey: 'k'));
      final body = model.body(sampleRequest(messages: [
        const UserMessage('What is on today?'),
        const AssistantMessage(
          text: 'Checking.',
          toolCalls: [ToolCall(id: 'fc:7/a', name: 'get_today')],
          state: ProviderState(provider: 'gemini', data: []),
        ),
        const ToolResultsMessage([ToolResult(callId: 'fc:7/a', name: 'get_today', content: 'Calendar is offline', isError: true)]),
      ]));
      expect(at(body, ['messages', 1, 'content']), [
        {'type': 'text', 'text': 'Checking.'},
        {'type': 'tool_use', 'id': 'fc_7_a', 'name': 'get_today', 'input': <String, Object?>{}},
      ]);
      expect(at(body, ['messages', 2, 'content', 0]), {
        'type': 'tool_result',
        'tool_use_id': 'fc_7_a',
        'content': 'Calendar is offline',
        'is_error': true,
      });
    });

    test('says when the turn may not call tools, sets effort, and sends photos', () {
      final model = AnthropicChatModel(endpoint: const ModelEndpoint.direct(apiKey: 'k'), effort: 'low');
      final body = model.body(sampleRequest(
        toolChoice: ToolChoice.none,
        messages: [UserMessage('What is this?', images: [tinyPng])],
      ));
      expect(body['tool_choice'], {'type': 'none'});
      expect(body['output_config'], {'effort': 'low'});
      expect(at(body, ['messages', 0, 'content', 0, 'type']), 'image');
      expect(at(body, ['messages', 0, 'content', 0, 'source', 'media_type']), 'image/png');
      expect(at(body, ['messages', 0, 'content', 1]), {'type': 'text', 'text': 'What is this?'});
    });
  });

  group('Anthropic response', () {
    test('posts to the Messages API with the key, and reads tool calls and cache reads', () async {
      final recorder = Recorder();
      final model = AnthropicChatModel(
        endpoint: const ModelEndpoint.direct(apiKey: 'sk-ant-test'),
        client: recorder.answer(200, 'anthropic/tool_use.json'),
      );
      final reply = await model.respond(sampleRequest());
      final request = recorder.requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://api.anthropic.com/v1/messages');
      expect(request.headers['x-api-key'], 'sk-ant-test');
      expect(request.headers['anthropic-version'], '2023-06-01');
      expect(recorder.lastBody['model'], 'claude-haiku-5-5');
      expect(reply.stopReason, StopReason.toolUse);
      expect(reply.text, 'I\'ll add those to Groceries.');
      expect(reply.toolCalls.single.id, 'toolu_01A09q90qw90lq917835lq9');
      expect(reply.toolCalls.single.name, 'add_items');
      expect(reply.toolCalls.single.input, {
        'list': 'Groceries',
        'items': [
          {'text': 'Eggs'},
          {'text': 'Milk', 'qty': '2'},
        ],
      });
      expect(reply.usage.inputTokens, 412);
      expect(reply.usage.cacheReadTokens, 3880);
      expect(reply.usage.cacheWriteTokens, 0);
      expect(reply.usage.outputTokens, 96);
      expect(reply.message.state?.provider, 'anthropic');
      expect(reply.model, 'claude-haiku-5-5');
    });

    test('reads a text answer with a cache write, and its cost', () {
      final reply = AnthropicChatModel.parse(200, fixtureJson('anthropic/text.json'), model: 'claude-haiku-5-5');
      expect(reply.stopReason, StopReason.endTurn);
      expect(reply.text, 'Added eggs and 2 milk to Groceries.');
      expect(reply.toolCalls, isEmpty);
      expect(reply.usage.cacheWriteTokens, 3880);
      expect(reply.usage.inputTokens, 57);
      // 57 x $0.10 + 14 x $0.50 + 3880 x $0.125, per million.
      expect(reply.usage.costUsd(defaultModel(ModelProvider.anthropic).price), closeTo(0.0004977, 0.0000001));
    });

    test('drops null fields when sending a turn back', () {
      final model = AnthropicChatModel(endpoint: const ModelEndpoint.direct(apiKey: 'k'));
      final reply = AnthropicChatModel.parse(200, fixtureJson('anthropic/text.json'), model: 'claude-haiku-5-5');
      final body = model.body(sampleRequest(messages: [const UserMessage('Add eggs'), reply.message, const UserMessage('Thanks')]));
      expect(at(body, ['messages', 1, 'content', 1]), {'type': 'text', 'text': 'Added eggs and 2 milk to Groceries.'});
    });

    test('maps stop reasons', () {
      StopReason stop(String reason) => AnthropicChatModel.parse(
            200,
            {
              'content': [
                {'type': 'text', 'text': 'x'},
              ],
              'stop_reason': reason,
            },
            model: 'm',
          ).stopReason;
      expect(stop('end_turn'), StopReason.endTurn);
      expect(stop('max_tokens'), StopReason.maxTokens);
      expect(stop('refusal'), StopReason.refusal);
      expect(stop('model_context_window_exceeded'), StopReason.contextFull);
      expect(stop('pause_turn'), StopReason.other);
    });

    test('turns error statuses into messages people can read', () {
      expect(
        () => AnthropicChatModel.parse(401, fixtureJson('anthropic/error_401.json'), model: 'claude-haiku-5-5'),
        throwsA(isA<ModelException>()
            .having((e) => e.kind, 'kind', ModelFailure.auth)
            .having((e) => e.detail, 'detail', 'invalid x-api-key')
            .having((e) => e.message, 'message', contains('Claude didn\'t accept the API key'))),
      );
      expect(
        () => AnthropicChatModel.parse(529, const {}, model: 'claude-haiku-5-5'),
        throwsA(isA<ModelException>().having((e) => e.retry, 'retry', isTrue).having((e) => e.kind, 'kind', ModelFailure.busy)),
      );
    });
  });

  group('Anthropic through the hub', () {
    test('posts to the hub, signed, without the key, naming provider and model', () async {
      final recorder = Recorder();
      final hub = Uri.parse('https://hub.local:8443/api/v1/assistant/model');
      final model = AnthropicChatModel(
        endpoint: ModelEndpoint.hub(
          hub,
          sign: (method, url, body) async => {'x-den-device': 'dev-1', 'x-den-signature': '$method ${url.path} ${body.length}'},
        ),
        client: recorder.answer(200, 'anthropic/text.json'),
        browser: true,
      );
      final reply = await model.respond(sampleRequest());
      final request = recorder.requests.single;
      expect(request.url, hub);
      expect(request.headers[HubHeaders.provider], 'anthropic');
      expect(request.headers[HubHeaders.model], 'claude-haiku-5-5');
      expect(request.headers['x-den-signature'], 'POST /api/v1/assistant/model ${request.bodyBytes.length}');
      expect(request.headers.containsKey('x-api-key'), isFalse);
      expect(request.headers.containsKey('anthropic-version'), isFalse);
      expect(request.headers.containsKey('anthropic-dangerous-direct-browser-access'), isFalse);
      expect(reply.text, 'Added eggs and 2 milk to Groceries.');
    });

    test('shows the hub\'s own refusals as they are', () {
      expect(
        () => AnthropicChatModel.parse(
          429,
          {
            'error': {'message': 'Leo has used today\'s 20 questions. Try again tomorrow.'},
          },
          model: 'claude-haiku-5-5',
          viaHub: true,
        ),
        throwsA(isA<ModelException>()
            .having((e) => e.message, 'message', 'Leo has used today\'s 20 questions. Try again tomorrow.')
            .having((e) => e.kind, 'kind', ModelFailure.rateLimited)),
      );
    });
  });
}
