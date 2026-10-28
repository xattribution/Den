/// Fails when something the engine can do has no action and no written reason, and when an
/// action's declared engine methods, example or output schema drift from what it does.
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';
import 'dart:mirrors';

import 'package:den_actions/den_actions.dart';
import 'package:den_core/den_core.dart';

import 'support.dart';

/// Every public `Future<...> name(` method of `Den`, read from its source.
Set<String> engineWrites() {
  final source = File('../den_core/lib/src/den.dart').readAsStringSync();
  return {
    for (final m in RegExp(r'^  (?:static )?Future<[^\s(]*> ([a-zA-Z]\w*)(?:<\w+>)?\(', multiLine: true).allMatches(source))
      m.group(1)!,
  };
}

/// A `Den` that forwards everything to a real one and notes which write methods are called while
/// [active].
class RecordingDen implements Den {
  RecordingDen(this.real, this.writes);

  final Den real;
  final Set<String> writes;
  final List<String> calls = [];
  bool active = false;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = MirrorSystem.getName(invocation.memberName);
    if (active && invocation.isMethod && writes.contains(name)) calls.add(name);
    return reflect(real).delegate(invocation);
  }
}

void main() {
  final writes = engineWrites();
  final specs = allActions();

  test('the engine has the write methods this test expects to find', () {
    expect(writes, containsAll(['addEvent', 'deleteChore', 'undo', 'recording', 'approveDevice', 'addSubscription']));
    expect(writes.length, greaterThan(50));
  });

  test('every engine write is offered by an action or listed as not exposed, with a reason, never both', () {
    final used = {for (final s in specs) ...s.engine};
    final missing = [for (final w in writes) if (!used.contains(w) && !notExposed.containsKey(w)) w];
    expect(missing, isEmpty, reason: 'Give these an action, or a reason in not_exposed.dart');
    final both = [for (final w in writes) if (used.contains(w) && notExposed.containsKey(w)) w];
    expect(both, isEmpty, reason: 'These are both offered and listed as not exposed');
    for (final e in notExposed.entries) {
      expect(e.value.trim(), isNotEmpty, reason: '${e.key} needs a reason');
    }
  });

  test('every engine method an action or not_exposed names is a real write method', () {
    final named = {for (final s in specs) ...s.engine, ...notExposed.keys};
    expect([for (final n in named) if (!writes.contains(n)) n], isEmpty);
  });

  test('names are unique, portable, and aliases point at actions', () {
    final runner = standardRunner();
    final names = [for (final s in specs) s.mcpName];
    expect(names.toSet(), hasLength(names.length));
    expect({for (final s in specs) s.name}, hasLength(specs.length));
    for (final n in names) {
      expect(n, matches(RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]{0,63}$')));
    }
    for (final a in runner.aliases) {
      expect(names, isNot(contains(a.name)));
      expect(runner.spec(a.target), isNotNull, reason: a.name);
    }
  });

  test('writes declare what they call; reads call nothing', () {
    for (final s in specs) {
      expect(s.readOnly, s.engine.isEmpty, reason: '${s.mcpName}: a read calls no write method, a write names one');
      expect(s.example, isNotNull);
      expect(s.outputSchema['type'], 'object', reason: s.mcpName);
      expect(s.inputSchema['type'], 'object', reason: s.mcpName);
    }
  });

  for (final spec in specs) {
    test('${spec.mcpName}: its example runs on the demo family, calls only its engine methods, and fits its output', () async {
      final real = await demoFamily();
      final den = RecordingDen(real, writes);
      final runner = ActionRunner([
        for (final s in specs)
          s.withRun((c, a) async {
            den.active = s.mcpName == spec.mcpName;
            try {
              return await s.run(c, a);
            } finally {
              den.active = false;
            }
          }),
      ]);
      final context = ActionContext(den, member: real.actor!.id, caller: 'coverage');
      if (spec.mcpName == 'undo') {
        final made = await runner.run(context, 'add_items', {'list': 'Groceries', 'items': ['Butter']}, mode: RunMode.confirmed);
        expect(made.receipt, isNotNull, reason: made.text);
      }
      final result = await runner.run(context, spec.mcpName, spec.example, mode: RunMode.confirmed);
      expect(result.isError, isFalse, reason: '${spec.mcpName}: ${result.text}');
      expect(den.calls.toSet().difference(spec.engine), isEmpty, reason: '${spec.mcpName} called methods it doesn\'t declare');
      if (!spec.readOnly) expect(den.calls, isNotEmpty, reason: '${spec.mcpName}\'s example changed nothing');
      expect(schemaProblems(spec.outputSchema, result.structured), isEmpty, reason: spec.mcpName);
      await real.close();
    });
  }
}
