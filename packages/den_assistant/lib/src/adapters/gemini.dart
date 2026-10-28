import 'dart:math';

import 'package:http/http.dart' as http;

import '../endpoint.dart';
import '../json.dart';
import '../messages.dart';
import '../model.dart';
import '../providers.dart';
import '../schema.dart';
import '../transport.dart';

/// Google Gemini through `generateContent` (`POST /v1beta/models/{model}:generateContent`) with
/// function declarations in Gemini's OpenAPI-style schema ([geminiSchemaFor]).
///
/// Gemini 3 and later sign their function calls (`thoughtSignature`); a reply's parts are kept in
/// [ProviderState] and sent back unchanged, since a call without its signature is refused.
/// Gemini caches repeated prefixes on its own; `cachedContentTokenCount` reports the hits.
class GeminiChatModel extends ChatModel {
  /// Gemini through [endpoint]; [model] defaults to the small model in [modelTable].
  GeminiChatModel({
    required ModelEndpoint endpoint,
    String? model,
    http.Client? client,
    this.thinkingLevel,
    Duration timeout = const Duration(seconds: 90),
  })  : model = model ?? defaultModel(ModelProvider.gemini).model,
        _transport = ModelTransport(
          provider: ModelProvider.gemini,
          endpoint: endpoint,
          client: client,
          timeout: timeout,
        );

  /// The API's model id.
  final String model;

  /// `thinkingConfig.thinkingLevel` (`minimal`, `low`, `medium`, `high`), or null for the model's
  /// default.
  final String? thinkingLevel;

  final ModelTransport _transport;

  /// What Google's docs say to send as the signature of a call that came from another model.
  static const foreignSignature = 'skip_thought_signature_validator';

  @override
  ModelInfo get info => modelInfo(ModelProvider.gemini, model);

  @override
  Future<ModelReply> respond(ModelRequest request) async {
    checkImages(info, request);
    final raw = await _transport.post(model, body(request));
    return parse(raw.status, raw.json, model: model, viaHub: _transport.viaHub);
  }

  /// The request body for [request].
  Map<String, Object?> body(ModelRequest request) {
    final system = [
      for (final block in request.system)
        if (block.text.trim().isNotEmpty) {'text': block.text},
    ];
    final declarations = [
      for (final t in request.tools)
        {'name': t.name, 'description': t.description, 'parameters': ?geminiSchemaFor(t.input)},
    ];
    return {
      if (system.isNotEmpty) 'systemInstruction': {'parts': system},
      'contents': contents(request.messages),
      if (declarations.isNotEmpty) 'tools': [
        {'functionDeclarations': declarations},
      ],
      if (declarations.isNotEmpty && request.toolChoice == ToolChoice.none)
        'toolConfig': {
          'functionCallingConfig': {'mode': 'NONE'},
        },
      'generationConfig': {
        'maxOutputTokens': request.maxTokens,
        if (thinkingLevel != null) 'thinkingConfig': {'thinkingLevel': thinkingLevel},
      },
    };
  }

  /// The conversation as Gemini contents; consecutive turns of one role are merged.
  List<Map<String, Object?>> contents(List<ChatMessage> history) {
    final roles = <String>[];
    final parts = <List<Object?>>[];
    void add(String role, List<Object?> more) {
      if (more.isEmpty) return;
      if (roles.isNotEmpty && roles.last == role) {
        parts.last.addAll(more);
      } else {
        roles.add(role);
        parts.add(<Object?>[...more]);
      }
    }

    for (final message in history) {
      switch (message) {
        case final UserMessage m:
          add('user', <Object?>[
            for (final image in m.images)
              {
                'inlineData': {'mimeType': image.mimeType, 'data': image.base64Data},
              },
            if (m.text.trim().isNotEmpty) {'text': m.text},
          ]);
        case final AssistantMessage m:
          add('model', _modelParts(m));
        case final ToolResultsMessage m:
          add('user', <Object?>[
            for (final r in m.results)
              {
                'functionResponse': {
                  'name': r.name,
                  if (!r.syntheticId) 'id': r.callId,
                  'response': r.isError ? {'error': r.content} : {'output': decodeOrText(r.content)},
                },
              },
          ]);
      }
    }
    return [
      for (var i = 0; i < roles.length; i++) {'role': roles[i], 'parts': parts[i]},
    ];
  }

  List<Object?> _modelParts(AssistantMessage message) {
    if (message.isEmpty) return const <Object?>[];
    final state = message.state;
    if (state != null && state.provider == ModelProvider.gemini.id && state.data is List) {
      return <Object?>[for (final part in asList(state.data)) withoutNulls(part)];
    }
    final calls = message.toolCalls;
    return <Object?>[
      if (message.text.trim().isNotEmpty) {'text': message.text},
      for (var i = 0; i < calls.length; i++)
        {
          'functionCall': {
            'name': calls[i].name,
            'args': calls[i].input,
            if (!calls[i].syntheticId) 'id': calls[i].id,
          },
          if (i == 0) 'thoughtSignature': foreignSignature,
        },
    ];
  }

  /// A `generateContent` response as a [ModelReply]. Throws [ModelException] for an error status.
  static ModelReply parse(int status, Map<String, Object?> json, {required String model, bool viaHub = false}) {
    if (status != 200) throw failureFor(ModelProvider.gemini, model, status, json, viaHub: viaHub);
    final usage = usageOf(json);
    final served = asString(json['modelVersion']) ?? model;
    final candidates = asList(json['candidates']);
    if (candidates.isEmpty) {
      final blocked = asString(asMap(json['promptFeedback'])['blockReason']);
      return ModelReply(
        message: const AssistantMessage(),
        stopReason: blocked == null ? StopReason.other : StopReason.refusal,
        rawStopReason: blocked,
        usage: usage,
        model: served,
      );
    }
    final candidate = asMap(candidates.first);
    final parts = asList(asMap(candidate['content'])['parts']);
    final text = StringBuffer();
    final calls = <ToolCall>[];
    for (final raw in parts) {
      final part = asMap(raw);
      final call = asMap(part['functionCall']);
      if (call.isNotEmpty) {
        calls.add(ToolCall(
          id: asString(call['id']) ?? syntheticCallId(),
          name: asString(call['name']) ?? '',
          input: asMap(call['args']),
        ));
      } else if (part['thought'] != true) {
        text.write(asString(part['text']) ?? '');
      }
    }
    final finish = asString(candidate['finishReason']);
    return ModelReply(
      message: AssistantMessage(
        text: text.toString(),
        toolCalls: calls,
        state: ProviderState(provider: ModelProvider.gemini.id, data: parts),
      ),
      stopReason: calls.isNotEmpty
          ? StopReason.toolUse
          : switch (finish) {
              'STOP' || null => StopReason.endTurn,
              'MAX_TOKENS' => StopReason.maxTokens,
              'SAFETY' ||
              'RECITATION' ||
              'LANGUAGE' ||
              'BLOCKLIST' ||
              'PROHIBITED_CONTENT' ||
              'SPII' ||
              'IMAGE_SAFETY' =>
                StopReason.refusal,
              _ => StopReason.other,
            },
      rawStopReason: finish,
      usage: usage,
      model: served,
    );
  }

  /// The `usageMetadata` of a response. `promptTokenCount` includes cached input, which is taken
  /// out here; thinking counts as output.
  static Usage usageOf(Map<String, Object?> json) {
    final u = asMap(json['usageMetadata']);
    final cached = asInt(u['cachedContentTokenCount']);
    return Usage(
      inputTokens: max(0, asInt(u['promptTokenCount']) - cached) + asInt(u['toolUsePromptTokenCount']),
      outputTokens: asInt(u['candidatesTokenCount']) + asInt(u['thoughtsTokenCount']),
      cacheReadTokens: cached,
    );
  }
}
