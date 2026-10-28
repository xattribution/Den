import 'package:den_app/platform/notifications/reminder_plan.dart';
import 'package:den_app/platform/notifications/reminder_scheduler.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_outlet.dart';

const _minute = 60000;
const _hour = 60 * _minute;

/// Friday, October 16, 2026, 8 AM in Chicago.
final int _start = DateTime.utc(2026, 10, 16, 13).millisecondsSinceEpoch;

/// A family of one parent on their own phone, with a clock the test moves.
class World {
  World._(this.den);
  final Den den;
  static int clock = 0;

  static Future<World> create() async {
    clock = _start;
    final den = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: () => clock);
    await den.createFamily(
      familyName: 'Carter family',
      timezone: 'America/Chicago',
      yourName: 'Alex',
      marker: Marker.sky,
      animal: Animal.dog,
      deviceName: "Alex's phone",
      deviceKind: DeviceKind.phone,
    );
    return World._(den);
  }

  /// An event starting [startsIn] from the start of the test, with [reminders] minutes before.
  Future<String> event(
    String title,
    Duration startsIn, {
    List<int> reminders = const [30],
    Audience audience = Audience.everyone,
    String? rrule,
  }) {
    final start = _start + startsIn.inMilliseconds;
    return den.addEvent(
      title: title,
      start: start,
      end: start + _hour,
      reminders: reminders,
      audience: audience,
      rrule: rrule,
    );
  }

  List<PlannedReminder> plan() => planReminders(den, now: clock);

  ReminderScheduler scheduler(FakeOutlet outlet, {bool enabled = true}) =>
      ReminderScheduler(den, outlet, enabled: enabled, now: () => clock, settle: Duration.zero);
}

/// Waits on the real clock until [done], for work a change starts in the background.
Future<void> until(bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue, reason: 'timed out');
}

void main() {
  group('the window', () {
    test('holds the reminders due in the next 48 hours, soonest first', () async {
      final w = await World.create();
      await w.event('Already passed', const Duration(minutes: 10));
      await w.event('Soon', const Duration(hours: 1));
      await w.event('Last minute in', const Duration(hours: 48, minutes: -1), reminders: [0]);
      await w.event('Exactly 48 hours out', const Duration(hours: 48), reminders: [0]);
      await w.event('Three days out', const Duration(hours: 72), reminders: [0]);
      await w.event('Early warning', const Duration(hours: 72), reminders: [25 * 60]);

      final plan = w.plan();
      expect(plan.map((r) => r.title), ['Soon', 'Early warning', 'Last minute in']);
      expect(plan.first.at, _start + 30 * _minute);
      expect(plan.map((r) => r.at), everyElement(inInclusiveRange(_start, _start + 48 * _hour - 1)));
    });

    test('rolls forward as time passes', () async {
      final w = await World.create();
      await w.event('Saturday swim', const Duration(hours: 50), reminders: [0]);
      final outlet = FakeOutlet();
      final s = w.scheduler(outlet);
      await s.start();
      expect(outlet.held, isEmpty);

      World.clock += 3 * _hour;
      await s.reschedule();
      expect(outlet.held.values.map((r) => r.title), ['Saturday swim']);
      await s.dispose();
    });

    test('keeps the 60 soonest, under the iOS limit', () async {
      final w = await World.create();
      for (var i = 0; i < 70; i++) {
        await w.event('Slot $i', Duration(minutes: 30 * (i + 1)), reminders: [0]);
      }
      final plan = w.plan();
      expect(plan, hasLength(maxScheduledReminders));
      expect(plan.last.title, 'Slot 59');
    });
  });

  group('dedupe', () {
    test('one notification per reminder key, with the same id on every plan', () async {
      final w = await World.create();
      await w.event('Practice', const Duration(hours: 2), reminders: [10, 10, 0], rrule: 'FREQ=DAILY');

      final first = w.plan();
      final second = w.plan();
      // Today's and tomorrow's practice, ten minutes before and at the start.
      expect(first, hasLength(4));
      expect(first.map((r) => r.key).toSet(), hasLength(4));
      expect(first.map((r) => r.id).toSet(), hasLength(4));
      expect(second, first);
      expect(first.map((r) => r.id), [for (final r in first) reminderId(r.key)]);
    });

    test('scheduling again never adds a second notification', () async {
      final w = await World.create();
      await w.event('Dentist', const Duration(hours: 3));
      final outlet = FakeOutlet();
      final s = w.scheduler(outlet);
      await s.start();
      expect(outlet.scheduledCalls, hasLength(1));

      await s.reschedule();
      await s.reschedule();
      // A change that touches no reminder.
      await w.den.addEvent(title: 'Pizza night', start: _start + 5 * _hour, end: _start + 6 * _hour);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await s.reschedule();
      expect(outlet.scheduledCalls, hasLength(1));
      expect(outlet.cancelled, isEmpty);
      await s.dispose();
    });

    test('a key the OS still holds from an earlier run is replaced, not doubled', () async {
      final w = await World.create();
      await w.event('Dentist', const Duration(hours: 3));
      final keep = w.plan().single;
      final outlet = FakeOutlet()..leftover = {keep.id, 12345};
      final s = w.scheduler(outlet);
      await s.start();
      expect(outlet.cancelled, [12345]);
      expect(outlet.scheduledCalls.map((r) => r.id), [keep.id]);
      await s.dispose();
    });
  });

  group('following changes', () {
    test('a new reminder is scheduled when the engine changes', () async {
      final w = await World.create();
      final outlet = FakeOutlet();
      final s = w.scheduler(outlet);
      await s.start();
      expect(outlet.held, isEmpty);

      await w.event('Soccer', const Duration(hours: 4));
      await until(() => outlet.held.isNotEmpty);
      expect(outlet.held.values.single.title, 'Soccer');
      expect(outlet.held.values.single.body, 'Starts at 12:00 PM');
      await s.dispose();
    });

    test('a changed event replaces its reminder under the same id', () async {
      final w = await World.create();
      final id = await w.event('Soccer', const Duration(hours: 4));
      final outlet = FakeOutlet();
      final s = w.scheduler(outlet);
      await s.start();
      final before = outlet.held.values.single;

      await w.den.updateEvent(id, {'title': 'Soccer, Field 4'});
      await until(() => outlet.scheduledCalls.length == 2);
      expect(outlet.cancelled, isEmpty);
      expect(outlet.held.keys, [before.id]);
      expect(outlet.held.values.single.title, 'Soccer, Field 4');
      await s.dispose();
    });

    test('a removed reminder is withdrawn; one that already fired stays in the tray', () async {
      final w = await World.create();
      final fired = await w.event('Drop-off', const Duration(hours: 1));
      final later = await w.event('Pick-up', const Duration(hours: 6));
      final outlet = FakeOutlet();
      final s = w.scheduler(outlet);
      await s.start();
      final ids = {for (final r in outlet.held.values) r.title: r.id};

      World.clock += _hour;
      await w.den.deleteEvent(fired);
      await w.den.deleteEvent(later);
      await until(() => outlet.cancelled.isNotEmpty);
      await s.reschedule();
      expect(outlet.cancelled, [ids['Pick-up']]);
      await s.dispose();
    });

    test('turning reminders off withdraws them all, and on brings them back', () async {
      final w = await World.create();
      await w.event('Dentist', const Duration(hours: 3));
      await w.event('Soccer', const Duration(hours: 5));
      final outlet = FakeOutlet();
      final s = w.scheduler(outlet);
      await s.start();
      expect(outlet.held, hasLength(2));

      await s.setEnabled(false);
      expect(outlet.held, isEmpty);
      expect(outlet.cancelled, hasLength(2));

      await s.setEnabled(true);
      expect(outlet.held, hasLength(2));
      await s.dispose();
    });

    test('a device with reminders off schedules nothing', () async {
      final w = await World.create();
      await w.event('Dentist', const Duration(hours: 3));
      final outlet = FakeOutlet();
      final s = w.scheduler(outlet, enabled: false);
      await s.start();
      expect(outlet.held, isEmpty);
      expect(outlet.asks, 0);
      await s.dispose();
    });

    test('asks to notify only once there is something to remind', () async {
      final w = await World.create();
      final outlet = FakeOutlet();
      final s = w.scheduler(outlet);
      await s.start();
      expect(outlet.asks, 0);

      await w.event('Dentist', const Duration(hours: 3));
      await until(() => outlet.held.isNotEmpty);
      await w.event('Soccer', const Duration(hours: 5));
      await until(() => outlet.held.length == 2);
      expect(outlet.asks, 1);
      await s.dispose();
    });
  });

  group('words and taps', () {
    test('a private item shows only "A reminder from Den" on a shared device', () async {
      final w = await World.create();
      await w.event('Therapy', const Duration(hours: 2), audience: Audience.justMe);
      await w.event('Date night', const Duration(hours: 3), audience: Audience.parents);
      await w.event('Soccer', const Duration(hours: 4));

      expect(w.plan().map((r) => r.title), ['Therapy', 'Date night', 'Soccer']);

      // The same phone becomes the family's hub on the kitchen counter.
      await w.den.setThisDeviceMode(DeviceMode.hub);
      final shared = w.plan();
      expect(shared.map((r) => r.title), [privateReminderTitle, privateReminderTitle, 'Soccer']);
      expect(shared.take(2).map((r) => r.body), ['', '']);
      expect(shared.last.body, 'Starts at 12:00 PM');
    });

    test('a tap opens the event occurrence or the chore day', () async {
      final w = await World.create();
      final event = await w.event('Soccer', const Duration(hours: 4));
      final chore = await w.den.addChore(
        title: 'Trash out',
        owner: OwnerMember(w.den.owner!.id),
        schedule: const ChoreSchedule.once('2026-10-16'),
        dueTime: '19:00',
        reminders: [15],
      );
      final routes = {for (final r in w.plan()) r.title: r.route};
      expect(routes['Soccer'], '/event/$event?at=${_start + 4 * _hour}');
      expect(routes['Trash out'], '/chore/$chore?date=2026-10-16');
      expect(reminderRoute('mystery'), '/today');
    });

    test('the tap that launched the app and later taps reach the router in order', () async {
      final w = await World.create();
      final outlet = FakeOutlet()..launch = '/event/abc?at=1';
      final s = w.scheduler(outlet);
      final routes = <String>[];
      final sub = s.taps.listen(routes.add);
      await s.start();
      outlet.tap!('/chore/xyz?date=2026-10-16');
      await Future<void>.delayed(Duration.zero);
      expect(routes, ['/event/abc?at=1', '/chore/xyz?date=2026-10-16']);
      await sub.cancel();
      await s.dispose();
    });
  });
}
