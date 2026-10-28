import 'dart:convert';

import 'package:http/http.dart' as http;

import '../endpoint.dart';
import '../json.dart';
import '../messages.dart';
import '../model.dart';
import '../providers.dart';
import '../schema.dart';
import '../transport.dart';
import 'openai.dart' show decodeCall;

/// A model the family runs at home with Ollama (`POST /api/chat` with tools), usually on the
/// hub's computer. Nothing leaves the house, and it costs nothing.
///
/// Ollama returns no call ids, so Den makes them up; results go back as `tool` messages named by
/// `tool_name`.
class OllamaChatModel extends ChatModel {
  /// A home model at [endpoint] (its [ModelEndpoint.baseUrl] is the computer's address, port
  /// 11434); [model] defaults to the small model in [modelTable].
  OllamaChatModel({
    required ModelEndpoint endpoint,
    String? model,
    http.Client? client,
    this.contextWindow = 16384,
    this.think,
    this.keepAlive,
    Duration timeout = const Duration(minutes: 3),
  })  : model = model ?? defaultModel(ModelProvider.ollama).model,
        _transport = ModelTransport(
          provider: ModelProvider.ollama,
          endpoint: endpoint,
          client: client,
          timeout: timeout,
        );

  /// The model's name as Ollama knows it: `qwen3:8b`.
  final String model;

  /// `options.num_ctx`: Ollama's default is too small for Den's context and tools.
  final int contextWindow;

  /// `think`: false for faster answers on modest hardware, null for the model's default.
  final bool? think;

  /// `keep_alive`, such as `30m`, or null for Ollama's default.
  final String? keepAlive;

  final ModelTransport _transport;

  @override
  ModelInfo get info => modelInfo(ModelProvider.ollama, model);

  @override
  Future<ModelReply> respond(ModelRequest request) async {
    checkImages(info, request);
    final raw = await _transport.post(model, body(request));
    return parse(raw.status, raw.json, model: model, viaHub: _transport.viaHub);
  }

  /// The request body for [request].
  Map<String, Object?> body(ModelRequest request) {
    final tools = [
      for (final t in request.tools)
        {
          'type': 'function',
          'function': {'name': t.name, 'description': t.description, 'parameters': jsonSchemaFor(t.input)},
        },
    ];
    return {
      'model': model,
      'stream': false,
      'messages': messages(request),
      // Ollama has no tool_choice; a turn that has used its calls is sent without tools.
      if (tools.isNotEmpty && request.toolChoice != ToolChoice.none) 'tools': tools,
      'options': {'num_predict': request.maxTokens, 'num_ctx': contextWindow},
      'think': ?think,
      'keep_alive': ?keepAlive,
    };
  }

  /// The system prompt and conversation as Ollama chat messages.
  List<Map<String, Object?>> messages(ModelRequest request) {
    final system = [
      for (final block in request.system)
        if (block.text.trim().isNotEmpty) block.text,
    ].join('\n\n');
    final out = <Map<String, Object?>>[
      if (system.isNotEmpty) {'role': 'system', 'content': system},
    ];
    for (final message in request.messages) {
      switch (message) {
        case final UserMessage m:
          out.add({
            'role': 'user',
            'content': m.text,
            if (m.images.isNotEmpty) 'images': [for (final image in m.images) image.base64Data],
          });
        case final AssistantMessage m:
          if (!m.isEmpty) out.add(_assistant(m));
        case final ToolResultsMessage m:
          for (final r in m.results) {
            out.add({
              'role': 'tool',
              'tool_name': r.name,
              'content': r.isError ? jsonEncode({'error': r.content}) : r.content,
            });
          }
      }
    }
    return out;
  }

  Map<String, Object?> _assistant(AssistantMessage message) {
    final state = message.state;
    final thinking = state != null && state.provider == ModelProvider.ollama.id
        ? asString(asMap(state.data)['thinking'])
        : null;
    final calls = message.toolCalls;
    return {
      'role': 'assistant',
      'content': message.text,
      'thinking': ?thinking,
      if (calls.isNotEmpty)
        'tool_calls': [
          for (var i = 0; i < calls.length; i++)
            {
              'type': 'function',
              'function': {'index': i, 'name': calls[i].name, 'arguments': calls[i].input},
            },
        ],
    };
  }

  /// An `/api/chat` response as a [ModelReply]. Throws [ModelException] for an error status.
  static ModelReply parse(int status, Map<String, Object?> json, {required String model, bool viaHub = false}) {
    if (status != 200) throw failureFor(ModelProvider.ollama, model, status, json, viaHub: viaHub);
    final message = asMap(json['message']);
    final calls = <ToolCall>[];
    for (final raw in asList(message['tool_calls'])) {
      final call = asMap(raw);
      final function = asMap(call['function']);
      calls.add(decodeCall(
        id: asString(call['id']) ?? syntheticCallId(),
        name: asString(function['name']) ?? '',
        arguments: function['arguments'],
      ));
    }
    final thinking = asString(message['thinking']) ?? '';
    final done = asString(json['done_reason']);
    return ModelReply(
      message: AssistantMessage(
        text: asString(message['content']) ?? '',
        toolCalls: calls,
        state: thinking.isEmpty ? null : ProviderState(provider: ModelProvider.ollama.id, data: {'thinking': thinking}),
      ),
      stopReason: calls.isNotEmpty
          ? StopReason.toolUse
          : switch (done) {
              'stop' || null => StopReason.endTurn,
              'length' => StopReason.maxTokens,
              _ => StopReason.other,
            },
      rawStopReason: done,
      usage: usageOf(json),
      model: asString(json['model']) ?? model,
    );
  }

  /// Ollama's token counts. It caches nothing that costs money.
  static Usage usageOf(Map<String, Object?> json) =>
      Usage(inputTokens: asInt(json['prompt_eval_count']), outputTokens: asInt(json['eval_count']));
}
