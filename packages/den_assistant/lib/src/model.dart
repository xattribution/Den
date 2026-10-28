import 'json.dart';
import 'messages.dart';
import 'providers.dart';
import 'tools.dart';

/// One block of the system prompt. Blocks that don't change between calls are marked [cache];
/// adapters that cache explicitly (Anthropic) put a cache breakpoint after them.
class SystemBlock {
  /// A block of [text].
  const SystemBlock(this.text, {this.cache = false, this.name = ''});

  /// The block's text.
  final String text;

  /// Whether it stays the same for a while (the static rules, the family for the day).
  final bool cache;

  /// `static`, `family`, `speaker`, `today` or `recent`, for tests and logs.
  final String name;
}

/// Whether the model may call tools in this request.
enum ToolChoice {
  /// It decides.
  auto,

  /// Answer in words only (the turn has used its tool calls).
  none,
}

/// One request to a model.
class ModelRequest {
  /// A request.
  const ModelRequest({
    required this.system,
    required this.messages,
    this.tools = const [],
    this.maxTokens = 2048,
    this.toolChoice = ToolChoice.auto,
    this.cacheKey,
  });

  /// The system prompt's blocks, in order.
  final List<SystemBlock> system;

  /// The conversation so far.
  final List<ChatMessage> messages;

  /// The tools this person may use.
  final List<AssistantTool> tools;

  /// The most the model may write, thinking included.
  final int maxTokens;

  /// Whether tools may be called.
  final ToolChoice toolChoice;

  /// A stable key for requests that share a prefix (OpenAI's `prompt_cache_key`).
  final String? cacheKey;
}

/// Why the model stopped.
enum StopReason {
  /// It finished answering.
  endTurn,

  /// It wants tools run.
  toolUse,

  /// It ran out of `maxTokens`.
  maxTokens,

  /// It declined, or the provider's safety filter stopped it.
  refusal,

  /// The conversation no longer fits.
  contextFull,

  /// Anything else; [ModelReply.rawStopReason] has the provider's word.
  other,
}

/// Tokens one or more calls used. [inputTokens] counts only input read at the full price, so a
/// cost is each count times its price.
class Usage {
  /// Token counts.
  const Usage({this.inputTokens = 0, this.outputTokens = 0, this.cacheReadTokens = 0, this.cacheWriteTokens = 0});

  /// Nothing.
  static const zero = Usage();

  /// Input not read from or written to a cache.
  final int inputTokens;

  /// Output, thinking included.
  final int outputTokens;

  /// Input read from the provider's cache.
  final int cacheReadTokens;

  /// Input written to the provider's cache.
  final int cacheWriteTokens;

  /// All input, however it was billed.
  int get totalInput => inputTokens + cacheReadTokens + cacheWriteTokens;

  /// Both together.
  Usage operator +(Usage other) => Usage(
        inputTokens: inputTokens + other.inputTokens,
        outputTokens: outputTokens + other.outputTokens,
        cacheReadTokens: cacheReadTokens + other.cacheReadTokens,
        cacheWriteTokens: cacheWriteTokens + other.cacheWriteTokens,
      );

  /// An estimate in US dollars at [price].
  double costUsd(ModelPrice price) =>
      (inputTokens * price.input +
          outputTokens * price.output +
          cacheReadTokens * price.cachedInput +
          cacheWriteTokens * price.cacheWrite) /
      1000000;

  /// `{input_tokens, output_tokens, cache_read_tokens, cache_write_tokens}`.
  Map<String, Object?> toJson() => {
        'input_tokens': inputTokens,
        'output_tokens': outputTokens,
        'cache_read_tokens': cacheReadTokens,
        'cache_write_tokens': cacheWriteTokens,
      };

  /// Reads [toJson]'s shape.
  static Usage fromJson(Object? json) {
    final m = asMap(json);
    return Usage(
      inputTokens: asInt(m['input_tokens']),
      outputTokens: asInt(m['output_tokens']),
      cacheReadTokens: asInt(m['cache_read_tokens']),
      cacheWriteTokens: asInt(m['cache_write_tokens']),
    );
  }

  @override
  String toString() => 'Usage(in $inputTokens, out $outputTokens, cache read $cacheReadTokens, '
      'cache write $cacheWriteTokens)';
}

/// What a model answered.
class ModelReply {
  /// An answer.
  const ModelReply({
    required this.message,
    required this.stopReason,
    this.usage = Usage.zero,
    this.model = '',
    this.rawStopReason,
  });

  /// The text and tool calls, with the provider's state for the next request.
  final AssistantMessage message;

  /// Why it stopped.
  final StopReason stopReason;

  /// The provider's own stop reason.
  final String? rawStopReason;

  /// Tokens used.
  final Usage usage;

  /// The model that answered.
  final String model;

  /// What it said.
  String get text => message.text;

  /// What it wants run.
  List<ToolCall> get toolCalls => message.toolCalls;
}

/// A piece of a streamed answer.
sealed class ModelEvent {
  /// Subclasses only.
  const ModelEvent();
}

/// More text.
final class ModelTextDelta extends ModelEvent {
  /// [text] arrived.
  const ModelTextDelta(this.text);

  /// The new text.
  final String text;
}

/// The whole answer; always the last event.
final class ModelFinished extends ModelEvent {
  /// The answer.
  const ModelFinished(this.reply);

  /// The complete reply.
  final ModelReply reply;
}

/// A model behind one provider's API.
abstract class ChatModel {
  /// Subclasses only.
  const ChatModel();

  /// Which model, where its data goes, and its prices.
  ModelInfo get info;

  /// Sends [request] and waits for the whole answer. Throws [ModelException].
  Future<ModelReply> respond(ModelRequest request);

  /// The answer as it arrives. Adapters that don't stream yet send it in one piece.
  Stream<ModelEvent> stream(ModelRequest request) async* {
    final reply = await respond(request);
    if (reply.text.isNotEmpty) yield ModelTextDelta(reply.text);
    yield ModelFinished(reply);
  }
}

/// Why a model call failed.
enum ModelFailure {
  /// The key was refused, or the device isn't allowed at the hub.
  auth,

  /// The hub's policy said no: the assistant is off, the budget is spent, a kid's daily limit.
  refused,

  /// Too many requests; try again soon.
  rateLimited,

  /// The provider is overloaded or down; try again soon.
  busy,

  /// The request is too big.
  tooBig,

  /// The model doesn't exist there (Ollama: not pulled).
  notFound,

  /// The provider rejected the request.
  badRequest,

  /// No answer in time.
  timeout,

  /// Couldn't reach it.
  network,

  /// Something else.
  unknown,
}

/// A model call that failed, with a message for people.
class ModelException implements Exception {
  /// A failure people can read as [message].
  const ModelException(this.message, {this.kind = ModelFailure.unknown, this.status, this.retry = false, this.detail});

  /// For people: "Claude is busy right now. Try again in a minute."
  final String message;

  /// What kind of failure.
  final ModelFailure kind;

  /// The HTTP status, when there was one.
  final int? status;

  /// Whether trying again later may work.
  final bool retry;

  /// The provider's own message, for developers.
  final String? detail;

  @override
  String toString() => 'ModelException($kind${status == null ? '' : ' $status'}): $message'
      '${detail == null ? '' : ' ($detail)'}';
}

/// Throws when [request] has photos and [info]'s model can't look at them.
void checkImages(ModelInfo info, ModelRequest request) {
  if (info.images) return;
  for (final m in request.messages) {
    if (m is UserMessage && m.images.isNotEmpty) {
      throw ModelException(
        '${info.label} can\'t look at photos. Ask in words, or add the photo with Add instead.',
        kind: ModelFailure.badRequest,
      );
    }
  }
}
