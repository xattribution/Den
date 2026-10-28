import 'package:den_assistant/den_assistant.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('Ollama request', () {
    test('one system message, function tools, a bigger context and the output cap', () {
      final model = OllamaChatModel(endpoint: ModelEndpoint.direct(baseUrl: Uri.parse('http://192.168.1.20:11434')));
      final body = model.body(sampleRequest());
      expect(body['model'], 'qwen3:8b');
      expect(body['stream'], isFalse);
      expect(body['options'], {'num_predict': 1000, 'num_ctx': 16384});
      expect(body.containsKey('think'), isFalse);
      expect(at(body, ['tools', 0]), {
        'type': 'function',
        'function': {'name': 'add_items', 'description': 'Adds items to a list.', 'parameters': addItems.input},
      });
      expect(body['messages'], [
        {'role': 'system', 'content': 'Static rules\n\nFamily facts\n\nNow: 3:42 PM.'},
        {'role': 'user', 'content': 'Add eggs to groceries'},
      ]);
    });

    test('sends calls back with arguments as objects and results as tool messages', () {
      final model = OllamaChatModel(endpoint: const ModelEndpoint.direct(), think: false, keepAlive: '30m');
      final previous = OllamaChatModel.parse(200, fixtureJson('ollama/tool_call.json'), model: 'qwen3:8b');
      final body = model.body(sampleRequest(
        toolChoice: ToolChoice.none,
        messages: [
          const UserMessage('Add eggs'),
          previous.message,
          ToolResultsMessage([
            ToolResult(callId: previous.toolCalls.single.id, name: 'add_items', content: '{"done":true}'),
          ]),
        ],
      ));
      expect(body['think'], isFalse);
      expect(body['keep_alive'], '30m');
      expect(body.containsKey('tools'), isFalse);
      final messages = body['messages'] as List;
      expect(messages[2], {
        'role': 'assistant',
        'content': '',
        'thinking': 'They want eggs on the grocery list.',
        'tool_calls': [
          {
            'type': 'function',
            'function': {
              'index': 0,
              'name': 'add_items',
              'arguments': {
                'list': 'Groceries',
                'items': [
                  {'text': 'Eggs'},
                ],
              },
            },
          },
        ],
      });
      expect(messages[3], {'role': 'tool', 'tool_name': 'add_items', 'content': '{"done":true}'});
    });

    test('sends photos as base64 to a model that can see them', () {
      final model = OllamaChatModel(endpoint: const ModelEndpoint.direct(), model: 'qwen3.8:27b');
      final body = model.body(sampleRequest(messages: [UserMessage('What is this?', images: [tinyPng])]));
      expect(at(body, ['messages', 1, 'images', 0]), tinyPng.base64Data);
    });
  });

  group('Ollama response', () {
    test('posts to /api/chat at home, and reads a call with a made-up id', () async {
      final recorder = Recorder();
      final model = OllamaChatModel(
        endpoint: ModelEndpoint.direct(baseUrl: Uri.parse('http://192.168.1.20:11434')),
        client: recorder.answer(200, 'ollama/tool_call.json'),
      );
      expect(model.info.dataGoesTo, 'home');
      expect(model.info.staysHome, isTrue);
      final reply = await model.respond(sampleRequest());
      final request = recorder.requests.single;
      expect(request.url.toString(), 'http://192.168.1.20:11434/api/chat');
      expect(request.headers.containsKey('authorization'), isFalse);
      expect(reply.stopReason, StopReason.toolUse);
      expect(reply.toolCalls.single.name, 'add_items');
      expect(reply.toolCalls.single.syntheticId, isTrue);
      expect(reply.toolCalls.single.input, {
        'list': 'Groceries',
        'items': [
          {'text': 'Eggs'},
        ],
      });
      expect(reply.usage.inputTokens, 3900);
      expect(reply.usage.outputTokens, 38);
      expect(reply.usage.costUsd(model.info.price), 0);
    });

    test('reads text', () {
      final reply = OllamaChatModel.parse(200, fixtureJson('ollama/text.json'), model: 'qwen3:8b');
      expect(reply.text, 'Added eggs to Groceries.');
      expect(reply.stopReason, StopReason.endTurn);
      expect(reply.message.state, isNull);
    });

    test('a model that isn\'t pulled says how to get it; photos need a model that sees', () async {
      expect(
        () => OllamaChatModel.parse(404, fixtureJson('ollama/error_404.json'), model: 'qwen3:8b'),
        throwsA(isA<ModelException>()
            .having((e) => e.kind, 'kind', ModelFailure.notFound)
            .having((e) => e.message, 'message', contains('ollama pull qwen3:8b'))),
      );
      final model = OllamaChatModel(endpoint: const ModelEndpoint.direct(), client: Recorder().answer(200, 'ollama/text.json'));
      await expectLater(
        model.respond(sampleRequest(messages: [UserMessage('What is this?', images: [tinyPng])])),
        throwsA(isA<ModelException>().having((e) => e.message, 'message', contains('can\'t look at photos'))),
      );
    });
  });
}
