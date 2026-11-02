import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../endpoint.dart';
import '../json.dart';
import '../messages.dart';
import '../model.dart';
import '../providers.dart';
import '../schema.dart';
import '../transport.dart';

/// OpenAI's Responses API (`POST /v1/responses`) with function tools, and xAI's Grok through the
/// same API at its own address ([OpenAIChatModel.grok]).
///
/// Requests are stateless (`store: false`): the whole conversation goes each time, and the
/// reasoning items a reply carries (with their encrypted content) are kept in [ProviderState] and
/// sent back with the tool results, as reasoning models need. Caching is automatic; a
/// [ModelRequest.cacheKey] becomes `prompt_cache_key`.
class OpenAIChatModel extends ChatModel {
  /// OpenAI through [endpoint]; [model] defaults to the small model in [modelTable].
  OpenAIChatModel({
    required ModelEndpoint endpoint,
    String? model,
    http.Client? client,
    this.reasoningEffort = 'low',
    Duration timeout = const Duration(seconds: 90),
  })  : provider = ModelProvider.openai,
        model = model ?? defaultModel(ModelProvider.openai).model,
        _transport = ModelTransport(
          provider: ModelProvider.openai,
          endpoint: endpoint,
          client: client,
          timeout: timeout,
        );

  /// xAI's Grok: the same adapter at `https://api.x.ai/v1` (or [ModelEndpoint.baseUrl]). Sends
  /// no `reasoning` or `strict` unless asked, since not every Grok model takes them.
  OpenAIChatModel.grok({
    required ModelEndpoint endpoint,
    String? model,
    http.Client? client,
    this.reasoningEffort,
    Duration timeout = const Duration(seconds: 90),
  })  : provider = ModelProvider.xai,
        model = model ?? defaultModel(ModelProvider.xai).model,
        _transport = ModelTransport(
          provider: ModelProvider.xai,
          endpoint: endpoint,
          client: client,
          timeout: timeout,
        );

  /// [ModelProvider.openai] or [ModelProvider.xai].
  final ModelProvider provider;

  /// The API's model id.
  final String model;

  /// `reasoning.effort`, or null for the model's default. OpenAI defaults to `low`: the
  /// assistant's jobs are short, and reasoning counts against `max_output_tokens`.
  final String? reasoningEffort;

  final ModelTransport _transport;

  @override
  ModelInfo get info => modelInfo(provider, model);

  @override
  Future<ModelReply> respond(ModelRequest request) async {
    checkImages(info, request);
    final raw = await _transport.post(model, body(request));
    return parse(provider, raw.status, raw.json, model: model, viaHub: _transport.viaHub);
  }

  /// The request body for [request].
  Map<String, Object?> body(ModelRequest request) {
    final instructions = [
      for (final block in request.system)
        if (block.text.trim().isNotEmpty) block.text,
    ].join('\n\n');
    final tools = [
      for (final t in request.tools)
        {
          'type': 'function',
          'name': t.name,
          'description': t.description,
          'parameters': jsonSchemaFor(t.input),
          // The Responses API makes functions strict unless told otherwise, and strict schemas
          // need every property required.
          if (provider == ModelProvider.openai) 'strict': false,
        },
    ];
    return {
      'model': model,
      if (instructions.isNotEmpty) 'instructions': instructions,
      'input': input(request.messages),
      if (tools.isNotEmpty) 'tools': tools,
      if (tools.isNotEmpty && request.toolChoice == ToolChoice.none) 'tool_choice': 'none',
      'max_output_tokens': request.maxTokens,
      'store': false,
      'prompt_cache_key': ?request.cacheKey,
      if (reasoningEffort != null) 'reasoning': {'effort': reasoningEffort},
    };
  }

  /// The conversation as Responses input items.
  List<Object?> input(List<ChatMessage> history) {
    final items = <Object?>[];
    for (final message in history) {
      switch (message) {
        case final UserMessage m:
          if (m.text.trim().isNotEmpty || m.images.isNotEmpty) {
            items.add({
              'role': 'user',
              'content': [
                for (final image in m.images)
                  {'type': 'input_image', 'image_url': 'data:${image.mimeType};base64,${image.base64Data}'},
                if (m.text.trim().isNotEmpty) {'type': 'input_text', 'text': m.text},
              ],
            });
          }
        case final AssistantMessage m:
          items.addAll(_assistantItems(m));
        case final ToolResultsMessage m:
          for (final r in m.results) {
            items.add({
              'type': 'function_call_output',
              'call_id': r.callId,
              'output': r.isError ? jsonEncode({'error': r.content}) : r.content,
            });
          }
      }
    }
    return items;
  }

  List<Object?> _assistantItems(AssistantMessage message) {
    if (message.isEmpty) return const <Object?>[];
    final state = message.state;
    if (state != null && state.provider == provider.id && state.data is List) {
      return [for (final item in asList(state.data)) withoutNulls(item)];
    }
    return [
      if (message.text.trim().isNotEmpty) {'role': 'assistant', 'content': message.text},
      for (final call in message.toolCalls)
        {'type': 'function_call', 'call_id': call.id, 'name': call.name, 'arguments': jsonEncode(call.input)},
    ];
  }

  /// A Responses API response from [provider] as a [ModelReply]. Throws [ModelException] for an
  /// error status or a failed response.
  static ModelReply parse(
    ModelProvider provider,
    int status,
    Map<String, Object?> json, {
    required String model,
    bool viaHub = false,
  }) {
    if (status != 200) throw failureFor(provider, model, status, json, viaHub: viaHub);
    final state = asString(json['status']);
    if (state == 'failed') {
      final detail = errorMessage(json);
      throw ModelException(
        '${provider.speaker} couldn\'t finish that answer. Try again.',
        kind: ModelFailure.busy,
        retry: true,
        detail: detail,
      );
    }
    final output = asList(json['output']);
    final text = StringBuffer();
    String? refusal;
    final calls = <ToolCall>[];
    for (final raw in output) {
      final item = asMap(raw);
      switch (item['type']) {
        case 'message':
          for (final p in asList(item['content'])) {
            final part = asMap(p);
            if (part['type'] == 'output_text') text.write(asString(part['text']) ?? '');
            if (part['type'] == 'refusal') refusal = asString(part['refusal']);
          }
        case 'function_call':
          calls.add(decodeCall(
            id: asString(item['call_id']) ?? asString(item['id']) ?? syntheticCallId(),
            name: asString(item['name']) ?? '',
            arguments: item['arguments'],
          ));
      }
    }
    final reason = asString(asMap(json['incomplete_details'])['reason']);
    final StopReason stop;
    if (calls.isNotEmpty) {
      stop = StopReason.toolUse;
    } else if (refusal != null) {
      stop = StopReason.refusal;
    } else if (state == 'incomplete') {
      stop = reason == 'content_filter' ? StopReason.refusal : StopReason.maxTokens;
    } else {
      stop = StopReason.endTurn;
    }
    final said = text.toString();
    return ModelReply(
      message: AssistantMessage(
        text: said.isEmpty ? refusal ?? '' : said,
        toolCalls: calls,
        state: ProviderState(provider: provider.id, data: output),
      ),
      stopReason: stop,
      rawStopReason: reason ?? state,
      usage: usageOf(json),
      model: asString(json['model']) ?? model,
    );
  }

  /// The `usage` of a Responses API response. `input_tokens` includes cached input, which is
  /// taken out here.
  static Usage usageOf(Map<String, Object?> json) {
    final u = asMap(json['usage']);
    final details = asMap(u['input_tokens_details']);
    final cached = asInt(details['cached_tokens']);
    final written = asInt(details['cache_write_tokens']);
    return Usage(
      inputTokens: max(0, asInt(u['input_tokens']) - cached - written),
      outputTokens: asInt(u['output_tokens']),
      cacheReadTokens: cached,
      cacheWriteTokens: written,
    );
  }
}

/// A function call whose [arguments] are a JSON string (OpenAI, xAI) or an object (Ollama).
ToolCall decodeCall({required String id, required String name, required Object? arguments}) {
  if (arguments is Map) return ToolCall(id: id, name: name, input: asMap(arguments));
  if (arguments == null || (arguments is String && arguments.trim().isEmpty)) return ToolCall(id: id, name: name);
  if (arguments is String) {
    final decoded = decodeOrText(arguments);
    if (decoded is Map) return ToolCall(id: id, name: name, input: asMap(decoded));
  }
  return ToolCall(id: id, name: name, problem: 'The arguments for $name weren\'t a JSON object. Send them as one.');
}
