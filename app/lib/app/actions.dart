import 'package:den_actions/den_actions.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../design/feedback.dart';

export 'package:den_actions/den_actions.dart' show ActionResult, Receipt;

/// What a tap did, in words ("Gave Maya 5 stars", "Removed Milk"), with the receipt Undo takes
/// back. A screen keeps it in the place the tap happened and shows it in a DoneRow.
typedef Done = ({String message, Receipt? receipt});

/// Every change the app makes to the family goes through here. Where den_actions has an action
/// for it, the change runs as that action, the same verb the hub's REST API, MCP and the
/// assistant offer, so anything the app can do they can do too. What no action offers on
/// purpose (this device's own setup, signing in on a shared screen, and the trust decisions a
/// parent makes on their own device) is written straight to the engine, from a feature's
/// `state/` and nowhere else; `test/actions_only_test.dart` keeps it that way.
///
/// Every write comes back with a [Receipt] of the changes it made, and [undo] takes exactly
/// those back.
class AppActions {
  AppActions(this._den);

  final Den Function() _den;
  final ActionRunner _runner = standardRunner();
  int _recorded = 0;

  /// The engine of the moment (the demo family swaps it).
  Den get den => _den();

  ActionContext _context() {
    final den = this.den;
    return ActionContext(den, member: den.actor?.id, surface: Surface.app, caller: 'app');
  }

  /// Runs the action [name] with [args] as the person using this device. Screens ask their own
  /// questions before they call, so the call runs confirmed. A refusal comes back as a failed
  /// result, never as an exception.
  Future<ActionResult> run(String name, Map<String, Object?> args) async {
    try {
      return await _runner.run(_context(), name, args, mode: RunMode.confirmed);
    } on Object catch (e, stack) {
      debugPrint('$name failed: $e\n$stack');
      return ActionResult.failed(writeFailedMessage, code: 'internal');
    }
  }

  /// Runs [body], a write no action offers (a reviewed draft from Add), and returns what it
  /// changed as a receipt [undo] can take back; null when it changed nothing.
  Future<Receipt?> record(String summary, Future<void> Function() body) async {
    final recorded = await den.recording(body);
    if (recorded.changes.isEmpty) return null;
    return Receipt(
      id: 'app_${++_recorded}',
      summary: summary,
      undoable: den.canUndo(recorded.changes),
      tool: 'app',
      changes: recorded.changes,
    );
  }

  /// Takes back exactly what [receipt] changed. Fields someone has changed since stay as they
  /// are.
  Future<ActionResult> undo(Receipt receipt) async {
    if (receipt.tool != 'app') return run('undo', {'receipt': receipt.id});
    try {
      final result = await den.undo(receipt.changes);
      return ActionResult(
        result.isEmpty ? 'Nothing to undo for: ${receipt.summary}' : 'Undid: ${receipt.summary}',
        {'undone': receipt.id, 'changes': result.changes},
      );
    } on Object catch (e, stack) {
      debugPrint('Undo failed: $e\n$stack');
      return ActionResult.failed(writeFailedMessage, code: 'internal');
    }
  }
}

/// What `who_can_see` says for [audience].
String whoCanSee(Audience audience) => switch (audience) {
      Audience.everyone => 'everyone',
      Audience.parents => 'parents',
      Audience.justMe => 'just me',
    };

/// What a failed write says when the reason isn't one written for people (storage, say).
const String writeFailedMessage = 'Den couldn’t save that. Try again in a moment.';

/// Runs a write and returns its result, or null when it failed, after showing why in a note.
/// [write] returns an [ActionResult] (a feature's actions) or nothing (the few direct writes).
/// A refusal or an error in the engine or in storage becomes words for people, never a crash.
Future<ActionResult?> perform(BuildContext context, Future<Object?> Function() write) async {
  final (result, problem) = await _write(write);
  if (problem != null && context.mounted) showNote(context, problem);
  return result;
}

/// [perform], when only whether it worked matters.
Future<bool> attempt(BuildContext context, Future<Object?> Function() write) async =>
    await perform(context, write) != null;

/// The reason in words a write failed, or null when it worked: for a screen that shows the
/// reason itself.
Future<String?> tryWrite(Future<Object?> Function() write) async => (await _write(write)).$2;

Future<(ActionResult?, String?)> _write(Future<Object?> Function() write) async {
  try {
    final result = await write();
    if (result is ActionResult) {
      return result.isError ? (null, result.message ?? result.text) : (result, null);
    }
    return (ActionResult('', const {}), null);
  } on PermissionDenied catch (e) {
    return (null, e.message);
  } on InvalidInput catch (e) {
    return (null, e.message);
  } on Object catch (e, stack) {
    debugPrint('A write failed: $e\n$stack');
    return (null, writeFailedMessage);
  }
}

/// Shows [message] with Undo, which takes back what [result] changed. [keep] should outlive the
/// page that made the change (the root navigator's context), since Undo can be tapped after
/// leaving it.
void offerUndo(BuildContext keep, AppActions actions, String message, ActionResult result) {
  final receipt = result.receipt;
  if (receipt == null || !receipt.undoable) return;
  showUndo(keep, message, () => attempt(keep, () => actions.undo(receipt)));
}
