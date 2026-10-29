import 'dart:async';

import 'package:den_core/den_core.dart';

import 'context.dart';
import 'input.dart';
import 'schema.dart';

/// What running an action does to the family's data.
enum Effect {
  /// Only reads.
  read,

  /// Adds or changes something, and can be undone.
  write,

  /// Removes or overwrites something.
  destructive,
}

/// Who asks the person before an action changes anything.
enum Confirm {
  /// Nobody: it runs at once, with an Undo.
  none,

  /// The client: MCP clients ask from the annotations, and the in-app assistant asks for a tap
  /// when [ActionSpec.confirmWhen] says this call touches someone else's things or a whole
  /// series.
  client,

  /// The server too (the plan's "H"): a call returns a preview from a fork of the engine and a
  /// token, and only a second call with `confirm` set to that token changes anything, when
  /// [ActionSpec.confirmWhen] holds (always, without one). The app and the assistant run it as
  /// [RunMode.confirmed] once the person tapped.
  server,
}

/// Where an action is offered.
enum Surface {
  /// The Den app's own screens.
  app,

  /// The hub's REST API (`/api/v1/actions`).
  rest,

  /// The hub's MCP server.
  mcp,

  /// The optional in-app assistant.
  assistant,
}

/// How [ActionRunner.run] treats a call.
enum RunMode {
  /// Run it, unless it needs confirming first: then change nothing and answer with a preview
  /// and a confirmation token ([ActionStatus.needsConfirmation]). A `confirm` argument with
  /// that token runs it.
  run,

  /// Change nothing: run it on a fork of the engine and answer with what would change.
  preview,

  /// The person already said yes (a tap in the app or the assistant, or a REST route that
  /// predates confirmations): run it.
  confirmed,
}

/// Runs an action with checked input.
typedef ActionBody = FutureOr<ActionResult> Function(ActionContext c, ActionInput a);

/// Decides something about one call from its input.
typedef ActionTest = bool Function(ActionContext c, ActionInput a);

/// Words for one call: the question a confirmation asks ("Remove Soccer practice and every one
/// of its occurrences?").
typedef ActionWords = String Function(ActionContext c, ActionInput a);

/// One verb Den offers: what it's called on each surface, its portable input and output
/// schemas, who may use it, what it does, and the engine methods it calls (checked by test).
class ActionSpec {
  /// Creates a spec.
  ActionSpec({
    required this.name,
    required this.mcpName,
    required this.title,
    required this.description,
    required Map<String, Object?> input,
    required Map<String, Object?> output,
    required this.scopes,
    this.needs = const [],
    this.person = false,
    required this.effect,
    this.idempotent = false,
    this.confirm = Confirm.none,
    this.confirmWhen,
    this.ask,
    this.surfaces = const {Surface.app, Surface.rest, Surface.mcp, Surface.assistant},
    required this.engine,
    required this.example,
    this.prepare,
    required this.run,
  })  : inputSchema = _withControls(input, effect, confirm),
        outputSchema = _withResults(output, effect);

  /// Dotted, for the app and logs: `events.update`.
  final String name;

  /// The MCP tool name, also the REST action name: `update_event`.
  final String mcpName;

  /// What people see: "Change an event".
  final String title;

  /// What it does and when to use it, for models.
  final String description;

  /// The portable input schema, with `preview` (and `confirm`, for server confirmations) added
  /// for writes.
  final Map<String, Object?> inputSchema;

  /// The output schema, with `receipt`, `preview` and `confirm` added for writes.
  final Map<String, Object?> outputSchema;

  /// Token scopes, any of which lets a connection call it (`admin` has them all).
  final Set<Scope> scopes;

  /// What the person must be allowed (`can`), any of; empty for everyone. The engine still
  /// decides each change: this only keeps the action out of their list, and buttons out of
  /// their screens.
  final List<DenAction> needs;

  /// Only for a caller who is someone: not offered to a connection acting for nobody (a
  /// parent-level automation), which has no "own" for it to work on.
  final bool person;

  /// Read, write or destructive.
  final Effect effect;

  /// Running it twice with the same input does no more than once.
  final bool idempotent;

  /// Who asks first.
  final Confirm confirm;

  /// For [Confirm.client] and [Confirm.server]: whether this call needs asking; null is always.
  final ActionTest? confirmWhen;

  /// The question a confirmation asks; null uses the preview's summary.
  final ActionWords? ask;

  /// Where it's offered.
  final Set<Surface> surfaces;

  /// The `Den` methods it may call, by name. The coverage test runs [example] through an
  /// engine that records its calls and fails when one isn't here.
  final Set<String> engine;

  /// An input that works on the demo family (`createDemoFamily`) for an admin parent.
  final Map<String, Object?> example;

  /// Reshapes raw arguments before they're checked, for inputs older clients send another way
  /// (a list of plain strings where objects go now).
  final Map<String, Object?> Function(Map<String, Object?> args)? prepare;

  /// Runs it, with the person acting.
  final ActionBody run;

  /// Whether it changes nothing.
  bool get readOnly => effect == Effect.read;

  /// This spec running [run] instead (to watch what it does, in tests).
  ActionSpec withRun(ActionBody run) => ActionSpec(
        name: name,
        mcpName: mcpName,
        title: title,
        description: description,
        input: inputSchema,
        output: outputSchema,
        scopes: scopes,
        needs: needs,
        person: person,
        effect: effect,
        idempotent: idempotent,
        confirm: confirm,
        confirmWhen: confirmWhen,
        ask: ask,
        surfaces: surfaces,
        engine: engine,
        example: example,
        prepare: prepare,
        run: run,
      );

  /// The MCP `tools/list` entry.
  Map<String, Object?> toolJson() => {
        'name': mcpName,
        'title': title,
        'description': description,
        'inputSchema': inputSchema,
        'outputSchema': outputSchema,
        'annotations': {
          'title': title,
          'readOnlyHint': readOnly,
          'destructiveHint': effect == Effect.destructive,
          'idempotentHint': readOnly || idempotent,
          'openWorldHint': false,
        },
      };

  /// The `GET /api/v1/actions` entry.
  Map<String, Object?> restJson() => {
        'name': mcpName,
        'id': name,
        'title': title,
        'description': description,
        'scopes': [for (final s in Scope.values) if (scopes.contains(s)) s.name],
        'effect': effect.name,
        'idempotent': readOnly || idempotent,
        'confirm': confirm.name,
        'input_schema': inputSchema,
        'output_schema': outputSchema,
      };

  static Map<String, Object?> _withControls(Map<String, Object?> input, Effect effect, Confirm confirm) {
    if (effect == Effect.read) return input;
    return {
      ...input,
      'properties': {
        ...(input['properties'] as Map).cast<String, Object?>(),
        'preview': S.boolean('Only show what would change, changing nothing.'),
        if (confirm == Confirm.server)
          'confirm': S.string('The token from a preview this needed, to go ahead with exactly that.'),
      },
    };
  }

  static Map<String, Object?> _withResults(Map<String, Object?> output, Effect effect) {
    if (effect == Effect.read) return output;
    return {
      ...output,
      'properties': {
        ...(output['properties'] as Map).cast<String, Object?>(),
        'receipt': receiptSchema,
        'preview': previewSchema,
        'confirm': confirmSchema,
      },
    };
  }
}

/// An older name for an action, still callable but not listed, with its arguments reshaped.
class ActionAlias {
  /// Creates an alias.
  const ActionAlias(this.name, this.target, [this.adapt]);

  /// The old name: `check_item`.
  final String name;

  /// The action it runs, by MCP name: `update_items`.
  final String target;

  /// The old arguments as the action takes them; null when they're the same.
  final Map<String, Object?> Function(Map<String, Object?> args)? adapt;
}

/// A record of what an action changed, for Undo.
class Receipt {
  /// Creates a receipt.
  const Receipt({required this.id, required this.summary, required this.undoable, required this.tool, required this.changes});

  /// What `undo` takes.
  final String id;

  /// What changed, in the person's words: "Moved Soccer practice to 6:00 PM".
  final String summary;

  /// Whether `undo` can take it back now.
  final bool undoable;

  /// The action that made it, by MCP name.
  final String tool;

  /// The ids of the changes it made, which the engine's undo reverses.
  final List<String> changes;

  /// `{id, summary, undoable, tool, changes}`, as the assistant's receipts are.
  Map<String, Object?> toJson() => {'id': id, 'summary': summary, 'undoable': undoable, 'tool': tool, 'changes': changes};
}

/// How a call ended.
enum ActionStatus {
  /// It ran (a read, or a write that changed things).
  done,

  /// It ran on a fork: nothing changed.
  preview,

  /// Nothing changed yet: the person must say yes first.
  needsConfirmation,

  /// It didn't run; [ActionResult.message] says why.
  failed,
}

/// What an action answers: a short line for people (spoken by voice assistants), and the same
/// facts as JSON.
class ActionResult {
  /// A result.
  ActionResult(this.text, this.data, {this.receipt, this.status = ActionStatus.done, this.code, this.message});

  /// A call that didn't run. [code] is the REST error code; [message] is the reason alone,
  /// and the text puts "Den didn't allow that" in front of a refusal.
  factory ActionResult.failed(String message, {String code = 'invalid_input', String? field, Map<String, Object?>? details}) =>
      ActionResult(
        code == 'permission_denied' ? 'Den didn\'t allow that: ${_sentence(message)}' : message,
        {'error': message, 'code': code, 'field': ?field, 'details': ?details},
        status: ActionStatus.failed,
        code: code,
        message: message,
      );

  static String _sentence(String s) => s.endsWith('.') || s.endsWith('!') || s.endsWith('?') ? s : '$s.';

  /// Words for people.
  final String text;

  /// The structured answer, without the receipt.
  final Map<String, Object?> data;

  /// What a write changed.
  final Receipt? receipt;

  /// How it ended.
  final ActionStatus status;

  /// For failures: the REST error code (`invalid_input`, `permission_denied`, `not_found`,
  /// `read_only`, `insufficient_scope`, `unknown_action`, `confirmation_required`).
  final String? code;

  /// For failures: why, without the prefix [text] may have.
  final String? message;

  /// Whether it failed.
  bool get isError => status == ActionStatus.failed;

  /// [data] with the receipt, as MCP's `structuredContent` and the REST API's `result`.
  Map<String, Object?> get structured => {...data, if (receipt != null) 'receipt': receipt!.toJson()};

  /// This result with a receipt.
  ActionResult withReceipt(Receipt r) => ActionResult(text, data, receipt: r, status: status, code: code, message: message);
}

/// The `receipt` every write returns.
final Map<String, Object?> receiptSchema = S.object({
  'id': S.string('Pass to undo to take this back.'),
  'summary': S.string('What changed.'),
  'undoable': S.boolean('Whether undo can take it back.'),
  'tool': S.string('The action that made it.'),
  'changes': S.array(S.string('A change id.'), 'The changes it made.'),
}, description: 'What this changed, for undo.', required: ['id', 'summary', 'undoable', 'tool', 'changes']);

/// What a preview would change.
final Map<String, Object?> previewSchema = S.object({
  'summary': S.string('What it would do.'),
  'question': S.string('What to ask the person before doing it.'),
  'changes': S.array(
    S.object({
      'type': S.string('What kind of record.'),
      'id': S.string('Its id.'),
      'title': S.string('What people call it.'),
      'verb': S.string('added, changed, removed, ...'),
      'fields': S.array(S.string('A field.'), 'Which fields.'),
    }),
    'What would change.',
  ),
  'warnings': S.array(S.string('A warning.'), 'Things to know first: overlaps, missing drivers, duplicates.'),
}, description: 'What would change; nothing has.');

/// What a call that needs a yes returns.
final Map<String, Object?> confirmSchema = S.object({
  'token': S.string('Call again with "confirm" set to this to go ahead.'),
  'question': S.string('What to ask the person.'),
  'expires_ms': S.integer('When the token stops working (UTC ms).'),
}, description: 'Nothing changed yet: ask the person, then call again with the token.');
