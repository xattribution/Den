import 'dart:convert';

import 'package:den_assistant/den_assistant.dart';
import 'package:den_assistant/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

const _system = [SystemBlock('rules', cache: true, name: 'static')];

const _checkItem = AssistantTool(
  name: 'check_item',
  description: 'Checks off an item.',
  effect: ToolEffect.write,
  input: {
    'type': 'object',
    'properties': {
      'item': {'type': 'string'},
    },
    'required': ['item'],
    'additionalProperties': false,
  },
);

const _deleteList = AssistantTool(
  name: 'delete_list',
  description: 'Removes a list.',
  effect: ToolEffect.destructive,
  confirm: ToolConfirm.tap,
  input: {
    'type': 'object',
    'properties': {
      'list': {'type': 'string'},
    },
    'required': ['list'],
  },
);

const _tools = [addItems, getToday, _checkItem, _deleteList];

/// An executor that records invocations and answers from [answer], or with a receipt per write.
class _Executor {
  _Executor([this.answer]);

  final ToolOutcome Function(ToolInvocation invocation)? answer;
  final List<ToolInvocation> calls = [];
  var _receipts = 0;

  Future<ToolOutcome> call(ToolInvocation invocation) async {
    calls.add(invocation);
    final custom = answer;
    if (custom != null) return custom(invocation);
    if (invocation.tool.readOnly) return const ToolDone(result: {'events': <Object?>[]}, summary: 'Nothing today');
    _receipts++;
    return ToolDone(
      summary: 'Did ${invocation.call.name} #$_receipts',
      receipt: Receipt(id: 'r$_receipts', summary: 'Did ${invocation.call.name} #$_receipts', tool: invocation.call.name),
    );
  }

  List<String> get names => [for (final c in calls) c.call.name];
  List<ToolMode> get modes => [for (final c in calls) c.mode];
}

List<ToolResult> _lastResults(ScriptedChatModel model) {
  final last = model.requests.last.messages.last;
  expect(last, isA<ToolResultsMessage>());
  return (last as ToolResultsMessage).results;
}

Map<String, Object?> _json(String text) => (jsonDecode(text) as Map).cast<String, Object?>();

void main() {
  test('one call, then an answer: results go back, receipts and usage are kept', () async {
    final model = ScriptedChatModel([
      ScriptedChatModel.calls([
        ScriptedChatModel.toolCall('c1', 'add_items', {
          'list': 'Groceries',
          'items': [
            {'text': 'Eggs'},
          ],
        }),
      ]),
      ScriptedChatModel.text('Added Eggs to Groceries.'),
    ]);
    final executor = _Executor();
    final loop = AssistantLoop(model: model, tools: _tools, execute: executor.call);
    final result = await loop.ask('Add eggs', system: _system);

    expect(result.end, TurnEnd.answered);
    expect(result.text, 'Added Eggs to Groceries.');
    expect(result.modelCalls, 2);
    expect(result.toolCalls, 1);
    expect(result.steps.single.status, StepStatus.done);
    expect(result.steps.single.summary, 'Did add_items #1');
    expect(result.receipts.single.id, 'r1');
    expect(loop.lastReceipt?.id, 'r1');
    expect(executor.modes, [ToolMode.run]);

    // Both requests carried the system blocks and the tools; the second ends with the result.
    expect(model.requests[0].system, _system);
    expect(model.requests[0].tools, hasLength(4));
    expect(model.requests[0].toolChoice, ToolChoice.auto);
    final sent = _lastResults(model).single;
    expect(sent.callId, 'c1');
    expect(sent.isError, isFalse);
    expect(_json(sent.content), {
      'done': true,
      'summary': 'Did add_items #1',
      'receipt': {'id': 'r1', 'undoable': true},
    });

    // Two calls at 1000 in / 80 and 50 out on Haiku 5.5.
    expect(result.usage.inputTokens, 2000);
    expect(result.usage.outputTokens, 130);
    expect(result.costUsd, closeTo((2000 * 0.10 + 130 * 0.50) / 1000000, 1e-12));
    expect(loop.totalUsage.inputTokens, 2000);
    expect(loop.messages.whereType<AssistantMessage>().last.text, 'Added Eggs to Groceries.');
  });

  test('several calls in one reply and across replies run in order', () async {
    final model = ScriptedChatModel([
      ScriptedChatModel.calls([
        ScriptedChatModel.toolCall('a', 'get_today'),
        ScriptedChatModel.toolCall('b', 'check_item', {'item': 'Milk'}),
      ]),
      ScriptedChatModel.calls([
        ScriptedChatModel.toolCall('c', 'check_item', {'item': 'Bread'}),
      ]),
      ScriptedChatModel.text('Done.'),
    ]);
    final executor = _Executor();
    final loop = AssistantLoop(model: model, tools: _tools, execute: executor.call);
    final result = await loop.ask('Check off milk and bread', system: _system);
    expect(executor.names, ['get_today', 'check_item', 'check_item']);
    expect(result.toolCalls, 3);
    expect(result.modelCalls, 3);
    expect(result.receipts.map((r) => r.id), ['r1', 'r2']);
    expect([for (final s in result.steps) s.call.id], ['a', 'b', 'c']);
    // The first batch's two results went back together, in order.
    final second = model.requests[1].messages.last as ToolResultsMessage;
    expect([for (final r in second.results) r.callId], ['a', 'b']);
  });

  test('stops at 8 tool calls, then asks for words only', () async {
    final model = ScriptedChatModel([
      for (var i = 0; i < 8; i++)
        ScriptedChatModel.calls([
          ScriptedChatModel.toolCall('c$i', 'check_item', {'item': 'Item $i'}),
        ]),
      ScriptedChatModel.text('Checked off eight; two are left.'),
    ]);
    final executor = _Executor();
    final loop = AssistantLoop(model: model, tools: _tools, execute: executor.call);
    final result = await loop.ask('Check off everything', system: _system);
    expect(executor.calls, hasLength(8));
    expect(model.requests, hasLength(9));
    expect(model.requests[7].toolChoice, ToolChoice.auto);
    expect(model.requests[8].toolChoice, ToolChoice.none);
    expect(result.end, TurnEnd.toolLimit);
    expect(result.text, 'Checked off eight; two are left.');
    expect(result.toolCalls, 8);
  });

  test('calls past the limit in one reply are answered but not run', () async {
    final model = ScriptedChatModel([
      ScriptedChatModel.calls([
        for (var i = 0; i < 10; i++) ScriptedChatModel.toolCall('c$i', 'check_item', {'item': 'Item $i'}),
      ]),
      // Asked for words only, the model still tries; the loop answers and stops.
      ScriptedChatModel.calls([ScriptedChatModel.toolCall('extra', 'get_today')], text: 'Eight done.'),
    ]);
    final executor = _Executor();
    final loop = AssistantLoop(model: model, tools: _tools, execute: executor.call);
    final result = await loop.ask('Check off all ten', system: _system);
    expect(executor.calls, hasLength(8));
    final skipped = [for (final s in result.steps) if (s.status == StepStatus.skipped) s.call.id];
    expect(skipped, ['c8', 'c9', 'extra']);
    final first = model.requests[1].messages.last as ToolResultsMessage;
    expect(first.results, hasLength(10));
    expect(first.results[9].isError, isTrue);
    expect(first.results[9].content, contains('at most 8'));
    expect(model.requests[1].toolChoice, ToolChoice.none);
    expect(result.end, TurnEnd.toolLimit);
    expect(result.text, 'Eight done.');
    // The unanswered calls were answered so the conversation stays well formed.
    expect(loop.messages.last, isA<ToolResultsMessage>());
  });

  test('a tool that needs a tap is previewed, waits, and runs after Do it', () async {
    final model = ScriptedChatModel([
      ScriptedChatModel.calls([
        ScriptedChatModel.toolCall('d1', 'delete_list', {'list': 'Camping'}),
      ], text: 'I can remove that list.'),
      ScriptedChatModel.text('Removed the Camping list.'),
    ]);
    final executor = _Executor((invocation) => switch (invocation.mode) {
          ToolMode.preview => const ToolNeedsConfirmation('Remove the Camping list and its 14 items?', details: {'items': 14}),
          _ => const ToolDone(
              summary: 'Removed Camping',
              receipt: Receipt(id: 'del-1', summary: 'Removed Camping', tool: 'delete_list'),
            ),
        });
    final loop = AssistantLoop(model: model, tools: _tools, execute: executor.call);
    final waiting = await loop.ask('Delete the camping list', system: _system);

    expect(waiting.end, TurnEnd.waiting);
    expect(waiting.waiting, isTrue);
    expect(waiting.pending?.preview, 'Remove the Camping list and its 14 items?');
    expect(waiting.pending?.details, {'items': 14});
    expect(waiting.pending?.tool.name, 'delete_list');
    expect(waiting.steps.single.status, StepStatus.waiting);
    expect(waiting.receipts, isEmpty);
    expect(loop.pending, isNotNull);
    expect(model.requests, hasLength(1));

    final done = await loop.decide(approve: true);
    expect(executor.modes, [ToolMode.preview, ToolMode.confirmed]);
    expect(done.end, TurnEnd.answered);
    expect(done.text, 'Removed the Camping list.');
    expect(done.steps.single.status, StepStatus.done);
    expect(done.receipts.single.id, 'del-1');
    expect(done.modelCalls, 2);
    expect(done.toolCalls, 1);
    expect(loop.pending, isNull);
    expect(_json(_lastResults(model).single.content)['done'], isTrue);
  });

  test('a preview given as ToolDone becomes the card\'s line', () async {
    final model = ScriptedChatModel([
      ScriptedChatModel.calls([
        ScriptedChatModel.toolCall('d1', 'delete_list', {'list': 'Camping'}),
      ]),
    ]);
    final loop = AssistantLoop(
      model: model,
      tools: _tools,
      execute: _Executor((i) => const ToolDone(summary: 'Remove Camping (14 items)?')).call,
    );
    final waiting = await loop.ask('Delete camping', system: _system);
    expect(waiting.pending?.preview, 'Remove Camping (14 items)?');
  });

  test('Not now: nothing runs, the model hears it, and later calls in the reply still run', () async {
    final model = ScriptedChatModel([
      ScriptedChatModel.calls([
        ScriptedChatModel.toolCall('x', 'check_item', {'item': 'Milk'}),
        ScriptedChatModel.toolCall('y', 'check_item', {'item': 'Mia\'s homework'}),
        ScriptedChatModel.toolCall('z', 'check_item', {'item': 'Bread'}),
      ]),
      ScriptedChatModel.text('Checked off milk and bread; left Mia\'s alone.'),
    ]);
    final executor = _Executor((invocation) {
      if (invocation.input['item'] == 'Mia\'s homework' && invocation.mode == ToolMode.run) {
        return const ToolNeedsConfirmation('Check off Mia\'s homework for her?');
      }
      return ToolDone(
        summary: 'Checked ${invocation.input['item']}',
        receipt: Receipt(id: 'r-${invocation.call.id}', summary: 'Checked ${invocation.input['item']}'),
      );
    });
    final loop = AssistantLoop(model: model, tools: _tools, execute: executor.call);
    final waiting = await loop.ask('Check off milk, Mia\'s homework and bread', system: _system);
    expect(waiting.end, TurnEnd.waiting);
    expect(executor.names, ['check_item', 'check_item']);
    expect(waiting.receipts.map((r) => r.id), ['r-x']);

    final done = await loop.decide(approve: false);
    expect(done.end, TurnEnd.answered);
    expect(executor.calls, hasLength(3));
    expect([for (final s in done.steps) s.status], [StepStatus.done, StepStatus.declined, StepStatus.done]);
    expect(done.receipts.map((r) => r.id), ['r-x', 'r-z']);
    final results = _lastResults(model);
    expect([for (final r in results) r.callId], ['x', 'y', 'z']);
    expect(results[1].isError, isFalse);
    expect(results[1].content, contains('Not now'));
    expect(_json(results[1].content)['done'], isFalse);
  });

  test('asking something new while a card waits counts as Not now', () async {
    final model = ScriptedChatModel([
      ScriptedChatModel.calls([
        ScriptedChatModel.toolCall('d1', 'delete_list', {'list': 'Camping'}),
      ]),
      ScriptedChatModel.text('Nothing on today.'),
    ]);
    final executor = _Executor((i) => const ToolNeedsConfirmation('Remove Camping?'));
    final loop = AssistantLoop(model: model, tools: _tools, execute: executor.call);
    await loop.ask('Delete camping', system: _system);
    final next = await loop.ask('Actually, what is on today?', system: _system);
    expect(next.end, TurnEnd.answered);
    expect(loop.pending, isNull);
    final history = model.requests.last.messages;
    final results = history[history.length - 2] as ToolResultsMessage;
    expect(results.results.single.content, contains('moved on'));
    expect((history.last as UserMessage).text, 'Actually, what is on today?');
    await expectLater(loop.decide(approve: true), throwsStateError);
  });

  test('tool errors go back to the model, which can try again', () async {
    final model = ScriptedChatModel([
      ScriptedChatModel.calls([
        ScriptedChatModel.toolCall('u', 'make_coffee'),
        ScriptedChatModel.toolCall('v', 'check_item', {'thing': 'Milk'}),
        ScriptedChatModel.toolCall('w', 'check_item', {'item': 'Milk'}),
        const ToolCall(id: 'p', name: 'check_item', problem: 'The arguments weren\'t JSON.'),
      ]),
      ScriptedChatModel.calls([
        ScriptedChatModel.toolCall('w2', 'check_item', {'item': 'Milk on Groceries'}),
      ]),
      ScriptedChatModel.text('Checked off milk on Groceries.'),
    ]);
    var attempts = 0;
    final executor = _Executor((invocation) {
      attempts++;
      if (attempts == 1) throw StateError('Milk is on two lists: Groceries and Costco');
      return const ToolDone(summary: 'Checked Milk', receipt: Receipt(id: 'r', summary: 'Checked Milk'));
    });
    final loop = AssistantLoop(model: model, tools: _tools, execute: executor.call);
    final result = await loop.ask('Check off milk', system: _system);

    final first = model.requests[1].messages.last as ToolResultsMessage;
    expect([for (final r in first.results) r.isError], [true, true, true, true]);
    expect(first.results[0].content, contains('no tool called "make_coffee"'));
    expect(first.results[1].content, contains('"item" is required.'));
    expect(first.results[1].content, contains('"thing" isn\'t one of'));
    expect(first.results[2].content, contains('Milk is on two lists'));
    expect(first.results[3].content, 'The arguments weren\'t JSON.');
    expect(executor.calls, hasLength(2));
    expect(result.end, TurnEnd.answered);
    expect([for (final s in result.steps) s.status], [
      StepStatus.failed,
      StepStatus.failed,
      StepStatus.failed,
      StepStatus.failed,
      StepStatus.done,
    ]);
    expect(result.toolCalls, 5);
  });

  test('a model that can\'t be reached ends the turn with a message', () async {
    final model = ScriptedChatModel([
      const ModelException('Claude is busy right now. Try again in a minute.', kind: ModelFailure.busy, retry: true),
    ]);
    final loop = AssistantLoop(model: model, tools: _tools, execute: _Executor().call);
    final result = await loop.ask('Hi', system: _system);
    expect(result.end, TurnEnd.failed);
    expect(result.error, 'Claude is busy right now. Try again in a minute.');
    expect(result.failure?.kind, ModelFailure.busy, reason: 'the exception itself, for an app to tell refusals apart');
    expect(result.modelCalls, 0);
  });

  test('refusals and cut-off answers say so', () async {
    final model = ScriptedChatModel([
      const ModelReply(message: AssistantMessage(), stopReason: StopReason.refusal),
      const ModelReply(message: AssistantMessage(text: 'The list is'), stopReason: StopReason.maxTokens),
    ]);
    final loop = AssistantLoop(model: model, tools: _tools, execute: _Executor().call);
    expect((await loop.ask('Something odd', system: _system)).end, TurnEnd.refused);
    expect((await loop.ask('Read me every list', system: _system)).end, TurnEnd.cutOff);
  });

  test('"undo that" takes the newest receipt that can be undone', () async {
    final model = ScriptedChatModel([
      ScriptedChatModel.calls([
        ScriptedChatModel.toolCall('a', 'check_item', {'item': 'Milk'}),
        ScriptedChatModel.toolCall('b', 'check_item', {'item': 'Bread'}),
        ScriptedChatModel.toolCall('c', 'check_item', {'item': 'Note'}),
      ]),
      ScriptedChatModel.text('Done.'),
    ]);
    final executor = _Executor((invocation) => ToolDone(
          receipt: Receipt(
            id: 'r-${invocation.call.id}',
            summary: 'Checked ${invocation.input['item']}',
            undoable: invocation.call.id != 'c',
          ),
        ));
    final loop = AssistantLoop(model: model, tools: _tools, execute: executor.call);
    final result = await loop.ask('Check off milk, bread and the note', system: _system);
    expect(result.steps[0].summary, 'Checked Milk');
    expect(loop.receipts.map((r) => r.id), ['r-a', 'r-b', 'r-c']);
    expect(loop.lastReceipt?.id, 'r-c');
    expect(UndoIntent.matches('undo that'), isTrue);
    expect(loop.takeLastUndoable()?.id, 'r-b');
    expect(loop.takeLastUndoable()?.id, 'r-a');
    expect(loop.takeLastUndoable(), isNull);
    expect(loop.receipts.map((r) => r.id), ['r-c']);
  });

  test('UndoIntent knows "undo that" from other requests', () {
    for (final yes in ['undo that', 'Undo.', 'oops, undo it please', 'Take that back', 'undo the last change!', 'no wait undo']) {
      expect(UndoIntent.matches(yes), isTrue, reason: yes);
    }
    for (final no in ['undo my dentist appointment', 'how do I undo?', 'add eggs', 'cancel soccer']) {
      expect(UndoIntent.matches(no), isFalse, reason: no);
    }
  });

  test('a conversation survives JSON', () async {
    final model = ScriptedChatModel([
      ScriptedChatModel.calls([
        ScriptedChatModel.toolCall('a', 'check_item', {'item': 'Milk'}),
      ]),
      ScriptedChatModel.text('Done.'),
    ]);
    final loop = AssistantLoop(model: model, tools: _tools, execute: _Executor().call);
    await loop.ask('Check off milk', system: _system);
    final saved = jsonDecode(jsonEncode([for (final m in loop.messages) m.toJson()])) as List;
    final restored = [for (final m in saved) ChatMessage.fromJson((m as Map).cast<String, Object?>())];
    expect(restored, hasLength(4));
    expect((restored[0] as UserMessage).text, 'Check off milk');
    expect((restored[1] as AssistantMessage).toolCalls.single.input, {'item': 'Milk'});
    expect((restored[2] as ToolResultsMessage).results.single.callId, 'a');
    expect((restored[3] as AssistantMessage).text, 'Done.');
    final again = AssistantLoop(model: ScriptedChatModel([]), tools: _tools, execute: _Executor().call, history: restored);
    expect(again.messages, hasLength(4));
  });
}
