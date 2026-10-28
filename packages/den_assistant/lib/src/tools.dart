import 'messages.dart';

/// What running a tool does to the family's data.
enum ToolEffect {
  /// Only reads.
  read,

  /// Adds or changes something, and can be undone.
  write,

  /// Removes or overwrites something.
  destructive,
}

/// Whether a tool waits for the person to tap "Do it".
enum ToolConfirm {
  /// Runs at once, with an Undo row. The executor can still ask for a tap for one call, when
  /// that call touches someone else's things or a whole series.
  none,

  /// Always previewed first, and run only after a tap. A spoken "yes" isn't a tap.
  tap,
}

/// A tool the model may call, in a form every provider can take.
class AssistantTool {
  /// A tool named [name] (letters, digits and underscores, starting with a letter, at most 64).
  const AssistantTool({
    required this.name,
    required this.description,
    this.input = emptyInput,
    this.effect = ToolEffect.read,
    this.confirm = ToolConfirm.none,
    this.title,
  });

  /// The input schema of a tool that takes nothing.
  static const Map<String, Object?> emptyInput = {'type': 'object', 'properties': <String, Object?>{}};

  /// What the model calls it: `update_event`.
  final String name;

  /// What it does and when to use it, for the model.
  final String description;

  /// A JSON Schema for its input in the portable subset (see `checkPortableSchema`): an object at
  /// the top, one type per value, string enums, no `anyOf` and no nested `additionalProperties`.
  final Map<String, Object?> input;

  /// Read, write or destructive.
  final ToolEffect effect;

  /// Whether every call waits for a tap.
  final ToolConfirm confirm;

  /// What people see ("Move an event"), or null to use [name].
  final String? title;

  /// Whether it only reads.
  bool get readOnly => effect == ToolEffect.read;
}

/// The record of one change, for "undo that". Mirrors den_actions' receipt.
class Receipt {
  /// A receipt for [changes].
  const Receipt({required this.id, required this.summary, this.undoable = true, this.tool = '', this.changes = const []});

  /// The receipt's id, which undo takes.
  final String id;

  /// What changed, in the person's words: "Moved Soccer to 6:00 PM Tue".
  final String summary;

  /// Whether it can be undone.
  final bool undoable;

  /// The tool that made it.
  final String tool;

  /// The ids of the changes it made, which the engine's undo reverses.
  final List<String> changes;

  /// `{id, summary, undoable, tool, changes}`.
  Map<String, Object?> toJson() => {'id': id, 'summary': summary, 'undoable': undoable, 'tool': tool, 'changes': changes};
}

/// How the loop is asking the executor to handle a call.
enum ToolMode {
  /// Run it, unless this call needs a tap; then change nothing and return
  /// [ToolNeedsConfirmation].
  run,

  /// The tool always needs a tap: change nothing, and return what would happen, as
  /// [ToolNeedsConfirmation] or as a [ToolDone] whose summary is the preview line.
  preview,

  /// The person tapped "Do it": run it.
  confirmed,
}

/// One call for the executor.
class ToolInvocation {
  /// [call] of [tool], in [mode].
  const ToolInvocation({required this.call, required this.tool, required this.mode});

  /// What the model asked for.
  final ToolCall call;

  /// The tool it named.
  final AssistantTool tool;

  /// Run, preview, or run after a tap.
  final ToolMode mode;

  /// The call's arguments.
  Map<String, Object?> get input => call.input;
}

/// Runs a tool call against the device's own engine, as the person speaking. den_actions adapts
/// its `ActionRunner` to this. Thrown errors are caught and given to the model like [ToolFailed].
typedef ToolExecutor = Future<ToolOutcome> Function(ToolInvocation invocation);

/// What happened to a tool call.
sealed class ToolOutcome {
  /// Subclasses only.
  const ToolOutcome();
}

/// The call ran (or, in [ToolMode.preview], what it would do).
final class ToolDone extends ToolOutcome {
  /// A finished call.
  const ToolDone({this.result, this.summary, this.receipt});

  /// The structured answer for the model; JSON-encodable.
  final Object? result;

  /// One speakable line: "Added Eggs to Groceries".
  final String? summary;

  /// The receipt of what changed, for Undo; null for reads.
  final Receipt? receipt;
}

/// Nothing changed yet: the person must tap "Do it" first.
final class ToolNeedsConfirmation extends ToolOutcome {
  /// A call waiting for a tap, shown as [preview].
  const ToolNeedsConfirmation(this.preview, {this.details});

  /// The card's line: "Remove all 12 Tuesday soccer practices?"
  final String preview;

  /// What would change, for the card (the fork's history entries, warnings).
  final Object? details;
}

/// The call failed; the model reads [message] and can try again.
final class ToolFailed extends ToolOutcome {
  /// A failure explained by [message].
  const ToolFailed(this.message, {this.details});

  /// Why, written so the model can fix its input.
  final String message;

  /// More for the model, JSON-encodable.
  final Object? details;
}
