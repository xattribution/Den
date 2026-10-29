import 'package:den_core/den_core.dart';
import 'package:den_core/src/time.dart';
import 'package:test/test.dart';

import 'support.dart';

const hour = 3600000;

void main() {
  const zone = 'America/Chicago';
  late TestClock clock;
  late Den den;
  late String dana;
  late String priya;
  late String leo;
  late String zoe;

  int at(String date, String time) => dateTimeIn(zone, date, time);

  setUp(() async {
    clock = TestClock(dateTimeIn(zone, '2026-10-16', '08:00'));
    den = await foundFamily(clock, timezone: zone);
    dana = den.actor!.id;
    priya = await den.addMember(name: 'Priya', role: Role.parent);
    leo = await den.addMember(name: 'Leo', role: Role.kid);
    zoe = await den.addMember(name: 'Zoe', role: Role.kid);
  });

  group('today', () {
    test('events, chores, and the lists that matter today', () async {
      await den.addEvent(title: 'Swim lesson', start: at('2026-10-16', '16:30'), end: at('2026-10-16', '17:15'), assignees: [zoe]);
      await den.addEvent(title: 'Tomorrow', start: at('2026-10-17', '09:00'), end: at('2026-10-17', '10:00'));
      final trip = await den.addEvent(title: 'Field trip', start: at('2026-10-16', '09:00'), end: at('2026-10-16', '15:00'));
      await den.addChore(title: 'Make bed', owner: OwnerMember(zoe), schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-10-01'));
      await den.addList(title: 'Groceries', kind: ListKind.shopping, pinned: true);
      await den.addList(title: 'Science fair', lifecycle: ListLifecycle.dated, needBy: '2026-10-16');
      await den.addList(title: 'Later', lifecycle: ListLifecycle.dated, needBy: '2026-10-19');
      await den.addList(title: 'Field trip bag', lifecycle: ListLifecycle.event, event: trip);
      final today = den.today();
      expect(today.date, '2026-10-16');
      expect(today.events.map((o) => o.title), ['Field trip', 'Swim lesson']);
      expect(today.chores.single.chore.title, 'Make bed');
      expect(today.lists.map((l) => l.list.title), unorderedEquals(['Groceries', 'Science fair', 'Field trip bag']));
      expect(den.today(date: '2026-10-17').events.single.title, 'Tomorrow');
    });
  });

  test('the week puts events in each person\'s column and family events across the row', () async {
    await den.addEvent(title: 'Soccer', start: at('2026-10-13', '17:00'), end: at('2026-10-13', '18:00'), assignees: [leo]);
    await den.addEvent(title: 'Dentist', start: at('2026-10-14', '15:00'), end: at('2026-10-14', '16:00'), assignees: [zoe, priya]);
    await den.addEvent(title: 'Dinner at Grandma\'s', start: at('2026-10-18', '18:00'), end: at('2026-10-18', '20:00'));
    await den.addEvent(
      title: 'Movie night',
      start: at('2026-10-17', '19:00'),
      end: at('2026-10-17', '21:00'),
      assignees: [dana, priya, leo, zoe],
    );
    await den.addChore(title: 'Feed the cat', owner: OwnerMember(leo), schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-10-01'));
    final week = den.week('2026-10-12');
    expect(week.days, ['2026-10-12', '2026-10-13', '2026-10-14', '2026-10-15', '2026-10-16', '2026-10-17', '2026-10-18']);
    expect(week.people.map((m) => m.name), ['Dana', 'Priya', 'Leo', 'Zoe']);
    expect(week.cells[('2026-10-13', leo)]!.events.single.title, 'Soccer');
    expect(week.cells[('2026-10-14', zoe)]!.events.single.title, 'Dentist');
    expect(week.cells[('2026-10-14', priya)]!.events.single.title, 'Dentist');
    expect(week.cells[('2026-10-14', dana)]!.events, isEmpty);
    expect(week.everyone['2026-10-18']!.single.title, 'Dinner at Grandma\'s');
    expect(week.everyone['2026-10-17']!.single.title, 'Movie night', reason: 'everyone assigned');
    expect(week.cells[('2026-10-17', leo)]!.events, isEmpty);
    expect(week.cells[('2026-10-15', leo)]!.chores.single.chore.title, 'Feed the cat');
  });

  group('history', () {
    test('shows who changed what, from and to', () async {
      final id = await den.addEvent(title: 'Soccer', start: at('2026-10-13', '17:00'), end: at('2026-10-13', '18:00'));
      clock.advance(const Duration(minutes: 5));
      await den.updateEvent(id, {'title': 'Soccer practice', 'location': 'Field 4'});
      final entry = den.history().first;
      expect(entry.verb, 'changed');
      expect(entry.actorName, 'Dana');
      expect(entry.deviceName, 'Dana\'s phone');
      expect(entry.title, 'Soccer practice');
      expect(entry.type, RecordType.event);
      expect(entry.rid, id);
      final title = entry.diffs.firstWhere((d) => d.field == 'title');
      expect(title.before, 'Soccer');
      expect(title.after, 'Soccer practice');
      expect(entry.diffs.firstWhere((d) => d.field == 'location').before, '');
      expect(entry.when.millis, clock.now);
      expect(den.history(query: 'field 4').single.rid, id);
      expect(den.history(type: RecordType.member).map((h) => h.title), containsAll(['Dana', 'Priya', 'Leo', 'Zoe']));
      expect(den.history(member: leo), isEmpty);
      expect(den.history(limit: 2), hasLength(2));
    });

    test('uses the verbs people would', () async {
      final chore = await den.addChore(
        title: 'Dishes',
        owner: OwnerMember(leo),
        schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-10-01'),
        steps: const [ChoreStep(id: 'a', text: 'Clear'), ChoreStep(id: 'b', text: 'Wipe')],
      );
      await den.setStep(chore, '2026-10-16', 'a', true);
      await den.setStep(chore, '2026-10-16', 'a', false);
      await den.setChoreDone(chore, '2026-10-16', true);
      await den.setChoreDone(chore, '2026-10-16', false);
      await den.swapForDay(chore, '2026-10-17', zoe);
      final list = await den.addList(title: 'Groceries');
      final milk = await den.addItem(list, text: 'Milk');
      await den.setItemChecked(milk, true);
      await den.setItemChecked(milk, false);
      await den.removeItem(milk);
      await den.adjustPoints(leo, 3, 'Helped');
      await den.adjustPoints(leo, -1, 'Oops');
      final verbs = den.history().map((h) => h.verb).toList().reversed.toList();
      expect(
        verbs.sublist(verbs.length - 13),
        ['added', 'checked', 'unchecked', 'completed', 'reopened', 'swapped', 'added', 'added', 'checked', 'unchecked', 'removed', 'gave', 'took'],
      );
    });

    test('names the device for open check-off and records the hub\'s caller', () async {
      final mail = await den.addChore(title: 'Mail', owner: const OwnerAnyone(), schedule: const ChoreSchedule.once('2026-10-16'));
      final display = await joinDevice(den, clock, mode: DeviceMode.shared, name: 'Kitchen', kind: DeviceKind.display);
      await den.updateDevice(display.deviceId, {
        'display': {'layout': 'today', 'openCheckoff': true},
      });
      await sync(den, display);
      await display.setChoreDone(mail, '2026-10-16', true);
      await sync(display, den);
      final entry = den.history().first;
      expect(entry.actor, isNull);
      expect(entry.actorName, 'Kitchen');
      expect(entry.verb, 'completed');
      final approval = den.history().firstWhere((h) => h.verb == 'approved');
      expect(approval.title, 'Kitchen');
      expect(den.history().firstWhere((h) => h.verb == 'requested').deviceName, 'Kitchen');
    });

    test('hides sign-in secrets and token hashes', () async {
      await den.setSignIn(leo, kind: 'pin', secret: '1234');
      await den.addTokenConnection(label: 'Script', scopes: {Scope.read});
      final signIn = den.history().firstWhere((h) => h.diffs.any((d) => d.field == 'signIn'));
      expect(signIn.diffs.single.after, {'kind': 'pin'});
      final token = den.history().first.diffs.firstWhere((d) => d.field == 'tokenHash');
      expect(token.after, '•••');
    });
  });

  test('search finds events, chores, lists, items, people, and removed things', () async {
    await den.addEvent(title: 'Soccer practice', start: at('2026-10-20', '17:00'), end: at('2026-10-20', '18:00'), location: 'Riverside Park');
    await den.addChore(title: 'Pack soccer bag', owner: OwnerMember(leo), schedule: const ChoreSchedule.once('2026-10-20'));
    final list = await den.addList(title: 'Soccer snacks');
    final item = await den.addItem(list, text: 'Orange slices for soccer');
    final old = await den.addItem(list, text: 'Soccer socks');
    await den.removeItem(old);
    final hits = den.search('soccer', includeHistory: true);
    expect(hits.first.title, 'Soccer practice');
    expect(hits.first.when, at('2026-10-20', '17:00'));
    expect(hits.map((h) => h.type), containsAll([RecordType.event, RecordType.chore, RecordType.list, RecordType.item]));
    expect(hits.firstWhere((h) => h.id == item).detail, 'Soccer snacks');
    expect(hits.firstWhere((h) => h.id == old).detail, 'History');
    expect(den.search('soccer').map((h) => h.id), isNot(contains(old)), reason: 'removed things only when asked');
    expect(den.search('riverside').single.title, 'Soccer practice');
    expect(den.search('zo').single.type, RecordType.member);
    expect(den.search('  '), isEmpty);
  });

  group('gaps', () {
    test('rides with no driver, people in two places, and chores nobody owns', () async {
      final soccer = await den.addEvent(
        title: 'Soccer',
        start: at('2026-10-16', '17:00'),
        end: at('2026-10-16', '18:30'),
        assignees: [leo],
        rides: const [Ride('to', null), Ride('from', null)],
      );
      await den.addEvent(title: 'Piano', start: at('2026-10-16', '18:00'), end: at('2026-10-16', '19:00'), assignees: [leo]);
      await den.addEvent(title: 'Book club', start: at('2026-10-16', '18:00'), end: at('2026-10-16', '19:00'), assignees: [dana]);
      await den.addEvent(title: 'Field trip', start: at('2026-10-16', '09:00'), end: at('2026-10-16', '12:00'), rides: const [Ride('to', null)]);
      await den.addChore(title: 'Water the plants', owner: const OwnerAnyone(), schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-10-01'));
      final gaps = den.gaps(den.dayStart('2026-10-16'), den.dayStart('2026-10-17'));
      expect(gaps.where((g) => g.kind == GapKind.noDriver).map((g) => g.message), [
        'Nobody is driving to Field trip',
        'Nobody is driving Leo to Soccer',
        'Nobody is picking up Leo from Soccer',
      ]);
      final overlap = gaps.singleWhere((g) => g.kind == GapKind.overlap);
      expect(overlap.message, 'Leo has Soccer and Piano at the same time');
      expect(overlap.members, [leo]);
      expect(gaps.singleWhere((g) => g.kind == GapKind.unowned).message, 'Water the plants is up for grabs');
      await den.claimRide(soccer, occurrence: at('2026-10-16', '17:00'), leg: 'from', driver: priya);
      expect(den.today().gaps.where((g) => g.message.contains('picking up')), isEmpty);
      expect(den.gaps(den.dayStart('2026-10-17'), den.dayStart('2026-10-18')), isEmpty,
          reason: 'unowned chores are gaps only today');
    });

    test('only people named on both events are in two places; an event for everyone isn\'t', () async {
      await den.addEvent(title: 'Dinner', start: at('2026-10-16', '18:00'), end: at('2026-10-16', '19:00'));
      await den.addEvent(title: 'Piano', start: at('2026-10-16', '18:30'), end: at('2026-10-16', '19:30'), assignees: [zoe]);
      expect(den.today().gaps, isEmpty);
      await den.addEvent(title: 'Art', start: at('2026-10-16', '19:00'), end: at('2026-10-16', '20:00'), assignees: [zoe, leo]);
      final gap = den.today().gaps.single;
      expect(gap.message, 'Zoe has Piano and Art at the same time');
      expect(gap.members, [zoe]);
    });

    test('a ride gap names the leg nobody is driving', () async {
      final soccer = await den.addEvent(
        title: 'Soccer',
        start: at('2026-10-16', '17:00'),
        end: at('2026-10-16', '18:30'),
        rrule: 'FREQ=WEEKLY',
        assignees: [leo],
        rides: const [Ride('to', null), Ride('from', null)],
      );
      await den.claimRide(soccer, occurrence: at('2026-10-16', '17:00'), leg: 'to', driver: priya);
      final gap = den.today().gaps.single;
      expect(gap.leg, 'from');
      expect(gap.message, 'Nobody is picking up Leo from Soccer');
      expect(den.event(soccer)!.rides.first.driver, isNull, reason: 'the series still has nobody driving');
    });
  });

  group('reminders', () {
    test('events remind before each occurrence; chores before their due time', () async {
      final soccer = await den.addEvent(
        title: 'Soccer',
        start: at('2026-10-13', '17:00'),
        end: at('2026-10-13', '18:30'),
        rrule: 'FREQ=WEEKLY;BYDAY=TU,TH',
        assignees: [leo],
        location: 'Field 4',
        reminders: [60, 15],
      );
      await den.addEvent(title: 'Quiet', start: at('2026-10-15', '12:00'), end: at('2026-10-15', '13:00'));
      final trash = await den.addChore(
        title: 'Take out the trash',
        owner: OwnerMember(leo),
        schedule: const ChoreSchedule.repeating('FREQ=WEEKLY;BYDAY=TH', '2026-10-01'),
        dueTime: '19:00',
        reminders: [30],
      );
      final due = den.remindersDue(at('2026-10-15', '00:00'), at('2026-10-16', '00:00'));
      expect(due.map((r) => r.key), [
        'event:$soccer:${at('2026-10-15', '17:00')}:60',
        'event:$soccer:${at('2026-10-15', '17:00')}:15',
        'chore:$trash:2026-10-15:30',
      ]);
      expect(due.first.at, at('2026-10-15', '16:00'));
      expect(due.first.body, 'Starts at 5:00 PM at Field 4');
      expect(due.first.members, [leo]);
      expect(due.last.at, at('2026-10-15', '18:30'));
      expect(due.last.body, 'Due at 7:00 PM');
      expect(den.remindersDue(at('2026-10-15', '00:00'), at('2026-10-16', '00:00'), memberId: zoe), isEmpty);
      final edge = den.remindersDue(at('2026-10-15', '16:00'), at('2026-10-15', '16:00') + 1);
      expect(edge.single.key, endsWith(':60'));
      await den.setChoreDone(trash, '2026-10-15', true);
      expect(den.remindersDue(at('2026-10-15', '18:00'), at('2026-10-15', '19:00')), isEmpty);
    });
  });
}
