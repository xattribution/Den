import 'package:device_calendar_plus/device_calendar_plus.dart' as dc;

import 'phone_calendars.dart';

/// Phone calendars through EventKit on iOS and the Calendar Provider on Android
/// (device_calendar_plus).
class DeviceCalendarSource implements PhoneCalendarSource {
  dc.DeviceCalendar get _plugin => dc.DeviceCalendar.instance;

  static PhoneAccess _access(dc.CalendarPermissionStatus status) => switch (status) {
        dc.CalendarPermissionStatus.granted => PhoneAccess.granted,
        dc.CalendarPermissionStatus.denied => PhoneAccess.denied,
        dc.CalendarPermissionStatus.restricted => PhoneAccess.restricted,
        // Write-only can't read the phone's events; asking again upgrades it to full access.
        dc.CalendarPermissionStatus.writeOnly || dc.CalendarPermissionStatus.notDetermined => PhoneAccess.ask,
      };

  @override
  Future<PhoneAccess> access() async => _access(await _plugin.hasPermissions());

  @override
  Future<PhoneAccess> requestAccess() async => _access(await _plugin.requestPermissions());

  @override
  Future<void> openSettings() => _plugin.openAppSettings();

  @override
  Future<List<PhoneCalendar>> calendars() async {
    final list = await _plugin.listCalendars();
    return [
      for (final c in list)
        if (!c.hidden) PhoneCalendar(id: c.id, name: c.name, account: c.accountName ?? ''),
    ];
  }

  @override
  Future<List<PhoneEvent>> events(List<String> calendarIds, DateTime from, DateTime to) async {
    if (calendarIds.isEmpty) return const [];
    final list = await _plugin.listEvents(from, to, calendarIds: calendarIds);
    return [
      for (final e in list)
        PhoneEvent(
          calendarId: e.calendarId,
          instanceId: e.instanceId,
          title: e.title,
          start: e.startDate,
          end: e.endDate,
          allDay: e.isAllDay,
          notes: e.description ?? '',
          location: e.location ?? '',
          timeZone: e.timeZone,
          cancelled: e.status == dc.EventStatus.canceled,
        ),
    ];
  }
}
