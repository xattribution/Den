import 'package:den_app/calendars/phone_calendars.dart';
import 'package:den_app/screens/events/event_detail.dart';
import 'package:den_app/screens/settings/phone_calendars_screen.dart';
import 'package:den_app/screens/settings/settings_screen.dart';
import 'package:den_app/state/app_state.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../calendars/fake_phone.dart';
import '../helpers/shots.dart';
import 'family_fakes.dart';

/// Alex's phone: a Google account with work and the family calendar, iCloud with the soccer
/// club, and one calendar kept only on the phone.
FakePhone alexsPhone({PhoneAccess grant = PhoneAccess.granted}) {
  DateTime at(int day, int hour, [int minute = 0]) =>
      demoNow.add(Duration(days: day, hours: hour - 8, minutes: minute));
  return FakePhone(
    grant: grant,
    calendars: const [
      PhoneCalendar(id: '3', name: 'Work', account: 'alex.carter@gmail.com'),
      PhoneCalendar(id: '4', name: 'Carter family', account: 'alex.carter@gmail.com'),
      PhoneCalendar(id: '5', name: 'Holidays in United States', account: 'alex.carter@gmail.com'),
      PhoneCalendar(id: '7', name: 'Soccer club', account: 'iCloud'),
      PhoneCalendar(id: '8', name: 'Birthdays', account: 'iCloud'),
      PhoneCalendar(id: '1', name: 'Personal'),
    ],
    events: [
      phoneEvent('3', '901', 'Quarterly review', at(0, 10)),
      phoneEvent('3', '902', 'Design sync', at(1, 14)),
      phoneEvent('3', '903', 'Flight to Denver', at(4, 7), length: const Duration(hours: 3)),
      for (var week = 0; week < 4; week++) phoneEvent('3', '904@$week', 'Team standup', at(3 + 7 * week, 9)),
      phoneEvent('4', '911', 'Parent-teacher conference', at(5, 16)),
      phoneEvent('4', '912', 'Fall festival', at(8, 11), length: const Duration(hours: 4)),
      for (var week = 0; week < 3; week++)
        phoneEvent('7', '921@$week', 'U10 game day', at(1 + 7 * week, 9), location: 'Riverside Park'),
      phoneEvent('1', '931', 'Haircut', at(2, 12)),
    ],
  );
}

/// The demo family on Alex's phone, with Work for parents, the family calendar and the soccer
/// club for everyone, and Personal for Alex only.
Future<(AppState, FakePhone)> withPhoneCalendars(WidgetTester tester, {PhoneAccess grant = PhoneAccess.granted}) async {
  final base = await demoIn(tester);
  final phone = alexsPhone();
  final calendars = PhoneCalendars(base.den, phone, now: () => demoNow.millisecondsSinceEpoch);
  await tester.runAsync(() async {
    await calendars.choose('3', Audience.parents);
    await calendars.choose('4', Audience.everyone);
    await calendars.choose('7', Audience.everyone);
    await calendars.choose('1', Audience.justMe);
  });
  phone.grant = grant;
  return (AppState(base.den, phoneCalendars: calendars), phone);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Calendars on this phone, phone', (tester) async {
    final (state, _) = await withPhoneCalendars(tester);
    await shootWith(tester, 'settings_phone_calendars_phone', const PhoneCalendarsScreen(), state: state);
  });

  testWidgets('Calendars on this phone, night', (tester) async {
    final (state, _) = await withPhoneCalendars(tester);
    await shootWith(
      tester,
      'settings_phone_calendars_phone_night',
      const PhoneCalendarsScreen(),
      state: state,
      night: true,
    );
  });

  testWidgets('Calendars on this phone, tablet', (tester) async {
    final (state, _) = await withPhoneCalendars(tester);
    await shootWith(tester, 'settings_phone_calendars_tablet', const PhoneCalendarsScreen(), state: state, size: tablet);
  });

  testWidgets('Calendars on this phone, before access, then allowed', (tester) async {
    final base = await demoIn(tester);
    final phone = alexsPhone(grant: PhoneAccess.ask);
    final state = AppState(base.den, phoneCalendars: PhoneCalendars(base.den, phone));
    await pumpScreen(tester, const PhoneCalendarsScreen(), state: state);
    await matchShot('settings_phone_calendars_ask_phone');

    await tester.tap(find.text('Allow access'));
    await tester.pumpAndSettle();
    expect(phone.grant, PhoneAccess.granted);
    expect(find.text('Holidays in United States'), findsOneWidget);
    expect(find.text('Off'), findsNWidgets(6));
  });

  testWidgets('Calendars on this phone, access turned off', (tester) async {
    final (state, phone) = await withPhoneCalendars(tester, grant: PhoneAccess.denied);
    await pumpScreen(tester, const PhoneCalendarsScreen(), state: state);
    await matchShot('settings_phone_calendars_denied_phone');

    await tester.tap(find.text('Open Settings'));
    await tester.pumpAndSettle();
    expect(phone.settingsOpened, 1);
  });

  testWidgets('Settings shows the calendars brought in', (tester) async {
    final (state, _) = await withPhoneCalendars(tester);
    await pumpScreen(tester, const SettingsScreen(version: '1.0.0'), state: state);
    expect(find.text('Calendars on this phone'), findsOneWidget);
    expect(find.text('4 brought in'), findsOneWidget);
  });

  testWidgets('An event from a phone calendar, phone', (tester) async {
    final (state, _) = await withPhoneCalendars(tester);
    final review = state.den.events.firstWhere((e) => e.title == 'Quarterly review');
    expect(review.source.label, 'Work');
    await shootWith(
      tester,
      'events_detail_phone_device',
      EventDetailScreen(eventId: review.id, at: review.start),
      state: state,
    );
    expect(find.textContaining("From Work on Alex's phone."), findsOneWidget);
  });
}
