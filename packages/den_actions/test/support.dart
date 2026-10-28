/// package:test, with [test] reporting a failure as a GitHub Actions annotation too, and the demo
/// family the actions' examples are written for.
library;

import 'dart:async';

import 'package:den_actions/den_actions.dart';
import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:test/test.dart' as base;

export 'package:test/test.dart' hide test;

/// [base.test], with a failing body also printed as an `::error` workflow command.
void test(Object? description, FutureOr<void> Function() body, {base.Timeout? timeout, Object? skip}) {
  base.test(
    description,
    () async {
      try {
        await body();
      } catch (e, stack) {
        final frames = stack.toString().split('\n').where((l) => l.contains('den_') || l.contains('test/')).take(6).join('\n');
        final text = '$description: $e\n$frames'.replaceAll('%', '%25').replaceAll('\r', '').replaceAll('\n', '%0A');
        print('::error title=den_actions test failed::$text');
        rethrow;
      }
    },
    timeout: timeout,
    skip: skip,
  );
}

/// The demo family on Alex's phone, as the actions' examples expect it: everyone has 100 more
/// stars, and Maya has a request for a reward waiting for a parent.
Future<Den> demoFamily() async {
  final den = await createDemoFamily();
  for (final m in den.members) {
    if (m.id != den.actor!.id) await den.adjustPoints(m.id, 100, 'Demo stars');
  }
  final maya = idOf(den, 'Maya');
  final points = den.points();
  if (!points.pending.any((p) => p.member == maya)) {
    final five = points.rewards.firstWhere((r) => r.needsApproval);
    await den.requestReward(five.id, member: maya);
  }
  return den;
}

/// A member id by name.
String idOf(Den den, String name) => den.members.firstWhere((m) => m.name == name).id;

/// A context for the phone's own parent, with every scope.
ActionContext parentOn(Den den, {Surface surface = Surface.app}) =>
    ActionContext(den, member: den.actor!.id, surface: surface, caller: 'test');
