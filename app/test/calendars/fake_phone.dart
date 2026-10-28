import 'package:den_app/platform/calendars/phone_calendars.dart';

/// A phone's calendars held in lists the test edits.
class FakePhone implements PhoneCalendarSource {
  FakePhone({this.grant = PhoneAccess.granted, List<PhoneCalendar>? calendars, List<PhoneEvent>? events})
      : list = [...?calendars],
        held = [...?events];

  PhoneAccess grant;
  final List<PhoneCalendar> list;
  final List<PhoneEvent> held;
  int settingsOpened = 0;
  int reads = 0;

  @override
  Future<PhoneAccess> access() async => grant;

  @override
  Future<PhoneAccess> requestAccess() async {
    if (grant == PhoneAccess.ask) grant = PhoneAccess.granted;
    return grant;
  }

  @override
  Future<void> openSettings() async => settingsOpened++;

  @override
  Future<List<PhoneCalendar>> calendars() async => [...list];

  @override
  Future<List<PhoneEvent>> events(List<String> calendarIds, DateTime from, DateTime to) async {
    reads++;
    return [
      for (final e in held)
        if (calendarIds.contains(e.calendarId) && e.end.isAfter(from) && e.start.isBefore(to)) e,
    ];
  }
}

/// A timed occurrence on the phone.
PhoneEvent phoneEvent(String calendar, String id, String title, DateTime start, {Duration length = const Duration(hours: 1), String location = ''}) =>
    PhoneEvent(calendarId: calendar, instanceId: id, title: title, start: start, end: start.add(length), location: location);
