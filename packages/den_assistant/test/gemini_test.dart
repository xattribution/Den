import 'package:den_assistant/den_assistant.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('Gemini request', () {
    test('system instruction, function declarations in Gemini\'s schema, output cap', () {
      final model = GeminiChatModel(endpoint: const ModelEndpoint.direct(apiKey: 'k'));
      final body = model.body(sampleRequest());
      expect(body['systemInstruction'], {
        'parts': [
          {'text': 'Static rules'},
          {'text': 'Family facts'},
          {'text': 'Now: 3:42 PM.'},
        ],
      });
      expect(at(body, ['tools', 0, 'functionDeclarations', 0]), {
        'name': 'add_items',
        'description': 'Adds items to a list.',
        'parameters': {
          'type': 'OBJECT',
          'properties': {
            'list': {'type': 'STRING', 'description': 'The list.'},
            'items': {
              'type': 'ARRAY',
              'maxItems': 100,
              'items': {
                'type': 'OBJECT',
                'properties': {
                  'text': {'type': 'STRING'},
                  'qty': {'type': 'STRING'},
                },
                'required': ['text'],
              },
            },
          },
          'required': ['list', 'items'],
        },
      });
      // A tool without inputs is declared without parameters.
      expect(at(body, ['tools', 0, 'functionDeclarations', 1]), {'name': 'get_today', 'description': 'Reads today.'});
      expect(body['generationConfig'], {'maxOutputTokens': 1000});
      expect(body.containsKey('toolConfig'), isFalse);
      expect(body['contents'], [
        {
          'role': 'user',
          'parts': [
            {'text': 'Add eggs to groceries'},
          ],
        },
      ]);
    });

    test('sends Gemini\'s parts back with their signatures, then the responses and the next words', () {
      final model = GeminiChatModel(endpoint: const ModelEndpoint.direct(apiKey: 'k'), thinkingLevel: 'low');
      final fixture = fixtureJson('gemini/function_call.json');
      final previous = GeminiChatModel.parse(200, fixture, model: model.model);
      final body = model.body(sampleRequest(
        toolChoice: ToolChoice.none,
        messages: [
          const UserMessage('Add eggs and check off milk'),
          previous.message,
          ToolResultsMessage([
            ToolResult(callId: previous.toolCalls[0].id, name: 'add_items', content: '{"done":true,"summary":"Added Eggs"}'),
            ToolResult(callId: previous.toolCalls[1].id, name: 'check_item', content: 'Milk is on two lists', isError: true),
          ]),
          const UserMessage('Thanks'),
        ],
      ));
      final contents = body['contents'] as List;
      expect(contents, hasLength(3));
      expect(at(contents, [1, 'role']), 'model');
      expect(at(contents, [1, 'parts']), at(fixture, ['candidates', 0, 'content', 'parts']));
      expect(at(contents, [1, 'parts', 0, 'thoughtSignature']), 'CiQBVKhcDenFixtureSignatureA');
      expect(at(contents, [2]), {
        'role': 'user',
        'parts': [
          {
            'functionResponse': {
              'name': 'add_items',
              'id': 'fc-7a1b',
              'response': {
                'output': {'done': true, 'summary': 'Added Eggs'},
              },
            },
          },
          {
            'functionResponse': {
              'name': 'check_item',
              'id': 'fc-7a1c',
              'response': {'error': 'Milk is on two lists'},
            },
          },
          {'text': 'Thanks'},
        ],
      });
      expect(body['toolConfig'], {
        'functionCallingConfig': {'mode': 'NONE'},
      });
      expect(body['generationConfig'], {
        'maxOutputTokens': 1000,
        'thinkingConfig': {'thinkingLevel': 'low'},
      });
    });

    test('another provider\'s calls get the documented stand-in signature, made-up ids stay home', () {
      final model = GeminiChatModel(endpoint: const ModelEndpoint.direct(apiKey: 'k'));
      final body = model.body(sampleRequest(messages: [
        const UserMessage('Add eggs'),
        AssistantMessage(toolCalls: [
          const ToolCall(id: 'toolu_1', name: 'add_items', input: {'list': 'Groceries'}),
          ToolCall(id: syntheticCallId(), name: 'get_today'),
        ]),
        ToolResultsMessage([
          const ToolResult(callId: 'toolu_1', name: 'add_items', content: 'plain text'),
          ToolResult(callId: syntheticCallId(), name: 'get_today', content: '[]'),
        ]),
      ]));
      expect(at(body, ['contents', 1, 'parts']), [
        {
          'functionCall': {
            'name': 'add_items',
            'args': {'list': 'Groceries'},
            'id': 'toolu_1',
          },
          'thoughtSignature': GeminiChatModel.foreignSignature,
        },
        {
          'functionCall': {'name': 'get_today', 'args': <String, Object?>{}},
        },
      ]);
      expect(at(body, ['contents', 2, 'parts', 0, 'functionResponse', 'response']), {'output': 'plain text'});
      expect((at(body, ['contents', 2, 'parts', 1, 'functionResponse']) as Map).containsKey('id'), isFalse);
      expect(at(body, ['contents', 2, 'parts', 1, 'functionResponse', 'response']), {'output': <Object?>[]});
    });
  });

  group('Gemini response', () {
    test('posts to generateContent for the model with the key header, and reads parallel calls', () async {
      final recorder = Recorder();
      final model = GeminiChatModel(
        endpoint: const ModelEndpoint.direct(apiKey: 'AIza-test'),
        client: recorder.answer(200, 'gemini/function_call.json'),
      );
      final reply = await model.respond(sampleRequest());
      final request = recorder.requests.single;
      expect(
        request.url.toString(),
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent',
      );
      expect(request.headers['x-goog-api-key'], 'AIza-test');
      expect(recorder.lastBody.containsKey('model'), isFalse);
      expect(reply.stopReason, StopReason.toolUse);
      expect([for (final c in reply.toolCalls) c.id], ['fc-7a1b', 'fc-7a1c']);
      expect([for (final c in reply.toolCalls) c.name], ['add_items', 'check_item']);
      expect(reply.toolCalls[1].input, {'item': 'Milk'});
      expect(reply.usage.inputTokens, 1100);
      expect(reply.usage.cacheReadTokens, 3000);
      expect(reply.usage.outputTokens, 52);
      expect(reply.model, 'gemini-3.5-flash-lite');
    });

    test('reads text and leaves thoughts out of it', () {
      final reply = GeminiChatModel.parse(200, fixtureJson('gemini/text.json'), model: 'gemini-3.5-flash-lite');
      expect(reply.text, 'Added eggs and checked off milk.');
      expect(reply.stopReason, StopReason.endTurn);
      expect(reply.usage.inputTokens, 204);
      expect(reply.usage.cacheReadTokens, 4096);

      final thinking = GeminiChatModel.parse(
        200,
        {
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'Thinking about lists', 'thought': true},
                  {'text': 'Done.'},
                ],
              },
              'finishReason': 'MAX_TOKENS',
            },
          ],
        },
        model: 'gemini-3.5-flash-lite',
      );
      expect(thinking.text, 'Done.');
      expect(thinking.stopReason, StopReason.maxTokens);
    });

    test('a blocked prompt is a refusal; error statuses are explained', () {
      final blocked = GeminiChatModel.parse(200, fixtureJson('gemini/blocked.json'), model: 'gemini-3.5-flash-lite');
      expect(blocked.stopReason, StopReason.refusal);
      expect(blocked.rawStopReason, 'SAFETY');
      expect(blocked.message.isEmpty, isTrue);
      expect(
        () => GeminiChatModel.parse(400, fixtureJson('gemini/error_400.json'), model: 'gemini-3.5-flash-lite'),
        throwsA(isA<ModelException>()
            .having((e) => e.kind, 'kind', ModelFailure.badRequest)
            .having((e) => e.message, 'message', startsWith('Gemini couldn\'t answer that'))),
      );
    });
  });
}
