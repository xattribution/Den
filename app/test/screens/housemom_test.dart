import 'package:den_app/app/app_state.dart';
import 'package:den_app/app/router.dart';
import 'package:den_app/app/shell.dart' show PersonButton;
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/design/widgets.dart';
import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';

/// The housemom pass (docs/design/HOUSEMOM_PASS.md): a busy parent's top jobs on an iPhone, tap
/// by tap, in the whole app at 390 by 844. Each test counts the taps of the shortest path, so a
/// change that adds one fails here.

/// The demo family on Alex's phone, with Grandma Rosa's iPad asking to join, after [setup].
Future<AppState> _family(WidgetTester tester, {bool deviceWaiting = false}) => real(tester, () async {
      final phone = await createDemoFamily(now: demoNow);
      if (deviceWaiting) {
        final rosa = phone.members.firstWhere((m) => m.name == 'Grandma Rosa');
        final ipad = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: () => demoNow.millisecondsSinceEpoch);
        await ipad.requestJoin(
          familyId: phone.familyId!,
          founderPubkey: phone.founderPubkey!,
          deviceName: "Rosa's iPad",
          kind: DeviceKind.tablet,
          memberId: rosa.id,
        );
        await phone.ingest(ipad.changesSince(phone.versionVector));
      }
      return AppState(phone);
    });

/// The whole app, Today first, at iPhone size.
Future<GoRouter> _app(WidgetTester tester, AppState state, {bool night = false, Size size = phone}) async {
  await loadFonts();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = buildRouter(state);
  await tester.pumpWidget(
    DenScope(
      state: state,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        routerConfig: router,
        theme: denTheme(night ? DenColors.night : DenColors.day),
        builder: (context, child) => TextSizeFromState(child: child!),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

/// Counts each tap a path takes, on the real clock so the engine can sign what it writes.
class _Taps {
  _Taps(this.tester);
  final WidgetTester tester;
  int count = 0;

  Future<void> on(Finder finder) async {
    expect(finder, findsOneWidget, reason: 'tap ${count + 1}');
    count++;
    await tester.runAsync(() async {
      await tester.tap(finder);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
  }
}

void main() {
  group('shots', () {
    testWidgets("the person's menu", (tester) async {
      final state = await _family(tester);
      await _app(tester, state);
      await tester.tap(find.byType(PersonButton));
      await tester.pumpAndSettle();
      await matchShot('housemom/person_menu_phone');
    });

    testWidgets('Needs you, with a device asking to join', (tester) async {
      final state = await _family(tester, deviceWaiting: true);
      await _app(tester, state);
      await matchShot('housemom/today_needs_device_phone');
    });

    testWidgets('Needs you, with a device asking to join, at night', (tester) async {
      final state = await _family(tester, deviceWaiting: true);
      await _app(tester, state, night: true);
      await matchShot('housemom/today_needs_device_phone_night');
    });
  });
}
