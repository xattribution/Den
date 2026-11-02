import 'dart:async';

import 'package:den_core/den_core.dart';

import 'annotated.dart';
import 'support.dart';

const hour = 3600000;
const day = '2026-04-06';

void main() {
  late TestClock clock;
  late Den den;
  late String leo;

  setUp(() async {
    clock = TestClock.at(DateTime.utc(2026, 4, 6, 14));
    den = await foundFamily(clock);
    leo = await den.addMember(name: 'Leo', role: Role.kid);
  });

  Future<String> feedTheCat({List<ChoreStep> steps = const [], int points = 2}) => den.addChore(
        title: 'Feed the cat',
        owner: OwnerMember(leo),
        schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-04-01'),
        points: points,
        steps: steps,
      );

  group('recording', () {
    test('names the changes its body made, not writes made meanwhile', () async {
      final list = await den.addList(title: 'Groceries');
      final gate = Completer<void>();
      final recorded = den.recording(() async {
        await den.addItem(list, text: 'Milk');
        await gate.future;
        return den.addItem(list, text: 'Bread');
      });
      await den.addItem(list, text: 'Eggs');
      gate.complete();
      final r = await recorded;
      expect(den.historyOf(r.changes).map((h) => h.title), ['Milk', 'Bread']);
      expect(den.historyOf(r.changes).map((h) => h.change), r.changes);
      expect(den.list(list)!.items.map((i) => i.id), contains(r.value));
    });

    test('nests, and the outer recording sees what the inner one made', () async {
      final outer = await den.recording(() async {
        await den.addList(title: 'A');
        return den.recording(() => den.addList(title: 'B'));
      });
      expect(outer.value.changes, hasLength(1));
      expect(outer.changes, hasLength(2));
      expect(outer.changes.last, outer.value.changes.single);
    });

    test('with undoOnError, a body that fails half way leaves nothing behind', () async {
      final list = await den.addList(title: 'Groceries');
      await expectLater(
        den.recording(() async {
          await den.addItem(list, text: 'Milk');
          await den.addItem('nosuchlist', text: 'Eggs');
        }, undoOnError: true),
        throwsA(isA<InvalidInput>()),
      );
      expect(den.list(list)!.items, isEmpty);
    });
  });

  group('undo', () {
    test('removes what was made, which can then be restored', () async {
      final start = DateTime.utc(2026, 4, 7, 21).millisecondsSinceEpoch;
      final r = await den.recording(() => den.addEvent(title: 'Dentist', start: start, end: start + hour));
      expect(den.canUndo(r.changes), isTrue);
      final undone = await den.undo(r.changes);
      expect(undone.changes, hasLength(1));
      expect(undone.skipped, isEmpty);
      expect(den.event(r.value), isNull);
      await den.restore(RecordType.event, r.value);
      expect(den.event(r.value)!.title, 'Dentist');
    });

    test('puts old values back field by field, leaving what someone changed since', () async {
      final start = DateTime.utc(2026, 4, 7, 21).millisecondsSinceEpoch;
      final id = await den.addEvent(title: 'Dentist', start: start, end: start + hour, location: 'Main St');
      final r = await den.recording(() => den.updateEvent(id, {'title': 'Orthodontist', 'location': 'Elm St'}));
      final priya = await den.addMember(name: 'Priya', role: Role.parent);
      final phone = await joinDevice(den, clock, member: priya);
      clock.advance(const Duration(minutes: 1));
      await phone.updateEvent(id, {'location': 'Oak St'});
      await sync(phone, den);
      final undone = await den.undo(r.changes);
      expect(den.event(id)!.title, 'Dentist');
      expect(den.event(id)!.location, 'Oak St');
      expect(undone.skipped.single.field, 'location');
      expect(undone.skipped.single.reason, contains('Priya'));
    });

    test('brings back a removed list with its items', () async {
      final list = await den.addList(title: 'Packing');
      await den.addItem(list, text: 'Socks');
      final r = await den.recording(() => den.deleteList(list));
      expect(den.list(list), isNull);
      await den.undo(r.changes);
      expect(den.list(list)!.items.single.text, 'Socks');
      expect(den.history().first.verb, 'restored');
    });

    test('a kid takes back completing their own chore without removing the record', () async {
      final chore = await feedTheCat();
      final tablet = await joinDevice(den, clock, member: leo);
      final r = await tablet.recording(() => tablet.setChoreDone(chore, day, true));
      expect(tablet.points().totals[leo], 2);
      final undone = await tablet.undo(r.changes);
      expect(undone.changes, hasLength(1));
      expect(tablet.choresOn(day).single.done, isFalse);
      expect(tablet.points().totals[leo] ?? 0, 0);
      expect(tablet.history().first.verb, 'reopened');
    });

    test('a parent taking back a completion removes it', () async {
      final chore = await feedTheCat();
      final r = await den.recording(() => den.setChoreDone(chore, day, true));
      await den.undo(r.changes);
      expect(den.choresOn(day).single.done, isFalse);
      expect(den.history().first.verb, 'removed');
    });

    test('the step that finished a chore is unchecked and the chore reopens', () async {
      final chore = await feedTheCat(steps: const [ChoreStep(id: 'a', text: 'Food'), ChoreStep(id: 'b', text: 'Water')]);
      await den.setStep(chore, day, 'a', true);
      final r = await den.recording(() => den.setStep(chore, day, 'b', true));
      expect(den.choresOn(day).single.done, isTrue);
      await den.undo(r.changes);
      final after = den.choresOn(day).single;
      expect(after.done, isFalse);
      expect(after.stepsDone, 1);
      expect(after.steps['a'], isNotNull);
    });

    test('points given are taken back with an adjustment the other way', () async {
      final r = await den.recording(() => den.adjustPoints(leo, 5, 'Helped'));
      expect(den.points().totals[leo], 5);
      await den.undo(r.changes);
      expect(den.points().totals[leo] ?? 0, 0);
      expect(den.history().first.verb, 'took');
      expect(den.history().first.title, 'Undo: Helped');
    });

    test('one removed occurrence, and this and following, come back with their changes', () async {
      final start = DateTime.utc(2026, 4, 7, 21).millisecondsSinceEpoch;
      final id = await den.addEvent(title: 'Soccer', start: start, end: start + hour, rrule: 'FREQ=WEEKLY', assignees: [leo]);
      List<String> shown() => [for (final o in den.occurrences(start, start + 60 * 24 * hour)) '${o.title} ${o.start}'];
      final occ = den.occurrences(start, start + 60 * 24 * hour);
      await den.updateEvent(id, {'title': 'Soccer (away)'}, scope: EditScope.one, occurrence: occ[3].seriesStart);
      final before = shown();

      final one = await den.recording(() => den.deleteEvent(id, scope: EditScope.one, occurrence: occ[1].seriesStart));
      expect(shown(), hasLength(before.length - 1));
      await den.undo(one.changes);
      expect(shown(), before);

      final following = await den.recording(
        () => den.deleteEvent(id, scope: EditScope.following, occurrence: occ[2].seriesStart),
      );
      expect(shown(), hasLength(2));
      await den.undo(following.changes);
      expect(shown(), before);
      expect(shown(), contains('Soccer (away) ${occ[3].start}'));
    });

    test('a ride claimed for one occurrence is released again', () async {
      final start = DateTime.utc(2026, 4, 7, 21).millisecondsSinceEpoch;
      final id = await den.addEvent(
        title: 'Soccer',
        start: start,
        end: start + hour,
        rrule: 'FREQ=WEEKLY',
        rides: const [Ride('from', null)],
      );
      final occ = den.occurrences(start, start + 30 * 24 * hour);
      final me = den.actor!.id;
      final r = await den.recording(() => den.claimRide(id, occurrence: occ[1].seriesStart, leg: 'from', driver: me));
      expect(den.occurrences(occ[1].start, occ[1].end).single.rides.single.driver, me);
      await den.undo(r.changes);
      expect(den.occurrences(occ[1].start, occ[1].end).single.rides.single.driver, isNull);
    });

    test('a list moved to parents-only goes back to everyone with its items', () async {
      final list = await den.addList(title: 'Gifts');
      await den.addItem(list, text: 'Lego');
      final r = await den.recording(() => den.updateList(list, {'audience': 'parents'}));
      expect(den.list(list)!.list.space, Space.parents);
      await den.undo(r.changes);
      expect(den.list(list)!.list.space, Space.family);
      expect(den.list(list)!.items.single.text, 'Lego');
    });

    test('adding someone is left alone, with a reason', () async {
      final r = await den.recording(() => den.addMember(name: 'Zoe', role: Role.kid));
      expect(den.canUndo(r.changes), isFalse);
      final undone = await den.undo(r.changes);
      expect(undone.isEmpty, isTrue);
      expect(undone.skipped.single.reason, contains('adding someone'));
      expect(den.members.any((m) => m.name == 'Zoe'), isTrue);
    });

    test('a change Den never saw is refused', () async {
      await expectLater(den.undo(['nosuchdevice:1']), throwsA(isA<InvalidInput>()));
    });
  });

  group('fork', () {
    test('tries changes without touching the engine it came from', () async {
      final list = await den.addList(title: 'Groceries');
      final fork = await den.fork();
      final r = await fork.recording(() => fork.addItem(list, text: 'Milk'));
      expect(fork.list(list)!.items.single.text, 'Milk');
      expect(fork.historyOf(r.changes).single.verb, 'added');
      expect(den.list(list)!.items, isEmpty);
      await fork.close();
      final eggs = await den.addItem(list, text: 'Eggs');
      expect(den.list(list)!.items.single.id, eggs);
    });

    test('acts as whoever is acting on the engine it came from', () async {
      final hub = await joinDevice(den, clock, mode: DeviceMode.hub, kind: DeviceKind.hub, name: 'Hub');
      hub.actAs(leo, via: 'Assistant');
      final fork = await hub.fork();
      expect(fork.actor?.id, leo);
      expect(fork.actingVia, 'Assistant');
      await fork.close();
      await hub.close();
    });
  });
}
