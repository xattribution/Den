import 'dart:convert';
import 'dart:math';

import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'support.dart';

String occurrenceText(Occurrence o) =>
    '${o.event.id}@${o.seriesStart}:${o.start}-${o.end} ${o.title} ${o.assignees} ${o.allDay} '
    '${[for (final r in o.rides) '${r.leg}=${r.driver}']} ${o.exceptionId}';

String choreText(ChoreDay c) => '${c.chore.id}@${c.date} ${c.chore.title} ${c.owner} ${c.done} ${c.doneBy} ${c.steps} ${c.late} ${c.swapped}';

/// Every view the screens ask for, as text.
String views(Den den, int from) {
  final today = den.todayDate();
  final t = den.today();
  final w = den.week(today);
  return jsonEncode({
    'readable': den.readableSpaces.toList()..sort(),
    'events': [for (final e in den.events) '${e.id} ${e.title} ${e.start}'],
    'occurrences': [for (final o in den.occurrences(from, from + 21 * 86400000)) occurrenceText(o)],
    'today': {
      'events': [for (final o in t.events) occurrenceText(o)],
      'chores': [for (final c in t.chores) choreText(c)],
      'lists': [for (final l in t.lists) '${l.list.id} ${l.list.title} ${[for (final i in l.items) '${i.text}:${i.checked}']}'],
      'gaps': [for (final g in t.gaps) '${g.kind} ${g.message} ${g.members}'],
    },
    'week': [
      for (final d in w.days)
        for (final p in w.people) [d, p.id, [for (final o in w.cells[(d, p.id)]!.events) occurrenceText(o)], [for (final c in w.cells[(d, p.id)]!.chores) choreText(c)]],
      for (final d in w.days) [d, [for (final o in w.everyone[d]!) occurrenceText(o)]],
    ],
    'chores': [for (final c in den.choresOn(today)) choreText(c)],
    'late': [for (final c in den.lateChores()) choreText(c)],
    'lists': [for (final l in den.lists) '${l.list.id} ${l.list.title} ${l.items.length}'],
    'members': [for (final m in den.members) '${m.id} ${m.name} ${m.order}'],
    'gaps': [for (final g in den.gaps(from, from + 7 * 86400000)) '${g.kind} ${g.message}'],
    'reminders': [for (final r in den.remindersDue(from, from + 3 * 86400000)) r.key],
  });
}

void main() {
  test('cached views always match what a fresh engine works out', () async {
    final random = Random(3);
    final clock = TestClock.at(DateTime.utc(2026, 5, 4, 13));
    final parent = await foundFamily(clock);
    final dana = parent.actor!.id;
    final leo = await parent.addMember(name: 'Leo', role: Role.kid, grants: {Grant.events});
    final maya = await parent.addMember(name: 'Maya', role: Role.kid);
    final display = await joinDevice(parent, clock, mode: DeviceMode.shared, name: 'Kitchen', kind: DeviceKind.tablet);
    final leoTablet = await joinDevice(parent, clock, member: leo, name: 'Leo tablet');
    final devices = [parent, display, leoTablet];
    final soccer = await parent.addEvent(
      title: 'Soccer',
      start: DateTime.utc(2026, 5, 5, 21).millisecondsSinceEpoch,
      end: DateTime.utc(2026, 5, 5, 22, 30).millisecondsSinceEpoch,
      rrule: 'FREQ=WEEKLY;BYDAY=TU,TH',
      assignees: [leo],
      rides: const [Ride('to', null), Ride('from', null)],
      reminders: const [30],
    );
    final chore = await parent.addChore(
      title: 'Feed the cat',
      owner: OwnerRotation([leo, maya], 'day', '2026-05-01'),
      schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-05-01'),
      dueTime: '18:00',
      reminders: const [15],
      steps: const [ChoreStep(id: 'food', text: 'Food'), ChoreStep(id: 'water', text: 'Water')],
    );
    final list = await parent.addList(title: 'Groceries', kind: ListKind.shopping, pinned: true);
    for (final d in devices) {
      await sync(parent, d);
    }

    for (var step = 0; step < 120; step++) {
      clock.advance(Duration(minutes: random.nextInt(240)));
      final from = DateTime.utc(2026, 5, 3).millisecondsSinceEpoch;
      try {
        switch (random.nextInt(12)) {
          case 0:
            final start = clock.now + random.nextInt(10) * 86400000;
            await parent.addEvent(
              title: 'Event $step',
              start: start,
              end: start + 3600000 * (1 + random.nextInt(2)),
              assignees: [if (random.nextBool()) leo, if (random.nextBool()) maya],
              audience: random.nextInt(3) == 0 ? Audience.parents : Audience.everyone,
            );
          case 1:
            final o = parent.occurrences(clock.now, clock.now + 14 * 86400000).where((o) => o.event.id == soccer).firstOrNull;
            if (o != null) {
              await parent.updateEvent(soccer, {'title': 'Soccer $step'}, scope: EditScope.one, occurrence: o.seriesStart);
            }
          case 2:
            final o = parent.occurrences(clock.now, clock.now + 14 * 86400000).where((o) => o.event.id == soccer).firstOrNull;
            if (o != null) await parent.claimRide(soccer, occurrence: o.seriesStart, leg: 'from', driver: random.nextBool() ? dana : null);
          case 3:
            await parent.setStep(chore, parent.todayDate(), random.nextBool() ? 'food' : 'water', random.nextBool());
          case 4:
            await parent.swapForDay(chore, parent.todayDate(), random.nextBool() ? leo : maya);
          case 5:
            await parent.addItem(list, text: 'Item $step');
          case 6:
            final items = parent.list(list)!.items;
            if (items.isNotEmpty) await parent.setItemChecked(items[random.nextInt(items.length)].id, random.nextBool());
          case 7:
            // Who is acting on the shared display.
            display.actAs(random.nextBool() ? leo : (random.nextBool() ? dana : null));
          case 8:
            await parent.updateFamily({'oversight.$leo': {'parentsSeePrivate': random.nextBool()}});
          case 9:
            await leoTablet.addEvent(title: 'Leo private $step', start: clock.now + 86400000, end: clock.now + 90000000, audience: Audience.justMe);
          case 10:
            await parent.updateFamily({'timezone': random.nextBool() ? 'America/New_York' : 'Europe/Berlin'});
          default:
            await parent.updateMember(maya, {'name': 'Maya $step', 'order': random.nextInt(5)});
        }
      } on PermissionDenied {
        // Fine: not everyone may do everything.
      } on InvalidInput {
        // Fine.
      }
      final x = random.nextInt(devices.length), y = random.nextInt(devices.length);
      if (x != y && random.nextBool()) await exchange(devices[x], devices[y]);
      for (final d in devices) {
        final fresh = await d.fork();
        expect(views(d, from), views(fresh, from), reason: 'step $step on ${d.thisDevice?.name}');
        await fresh.close();
      }
    }
  });
}
