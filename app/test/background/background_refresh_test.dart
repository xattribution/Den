import 'dart:async';
import 'dart:convert';

import 'package:den_app/background/background_refresh.dart';
import 'package:den_app/calendars/phone_calendars.dart';
import 'package:den_app/reminders/reminder_plan.dart';
import 'package:den_app/reminders/reminder_scheduler.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../calendars/fake_phone.dart';
import '../reminders/fake_outlet.dart';

const _hour = 3600000;

/// Friday, October 16, 2026, 8 AM in Chicago.
final DateTime _now = DateTime.utc(2026, 10, 16, 13);
int _clock() => _now.millisecondsSinceEpoch;

Future<Den> _phone({bool family = true}) async {
  final den = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: _clock);
  if (!family) return den;
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

Future<void> _bringIn(Den den, Map<String, String> calendars) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(PhoneCalendars.prefKey, jsonEncode({'family': den.familyId, 'calendars': calendars}));
}

FakePhone _workPhone() => FakePhone(
      calendars: const [PhoneCalendar(id: 'work', name: 'Work')],
      events: [phoneEvent('work', 'w1', 'Quarterly review', _now.add(const Duration(hours: 2)))],
    );

Future<String> _event(Den den, String title, int startsIn, {List<int> reminders = const [30]}) => den.addEvent(
      title: title,
      start: _clock() + startsIn,
      end: _clock() + startsIn + _hour,
      reminders: reminders,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a pass catches up first, then brings in calendars, then plans reminders', () async {
    final den = await _phone();
    await _bringIn(den, {'work': 'everyone'});
    final outlet = FakeOutlet();
    final steps = <String>[];

    await BackgroundRefresh(
      den,
      outlet: outlet,
      calendars: _workPhone(),
      now: _clock,
      connect: (den) async {
        steps.add('connect');
        // Priya added soccer from her phone while this one slept.
        await _event(den, 'Soccer', 4 * _hour);
        return () async => steps.add('disconnect');
      },
    ).run();

    expect(steps, ['connect', 'disconnect']);
    expect(den.events.where((e) => e.source.kind == 'device').map((e) => e.title), ['Quarterly review']);
    expect(outlet.held.values.map((r) => r.title), ['Soccer']);
    expect(outlet.asks, 0);
  });

  test('a pass replaces what the OS already holds instead of adding to it', () async {
    final den = await _phone();
    await _event(den, 'Dentist', 3 * _hour);
    final held = planReminders(den, now: _clock()).single;
    final outlet = FakeOutlet()..leftover = {held.id, 4242};

    await BackgroundRefresh(den, outlet: outlet, now: _clock).run();
    expect(outlet.cancelled, [4242]);
    expect(outlet.scheduledCalls.map((r) => r.id), [held.id]);
  });

  test('with reminders off, a pass withdraws what the OS holds and schedules nothing', () async {
    final den = await _phone();
    await _event(den, 'Dentist', 3 * _hour);
    (await SharedPreferences.getInstance()).setBool(remindersPrefKey, false);
    final outlet = FakeOutlet()..leftover = {planReminders(den, now: _clock()).single.id};

    await BackgroundRefresh(den, outlet: outlet, now: _clock).run();
    expect(outlet.held, isEmpty);
    expect(outlet.cancelled, hasLength(1));
  });

  test('a failed connection or calendar read still leaves the reminders planned', () async {
    final den = await _phone();
    await _event(den, 'Dentist', 3 * _hour);
    await _bringIn(den, {'work': 'parents'});
    final outlet = FakeOutlet();

    await BackgroundRefresh(
      den,
      outlet: outlet,
      calendars: _workPhone()..grant = PhoneAccess.denied,
      now: _clock,
      connect: (_) async => throw StateError('no network'),
    ).run();
    expect(outlet.held.values.map((r) => r.title), ['Dentist']);
    expect(den.events.where((e) => e.source.kind == 'device'), isEmpty);
  });

  test('a connection that never finishes is given up on, and the reminders still get planned', () async {
    final den = await _phone();
    await _event(den, 'Dentist', 3 * _hour);
    final outlet = FakeOutlet();

    await BackgroundRefresh(
      den,
      outlet: outlet,
      now: _clock,
      connectLimit: const Duration(milliseconds: 50),
      connect: (_) => Completer<Disconnect?>().future,
    ).run();
    expect(outlet.held.values.map((r) => r.title), ['Dentist']);
  });

  test('a phone with no calendars brought in never reads them', () async {
    final den = await _phone();
    final phone = _workPhone();
    await BackgroundRefresh(den, outlet: FakeOutlet(), calendars: phone, now: _clock).run();
    expect(phone.reads, 0);
  });

  test('a device that is not in a family yet does nothing', () async {
    final den = await _phone(family: false);
    var connected = false;
    final outlet = FakeOutlet();
    await BackgroundRefresh(
      den,
      outlet: outlet,
      now: _clock,
      connect: (_) async {
        connected = true;
        return null;
      },
    ).run();
    expect(connected, isFalse);
    expect(outlet.scheduledCalls, isEmpty);
  });
}
