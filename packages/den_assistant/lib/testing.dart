/// A scripted [ChatModel] for tests here and in the packages that use the assistant.
library;

import 'src/messages.dart';
import 'src/model.dart';
import 'src/providers.dart';

/// Answers each request with the next scripted reply, and records what it was asked. A scripted
/// [ModelException] is thrown instead of answered.
class ScriptedChatModel extends ChatModel {
  /// A model that answers with [script], in order: [ModelReply]s and [ModelException]s.
  ScriptedChatModel(List<Object> script, {ModelInfo? info})
      : _script = [...script],
        _info = info ?? defaultModel(ModelProvider.anthropic);

  final List<Object> _script;
  final ModelInfo _info;

  /// Every request, in order.
  final List<ModelRequest> requests = [];

  @override
  ModelInfo get info => _info;

  /// Replies not used yet.
  int get remaining => _script.length;

  /// Adds to the script.
  void add(Object reply) => _script.add(reply);

  @override
  Future<ModelReply> respond(ModelRequest request) async {
    requests.add(request);
    if (_script.isEmpty) throw StateError('The script has no reply for request ${requests.length}.');
    final next = _script.removeAt(0);
    if (next is ModelException) throw next;
    if (next is ModelReply) return next;
    throw ArgumentError.value(next, 'script', 'must hold ModelReply or ModelException');
  }

  /// A reply in words.
  static ModelReply text(String text, {Usage usage = const Usage(inputTokens: 1000, outputTokens: 50)}) =>
      ModelReply(message: AssistantMessage(text: text), stopReason: StopReason.endTurn, usage: usage);

  /// A reply that calls [calls], with optional [text] before them.
  static ModelReply calls(
    List<ToolCall> calls, {
    String text = '',
    Usage usage = const Usage(inputTokens: 1000, outputTokens: 80),
  }) =>
      ModelReply(message: AssistantMessage(text: text, toolCalls: calls), stopReason: StopReason.toolUse, usage: usage);

  /// One call of [name] with [input].
  static ToolCall toolCall(String id, String name, [Map<String, Object?> input = const {}]) =>
      ToolCall(id: id, name: name, input: input);
}
