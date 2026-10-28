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

/// The demo family on Alex's phone, as the actions' examples expect it ([prepareDemo]).
Future<Den> demoFamily() async {
  final den = await createDemoFamily();
  await prepareDemo(den);
  return den;
}

/// What the actions' examples expect of the demo family besides what [createDemoFamily] makes:
/// everyone has 100 more stars, Maya has one request for a reward waiting for a parent, and the
/// family subscribes to a "School calendar". [den] is a parent's own device.
Future<void> prepareDemo(Den den) async {
  final me = den.actor!.id;
  for (final m in den.members) {
    if (m.id != me) await den.adjustPoints(m.id, 100, 'Demo stars');
  }
  final maya = idOf(den, 'Maya');
  final points = den.points();
  if (!points.pending.any((p) => p.member == maya)) {
    final five = points.rewards.firstWhere((r) => r.needsApproval);
    await den.requestReward(five.id, member: maya);
  }
  await den.addSubscription(url: 'https://calendar.invalid/school.ics', label: 'School calendar');
}

/// A member id by name.
String idOf(Den den, String name) => den.members.firstWhere((m) => m.name == name).id;

/// A context for the phone's own parent, with every scope.
ActionContext parentOn(Den den, {Surface surface = Surface.app}) =>
    ActionContext(den, member: den.actor!.id, surface: surface, caller: 'test');
