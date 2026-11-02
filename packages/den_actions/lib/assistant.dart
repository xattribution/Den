/// Den's actions as den_assistant's tools: [assistantTool] turns an [ActionSpec] into an
/// `AssistantTool`, and [actionExecutor] runs the assistant's tool calls through an
/// [ActionRunner] on the device's own engine, as the person speaking. Receipts, previews on a
/// fork and confirmations map one to one.
library;

import 'package:den_assistant/den_assistant.dart' as assistant;
import 'package:den_core/den_core.dart' show CaptureKind, CaptureOrigin;

import 'den_actions.dart';

/// [spec] as a tool the assistant offers a model: its MCP name, description and portable input
/// (without `preview` and `confirm`, which the assistant's loop does with modes and taps). A spec
/// that always needs a yes ([Confirm.server] with no test) is always previewed and tapped;
/// others run, and ask for a tap only when the runner says this call needs one.
assistant.AssistantTool assistantTool(ActionSpec spec) => assistant.AssistantTool(
      name: spec.mcpName,
      description: spec.description,
      input: {
        ...spec.inputSchema,
        'properties': {
          for (final e in (spec.inputSchema['properties'] as Map).cast<String, Object?>().entries)
            if (e.key != 'preview' && e.key != 'confirm') e.key: e.value,
        },
      },
      effect: switch (spec.effect) {
        Effect.read => assistant.ToolEffect.read,
        Effect.write => assistant.ToolEffect.write,
        Effect.destructive => assistant.ToolEffect.destructive,
      },
      confirm: spec.confirm == Confirm.server && spec.confirmWhen == null ? assistant.ToolConfirm.tap : assistant.ToolConfirm.none,
      title: spec.title,
    );

/// The tools [context]'s person may use, for the assistant.
List<assistant.AssistantTool> assistantTools(ActionRunner runner, ActionContext context) =>
    [for (final s in runner.available(context)) assistantTool(s)];

/// den_actions' receipt as the assistant's.
assistant.Receipt assistantReceipt(Receipt r) =>
    assistant.Receipt(id: r.id, summary: r.summary, undoable: r.undoable, tool: r.tool, changes: r.changes);

/// Runs the assistant's tool calls through [runner], in a context from [context] (made per call,
/// so it sees the engine as it is then; its surface should be [Surface.assistant]). What it
/// changes is marked as coming from the assistant (`_from`), with [speaker] ("Claude") as its
/// reader, so History says "from the assistant (Claude)".
assistant.ToolExecutor actionExecutor(ActionRunner runner, ActionContext Function() context, {String? speaker}) =>
    (invocation) async {
      final mode = switch (invocation.mode) {
        assistant.ToolMode.run => RunMode.run,
        assistant.ToolMode.preview => RunMode.preview,
        assistant.ToolMode.confirmed => RunMode.confirmed,
      };
      final c = context();
      final r = await c.den.attributed(
        CaptureOrigin(CaptureKind.assistant, reader: speaker),
        () => runner.run(c, invocation.call.name, invocation.input, mode: mode),
      );
      final preview = r.data['preview'];
      switch (r.status) {
        case ActionStatus.failed:
          return assistant.ToolFailed(r.text, details: r.data);
        case ActionStatus.needsConfirmation:
          final ask = (r.data['confirm'] as Map?)?['question'];
          return assistant.ToolNeedsConfirmation(ask is String ? ask : r.text, details: preview);
        case ActionStatus.preview:
          final ask = preview is Map ? preview['question'] : null;
          return assistant.ToolDone(result: r.data, summary: ask is String ? ask : r.text);
        case ActionStatus.done:
          final receipt = r.receipt;
          return assistant.ToolDone(
            result: r.structured,
            summary: r.text.split('\n').first,
            receipt: receipt == null ? null : assistantReceipt(receipt),
          );
      }
    };
