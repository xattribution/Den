import 'package:den_app/app/den_app.dart';
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/app/app_state.dart';
import 'package:den_core/den_core.dart';
import 'package:den_core/demo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';

/// Screenshot helpers shared by the chores, lists and points tests, on top of
/// `helpers/shots.dart`.

/// A phone tall enough to show a whole editor or detail page in one image.
const Size tall = Size(390, 1700);

/// The demo family on a parent's phone, built outside the test's fake clock: signing changes
/// needs real async work, which never completes inside `testWidgets`' fake zone.
Future<AppState> demo(WidgetTester tester, {bool wall = false}) async =>
    (await tester.runAsync(() => demoState(wall: wall)))!;

/// The demo family as a kid sees it on their own phone (see [kidState]).
Future<AppState> kidDemo(WidgetTester tester, String kidName) async =>
    (await tester.runAsync(() => kidState(kidName)))!;

/// The demo family as a kid sees it on their own phone: a second device that joins as [kidName],
/// is approved on the parent's phone, and syncs what it may hold.
Future<AppState> kidState(String kidName) async {
  final parent = await createDemoFamily(now: demoNow);
  final kid = parent.members.firstWhere((m) => m.name == kidName);
  final phone = await Den.open(
    storage: MemoryStorage(),
    keys: await DeviceKeys.generate(),
    now: () => demoNow.millisecondsSinceEpoch,
  );
  await phone.requestJoin(
    familyId: parent.familyId!,
    founderPubkey: parent.founderPubkey!,
    deviceName: '$kidName\'s phone',
    kind: DeviceKind.phone,
    memberId: kid.id,
  );
  await parent.ingest(phone.changesSince(parent.versionVector));
  await parent.approveDevice(phone.deviceId, member: kid.id);
  await phone.ingest(
    parent.changesSince(phone.versionVector, spaces: parent.spacesForDevice(phone.deviceId)),
    through: parent.completeVector,
  );
  return AppState(phone);
}

/// Like [shoot], but runs [act] (taps, long-presses, typing) before the comparison.
Future<void> shootAfter(
  WidgetTester tester,
  String name,
  Widget screen, {
  required AppState state,
  required Future<void> Function(WidgetTester tester) act,
  Size size = phone,
  bool night = false,
}) async {
  await loadFonts();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final scale = state.wall ? DenType.wallScale : 1.0;
  await tester.pumpWidget(
    DenScope(
      state: state,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: denTheme(night ? DenColors.night : DenColors.day, typeScale: scale),
        home: Scaffold(body: SafeArea(child: screen)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await act(tester);
  await tester.pumpAndSettle();
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/$name.png'));
}

/// Renders the whole app (shell included) at [path].
Future<void> shootPath(
  WidgetTester tester,
  String name,
  String path, {
  required AppState state,
  Size size = phone,
  bool night = false,
  Future<void> Function(WidgetTester tester)? act,
}) async {
  await loadFonts();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = buildRouter(state);
  final scale = state.wall ? DenType.wallScale : 1.0;
  await tester.pumpWidget(
    DenScope(
      state: state,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        routerConfig: router,
        theme: denTheme(night ? DenColors.night : DenColors.day, typeScale: scale),
      ),
    ),
  );
  await tester.pumpAndSettle();
  router.go(path);
  await tester.pumpAndSettle();
  if (act != null) {
    await act(tester);
    await tester.pumpAndSettle();
  }
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/$name.png'));
}
