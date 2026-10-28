import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/features/calendar/screens/day_view.dart';
import 'package:den_app/app/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';
import 'calendar_shots.dart';

void main() {
  Future<void> pumpDay(WidgetTester tester, AppState state, String date) async {
    await loadFonts();
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      DenScope(
        state: state,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: denTheme(DenColors.day),
          home: Scaffold(body: DayView(date: date, now: demoNow.millisecondsSinceEpoch)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('press, hold and drag moves an event by the snapped amount', (tester) async {
    final state = await demo(tester);
    final party = findEvent(state, 'Sophie');
    final date = state.formats.localDate(party.start);
    await pumpDay(tester, state, date);

    final block = find.bySemanticsLabel(RegExp('^Sophie'));
    final gesture = await tester.startGesture(tester.getCenter(block));
    await tester.pump(const Duration(milliseconds: 600));
    // 64 px is an hour; 60 px snaps to the hour, not short of it.
    await gesture.moveBy(const Offset(0, 30));
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    await tester.runAsync(() async {
      await gesture.up();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    final moved = state.den.event(party.event.id)!;
    expect(moved.start, party.start + 3600000);
    expect(moved.end, party.end + 3600000);
    expect(find.text('Undo'), findsOneWidget);
  });

  testWidgets('dragging the bottom edge changes only when it ends', (tester) async {
    final state = await demo(tester);
    final party = findEvent(state, 'Sophie');
    final date = state.formats.localDate(party.start);
    await pumpDay(tester, state, date);

    final rect = tester.getRect(find.bySemanticsLabel(RegExp('^Sophie')));
    final gesture = await tester.startGesture(Offset(rect.center.dx, rect.bottom - 4));
    await gesture.moveBy(const Offset(0, 20));
    await gesture.moveBy(const Offset(0, 8));
    await tester.pump();
    await tester.runAsync(() async {
      await gesture.up();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    final changed = state.den.event(party.event.id)!;
    expect(changed.start, party.start);
    expect(changed.end, party.end + 30 * 60000);
  });

  testWidgets('moving a repeating event asks in place, and "just this one" moves only it', (tester) async {
    final state = await demo(tester);
    final soccer = findEvent(state, 'Soccer');
    final date = state.formats.localDate(soccer.start);
    await pumpDay(tester, state, date);

    final block = find.bySemanticsLabel(RegExp('^Soccer'));
    final gesture = await tester.startGesture(tester.getCenter(block));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(0, 30));
    await gesture.moveBy(const Offset(0, 34));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.textContaining('Move just this'), findsOneWidget);
    expect(state.den.event(soccer.event.id)!.start, soccer.event.start, reason: 'nothing moves before the answer');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/calendar_day_phone_ask.png'));

    await tester.runAsync(() async {
      await tester.tap(find.text('Just this one'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    final moved = state.den.occurrences(soccer.start, soccer.start + 7200000).where((o) => o.event.id == soccer.event.id);
    expect(moved.single.start, soccer.start + 3600000);
    expect(state.den.event(soccer.event.id)!.start, soccer.event.start, reason: 'the series stays');
    expect(find.text('Undo'), findsOneWidget);
  });
}
