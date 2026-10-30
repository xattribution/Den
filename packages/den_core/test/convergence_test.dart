import 'dart:convert';
import 'dart:math';

import 'package:den_core/den_core.dart';
import 'package:den_core/src/materializer.dart';
import 'package:den_core/src/validity.dart';
import 'package:test/test.dart';

import 'group_support.dart';
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
      expect({for (final r in occ.rides) r.leg: r.driver}, {'to': dana, 'from': priya}, reason: 'and each ride leg on its own');
      for (final d in [b, h]) {
        final other = d.occurrences(occurrence, occurrence + 1).single;
        expect(other.rides.map((r) => r.driver), occ.rides.map((r) => r.driver));
      }
    });
  }

  test('two devices adding different ride legs to an event at once both count', () async {
    final clock = TestClock.at(DateTime.utc(2026, 5, 4, 15));
    final a = await foundFamily(clock);
    final dana = a.actor!.id;
    final priya = await a.addMember(name: 'Priya', role: Role.parent);
    final b = await joinDevice(a, clock, member: priya, name: 'Priya phone', kind: DeviceKind.phone);
    final start = DateTime.utc(2026, 5, 5, 21).millisecondsSinceEpoch;
    final party = await a.addEvent(title: 'Party', start: start, end: start + 3600000, rides: const [Ride('to', null)]);
    await sync(a, b);
    clock.advance(const Duration(seconds: 30));
    // Dana takes the drive there; Priya, not having heard, adds a pickup she'll do.
    await a.claimRide(party, occurrence: start, leg: 'to', driver: dana);
    await b.updateEvent(party, {'rides': [const Ride('to', null), Ride('from', priya)]});
    await exchange(a, b);
    for (final d in [a, b]) {
      expect({for (final r in d.event(party)!.rides) r.leg: r.driver}, {'to': dana, 'from': priya});
    }
  });

  group('two devices taking different ride legs at once both count', () {
    for (final repeating in [false, true]) {
      for (final fromLast in [false, true]) {
        for (final fromArrivesFirst in [false, true]) {
          final what = repeating ? 'one occurrence of a series' : 'an event';
          test('$what, ${fromLast ? 'from' : 'to'} written last, ${fromArrivesFirst ? 'from' : 'to'} arriving first', () async {
            final clockA = TestClock.at(DateTime.utc(2026, 5, 4, 15));
            final a = await foundFamily(clockA);
            final dana = a.actor!.id;
            final priya = await a.addMember(name: 'Priya', role: Role.parent);
            final clockB = TestClock(clockA.now);
            final b = await joinDevice(a, clockB, member: priya, name: 'Priya phone', kind: DeviceKind.phone);
            final h = await joinDevice(a, TestClock(clockA.now), mode: DeviceMode.hub, name: 'Hub', kind: DeviceKind.hub);
            final start = DateTime.utc(2026, 5, 5, 21).millisecondsSinceEpoch;
            final soccer = await a.addEvent(
              title: 'Soccer',
              start: start,
              end: start + 3600000,
              rrule: repeating ? 'FREQ=WEEKLY' : null,
              rides: const [Ride('to', null), Ride('from', null)],
            );
            await sync(a, b);
            await sync(a, h);

            // Neither has heard of the other's: Dana drives there, Priya picks up.
            (fromLast ? clockB : clockA).advance(const Duration(seconds: 30));
            final to = await a.recording(() => a.claimRide(soccer, occurrence: start, leg: 'to', driver: dana));
            final from = await b.recording(() => b.claimRide(soccer, occurrence: start, leg: 'from', driver: priya));
            List<Change> made(Den d, List<String> ids) => [for (final c in d.changesSince({})) if (ids.contains(c.id)) c];
            final toChanges = made(a, to.changes), fromChanges = made(b, from.changes);
            for (final batch in fromArrivesFirst ? [fromChanges, toChanges] : [toChanges, fromChanges]) {
              await h.ingest(batch);
            }
            await exchange(a, b);

            Map<String, String?> legs(Den d) => {for (final r in d.occurrences(start, start + 1).single.rides) r.leg: r.driver};
            for (final d in [a, b, h]) {
              expect(legs(d), {'to': dana, 'from': priya}, reason: d.thisDevice?.name);
            }
            expect(jsonEncode(b.exportJson()), jsonEncode(a.exportJson()));
            expect(jsonEncode(h.exportJson()), jsonEncode(a.exportJson()));
          });
        }
      }
    }
  });

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

  for (final seed in [41, 42, 43]) {
    test('two families\' devices editing a group at once converge, every replica in any order (seed $seed)', () async {
      final random = Random(seed);
      final clock = TestClock.at(DateTime.utc(2026, 6, 1, 15));
      final f = await bothFamilies(clock);
      final start = DateTime.utc(2026, 6, 6, 21).millisecondsSinceEpoch;
      final soccer = await f.alex.addEvent(
        title: 'Soccer',
        start: start,
        end: start + 3600000,
        rrule: 'FREQ=WEEKLY',
        rides: const [Ride('to', null), Ride('from', null)],
      );
      final snacks = await f.dana.addList(title: 'Snacks', kind: ListKind.shopping);
      final oranges = await f.dana.addItem(snacks, text: 'Oranges');
      await settle(f);

      // Nobody hears from anybody while both families edit, the hubs too.
      clock.advance(const Duration(seconds: 30));
      await f.alex.updateEvent(soccer, {'title': 'Soccer practice'});
      await f.dana.updateEvent(soccer, {'location': 'Field 4'});
      await f.dana.claimRide(soccer, occurrence: start, leg: 'to', driver: f.gDana);
      await f.priya.claimRide(soccer, occurrence: start, leg: 'from', driver: f.gPriya);
      await f.dana.updateEvent(soccer, {'title': 'Soccer, early'}, scope: EditScope.one, occurrence: start);
      await f.leo.setItemChecked(oranges, true);
      await f.mia.addItem(snacks, text: 'Juice').then((_) => null, onError: (Object _) => null);
      await f.priya.addItem(snacks, text: 'Water');
      await f.dana.updateMember(f.gMia, {'grants': [Grant.lists]});
      await f.priya.updateMember(f.gLeo, {'grants': [Grant.events]});
      f.kHub.actAs(f.gAlex, via: 'Claude');
      await f.kHub.addEvent(title: 'Team photo', start: start + 86400000, end: start + 90000000);
      f.kHub.actAs(null);
      f.sHub.actAs(f.gDana, via: 'Calendar feed');
      await f.sHub.updateList(snacks, {'title': 'Snacks for Saturday'});
      f.sHub.actAs(null);
      // Another family's parent and a kid overreaching, signed past their engines' checks.
      final overreach = [
        await forgeAs(f.dana, type: RecordType.member, rid: f.gLeo, fields: {'grants': <String>[]}, actor: f.gDana),
        await forgeAs(f.leo, type: RecordType.event, rid: soccer, fields: {'drivers.to': f.gLeo}, actor: f.gLeo),
      ];
      // And the Kotvases turning on the Smiths, now or dated inside the Smiths' window (the
      // review's R1-R6b): the window keys taken back, "That wasn't them", the invitation taken
      // back, devices let in with the invitation's keys, a stale phone's "Cancel invitation".
      Change ownJoin(Den d) =>
          d.changesSince(const {}).firstWhere((c) => c.device == d.deviceId && c.type == RecordType.device && c.rid == d.deviceId);
      final invitedAt = f.kHub.home(f.smithHome)!.rec.created.millis;
      final danaJoin = ownJoin(f.dana);
      final inWindow = danaJoin.hlc.millis + 1 + random.nextInt(200);
      var skip = 0;
      Future<Change> byAlex(String type, String rid, Map<String, Object?> fields, {int? millis}) =>
          forgeAs(f.alex, type: type, rid: rid, fields: fields, actor: f.gAlex, millis: millis, skip: skip++);
      Future<Change> joinWith(GroupAdmission admission, int millis) async {
        final device = await DeviceKeys.generate();
        final proof = await (await admission.key())
            .prove(family: f.group, member: admission.member, mode: admission.mode, devicePubkey: device.pubkey, expires: millis + 600000);
        return forge(device, counter: 1, millis: millis, type: RecordType.device, rid: await device.deviceId(), fields: {
          'name': 'Evil',
          'kind': admission.mode == DeviceMode.hub ? 'hub' : 'phone',
          'pubkey': device.pubkey,
          'member': admission.member,
          'mode': admission.mode.name,
          'approved': true,
          'home': admission.home,
          'invite': proof.toJson(),
        });
      }

      final attacks = [
        for (final millis in [null, inWindow]) ...[
          await byAlex(RecordType.inviteKey, f.invitation.parent.invite, {'key': null, 'kept': <String>[]}, millis: millis),
          await byAlex(RecordType.inviteKey, f.invitation.hub.invite, {'key': null, 'kept': <String>[]}, millis: millis == null ? null : millis + 1),
          await byAlex(RecordType.device, f.dana.deviceId, {'revoked': true, 'revokedAfter': danaJoin.counter},
              millis: millis == null ? null : millis + 2),
        ],
        await byAlex(RecordType.home, f.smithHome, {'status': 'left'}, millis: invitedAt + 500),
        await joinWith(f.invitation.parent, danaJoin.hlc.millis - 100),
        await joinWith(f.invitation.hub, ownJoin(f.sHub).hlc.millis - 100),
        await forgeAs(f.priya, type: RecordType.home, rid: f.smithHome, fields: {'status': 'left'}, actor: f.gPriya),
      ];
      overreach.addAll(attacks);

      final engines = [...f.kotvasDevices, ...f.smithDevices];
      final pool = {
        for (final d in engines)
          for (final c in d.changesSince({})) c.id: c,
        for (final c in overreach) c.id: c,
      }.values.toList();
      // Each hub takes everything, in its own shuffled order; then the devices sync as usual.
      for (final hub in [f.kHub, f.sHub]..shuffle(random)) {
        await deliver(hub, pool, random);
      }
      await settle(f);

      expect(jsonEncode(f.sHub.exportJson()), jsonEncode(f.kHub.exportJson()), reason: 'both families\' replicas agree');
      expect(f.sHub.history().length, f.kHub.history().length);
      // Every device sees the same shared things, whichever family it is of.
      String shared(Den d) {
        final records = (d.exportJson()['records']! as Map).map((type, byId) => MapEntry(type, {
              for (final e in (byId as Map).entries)
                if ((e.value as Map)['space'] == Space.family) e.key: e.value,
            }));
        return jsonEncode(records);
      }

      for (final d in engines) {
        expect(shared(d), shared(f.kHub), reason: d.thisDevice!.name);
      }
      final occ = f.mia.occurrences(start, start + 1).single;
      expect(occ.title, 'Soccer, early');
      expect({for (final r in occ.rides) r.leg: r.driver}, {'to': f.gDana, 'from': f.gPriya}, reason: 'each family\'s claim of a leg counts');
      expect(f.alex.member(f.gLeo)!.grants, {Grant.events}, reason: 'another family\'s parent took nothing away');
      expect(f.alex.list(snacks)!.list.title, 'Snacks for Saturday');
      expect(f.alex.list(snacks)!.items.firstWhere((i) => i.text == 'Oranges').checked, isTrue);
      for (final c in overreach) {
        expect(f.kHub.history().any((h) => h.change == c.id), isFalse);
      }
      // The Smiths are as they were, on every replica of either family.
      for (final d in engines) {
        expect(d.home(f.smithHome)!.status, HomeStatus.active, reason: d.thisDevice!.name);
        expect(d.deviceCounts(f.dana.deviceId), isTrue, reason: d.thisDevice!.name);
        expect(d.deviceCounts(f.sHub.deviceId), isTrue, reason: d.thisDevice!.name);
        expect(d.invitationOpen(f.smithHome), isFalse, reason: d.thisDevice!.name);
      }
      for (final c in attacks.where((c) => c.type == RecordType.device && c.rid == c.device)) {
        expect(f.kHub.deviceCounts(c.rid), isFalse);
      }
    });
  }

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
