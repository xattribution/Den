import 'package:den_app/app.dart';
import 'package:den_app/screens/calendar/family_week.dart';
import 'package:den_app/screens/today/today_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';

void main() {
  testWidgets('Today, phone, day theme', (tester) async {
    final state = await demoIn(tester);
    await shoot(tester, 'today_phone', const TodayScreen(), state: state);
  });

  testWidgets('Today, phone, night theme', (tester) async {
    final state = await demoIn(tester);
    await shoot(tester, 'today_phone_night', const TodayScreen(), state: state, night: true);
  });

  testWidgets('App shell on a tablet', (tester) async {
    final state = await demoIn(tester);
    await shootRoute(tester, 'shell_tablet', buildRouter(state), state: state, size: tablet);
  });

  testWidgets('Family week on the wall', (tester) async {
    final state = await demoIn(tester, wall: true);
    await shoot(
      tester,
      'family_week_wall',
      FamilyWeek(startDate: state.den.todayDate(), fillHeight: true),
      state: state,
      size: wall,
    );
  });
}
