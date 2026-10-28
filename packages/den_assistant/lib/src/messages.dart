import 'dart:convert';

import 'json.dart';

/// The start of an id Den makes up for a tool call when the provider gives none (Ollama, older
/// Gemini models). Adapters never send these back to the provider.
const syntheticCallIdPrefix = 'den-call-';

var _synthetic = 0;

/// A fresh made-up call id, unique within this process.
String syntheticCallId() => '$syntheticCallIdPrefix${DateTime.now().microsecondsSinceEpoch}-${_synthetic++}';

/// A photo a person added to what they asked. Sent only to models that can see images, and never
/// for kids.
class ImagePart {
  /// A photo of [mimeType] (`image/jpeg`, `image/png`, `image/gif` or `image/webp`).
  const ImagePart({required this.mimeType, required this.bytes});

  /// `image/jpeg`, `image/png`, `image/gif` or `image/webp`.
  final String mimeType;

  /// The encoded image.
  final List<int> bytes;

  /// The bytes as base64, the way every provider takes them.
  String get base64Data => base64Encode(bytes);

  /// `{mime_type, data}`.
  Map<String, Object?> toJson() => {'mime_type': mimeType, 'data': base64Data};

  /// Reads [toJson]'s shape.
  static ImagePart fromJson(Map<String, Object?> json) => ImagePart(
        mimeType: asString(json['mime_type']) ?? 'image/jpeg',
        bytes: base64Decode(asString(json['data']) ?? ''),
      );
}

/// A tool the model asked to run.
class ToolCall {
  /// A call of [name] with [input]; [problem] says why the input couldn't be read.
  const ToolCall({required this.id, required this.name, this.input = const {}, this.problem});

  /// The provider's id for the call, which its result must carry back.
  final String id;

  /// The tool's name.
  final String name;

  /// The arguments, as the model wrote them.
  final Map<String, Object?> input;

  /// Why the arguments couldn't be read (they weren't a JSON object), or null.
  final String? problem;

  /// Whether Den made up [id] because the provider gave none.
  bool get syntheticId => id.startsWith(syntheticCallIdPrefix);

  /// `{id, name, input, problem?}`.
  Map<String, Object?> toJson() => {'id': id, 'name': name, 'input': input, 'problem': ?problem};

  /// Reads [toJson]'s shape.
  static ToolCall fromJson(Map<String, Object?> json) => ToolCall(
        id: asString(json['id']) ?? '',
        name: asString(json['name']) ?? '',
        input: asMap(json['input']),
        problem: asString(json['problem']),
      );
}

/// What a tool answered, sent back to the model.
class ToolResult {
  /// The answer to call [callId] of tool [name].
  const ToolResult({required this.callId, required this.name, required this.content, this.isError = false});

  /// The [ToolCall.id] this answers.
  final String callId;

  /// The tool's name (Gemini and Ollama match results by name).
  final String name;

  /// The answer as text, usually JSON.
  final String content;

  /// Whether the call failed; [content] then says why.
  final bool isError;

  /// Whether the call's id was made up by Den.
  bool get syntheticId => callId.startsWith(syntheticCallIdPrefix);

  /// `{call_id, name, content, is_error}`.
  Map<String, Object?> toJson() => {'call_id': callId, 'name': name, 'content': content, 'is_error': isError};

  /// Reads [toJson]'s shape.
  static ToolResult fromJson(Map<String, Object?> json) => ToolResult(
        callId: asString(json['call_id']) ?? '',
        name: asString(json['name']) ?? '',
        content: asString(json['content']) ?? '',
        isError: json['is_error'] == true,
      );
}

/// What one provider needs back, exactly as it sent it: Claude's thinking blocks with their
/// signatures, OpenAI's and xAI's encrypted reasoning items, Gemini's thought signatures.
/// Adapters replay it when the next request goes to the same provider.
class ProviderState {
  /// [data] from [provider] (a [ModelProvider] id).
  const ProviderState({required this.provider, required this.data});

  /// The provider's id: `anthropic`, `openai`, `gemini`, `xai` or `ollama`.
  final String provider;

  /// The provider's own JSON for the reply.
  final Object? data;

  /// `{provider, data}`.
  Map<String, Object?> toJson() => {'provider': provider, 'data': data};

  /// Reads [toJson]'s shape; null when there's nothing.
  static ProviderState? fromJson(Object? json) {
    final map = asMap(json);
    final provider = asString(map['provider']);
    return provider == null ? null : ProviderState(provider: provider, data: map['data']);
  }
}

/// One message in a conversation.
sealed class ChatMessage {
  /// Subclasses only.
  const ChatMessage();

  /// The message as JSON, for keeping a session on the device.
  Map<String, Object?> toJson();

  /// Reads any message's [toJson].
  static ChatMessage fromJson(Map<String, Object?> json) => switch (json['role']) {
        'assistant' => AssistantMessage(
            text: asString(json['text']) ?? '',
            toolCalls: [for (final c in asList(json['tool_calls'])) ToolCall.fromJson(asMap(c))],
            state: ProviderState.fromJson(json['state']),
          ),
        'tool' => ToolResultsMessage([for (final r in asList(json['results'])) ToolResult.fromJson(asMap(r))]),
        _ => UserMessage(
            asString(json['text']) ?? '',
            images: [for (final i in asList(json['images'])) ImagePart.fromJson(asMap(i))],
          ),
      };
}

/// What the person typed or said, with any photos.
final class UserMessage extends ChatMessage {
  /// The person's [text].
  const UserMessage(this.text, {this.images = const []});

  /// What they typed or said.
  final String text;

  /// Photos they added.
  final List<ImagePart> images;

  @override
  Map<String, Object?> toJson() => {
        'role': 'user',
        'text': text,
        if (images.isNotEmpty) 'images': [for (final i in images) i.toJson()],
      };
}

/// The model's answer: text, tool calls, or both.
final class AssistantMessage extends ChatMessage {
  /// An answer.
  const AssistantMessage({this.text = '', this.toolCalls = const [], this.state});

  /// What the model said to the person.
  final String text;

  /// The tools it asked to run, in order.
  final List<ToolCall> toolCalls;

  /// The provider's own record of the reply, replayed to the same provider.
  final ProviderState? state;

  /// Whether there's nothing to show or send back.
  bool get isEmpty => text.trim().isEmpty && toolCalls.isEmpty;

  @override
  Map<String, Object?> toJson() => {
        'role': 'assistant',
        'text': text,
        if (toolCalls.isNotEmpty) 'tool_calls': [for (final c in toolCalls) c.toJson()],
        'state': ?state?.toJson(),
      };
}

/// The answers to every tool call in the assistant message before it.
final class ToolResultsMessage extends ChatMessage {
  /// [results], in the order of the calls.
  const ToolResultsMessage(this.results);

  /// One per call.
  final List<ToolResult> results;

  @override
  Map<String, Object?> toJson() => {
        'role': 'tool',
        'results': [for (final r in results) r.toJson()],
      };
}
