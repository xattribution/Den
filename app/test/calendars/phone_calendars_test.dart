import 'dart:convert';

import 'package:den_app/calendars/phone_calendars.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_phone.dart';

/// Friday, October 16, 2026, 8 AM in Chicago.
final DateTime _now = DateTime.utc(2026, 10, 16, 13);
int _clock = 0;

Future<Den> _family() async {
  _clock = _now.millisecondsSinceEpoch;
  final den = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: () => _clock);
  await den.createFamily(
    familyName: 'Carter family',
    timezone: 'America/Chicago',
    yourName: 'Alex',
    marker: Marker.sky,
    animal: Animal.dog,
    deviceName: "Alex's phone",
    deviceKind: DeviceKind.phone,
  );
  return den;
}

FakePhone _phone() => FakePhone(
      calendars: const [
        PhoneCalendar(id: 'work', name: 'Work', account: 'alex@example.com'),
        PhoneCalendar(id: 'home', name: 'Home', account: 'iCloud'),
      ],
      events: [
        phoneEvent('work', 'w1', 'Standup', _now.add(const Duration(hours: 2)), location: 'Room 4'),
        phoneEvent('work', 'w2', '', _now.add(const Duration(days: 1))),
        PhoneEvent(
          calendarId: 'work',
          instanceId: 'w3',
          title: 'Offsite',
          start: DateTime(2026, 10, 20),
          end: DateTime(2026, 10, 22),
          allDay: true,
        ),
        PhoneEvent(
          calendarId: 'work',
          instanceId: 'w4',
          title: 'Called off',
          start: _now.add(const Duration(hours: 5)),
          end: _now.add(const Duration(hours: 6)),
          cancelled: true,
        ),
        phoneEvent('home', 'h1', 'Plumber', _now.add(const Duration(hours: 3))),
      ],
    );

PhoneCalendars _calendars(Den den, FakePhone phone) => PhoneCalendars(den, phone, now: () => _clock);

List<Event> _imported(Den den) => den.events.where((e) => e.source.kind == 'device').toList()
  ..sort((a, b) => a.start.compareTo(b.start));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a picked calendar comes in read-only, for the people chosen, assigned to the parent', () async {
    final den = await _family();
    final phone = _phone();
    final calendars = _calendars(den, phone);

    final result = await calendars.choose('work', Audience.parents);
    expect(result.added, 3);
    final events = _imported(den);
    expect(events.map((e) => e.title), ['Standup', 'Busy', 'Offsite']);
    expect(events.map((e) => e.space).toSet(), {Space.parents});
    expect(events.map((e) => e.assignees), everyElement([den.owner!.id]));
    expect(events.every((e) => e.source.readOnly && e.source.label == 'Work'), isTrue);
    expect(events.first.source.ref, '${den.deviceId}/work/w1');
    expect(events.first.location, 'Room 4');
    expect(events.first.reminders, isEmpty);

    final offsite = events.last;
    expect(offsite.allDay, isTrue);
    expect(den.dateOf(offsite.start), '2026-10-20');
    expect(offsite.end, den.dayStart('2026-10-22'));
    expect(calendars.countFor('work'), 3);
    expect(calendars.countFor('home'), 0);
  });

  test('edits on the phone update in place and deletions are removed', () async {
    final den = await _family();
    final phone = _phone();
    final calendars = _calendars(den, phone);
    await calendars.choose('work', Audience.everyone);
    final standup = _imported(den).first.id;

    phone.held
      ..removeWhere((e) => e.instanceId == 'w1' || e.instanceId == 'w2')
      ..add(phoneEvent('work', 'w1', 'Standup, moved', _now.add(const Duration(hours: 4))));
    final result = await calendars.sync();
    expect((result.added, result.updated, result.removed), (0, 1, 1));
    final events = _imported(den);
    expect(events.map((e) => e.title), ['Standup, moved', 'Offsite']);
    expect(events.first.id, standup);
    expect(events.first.start, _now.add(const Duration(hours: 4)).millisecondsSinceEpoch);

    final again = await calendars.sync();
    expect((again.added, again.updated, again.removed), (0, 0, 0));
  });

  test('changing who sees a calendar moves its events and keeps their ids', () async {
    final den = await _family();
    final calendars = _calendars(den, _phone());
    await calendars.choose('work', Audience.justMe);
    final ids = _imported(den).map((e) => e.id).toList();
    expect(_imported(den).map((e) => e.space).toSet(), {Space.member(den.owner!.id)});

    final result = await calendars.choose('work', Audience.everyone);
    expect(result.updated, 3);
    expect(_imported(den).map((e) => e.id), ids);
    expect(_imported(den).map((e) => e.space).toSet(), {Space.family});
  });

  test('turning a calendar off removes its events and leaves the others', () async {
    final den = await _family();
    final calendars = _calendars(den, _phone());
    await calendars.choose('work', Audience.everyone);
    await calendars.choose('home', Audience.parents);
    expect(_imported(den), hasLength(4));

    final result = await calendars.choose('work', null);
    expect(result.removed, 3);
    expect(_imported(den).map((e) => e.title), ['Plumber']);
    expect(calendars.picks, {'home': Audience.parents});
  });

  test('a calendar gone from the phone is dropped with its events', () async {
    final den = await _family();
    final phone = _phone();
    final calendars = _calendars(den, phone);
    await calendars.choose('home', Audience.everyone);
    phone.list.removeWhere((c) => c.id == 'home');

    await calendars.sync();
    expect(_imported(den), isEmpty);
    expect(calendars.picks, isEmpty);
  });

  test('without calendar access nothing is read and nothing is removed', () async {
    final den = await _family();
    final phone = _phone();
    final calendars = _calendars(den, phone);
    await calendars.choose('work', Audience.everyone);
    phone
      ..grant = PhoneAccess.denied
      ..held.clear();

    final result = await calendars.sync();
    expect(result.removed, 0);
    expect(_imported(den), hasLength(3));
    expect(calendars.access, PhoneAccess.denied);
  });

  test('each occurrence of a repeating event comes in on its own', () async {
    final den = await _family();
    final phone = FakePhone(
      calendars: const [PhoneCalendar(id: 'kids', name: 'Swim club')],
      events: [
        for (var week = 0; week < 3; week++)
          phoneEvent('kids', 'swim@${week + 1}', 'Swim lesson', _now.add(Duration(days: 7 * week, hours: 9))),
      ],
    );
    final calendars = _calendars(den, phone);
    await calendars.choose('kids', Audience.everyone);
    final events = _imported(den);
    expect(events, hasLength(3));
    expect(events.map((e) => e.source.ref).toSet(), hasLength(3));
    expect(events.every((e) => e.rrule == null), isTrue);
  });

  test('events that ended before the window stay as history', () async {
    final den = await _family();
    final phone = _phone();
    final calendars = _calendars(den, phone);
    await calendars.choose('home', Audience.everyone);

    // A month later the phone no longer returns last month's plumber visit.
    _clock += const Duration(days: 30).inMilliseconds;
    final result = await calendars.sync();
    expect(result.removed, 0);
    expect(_imported(den).map((e) => e.title), ['Plumber']);
  });

  test("another phone's events are never touched", () async {
    final den = await _family();
    final other = await den.addEvent(
      title: "Priya's standup",
      start: _now.add(const Duration(hours: 2)).millisecondsSinceEpoch,
      end: _now.add(const Duration(hours: 3)).millisecondsSinceEpoch,
      source: const EventSource('device', 'otherphone0000000/work/w1', 'Work'),
    );
    final calendars = _calendars(den, _phone());
    await calendars.choose('work', Audience.everyone);
    await calendars.choose('work', null);
    expect(den.event(other), isNotNull);
    expect(calendars.countFor('work'), 0);
  });

  test('the choices are kept on this phone, for this family only', () async {
    final den = await _family();
    await _calendars(den, _phone()).choose('work', Audience.parents);

    final reopened = _calendars(den, _phone());
    await reopened.load();
    expect(reopened.picks, {'work': Audience.parents});

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      PhoneCalendars.prefKey,
      jsonEncode({
        'family': 'another family',
        'calendars': {'work': 'everyone'},
      }),
    );
    await reopened.load();
    expect(reopened.picks, isEmpty);
  });
}
