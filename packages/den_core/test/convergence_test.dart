import 'dart:convert';
import 'dart:math';

import 'package:den_core/den_core.dart';
import 'package:den_core/src/materializer.dart';
import 'package:den_core/src/validity.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Delivers every change [to] lacks from [pool] in a shuffled order, in random chunks, with some
/// duplicates thrown in.
Future<void> deliver(Den to, List<Change> pool, Random random) async {
  final lacking = pool.where((c) => !to.changesSince({}).any((h) => h.id == c.id)).toList()..shuffle(random);
  final withDuplicates = [...lacking, ...lacking.take(lacking.length ~/ 3)]..shuffle(random);
  var i = 0;
  while (i < withDuplicates.length) {
    final n = 1 + random.nextInt(4);
    await to.ingest(withDuplicates.sublist(i, min(i + n, withDuplicates.length)));
    i += n;
  }
}

void main() {
  for (final seed in [1, 2, 3, 4, 5]) {
    test('three devices editing concurrently converge (seed $seed)', () async {
      final random = Random(seed);
      final clockA = TestClock.at(DateTime.utc(2026, 5, 4, 15));
      final a = await foundFamily(clockA);
      final dana = a.actor!.id;
      final priya = await a.addMember(name: 'Priya', role: Role.parent);
      final leo = await a.addMember(name: 'Leo', role: Role.kid);
      final clockB = TestClock(clockA.now);
      final b = await joinDevice(a, clockB, member: priya, name: 'Priya phone', kind: DeviceKind.phone);
      final clockH = TestClock(clockA.now);
      final h = await joinDevice(a, clockH, mode: DeviceMode.hub, name: 'Hub', kind: DeviceKind.hub);

      final soccer = await a.addEvent(
        title: 'Soccer',
        start: DateTime.utc(2026, 5, 5, 21).millisecondsSinceEpoch,
        end: DateTime.utc(2026, 5, 5, 22).millisecondsSinceEpoch,
        rrule: 'FREQ=WEEKLY;BYDAY=TU',
        assignees: [leo],
        rides: const [Ride('to', null), Ride('from', null)],
      );
      final chore = await a.addChore(
        title: 'Clean the kitchen',
        owner: OwnerMember(leo),
        schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-05-01'),
        points: 3,
        steps: const [ChoreStep(id: 's1', text: 'Sweep', points: 1), ChoreStep(id: 's2', text: 'Wipe', points: 1)],
      );
      final groceries = await a.addList(title: 'Groceries', kind: ListKind.shopping, pinned: true);
      final milk = await a.addItem(groceries, text: 'Milk');
      final eggs = await a.addItem(groceries, text: 'Eggs');
      final secret = await a.addEvent(title: 'Surprise', start: 0, end: 1, audience: Audience.parents);
      for (final d in [b, h]) {
        await sync(a, d);
      }
      final occurrence = a.occurrences(clockA.now, clockA.now + 14 * 86400000).first.seriesStart;

      // Concurrent edits, with skewed clocks so arrival order and HLC order disagree.
      clockB.advance(Duration(seconds: 30 + random.nextInt(60)));
      clockH.advance(Duration(seconds: random.nextInt(60)));
      clockA.advance(Duration(seconds: random.nextInt(60)));

      await a.updateEvent(soccer, {'title': 'Soccer practice'});
      await b.updateEvent(soccer, {'title': 'Soccer (field 4)', 'location': 'Field 4'});
      await b.updateEvent(soccer, {'title': 'Soccer, early'}, scope: EditScope.one, occurrence: occurrence);
      await a.claimRide(soccer, occurrence: occurrence, leg: 'to', driver: dana);
      await b.claimRide(soccer, occurrence: occurrence, leg: 'from', driver: priya);
      await a.setItemChecked(milk, true);
      await b.removeItem(milk);
      await b.updateItem(eggs, {'qty': '2 dozen'});
      await a.addItem(groceries, text: 'Bread');
      await b.addItem(groceries, text: 'Butter');
      await a.setStep(chore, '2026-05-04', 's1', true);
      await b.setStep(chore, '2026-05-04', 's2', true);
      h.actAs(leo);
      await h.setChoreDone(chore, '2026-05-03', true);
      h.actAs(null, via: 'Calendar feed');
      await h.addEvent(title: 'Library hours', start: clockH.now, end: clockH.now + 3600000);
      await h.updateEvent(secret, {'title': 'Surprise party'});
      await a.adjustPoints(leo, 5, 'Helped carry groceries');
      await b.adjustPoints(leo, -1, 'Left the door open');
      await a.swapForDay(chore, '2026-05-05', dana);
      await b.swapForDay(chore, '2026-05-05', priya);
      await b.updateFamily({'weekStart': 1});
      await a.updateFamily({'name': 'The Riveras'});

      final pool = {
        for (final d in [a, b, h])
          for (final c in d.changesSince({})) c.id: c,
      }.values.toList();
      for (final d in [a, b, h]..shuffle(random)) {
        await deliver(d, pool, random);
      }
      h.actAs(null);

      final exports = [for (final d in [a, b, h]) jsonEncode(d.exportJson())];
      expect(exports[1], exports[0]);
      expect(exports[2], exports[0]);
      expect(b.history().length, a.history().length);
      expect(h.history().length, a.history().length);
      expect(a.versionVector, b.versionVector);

      final steps = a.choresOn('2026-05-04').single;
      expect(steps.done, isTrue, reason: 'both steps were checked on different devices');
      expect(a.points().totals, b.points().totals);
      // May 4: the chore to Leo, each unowned step to whoever checked it. May 3: all of it to
      // Leo, who did it on the hub. Then the two adjustments.
      expect(a.points().totals[leo], 3 + (3 + 1 + 1) + 5 - 1);
      expect(a.points().totals[dana], 1);
      expect(a.points().totals[priya], 1);
      expect(a.list(groceries)!.items.map((i) => i.text), containsAll(['Eggs', 'Bread', 'Butter']));
      final occ = a.occurrences(occurrence, occurrence + 1).single;
      expect(occ.title, 'Soccer, early', reason: 'one occurrence\'s title and rides merge per field');
      expect(occ.rides.map((r) => r.driver).where((d) => d != null), isNotEmpty);
      for (final d in [b, h]) {
        final other = d.occurrences(occurrence, occurrence + 1).single;
        expect(other.rides.map((r) => r.driver), occ.rides.map((r) => r.driver));
      }
    });
  }

  test('a late change older than everything applied triggers a replay with the same result', () async {
    final clock = TestClock.at(DateTime.utc(2026, 5, 4, 15));
    final a = await foundFamily(clock);
    final dana = a.actor!.id;
    final slowClock = TestClock(clock.now);
    final b = await joinDevice(a, slowClock, member: dana, name: 'Old laptop', kind: DeviceKind.desktop);
    final list = await a.addList(title: 'Groceries');
    await sync(a, b);
    slowClock.advance(const Duration(seconds: 1));
    await b.updateList(list, {'title': 'Groceries (old)'});
    clock.advance(const Duration(minutes: 10));
    await a.updateList(list, {'title': 'Groceries for the week'});
    await sync(b, a);
    await sync(a, b);
    expect(a.list(list)!.list.title, 'Groceries for the week');
    expect(b.list(list)!.list.title, 'Groceries for the week');
    final fresh = await openDen(clock);
    await fresh.requestJoin(
      familyId: a.familyId!,
      founderPubkey: a.founderPubkey!,
      deviceName: 'Replay',
      kind: DeviceKind.desktop,
    );
    await fresh.ingest(a.changesSince({}).reversed);
    expect(jsonEncode(fresh.family!.rec.fields), jsonEncode(a.family!.rec.fields));
  });

  test('changes newer than everything apply directly; older ones replay the log', () {
    final mat = Materializer(TrustRoot.new);
    Change at(int millis, String device) => Change(
          id: '$device:$millis',
          space: Space.family,
          hlc: Hlc(millis, 0, device),
          type: RecordType.category,
          rid: 'c$millis',
          fields: const {'name': 'x'},
          device: device,
          actor: null,
          sig: '',
        );
    mat.add([at(1, 'a'), at(2, 'a')]);
    mat.add([at(3, 'b')]);
    expect(mat.replays, 0);
    mat.add([at(2, 'c')]);
    expect(mat.replays, 1);
    expect(mat.log.map((c) => c.id), ['a:1', 'a:2', 'c:2', 'b:3']);
    expect(mat.rejected, hasLength(4), reason: 'none of them belong to a family');
    mat.add([at(2, 'c')]);
    expect(mat.replays, 1, reason: 'a duplicate changes nothing');
  });

  test('a device that receives only some spaces still advances its version vector', () async {
    final clock = TestClock.at(DateTime.utc(2026, 5, 4, 15));
    final parent = await foundFamily(clock);
    final leo = await parent.addMember(name: 'Leo', role: Role.kid);
    final tablet = await joinDevice(parent, clock, member: leo);
    await parent.addEvent(title: 'Private', start: 0, end: 1, audience: Audience.parents);
    await parent.addEvent(title: 'Public', start: 0, end: 1);
    await sync(parent, tablet);
    expect(tablet.versionVector[parent.deviceId], parent.versionVector[parent.deviceId]);
    expect(tablet.changesSince({}).any((c) => c.space == Space.parents), isFalse);
    final again = parent.changesSince(tablet.versionVector, spaces: parent.spacesForDevice(tablet.deviceId));
    expect(again, isEmpty);
  });

  test('changes from a device whose record hasn\'t arrived wait, then apply', () async {
    final clock = TestClock.at(DateTime.utc(2026, 5, 4, 15));
    final a = await foundFamily(clock);
    final dana = a.actor!.id;
    final b = await joinDevice(a, clock, member: dana, name: 'Second');
    await b.addCategory(name: 'Sports');
    final c = await openDen(clock);
    await c.requestJoin(familyId: a.familyId!, founderPubkey: a.founderPubkey!, deviceName: 'Third', kind: DeviceKind.phone);
    final fromB = b.changesSince({});
    final bOwn = fromB.where((x) => x.device == b.deviceId).toList();
    final rest = fromB.where((x) => x.device != b.deviceId).toList();
    final first = await c.ingest(bOwn.where((x) => x.type != RecordType.device));
    expect(first.pending, greaterThan(0));
    expect(first.added, 0);
    final second = await c.ingest([...rest, ...bOwn.where((x) => x.type == RecordType.device)]);
    expect(second.pending, 0);
    expect(c.categories.map((x) => x.name), ['Sports']);
  });
}
