import 'dart:convert';
import 'dart:io';

import 'package:den_assistant/den_assistant.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A recorded response's text.
String fixtureText(String name) => File('test/fixtures/$name').readAsStringSync();

/// A recorded response as JSON.
Map<String, Object?> fixtureJson(String name) => (jsonDecode(fixtureText(name)) as Map).cast<String, Object?>();

/// The value at [path] (keys and indexes) in decoded JSON, or null.
Object? at(Object? json, List<Object> path) {
  Object? node = json;
  for (final key in path) {
    if (key is int) {
      if (node is! List || key >= node.length) return null;
      node = node[key];
    } else {
      if (node is! Map) return null;
      node = node[key];
    }
  }
  return node;
}

/// Answers every request with a fixture, and keeps the requests.
class Recorder {
  /// What was sent.
  final List<http.Request> requests = [];

  /// A client that answers [status] with the fixture [name].
  http.Client answer(int status, String name) => MockClient((request) async {
        requests.add(request);
        return http.Response.bytes(
          utf8.encode(fixtureText(name)),
          status,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

  /// The last request's JSON body.
  Map<String, Object?> get lastBody => (jsonDecode(requests.last.body) as Map).cast<String, Object?>();
}

/// A list tool with a nested array of objects.
const addItems = AssistantTool(
  name: 'add_items',
  description: 'Adds items to a list.',
  effect: ToolEffect.write,
  input: {
    'type': 'object',
    'properties': {
      'list': {'type': 'string', 'description': 'The list.'},
      'items': {
        'type': 'array',
        'maxItems': 100,
        'items': {
          'type': 'object',
          'properties': {
            'text': {'type': 'string'},
            'qty': {'type': 'string'},
          },
          'required': ['text'],
        },
      },
    },
    'required': ['list', 'items'],
  },
);

/// A read tool without inputs.
const getToday = AssistantTool(name: 'get_today', description: 'Reads today.');

/// A request with three system blocks (two cached), [messages] and both tools.
ModelRequest sampleRequest({List<ChatMessage>? messages, ToolChoice toolChoice = ToolChoice.auto}) => ModelRequest(
      system: const [
        SystemBlock('Static rules', cache: true, name: 'static'),
        SystemBlock('Family facts', cache: true, name: 'family'),
        SystemBlock('Now: 3:42 PM.', name: 'today'),
      ],
      messages: messages ?? const [UserMessage('Add eggs to groceries')],
      tools: const [addItems, getToday],
      maxTokens: 1000,
      toolChoice: toolChoice,
      cacheKey: 'family-1:m1',
    );

/// A one-pixel PNG.
final tinyPng = ImagePart(mimeType: 'image/png', bytes: base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='));
