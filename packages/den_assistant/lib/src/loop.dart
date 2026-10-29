import 'json.dart';
import 'messages.dart';
import 'model.dart';
import 'schema.dart';
import 'tools.dart';

/// How a turn ended.
enum TurnEnd {
  /// The model answered in words.
  answered,

  /// A call waits for the person to tap "Do it" or "Not now"; see [TurnResult.pending].
  waiting,

  /// The turn used its tool calls; the model said what it did and what's left.
  toolLimit,

  /// The answer was cut short (output cap or context window).
  cutOff,

  /// The model declined, or the provider's filter stopped it.
  refused,

  /// The model couldn't be reached or refused the request; see [TurnResult.error].
  failed,
}

/// What happened to one tool call.
enum StepStatus {
  /// It ran.
  done,

  /// It failed; the model was told why.
  failed,

  /// It waits for a tap.
  waiting,

  /// The person tapped "Not now", or moved on.
  declined,

  /// Not run: the turn had used its tool calls.
  skipped,
}

/// One tool call in a turn, for the rows the person sees.
class ToolStep {
  /// A step.
  const ToolStep({required this.call, required this.status, this.summary, this.receipt, this.error, this.preview});

  /// What the model asked for.
  final ToolCall call;

  /// What happened.
  final StepStatus status;

  /// The speakable line for a call that ran.
  final String? summary;

  /// Its receipt, for an Undo button.
  final Receipt? receipt;

  /// Why it failed or wasn't run.
  final String? error;

  /// The "Do it / Not now" card's line, for a call that needed a tap.
  final String? preview;
}

/// A call waiting for the person's tap.
class PendingConfirmation {
  /// [call] of [tool], shown as [preview].
  const PendingConfirmation({required this.call, required this.tool, required this.preview, this.details});

  /// The call.
  final ToolCall call;

  /// Its tool.
  final AssistantTool tool;

  /// The card's line: "Remove all 12 Tuesday soccer practices?"
  final String preview;

  /// What would change, from the executor.
  final Object? details;
}

/// The result of [AssistantLoop.ask] or [AssistantLoop.decide]. Steps, receipts and usage cover
/// the whole turn, across taps.
class TurnResult {
  /// A result.
  const TurnResult({
    required this.end,
    this.text = '',
    this.steps = const [],
    this.receipts = const [],
    this.pending,
    this.usage = Usage.zero,
    this.costUsd = 0,
    this.modelCalls = 0,
    this.toolCalls = 0,
    this.error,
    this.failure,
  });

  /// How it ended.
  final TurnEnd end;

  /// What the model said last.
  final String text;

  /// Every tool call in the turn, in order.
  final List<ToolStep> steps;

  /// What changed in the turn, oldest first.
  final List<Receipt> receipts;

  /// The call waiting for a tap, when [end] is [TurnEnd.waiting].
  final PendingConfirmation? pending;

  /// Tokens the turn used so far.
  final Usage usage;

  /// Their estimated cost in US dollars.
  final double costUsd;

  /// Model calls in the turn so far.
  final int modelCalls;

  /// Tool calls run (or tried) in the turn so far.
  final int toolCalls;

  /// Why the turn failed, for people.
  final String? error;

  /// The model call that failed, with its status and the hub's code, when [end] is
  /// [TurnEnd.failed] because of one: an app tells a daily limit from a spent budget with it.
  final ModelException? failure;

  /// Whether a tap is needed to go on.
  bool get waiting => pending != null;
}

/// One conversation with the assistant, run on the person's own device: model call, tool calls,
/// results, model again, until the model answers in words or the turn has used [maxToolCalls].
///
/// A call that needs a tap stops the turn with [TurnEnd.waiting]; [decide] goes on from there.
/// Tool errors go back to the model to fix. Every change's [Receipt] is kept so the caller can
/// handle "undo that" with [takeLastUndoable].
class AssistantLoop {
  /// A conversation with [model], offering [tools] and running them with [execute].
  AssistantLoop({
    required this.model,
    required List<AssistantTool> tools,
    required this.execute,
    this.maxToolCalls = defaultMaxToolCalls,
    this.maxTokens = 2048,
    this.cacheKey,
    List<ChatMessage> history = const [],
  })  : tools = List.unmodifiable(tools),
        _byName = {for (final t in tools) t.name: t},
        _messages = [...history];

  /// At most this many tool calls per turn.
  static const defaultMaxToolCalls = 8;

  /// The model.
  final ChatModel model;

  /// What this person may call: a kid gets fewer.
  final List<AssistantTool> tools;

  /// Runs calls on the device's own engine.
  final ToolExecutor execute;

  /// Tool calls allowed per turn.
  final int maxToolCalls;

  /// The output cap per model call.
  final int maxTokens;

  /// Passed to the model as [ModelRequest.cacheKey].
  final String? cacheKey;

  final Map<String, AssistantTool> _byName;
  final List<ChatMessage> _messages;
  final List<Receipt> _receipts = [];
  Usage _total = Usage.zero;
  _Turn? _turn;
  _Pause? _pause;

  /// The conversation so far.
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  /// Every change made in this conversation and not taken back, oldest first.
  List<Receipt> get receipts => List.unmodifiable(_receipts);

  /// The newest receipt.
  Receipt? get lastReceipt => _receipts.isEmpty ? null : _receipts.last;

  /// The call waiting for a tap.
  PendingConfirmation? get pending => _pause?.pending;

  /// Tokens used by the whole conversation.
  Usage get totalUsage => _total;

  /// Their estimated cost in US dollars.
  double get totalCostUsd => _total.costUsd(model.info.price);

  /// Removes and returns the newest change that can be undone, for "undo that". The caller
  /// undoes it on the engine.
  Receipt? takeLastUndoable() {
    for (var i = _receipts.length - 1; i >= 0; i--) {
      if (_receipts[i].undoable) return _receipts.removeAt(i);
    }
    return null;
  }

  /// Sends what the person typed or said, with this turn's [system] blocks, and runs the turn.
  /// A call still waiting for a tap counts as "Not now".
  Future<TurnResult> ask(String text, {required List<SystemBlock> system, List<ImagePart> images = const []}) {
    _letGo();
    _messages.add(UserMessage(text, images: images));
    final turn = _Turn(system);
    _turn = turn;
    return _run(turn);
  }

  /// Goes on after the person tapped "Do it" ([approve]) or "Not now".
  Future<TurnResult> decide({required bool approve}) async {
    final pause = _pause;
    final turn = _turn;
    if (pause == null || turn == null) throw StateError('Nothing is waiting for a tap.');
    _pause = null;
    final call = pause.pending.call;
    if (approve) {
      final outcome = await _invoke(ToolInvocation(call: call, tool: pause.pending.tool, mode: ToolMode.confirmed));
      switch (outcome) {
        case final ToolDone done:
          _recordDone(turn, pause.results, call, done);
        case ToolNeedsConfirmation():
          _recordFailure(turn, pause.results, call, 'It still needed a tap after they tapped Do it, so nothing changed.');
        case final ToolFailed failed:
          _recordFailure(turn, pause.results, call, failed.message);
      }
    } else {
      pause.results.add(ToolResult(
        callId: call.id,
        name: call.name,
        content: encodeJson({
          'done': false,
          'note': 'They tapped Not now, so nothing changed. Leave it unless they ask again.',
        }),
      ));
      turn.setStep(ToolStep(call: call, status: StepStatus.declined, preview: pause.pending.preview));
    }
    final paused = await _runCalls(turn, pause.assistant, pause.results, pause.index + 1);
    if (paused != null) return paused;
    return _run(turn);
  }

  Future<TurnResult> _run(_Turn turn) async {
    while (true) {
      final wrapUp = turn.toolCalls >= maxToolCalls;
      final ModelReply reply;
      try {
        reply = await model.respond(ModelRequest(
          system: turn.system,
          messages: List.unmodifiable(_messages),
          tools: tools,
          maxTokens: maxTokens,
          toolChoice: wrapUp ? ToolChoice.none : ToolChoice.auto,
          cacheKey: cacheKey,
        ));
      } on ModelException catch (e) {
        return _finish(turn, TurnEnd.failed, error: e.message, failure: e);
      } on Object catch (e) {
        return _finish(turn, TurnEnd.failed, error: 'Something went wrong with the assistant ($e).');
      }
      turn.modelCalls++;
      turn.usage += reply.usage;
      _total += reply.usage;
      _messages.add(reply.message);
      final calls = reply.toolCalls;
      if (calls.isEmpty) {
        return _finish(turn, wrapUp ? TurnEnd.toolLimit : _endFor(reply.stopReason), text: reply.text);
      }
      if (wrapUp) {
        // Asked for more after the limit: answer each call so the conversation stays well formed.
        _messages.add(ToolResultsMessage([for (final call in calls) _limitResult(call)]));
        for (final call in calls) {
          turn.setStep(ToolStep(call: call, status: StepStatus.skipped, error: _limitNote));
        }
        return _finish(turn, TurnEnd.toolLimit, text: reply.text);
      }
      final paused = await _runCalls(turn, reply.message, <ToolResult>[], 0);
      if (paused != null) return paused;
    }
  }

  /// Runs [assistant]'s calls from [start], adding to [results]; returns a waiting result when
  /// one needs a tap, or null after adding every result to the conversation.
  Future<TurnResult?> _runCalls(_Turn turn, AssistantMessage assistant, List<ToolResult> results, int start) async {
    final calls = assistant.toolCalls;
    for (var i = start; i < calls.length; i++) {
      final call = calls[i];
      if (turn.toolCalls >= maxToolCalls) {
        results.add(_limitResult(call));
        turn.setStep(ToolStep(call: call, status: StepStatus.skipped, error: _limitNote));
        continue;
      }
      turn.toolCalls++;
      final tool = _byName[call.name];
      if (tool == null) {
        _recordFailure(turn, results, call, 'There\'s no tool called "${call.name}" for this person. Use only the tools you were given.');
        continue;
      }
      final problem = call.problem ?? _inputProblem(tool, call);
      if (problem != null) {
        _recordFailure(turn, results, call, problem);
        continue;
      }
      final mode = tool.confirm == ToolConfirm.tap ? ToolMode.preview : ToolMode.run;
      final outcome = await _invoke(ToolInvocation(call: call, tool: tool, mode: mode));
      switch (outcome) {
        case final ToolDone done when mode == ToolMode.preview:
          return _pauseAt(turn, assistant, results, i, PendingConfirmation(
            call: call,
            tool: tool,
            preview: done.summary ?? 'Do this: ${tool.title ?? tool.name}?',
            details: done.result,
          ));
        case final ToolDone done:
          _recordDone(turn, results, call, done);
        case final ToolNeedsConfirmation needs:
          return _pauseAt(turn, assistant, results, i, PendingConfirmation(
            call: call,
            tool: tool,
            preview: needs.preview,
            details: needs.details,
          ));
        case final ToolFailed failed:
          _recordFailure(turn, results, call, failed.message);
      }
    }
    _messages.add(ToolResultsMessage(List.unmodifiable(results)));
    return null;
  }

  TurnResult _pauseAt(_Turn turn, AssistantMessage assistant, List<ToolResult> results, int index, PendingConfirmation pending) {
    _pause = _Pause(assistant: assistant, results: results, index: index, pending: pending);
    turn.setStep(ToolStep(call: pending.call, status: StepStatus.waiting, preview: pending.preview));
    return _result(turn, TurnEnd.waiting, pending: pending);
  }

  /// A new message while a call waits: the waiting call counts as "Not now", and the calls after
  /// it aren't run.
  void _letGo() {
    final pause = _pause;
    if (pause == null) return;
    _pause = null;
    final calls = pause.assistant.toolCalls;
    for (var i = pause.index; i < calls.length; i++) {
      final call = calls[i];
      pause.results.add(ToolResult(
        callId: call.id,
        name: call.name,
        content: 'Not done: they moved on without tapping Do it.',
        isError: true,
      ));
      _turn?.setStep(ToolStep(call: call, status: i == pause.index ? StepStatus.declined : StepStatus.skipped));
    }
    _messages.add(ToolResultsMessage(List.unmodifiable(pause.results)));
  }

  Future<ToolOutcome> _invoke(ToolInvocation invocation) async {
    try {
      return await execute(invocation);
    } on Object catch (e) {
      return ToolFailed('That didn\'t work: $e');
    }
  }

  String? _inputProblem(AssistantTool tool, ToolCall call) {
    final problems = checkInput(tool.input, call.input);
    if (problems.isEmpty) return null;
    return 'The input didn\'t fit ${tool.name}. ${problems.join(' ')} Fix it and try again.';
  }

  void _recordDone(_Turn turn, List<ToolResult> results, ToolCall call, ToolDone done) {
    final receipt = done.receipt;
    if (receipt != null) {
      _receipts.add(receipt);
      turn.receipts.add(receipt);
    }
    results.add(ToolResult(
      callId: call.id,
      name: call.name,
      content: encodeJson({
        'done': true,
        'summary': ?done.summary,
        'result': ?done.result,
        if (receipt != null) 'receipt': {'id': receipt.id, 'undoable': receipt.undoable},
      }),
    ));
    turn.setStep(ToolStep(call: call, status: StepStatus.done, summary: done.summary ?? receipt?.summary, receipt: receipt));
  }

  void _recordFailure(_Turn turn, List<ToolResult> results, ToolCall call, String message) {
    results.add(ToolResult(callId: call.id, name: call.name, content: message, isError: true));
    turn.setStep(ToolStep(call: call, status: StepStatus.failed, error: message));
  }

  String get _limitNote => 'Not run: a request can do at most $maxToolCalls things. Say what was done and what\'s left.';

  ToolResult _limitResult(ToolCall call) =>
      ToolResult(callId: call.id, name: call.name, content: _limitNote, isError: true);

  static TurnEnd _endFor(StopReason reason) => switch (reason) {
        StopReason.endTurn || StopReason.toolUse || StopReason.other => TurnEnd.answered,
        StopReason.maxTokens || StopReason.contextFull => TurnEnd.cutOff,
        StopReason.refusal => TurnEnd.refused,
      };

  TurnResult _finish(_Turn turn, TurnEnd end, {String text = '', String? error, ModelException? failure}) {
    if (identical(_turn, turn)) _turn = null;
    return _result(turn, end, text: text, error: error, failure: failure);
  }

  TurnResult _result(
    _Turn turn,
    TurnEnd end, {
    String text = '',
    PendingConfirmation? pending,
    String? error,
    ModelException? failure,
  }) =>
      TurnResult(
        end: end,
        text: text,
        steps: List.unmodifiable(turn.steps),
        receipts: List.unmodifiable(turn.receipts),
        pending: pending,
        usage: turn.usage,
        costUsd: turn.usage.costUsd(model.info.price),
        modelCalls: turn.modelCalls,
        toolCalls: turn.toolCalls,
        error: error,
        failure: failure,
      );
}

class _Turn {
  _Turn(this.system);

  final List<SystemBlock> system;
  final List<ToolStep> steps = [];
  final List<Receipt> receipts = [];
  Usage usage = Usage.zero;
  int modelCalls = 0;
  int toolCalls = 0;

  /// Replaces the step for the same call, or adds it.
  void setStep(ToolStep step) {
    final i = steps.indexWhere((s) => identical(s.call, step.call));
    if (i < 0) {
      steps.add(step);
    } else {
      steps[i] = step;
    }
  }
}

class _Pause {
  _Pause({required this.assistant, required this.results, required this.index, required this.pending});

  final AssistantMessage assistant;
  final List<ToolResult> results;
  final int index;
  final PendingConfirmation pending;
}
