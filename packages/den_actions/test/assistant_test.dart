@Timeout(Duration(seconds: 120))
library;

import 'package:den_actions/assistant.dart';
import 'package:den_actions/den_actions.dart';
import 'package:den_assistant/den_assistant.dart' as assistant;

import 'support.dart';

void main() {
  annotateFailures();
  test('every action is a tool every provider takes', () {
    for (final s in allActions()) {
      final tool = assistantTool(s);
      expect(assistant.checkTool(tool), isEmpty, reason: s.mcpName);
      expect(assistant.checkPortableSchema(s.inputSchema), isEmpty, reason: '${s.mcpName} with preview and confirm');
      expect(tool.readOnly, s.readOnly);
    }
  });

  test('the executor runs, previews, asks for a tap and hands back receipts', () async {
    final den = await demoFamily();
    addTearDown(den.close);
    final runner = standardRunner();
    ActionContext context() => ActionContext(den, member: den.actor!.id, surface: Surface.assistant, caller: 'assistant');
    final execute = actionExecutor(runner, context);
    final tools = {for (final t in assistantTools(runner, context())) t.name: t};
    Future<assistant.ToolOutcome> call(String name, Map<String, Object?> input, assistant.ToolMode mode) => execute(
          assistant.ToolInvocation(call: assistant.ToolCall(id: 'call-1', name: name, input: input), tool: tools[name]!, mode: mode),
        );

    final done = await call('add_items', {
      'list': 'Groceries',
      'items': [
        {'text': 'Butter'},
      ],
    }, assistant.ToolMode.run);
    expect(done, isA<assistant.ToolDone>());
    expect((done as assistant.ToolDone).receipt!.tool, 'add_items');
    expect(done.summary, 'Added Butter to Groceries.');

    expect(tools['delete_list']!.confirm, assistant.ToolConfirm.tap);
    expect(tools['delete_event']!.confirm, assistant.ToolConfirm.none, reason: 'only a series asks');
    final preview = await call('delete_list', {'list': 'Meal plan'}, assistant.ToolMode.preview);
    expect((preview as assistant.ToolDone).summary, 'Remove the list Meal plan and its 7 items?');
    expect(preview.receipt, isNull);
    expect(den.lists.any((l) => l.list.title == 'Meal plan'), isTrue);

    final asks = await call('update_chore', {'chore': 'Feed the cat', 'points': 3}, assistant.ToolMode.run);
    expect(asks, isA<assistant.ToolNeedsConfirmation>());
    final tapped = await call('update_chore', {'chore': 'Feed the cat', 'points': 3}, assistant.ToolMode.confirmed);
    expect((tapped as assistant.ToolDone).receipt, isNotNull);

    final failed = await call('adjust_points', {'person': 'Nobody', 'delta': 1, 'reason': 'x'}, assistant.ToolMode.confirmed);
    expect(failed, isA<assistant.ToolFailed>());
    expect((failed as assistant.ToolFailed).message, contains('There\'s no person called "Nobody"'));
  });
}
