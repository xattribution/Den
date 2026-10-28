import 'package:den_assistant/den_assistant.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('OpenAI request', () {
    test('instructions, function tools that aren\'t strict, stateless and capped', () {
      final model = OpenAIChatModel(endpoint: const ModelEndpoint.direct(apiKey: 'k'));
      final body = model.body(sampleRequest());
      expect(body['model'], 'gpt-6-luna');
      expect(body['instructions'], 'Static rules\n\nFamily facts\n\nNow: 3:42 PM.');
      expect(body['store'], isFalse);
      expect(body['max_output_tokens'], 1000);
      expect(body['prompt_cache_key'], 'family-1:m1');
      expect(body['reasoning'], {'effort': 'low'});
      expect(body.containsKey('tool_choice'), isFalse);
      expect(at(body, ['tools', 0]), {
        'type': 'function',
        'name': 'add_items',
        'description': 'Adds items to a list.',
        'parameters': addItems.input,
        'strict': false,
      });
      expect(at(body, ['tools', 1, 'parameters']), {'type': 'object', 'properties': <String, Object?>{}});
      expect(body['input'], [
        {
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': 'Add eggs to groceries'},
          ],
        },
      ]);
    });

    test('sends the reasoning and call items back, then the outputs', () {
      final model = OpenAIChatModel(endpoint: const ModelEndpoint.direct(apiKey: 'k'));
      final previous = OpenAIChatModel.parse(
        ModelProvider.openai,
        200,
        fixtureJson('openai/function_call.json'),
        model: model.model,
      );
      final body = model.body(sampleRequest(
        toolChoice: ToolChoice.none,
        messages: [
          const UserMessage('Add eggs to groceries'),
          previous.message,
          const ToolResultsMessage([
            ToolResult(callId: 'call_k9Xr2QfDenFixture', name: 'add_items', content: '{"done":true}'),
          ]),
        ],
      ));
      final input = body['input'] as List;
      expect(input, hasLength(4));
      expect(input[1], {
        'id': 'rs_68f0denreasoning',
        'type': 'reasoning',
        'summary': <Object?>[],
        'encrypted_content': 'gAAAAABoDenEncryptedReasoningFixture',
      });
      expect(at(input, [2, 'type']), 'function_call');
      expect(at(input, [2, 'call_id']), 'call_k9Xr2QfDenFixture');
      expect(input[3], {'type': 'function_call_output', 'call_id': 'call_k9Xr2QfDenFixture', 'output': '{"done":true}'});
      expect(body['tool_choice'], 'none');
    });

    test('writes another provider\'s turn as items, errors as JSON, and photos as data URLs', () {
      final model = OpenAIChatModel(endpoint: const ModelEndpoint.direct(apiKey: 'k'));
      final body = model.body(sampleRequest(messages: [
        UserMessage('Add this', images: [tinyPng]),
        const AssistantMessage(
          text: 'On it.',
          toolCalls: [
            ToolCall(id: 'toolu_1', name: 'add_items', input: {'list': 'Groceries', 'items': <Object?>[]}),
          ],
        ),
        const ToolResultsMessage([ToolResult(callId: 'toolu_1', name: 'add_items', content: 'No list called Groceries', isError: true)]),
      ]));
      final input = body['input'] as List;
      expect(at(input, [0, 'content', 0, 'type']), 'input_image');
      expect(at(input, [0, 'content', 0, 'image_url']), startsWith('data:image/png;base64,iVBOR'));
      expect(input[1], {'role': 'assistant', 'content': 'On it.'});
      expect(input[2], {
        'type': 'function_call',
        'call_id': 'toolu_1',
        'name': 'add_items',
        'arguments': '{"list":"Groceries","items":[]}',
      });
      expect(input[3], {
        'type': 'function_call_output',
        'call_id': 'toolu_1',
        'output': '{"error":"No list called Groceries"}',
      });
    });
  });

  group('OpenAI response', () {
    test('posts to /v1/responses with a bearer key, and reads a call and cached input', () async {
      final recorder = Recorder();
      final model = OpenAIChatModel(
        endpoint: const ModelEndpoint.direct(apiKey: 'sk-test'),
        client: recorder.answer(200, 'openai/function_call.json'),
      );
      final reply = await model.respond(sampleRequest());
      final request = recorder.requests.single;
      expect(request.url.toString(), 'https://api.openai.com/v1/responses');
      expect(request.headers['authorization'], 'Bearer sk-test');
      expect(reply.stopReason, StopReason.toolUse);
      expect(reply.toolCalls.single.id, 'call_k9Xr2QfDenFixture');
      expect(reply.toolCalls.single.input, {
        'list': 'Groceries',
        'items': [
          {'text': 'Eggs'},
        ],
      });
      expect(reply.usage.inputTokens, 460);
      expect(reply.usage.cacheReadTokens, 3840);
      expect(reply.usage.outputTokens, 61);
      expect(reply.message.state?.provider, 'openai');
    });

    test('reads text, cache writes, and a cut-off answer', () {
      final text = OpenAIChatModel.parse(ModelProvider.openai, 200, fixtureJson('openai/text.json'), model: 'gpt-6-luna');
      expect(text.text, 'Added eggs to Groceries.');
      expect(text.stopReason, StopReason.endTurn);
      expect(text.usage.inputTokens, 1000);
      expect(text.usage.cacheWriteTokens, 4000);

      final cut = OpenAIChatModel.parse(ModelProvider.openai, 200, fixtureJson('openai/incomplete.json'), model: 'gpt-6-luna');
      expect(cut.stopReason, StopReason.maxTokens);
      expect(cut.rawStopReason, 'max_output_tokens');
      expect(cut.text, isEmpty);
    });

    test('reads a refusal and arguments that aren\'t JSON', () {
      final refused = OpenAIChatModel.parse(
        ModelProvider.openai,
        200,
        {
          'status': 'completed',
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'refusal', 'refusal': 'I can\'t help with that.'},
              ],
            },
          ],
        },
        model: 'gpt-6-luna',
      );
      expect(refused.stopReason, StopReason.refusal);
      expect(refused.text, 'I can\'t help with that.');

      final broken = OpenAIChatModel.parse(
        ModelProvider.openai,
        200,
        {
          'status': 'completed',
          'output': [
            {'type': 'function_call', 'call_id': 'call_1', 'name': 'add_items', 'arguments': '{"list": "Groc'},
          ],
        },
        model: 'gpt-6-luna',
      );
      expect(broken.toolCalls.single.problem, contains('weren\'t a JSON object'));
    });

    test('rate limits are worth retrying', () {
      expect(
        () => OpenAIChatModel.parse(ModelProvider.openai, 429, fixtureJson('openai/error_429.json'), model: 'gpt-6-luna'),
        throwsA(isA<ModelException>()
            .having((e) => e.kind, 'kind', ModelFailure.rateLimited)
            .having((e) => e.retry, 'retry', isTrue)
            .having((e) => e.detail, 'detail', startsWith('Rate limit reached'))),
      );
    });
  });

  group('xAI Grok', () {
    test('the same adapter at api.x.ai, without reasoning or strict', () async {
      final recorder = Recorder();
      final model = OpenAIChatModel.grok(
        endpoint: const ModelEndpoint.direct(apiKey: 'xai-test'),
        client: recorder.answer(200, 'openai/grok_function_call.json'),
      );
      expect(model.info.provider, ModelProvider.xai);
      expect(model.info.dataGoesTo, 'xAI');
      final reply = await model.respond(sampleRequest());
      final request = recorder.requests.single;
      expect(request.url.toString(), 'https://api.x.ai/v1/responses');
      expect(request.headers['authorization'], 'Bearer xai-test');
      final body = recorder.lastBody;
      expect(body['model'], 'grok-4.20-0309-non-reasoning');
      expect(body.containsKey('reasoning'), isFalse);
      expect((at(body, ['tools', 0]) as Map).containsKey('strict'), isFalse);
      expect(reply.toolCalls.single.name, 'check_item');
      expect(reply.toolCalls.single.input, {'item': 'Milk', 'list': 'Groceries'});
      expect(reply.usage.inputTokens, 52);
      expect(reply.usage.cacheReadTokens, 2048);
      expect(reply.message.state?.provider, 'xai');
    });

    test('an OpenAI turn isn\'t replayed to Grok', () {
      final openai = OpenAIChatModel.parse(ModelProvider.openai, 200, fixtureJson('openai/function_call.json'), model: 'gpt-6-luna');
      final grok = OpenAIChatModel.grok(endpoint: const ModelEndpoint.direct(apiKey: 'k'));
      final input = grok.body(sampleRequest(messages: [const UserMessage('Add eggs'), openai.message]))['input'] as List;
      expect(input, hasLength(2));
      expect(at(input, [1, 'type']), 'function_call');
    });
  });
}
