import 'dart:async';

import 'package:den_actions/assistant.dart';
import 'package:den_actions/den_actions.dart' hide Receipt;
import 'package:den_assistant/den_assistant.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/foundation.dart';

import '../../../app/app_state.dart' hide Receipt;
import '../../../platform/sync/hub_client.dart' show HubException;
import '../words/assistant_words.dart';
import 'change_words.dart';
import 'helper_link.dart';
import 'snapshot.dart';

/// One change the helper made, as a row: its words, the receipt Undo takes back, and whether it
/// was taken back.
class ChangeLine {
  ChangeLine(this.receipt, this.words);

  final Receipt receipt;

  /// "Moved Dentist to 4:00 PM Tue".
  final String words;

  bool undone = false;
  bool undoing = false;

  /// Why Undo didn't work.
  String? error;

  bool get canUndo => receipt.undoable && !undone && !undoing;
}

/// One thing the person asked and what came of it: the helper's answer in plain sentences, each
/// change as a row, a call waiting for "Do it", or why it couldn't answer.
class Exchange {
  Exchange(this.asked, {this.spoken = false});

  final String asked;
  final bool spoken;

  /// The helper's words.
  String answer = '';

  final List<ChangeLine> changes = [];

  /// A change that waits for "Do it" or "Not now".
  PendingConfirmation? pending;

  /// The question of a change they said "Not now" to, or moved on from.
  String? declined;

  HelperProblem? problem;

  /// Still waiting for the helper.
  bool working = true;

  /// What [pending] would change, from the runner's preview on a fork of the family: one line per
  /// record ("Removes Feed the cat") and its warnings ("Nobody is driving Leo to soccer").
  ({List<String> changes, int more, List<String> warnings}) get previewLines {
    final details = pending?.details;
    final raw = details is Map && details['preview'] is Map ? details['preview'] : details;
    final map = raw is Map ? raw : const {};
    final changes = [
      for (final c in map['changes'] is List ? map['changes']! as List : const [])
        if (c is Map) previewLine('${c['verb'] ?? ''}', '${c['title'] ?? ''}'),
    ];
    final unique = <String>{...changes}.toList();
    return (
      changes: unique.take(4).toList(),
      more: unique.length > 4 ? unique.length - 4 : 0,
      warnings: [for (final w in map['warnings'] is List ? map['warnings']! as List : const []) '$w'],
    );
  }
}

/// One conversation with the AI helper, kept only while Ask is open on this device and never
/// written anywhere: what the person asked, what the helper answered, each change it made (with
/// Undo), and a change waiting for "Do it". Closing Ask forgets it all.
///
/// The helper's loop runs here, on the person's own device, against the family's own engine:
/// every tool call is a den_actions action run as [Surface.assistant] with exactly this person's
/// permissions (a kid gets fewer tools), and what it changes is marked as from the assistant in
/// History. Model calls go through the family's hub ([HelperLink]).
class AskSession extends ChangeNotifier {
  AskSession({required this.app, required this.link, this.packer = const ContextPacker()});

  final AppState app;

  /// Null when the family has no hub to run the helper through.
  final HelperLink? link;
  final ContextPacker packer;

  /// The runner for this conversation's actions: its receipts live as long as the conversation.
  final ActionRunner _runner = standardRunner();

  final List<Exchange> exchanges = [];

  HelperStatus? _status;
  AssistantLoop? _loop;
  bool _busy = false;
  bool _disposed = false;
  bool _closed = false;
  int _views = 0;

  /// Waiting for the helper or for an Undo.
  bool get busy => _busy;

  Member? get me => app.den.actor;

  /// A kid gets big buttons, read-aloud, fewer tools and simpler words.
  bool get kid => me?.isKid ?? false;

  /// What people call the helper: "Claude", once the hub has said.
  String get speaker => _status?.speaker ?? 'the AI helper';

  /// The exchange waiting for "Do it", if any.
  Exchange? get waiting => exchanges.where((x) => x.pending != null).lastOrNull;

  ActionContext _context() =>
      ActionContext(app.den, member: app.den.actor?.id, surface: Surface.assistant, caller: 'assistant');

  /// Whether Ask was closed: the helper may still be answering, but it changes nothing more.
  bool get closed => _closed;

  /// Ask shows this conversation (as a sheet, or as the iPad panel).
  void attach() => _views++;

  /// Ask stopped showing it. When nothing shows it any more, Ask was closed, and it [close]s.
  /// Drawn again as a sheet or as the iPad panel (an iPad turning), the new view attaches while
  /// the old one is still there, so it carries on.
  void detach() {
    if (_views > 0) _views--;
    if (_views == 0) close();
  }

  /// Ends the conversation: a turn still running changes nothing more, and nothing new is sent.
  void close() => _closed = true;

  /// Sends [words] to the helper. "Undo that" takes back the last change here, without asking
  /// the helper.
  Future<void> ask(String words, {bool spoken = false}) async {
    final text = words.trim();
    if (text.isEmpty || _busy || _closed) return;
    for (final x in exchanges) {
      if (x.pending != null) {
        x.declined = x.pending!.preview;
        x.pending = null;
      }
    }
    final x = Exchange(text, spoken: spoken);
    exchanges.add(x);
    if (UndoIntent.matches(text)) {
      await _undoLast(x);
      return;
    }
    await _turn(x, () async {
      final problem = await _ready();
      if (problem != null) {
        x.problem = problem;
        return null;
      }
      return _loop!.ask(text, system: _system());
    });
  }

  /// Tries the last thing again after the hub or the company couldn't answer.
  Future<void> retry(Exchange x) async {
    if (_busy || x.problem == null) return;
    exchanges.remove(x);
    await ask(x.asked, spoken: x.spoken);
  }

  /// The person tapped "Do it" ([approve]) or "Not now" on the waiting change.
  Future<void> decide({required bool approve}) async {
    final x = waiting;
    final loop = _loop;
    if (x == null || loop == null || _busy) return;
    if (!approve) x.declined = x.pending!.preview;
    x.pending = null;
    await _turn(x, () => loop.decide(approve: approve));
  }

  /// Takes back [line]'s change, exactly what it changed. Fields someone changed since stay.
  Future<void> undo(ChangeLine line) async {
    if (!line.canUndo) return;
    line
      ..undoing = true
      ..error = null;
    _notify();
    final ActionResult r;
    try {
      r = await _runner.run(_context(), 'undo', {'receipt': line.receipt.id}, mode: RunMode.confirmed);
    } on Object catch (e, stack) {
      debugPrint('Undo failed: $e\n$stack');
      line
        ..undoing = false
        ..error = writeFailedMessage;
      _notify();
      return;
    }
    line.undoing = false;
    if (r.isError) {
      line.error = r.message ?? r.text;
    } else {
      line.undone = true;
    }
    _notify();
  }

  /// "Undo that": the newest change still in place, taken back with its row's Undo.
  Future<void> _undoLast(Exchange x) async {
    final lines = {
      for (final e in exchanges)
        for (final c in e.changes) c.receipt.id: c,
    };
    ChangeLine? line;
    final loop = _loop;
    if (loop != null) {
      for (var r = loop.takeLastUndoable(); r != null; r = loop.takeLastUndoable()) {
        final candidate = lines[r.id];
        if (candidate != null && candidate.canUndo) {
          line = candidate;
          break;
        }
      }
    }
    if (line == null) {
      x
        ..answer = "There's nothing here to undo yet."
        ..working = false;
      _notify();
      return;
    }
    await undo(line);
    x
      ..answer = line.undone ? 'Took that back: ${line.words}.' : (line.error ?? writeFailedMessage)
      ..working = false;
    _notify();
  }

  /// Runs one step of the conversation and puts what came of it on [x].
  Future<void> _turn(Exchange x, Future<TurnResult?> Function() step) async {
    _busy = true;
    x.working = true;
    _notify();
    try {
      final r = await step();
      if (r != null) _apply(x, r);
    } on HubException catch (e) {
      x.problem = HelperProblem.down(e.message);
    } on ModelException catch (e) {
      x.problem = _problem(e, e.message);
    } on Object catch (e, stack) {
      debugPrint('The AI helper failed: $e\n$stack');
      x.problem = HelperProblem.down('Something went wrong with the AI helper. Try again.');
    } finally {
      _busy = false;
      x.working = false;
      _notify();
    }
  }

  void _apply(Exchange x, TurnResult r) {
    for (final receipt in r.receipts) {
      if (x.changes.any((c) => c.receipt.id == receipt.id)) continue;
      x.changes.add(ChangeLine(receipt, changeWords(app, receipt.changes, fallback: receipt.summary)));
    }
    x.pending = r.pending;
    final said = r.text.trim();
    switch (r.end) {
      case TurnEnd.failed:
        x.problem = _problem(r.failure, r.error ?? 'Something went wrong with the AI helper. Try again.');
      case TurnEnd.refused:
        x.answer = said.isEmpty ? "$speaker didn't answer that. Try asking another way." : said;
      case TurnEnd.waiting:
        // What the helper said with the call that waits ("I can remove that chore."): the loop
        // keeps it in the conversation rather than on a waiting result.
        final before = _loop?.messages.whereType<AssistantMessage>().lastOrNull?.text.trim() ?? '';
        if (before.isNotEmpty) x.answer = before;
      case TurnEnd.answered || TurnEnd.toolLimit || TurnEnd.cutOff:
        x.answer = said;
    }
    if (x.answer.isEmpty && x.changes.isEmpty && x.pending == null && x.problem == null && x.declined == null) {
      final failed = r.steps
          .where((s) => s.status == StepStatus.failed && s.error != null)
          .map((s) => s.error!)
          .firstOrNull;
      x.answer = failed ?? "$speaker didn't say anything. Try asking another way.";
    }
  }

  HelperProblem _problem(ModelException? e, String fallback) => problemFor(
    e,
    fallback: fallback,
    speaker: _status?.speaker ?? 'The AI helper',
    name: me?.name ?? 'this person',
    dailyLimit: _status?.dailyLimit ?? app.den.family?.assistant.kidDailyLimit ?? AssistantPolicy.defaultKidDailyLimit,
    month: _status?.month.isNotEmpty ?? false ? _status!.month : app.today,
  );

  /// Gets the hub's word for this person and starts the loop, or says why the helper can't
  /// answer: off, not set up, a spent budget, a kid's day used up. The hub checks all of it again.
  Future<HelperProblem?> _ready() async {
    if (_loop != null) return null;
    final link = this.link;
    final me = this.me;
    if (link == null) return const HelperProblem.refused(noHubWords);
    final policy = app.den.family?.assistant ?? const AssistantPolicy();
    if (me == null || !policy.enabled) return const HelperProblem.refused(helperOffWords);
    if (!helperOn(app, linked: true)) {
      return HelperProblem.refused(policy.allows(me) ? sharedScreenWords : notForWords(me.name));
    }
    final status = _status = await link.status();
    final model = status.model;
    if (status.provider == null || model == null) return const HelperProblem.refused(notSetUpWords);
    if (!status.allowed) return HelperProblem.refused(notForWords(me.name));
    if (status.stopped && status.provider != ModelProvider.ollama) {
      return HelperProblem.limit(budgetWords(status.month.isEmpty ? app.today : status.month));
    }
    final used = status.usedToday, limit = status.dailyLimit;
    if (me.isKid && used != null && limit != null && used >= limit) return HelperProblem.limit(dailyLimitWords(limit));
    final chat = _UntilClosed(await link.model(status), () => _closed);
    final execute = actionExecutor(_runner, _context, speaker: status.speaker ?? status.provider!.speaker);
    _loop = AssistantLoop(
      model: chat,
      tools: assistantTools(_runner, _context()),
      execute: (call) async => _closed ? const ToolFailed('They closed Ask, so nothing changed.') : execute(call),
      cacheKey: 'den-${app.den.familyId ?? ''}-${me.id}',
    );
    return null;
  }

  /// This turn's system blocks: the family as it is now, and what this conversation changed and
  /// didn't take back.
  List<SystemBlock> _system() {
    final kept = [
      for (final x in exchanges)
        for (final c in x.changes)
          if (!c.undone) c.receipt,
    ];
    return packer.pack(assistantSnapshot(app, now: app.den.now()), receipts: kept).blocks;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _closed = true;
    exchanges.clear();
    super.dispose();
  }
}

/// [model], until [closed] says Ask was closed: then no more calls go out.
class _UntilClosed extends ChatModel {
  _UntilClosed(this.model, this.closed);

  final ChatModel model;
  final bool Function() closed;

  @override
  ModelInfo get info => model.info;

  @override
  Future<ModelReply> respond(ModelRequest request) {
    if (closed()) throw const ModelException('Ask was closed.', kind: ModelFailure.unknown, code: 'closed');
    return model.respond(request);
  }
}
