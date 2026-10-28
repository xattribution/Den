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
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      DenScope(
        state: state,
        child: MaterialApp(
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
    // 56 px is an hour; a little extra snaps to the hour, not past it.
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
}
