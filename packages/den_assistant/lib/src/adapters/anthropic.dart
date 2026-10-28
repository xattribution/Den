import 'package:http/http.dart' as http;

import '../endpoint.dart';
import '../json.dart';
import '../messages.dart';
import '../model.dart';
import '../providers.dart';
import '../schema.dart';
import '../transport.dart';

/// Claude through Anthropic's Messages API (`POST /v1/messages`), with tool use and prompt
/// caching: breakpoints after the tool list and after each cached system block, plus automatic
/// caching of the conversation so a turn's later calls read what its first call wrote.
///
/// Claude's replies carry thinking blocks with signatures; they're kept in [ProviderState] and
/// sent back unchanged, as the API requires during tool use.
class AnthropicChatModel extends ChatModel {
  /// Claude through [endpoint]; [model] defaults to the small model in [modelTable].
  AnthropicChatModel({
    required ModelEndpoint endpoint,
    String? model,
    http.Client? client,
    this.browser = false,
    this.effort,
    this.cacheTtl,
    this.cacheConversation = true,
    Duration timeout = const Duration(seconds: 90),
  })  : model = model ?? defaultModel(ModelProvider.anthropic).model,
        _transport = ModelTransport(
          provider: ModelProvider.anthropic,
          endpoint: endpoint,
          client: client,
          timeout: timeout,
        );

  /// The API's model id.
  final String model;

  /// Running in a browser with a key on the device, where the API wants an explicit opt-in.
  final bool browser;

  /// `output_config.effort` (`low`, `medium`, `high`), or null for the model's default.
  final String? effort;

  /// The cache lifetime: null for the default five minutes, or `1h`.
  final String? cacheTtl;

  /// Whether to cache the conversation too (the top-level `cache_control`).
  final bool cacheConversation;

  final ModelTransport _transport;

  /// Explicit breakpoints Den uses at most; the API allows four, and automatic caching takes one.
  static const maxExplicitBreakpoints = 3;

  static final RegExp _idUnsafe = RegExp(r'[^a-zA-Z0-9_-]');

  @override
  ModelInfo get info => modelInfo(ModelProvider.anthropic, model);

  @override
  Future<ModelReply> respond(ModelRequest request) async {
    checkImages(info, request);
    final raw = await _transport.post(
      model,
      body(request),
      directHeaders: {if (browser) 'anthropic-dangerous-direct-browser-access': 'true'},
    );
    return parse(raw.status, raw.json, model: model, viaHub: _transport.viaHub);
  }

  /// The request body for [request].
  Map<String, Object?> body(ModelRequest request) {
    final cache = <String, Object?>{'type': 'ephemeral', 'ttl': ?cacheTtl};
    var breakpoints = 0;
    final tools = <Map<String, Object?>>[
      for (final t in request.tools)
        {'name': t.name, 'description': t.description, 'input_schema': jsonSchemaFor(t.input)},
    ];
    if (tools.isNotEmpty) {
      tools.last['cache_control'] = cache;
      breakpoints++;
    }
    final system = <Map<String, Object?>>[];
    for (final block in request.system) {
      if (block.text.trim().isEmpty) continue;
      final cached = block.cache && breakpoints < maxExplicitBreakpoints;
      if (cached) breakpoints++;
      system.add({'type': 'text', 'text': block.text, if (cached) 'cache_control': cache});
    }
    return {
      'model': model,
      'max_tokens': request.maxTokens,
      if (system.isNotEmpty) 'system': system,
      if (tools.isNotEmpty) 'tools': tools,
      if (tools.isNotEmpty && request.toolChoice == ToolChoice.none) 'tool_choice': {'type': 'none'},
      if (cacheConversation) 'cache_control': cache,
      if (effort != null) 'output_config': {'effort': effort},
      'messages': messages(request.messages),
    };
  }

  /// The conversation as Messages API turns. Consecutive turns of one role are merged, so tool
  /// results and the person's next words share a user turn, results first.
  List<Map<String, Object?>> messages(List<ChatMessage> history) {
    final roles = <String>[];
    final contents = <List<Object?>>[];
    void add(String role, List<Object?> content) {
      if (content.isEmpty) return;
      if (roles.isNotEmpty && roles.last == role) {
        contents.last.addAll(content);
      } else {
        roles.add(role);
        contents.add(<Object?>[...content]);
      }
    }

    for (final message in history) {
      switch (message) {
        case final UserMessage m:
          add('user', <Object?>[
            for (final image in m.images)
              {
                'type': 'image',
                'source': {'type': 'base64', 'media_type': image.mimeType, 'data': image.base64Data},
              },
            if (m.text.trim().isNotEmpty) {'type': 'text', 'text': m.text},
          ]);
        case final AssistantMessage m:
          add('assistant', _assistantContent(m));
        case final ToolResultsMessage m:
          add('user', <Object?>[
            for (final r in m.results)
              {
                'type': 'tool_result',
                'tool_use_id': _safeId(r.callId),
                'content': r.content.isEmpty ? '(no output)' : r.content,
                if (r.isError) 'is_error': true,
              },
          ]);
      }
    }
    return [
      for (var i = 0; i < roles.length; i++) {'role': roles[i], 'content': contents[i]},
    ];
  }

  List<Object?> _assistantContent(AssistantMessage message) {
    // A reply with nothing in it (a refusal) isn't sent back.
    if (message.isEmpty) return const <Object?>[];
    final state = message.state;
    if (state != null && state.provider == ModelProvider.anthropic.id && state.data is List) {
      return <Object?>[for (final block in asList(state.data)) withoutNulls(block)];
    }
    return <Object?>[
      if (message.text.trim().isNotEmpty) {'type': 'text', 'text': message.text},
      for (final call in message.toolCalls)
        {'type': 'tool_use', 'id': _safeId(call.id), 'name': call.name, 'input': call.input},
    ];
  }

  /// Tool ids from other providers, made to fit Anthropic's pattern.
  static String _safeId(String id) {
    final safe = id.replaceAll(_idUnsafe, '_');
    return safe.isEmpty ? 'call' : safe;
  }

  /// A Messages API response as a [ModelReply]. Throws [ModelException] for an error status.
  static ModelReply parse(int status, Map<String, Object?> json, {required String model, bool viaHub = false}) {
    if (status != 200) throw failureFor(ModelProvider.anthropic, model, status, json, viaHub: viaHub);
    final content = asList(json['content']);
    final text = StringBuffer();
    final calls = <ToolCall>[];
    for (final raw in content) {
      final block = asMap(raw);
      switch (block['type']) {
        case 'text':
          text.write(asString(block['text']) ?? '');
        case 'tool_use':
          calls.add(ToolCall(
            id: asString(block['id']) ?? syntheticCallId(),
            name: asString(block['name']) ?? '',
            input: asMap(block['input']),
          ));
      }
    }
    final stop = asString(json['stop_reason']);
    return ModelReply(
      message: AssistantMessage(
        text: text.toString(),
        toolCalls: calls,
        state: ProviderState(provider: ModelProvider.anthropic.id, data: content),
      ),
      stopReason: calls.isNotEmpty
          ? StopReason.toolUse
          : switch (stop) {
              'end_turn' || 'stop_sequence' => StopReason.endTurn,
              'max_tokens' => StopReason.maxTokens,
              'refusal' => StopReason.refusal,
              'model_context_window_exceeded' => StopReason.contextFull,
              _ => StopReason.other,
            },
      rawStopReason: stop,
      usage: usageOf(json),
      model: asString(json['model']) ?? model,
    );
  }

  /// The `usage` of a Messages API response. `input_tokens` already leaves out cached input.
  static Usage usageOf(Map<String, Object?> json) {
    final u = asMap(json['usage']);
    return Usage(
      inputTokens: asInt(u['input_tokens']),
      outputTokens: asInt(u['output_tokens']),
      cacheReadTokens: asInt(u['cache_read_input_tokens']),
      cacheWriteTokens: asInt(u['cache_creation_input_tokens']),
    );
  }
}
