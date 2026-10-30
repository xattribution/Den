import 'dart:convert';
import 'dart:math';

import 'package:den_core/den_core.dart';
import 'package:den_core/src/groups.dart' show GroupStarts, deviceOutOfGroup;
import 'package:den_core/src/materializer.dart';
import 'package:den_core/src/snapshot.dart';
import 'package:den_core/src/validity.dart';
import 'package:test/test.dart';

import 'group_support.dart';
import 'support.dart';

/// Attacks by the inviting family (the Kotvases, "A") on the family it invited (the Smiths, "B"),
/// from the two independent reviews of feat/groups-core (R1-R11, then V1-V7), each now refused:
/// once B's own first parent's phone says B is in, A's window over B is shut (groups.dart,
/// WindowClosure), and nothing A does after, or dates before without that phone having held it,
/// counts. A can still end B's place (a second "we're in" with the invitation's key, or "That
/// wasn't them" within a day), loudly, but never act as B (GroupStarts). Signed past the
/// engines' own checks, the way a misbehaving device would, and judged by a replica.
void main() {
  const minute = 60000;
  const hour = 60 * minute;
  const day = 24 * hour;

  Change ownJoin(Den d) =>
      d.changesSince(const {}).firstWhere((c) => c.device == d.deviceId && c.type == RecordType.device && c.rid == d.deviceId);

  /// The change that said B is in (and closed A's window).
  Change activation(Den d, String home) =>
      d.changesSince(const {}).firstWhere((c) => c.type == RecordType.home && c.rid == home && c.fields.containsKey('heard'));

  int maxCounter(Den d) => d.changesSince(const {}).where((c) => c.device == d.deviceId).map((c) => c.counter).reduce(max);

  /// A fresh device joining with [admission]'s key, clocked at [millis] (forged: no engine checks).
  Future<(DeviceKeys, Change)> joinWith(Families f, GroupAdmission admission, int millis, {DeviceMode? mode, String? member}) async {
    final keys = await DeviceKeys.generate();
    final key = await admission.key();
    final m = mode ?? admission.mode;
    final who = mode == null ? admission.member : member;
    final proof = await key.prove(family: f.group, member: who, mode: m, devicePubkey: keys.pubkey, expires: admission.expires);
    final c = await forge(keys, counter: 1, millis: millis, type: RecordType.device, rid: await keys.deviceId(), fields: {
      'name': 'Evil',
      'kind': m == DeviceMode.hub ? 'hub' : 'phone',
      'pubkey': keys.pubkey,
      'xpub': keys.xpub,
      'member': who,
      'mode': m.name,
      'approved': true,
      'home': admission.home,
      'invite': proof.toJson(),
    });
    return (keys, c);
  }

  /// A "we're in" for [home], by [keys] (a device let in with the invitation's key), clocked at
  /// [millis], naming [heard].
  Future<Change> sayIn(DeviceKeys keys, String home, String member, int millis, {int counter = 2, List<String> heard = const []}) =>
      forge(keys, counter: counter, millis: millis, type: RecordType.home, rid: home, actor: member, fields: {
        'status': 'active',
        'heard': heard,
      });

  void smithsIntact(Families f, Den replica) {
    expect(replica.deviceCounts(f.dana.deviceId), isTrue, reason: 'Dana\'s phone');
    expect(replica.deviceCounts(f.sHub.deviceId), isTrue, reason: 'the Smith hub');
    expect(replica.deviceCounts(f.mia.deviceId), isTrue, reason: 'Mia\'s tablet');
    expect(replica.home(f.smithHome)!.status, HomeStatus.active);
    expect(replica.members.where((m) => m.id == f.gMia), isNotEmpty);
    expect(replica.invitationOpen(f.smithHome), isFalse);
    expect(replica.closureFor(f.smithHome)!.author, f.dana.deviceId);
  }

  /// The Smiths' place ended: nobody of them counts, nobody acts as them, the window stays shut.
  void smithsEnded(Families f, Den replica, {String why = 'contested'}) {
    final h = replica.home(f.smithHome)!;
    expect(h.left, isTrue);
    expect(h.ended, why);
    expect(replica.homeEnd(f.smithHome), isNotNull);
    expect(replica.closureFor(f.smithHome), isNull);
    expect(replica.invitationOpen(f.smithHome), isFalse, reason: 'an ended home never opens its window again');
    for (final d in [f.dana, f.sHub, f.mia]) {
      expect(replica.deviceCounts(d.deviceId), isFalse, reason: d.thisDevice?.name);
    }
  }

  group('A, a month after B is in', () {
    final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
    late Families f;
    late int joinedAt;
    setUpAll(() async {
      f = await bothFamilies(clock);
      joinedAt = ownJoin(f.dana).hlc.millis;
      expect(activation(f.dana, f.smithHome).hlc.millis, greaterThan(joinedAt + 100), reason: 'the window lasts a moment');
      clock.advance(const Duration(days: 30));
    });

    /// [c] on a fork of the Kotvas hub; its reason, or null when it counted.
    Future<(Den, String?)> judge(Change c) async {
      final fork = await f.kHub.fork();
      final r = await fork.ingest([c]);
      return (fork, r.invalid[c.id]);
    }

    test('R1: taking the invitation\'s key back, now or dated inside the window, erases nothing', () async {
      for (final millis in [null, joinedAt + 1]) {
        final fork = await f.kHub.fork();
        final w = await forgeAs(f.alex, type: RecordType.inviteKey, rid: f.invitation.parent.invite, actor: f.gAlex, millis: millis,
            fields: {'key': null, 'kept': <String>[]});
        final r = await fork.ingest([w]);
        expect(r.invalid.keys, contains(w.id), reason: 'dated ${millis == null ? 'now' : 'in the window'}');
        smithsIntact(f, fork);
      }
    });

    test('R2: removing Dana\'s phone, now or dated inside the window, erases nothing, and A gets no new key in', () async {
      final join = ownJoin(f.dana);
      for (final millis in [null, joinedAt + 1]) {
        final (fork, why) = await judge(await forgeAs(f.alex, type: RecordType.device, rid: f.dana.deviceId, actor: f.gAlex, millis: millis,
            fields: {'revoked': true, 'revokedAfter': join.counter}));
        expect(why, anyOf(contains('own parents'), contains('said it was in')));
        smithsIntact(f, fork);
      }
      // Nor may A make a fresh key for Dana, now or dated inside the window.
      for (final millis in [null, joinedAt + 1]) {
        final k = await InviteKey.generate();
        final made = await forgeAs(f.alex, type: RecordType.inviteKey, rid: k.id, actor: f.gAlex, skip: 1, millis: millis, fields: {
          'member': f.gDana,
          'home': f.smithHome,
          'key': k.publicKey,
          'by': f.gAlex,
          'device': f.alex.deviceId,
          'expires': (millis ?? clock.now) + hour,
        });
        final fork = await f.kHub.fork();
        expect((await fork.ingest([made])).invalid[made.id], isNotNull);
        final adm = GroupAdmission(group: f.group, founder: f.alex.founderPubkey!, name: 'x', home: f.smithHome, member: f.gDana,
            mode: DeviceMode.personal, invite: k.id, seed: await k.seed(), expires: (millis ?? clock.now) + 30 * minute);
        final (evil, joinC) = await joinWith(f, adm, (millis ?? clock.now) + 5);
        expect((await fork.ingest([joinC])).invalid[joinC.id], isNotNull);
        final hijack = await forge(evil, counter: 2, millis: clock.now + 10, type: RecordType.home, rid: f.smithHome, actor: f.gDana,
            fields: {'hubs': ['https://evil.example/ws']});
        expect((await fork.ingest([hijack])).invalid[hijack.id], isNotNull);
        expect(fork.home(f.smithHome)!.hubs, ['https://den.smith.example/ws']);
        smithsIntact(f, fork);
      }
    });

    test('R3: A can\'t turn off Dana\'s words, now or dated inside the window', () async {
      final fork = await f.kHub.fork();
      final dana = await f.dana.fork();
      final words = await RecoveryKey.generate();
      await dana.setRecoveryKey(f.gDana, words.publicKey);
      await fork.ingest(dana.changesSince(fork.versionVector));
      clock.advance(const Duration(seconds: 2));
      final phone = await DeviceKeys.generate();
      final proof = await words.prove(
          family: f.group, kind: RecoveryKind.words, member: f.gDana, devicePubkey: phone.pubkey, expires: clock.now + 10 * minute);
      final rec = await forge(phone, counter: 1, millis: clock.now, type: RecordType.device, rid: await phone.deviceId(), fields: {
        'name': 'New phone',
        'kind': 'phone',
        'pubkey': phone.pubkey,
        'member': f.gDana,
        'mode': 'personal',
        'approved': true,
        'home': f.smithHome,
        'recovery': proof.toJson(),
      });
      expect((await fork.ingest([rec])).invalid, isEmpty);
      clock.advance(const Duration(days: 3));
      for (final millis in [null, joinedAt + 1]) {
        final wipe = await forgeAs(f.alex, type: RecordType.member, rid: f.gDana, actor: f.gAlex, millis: millis, fields: {
          'recovery': {'key': null, 'kept': <String>[]},
        });
        final judged = await fork.fork();
        expect((await judged.ingest([wipe])).invalid[wipe.id], isNotNull);
        expect(judged.deviceCounts(await phone.deviceId()), isTrue, reason: 'Dana\'s recovered phone stays');
        expect(recoveryKeyOf(judged.member(f.gDana)!), words.publicKey);
      }
    });

    test('"That wasn\'t them" a month later, or dated inside the day after: refused, and a forged one ends nothing', () async {
      await expectLater(f.alex.disownInvite(f.dana.deviceId), throwsA(isA<PermissionDenied>()));
      final (fork, why) = await judge(await forgeAs(f.alex, type: RecordType.home, rid: f.smithHome, actor: f.gAlex, fields: {'disowned': true}));
      expect(why, contains('within a day'));
      smithsIntact(f, fork);
    });
  });

  group('A dates things inside the invited window', () {
    final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
    late Families f;
    late int invitedAt;
    setUpAll(() async {
      f = await bothFamilies(clock);
      invitedAt = f.kHub.home(f.smithHome)!.rec.created.millis;
      clock.advance(const Duration(days: 30));
    });

    test('R4: taking the invitation back, dated before Dana joined, counts for nothing', () async {
      final fork = await f.kHub.fork();
      expect(ownJoin(f.dana).hlc.millis, greaterThan(invitedAt + 500));
      final take = await forgeAs(f.alex, type: RecordType.home, rid: f.smithHome, actor: f.gAlex, millis: invitedAt + 500,
          fields: {'status': 'left'});
      final r = await fork.ingest([take]);
      expect(r.invalid[take.id], contains('said it was in'));
      smithsIntact(f, fork);
      // The Smiths' devices see it for what it was.
      expect(fork.unheardWindowPowers(f.smithHome).map((c) => c.id), [take.id]);
      expect(f.smith.groupAlarm(f.smith.groupLink(f.group)!, fork)?.kind, GroupAlarmKind.backdated);
    });

    test('R5: devices let in with the invitation\'s key, dated before Dana\'s phone, count for nothing; hers stays', () async {
      final fork = await f.kHub.fork();
      final danaAt = ownJoin(f.dana).hlc.millis;
      final (evil, p) = await joinWith(f, f.invitation.parent, danaAt - 100);
      final (evilHub, h) = await joinWith(f, f.invitation.parent, danaAt - 50, mode: DeviceMode.hub);
      final r = await fork.ingest([p, h]);
      expect(r.invalid.keys, containsAll([p.id, h.id]));
      expect(fork.deviceCounts(await evil.deviceId()), isFalse);
      expect(fork.deviceCounts(await evilHub.deviceId()), isFalse);
      smithsIntact(f, fork);
      final list = await forge(evil, counter: 2, millis: clock.now, type: RecordType.list, rid: newId(), actor: f.gDana,
          fields: {'title': 'Planted'});
      expect((await fork.ingest([list])).invalid[list.id], isNotNull);
      // The Smiths' own devices see that someone else had their invitation.
      expect(fork.windowAdmissions(f.smithHome).map((a) => a.device), contains(await evil.deviceId()));
      expect(f.smith.groupAlarm(f.smith.groupLink(f.group)!, fork)?.kind, GroupAlarmKind.stranger);
      // And the same with a key A makes afresh, dated inside the window too: refused outright.
      final k = await InviteKey.generate();
      final made = await forgeAs(f.alex, type: RecordType.inviteKey, rid: k.id, actor: f.gAlex, millis: invitedAt + 200, fields: {
        'member': f.gDana,
        'home': f.smithHome,
        'key': k.publicKey,
        'by': f.gAlex,
        'device': f.alex.deviceId,
        'expires': invitedAt + hour,
      });
      final adm = GroupAdmission(group: f.group, founder: f.alex.founderPubkey!, name: 'x', home: f.smithHome, member: f.gDana,
          mode: DeviceMode.personal, invite: k.id, seed: await k.seed(), expires: invitedAt + 30 * minute);
      final (fresh, j) = await joinWith(f, adm, invitedAt + 300);
      final r2 = await fork.ingest([made, j]);
      expect(r2.invalid.keys, containsAll([made.id, j.id]));
      expect(fork.deviceCounts(await fresh.deviceId()), isFalse);
      smithsIntact(f, fork);
    });

    test('a device of A the Smiths never heard of gets no window power, whenever it dates it', () async {
      final fork = await f.kHub.fork();
      // A's new laptop, let in by Alex's phone now but dated inside the window.
      final laptop = await DeviceKeys.generate();
      final laptopId = await laptop.deviceId();
      final ask = await forge(laptop, counter: 1, millis: invitedAt + 100, type: RecordType.device, rid: laptopId, fields: {
        'name': 'Laptop',
        'kind': 'desktop',
        'pubkey': laptop.pubkey,
        'mode': 'personal',
        'approved': false,
        'home': f.kotvasHome,
      });
      final ok = await forgeAs(f.alex, type: RecordType.device, rid: laptopId, actor: f.gAlex, millis: invitedAt + 150,
          fields: {'approved': true, 'approvedBy': f.gAlex, 'member': f.gAlex, 'mode': 'personal'});
      final take = await forge(laptop, counter: 2, millis: invitedAt + 500, type: RecordType.home, rid: f.smithHome, actor: f.gAlex,
          fields: {'status': 'left'});
      final r = await fork.ingest([ask, ok, take]);
      expect(r.invalid.keys, contains(take.id));
      smithsIntact(f, fork);
    });

    test('a forged join AND a forged "we\'re in" with the invitation\'s key, dated inside the window: the Smiths\' place ends, and A never acts as them', () async {
      // With the key it made, the inviting family can write another beginning for the Smiths:
      // its own device let in as Dana, saying they're in before her phone did. Two phones
      // each saying they are the Smiths: no beginning wins, and the Smiths' place ends for
      // everyone (GroupStarts), loudly, rather than A becoming them.
      final fork = await f.kHub.fork();
      final danaAt = ownJoin(f.dana).hlc.millis;
      final (evil, p) = await joinWith(f, f.invitation.parent, danaAt - 100);
      final evilId = await evil.deviceId();
      final fakeIn = await sayIn(evil, f.smithHome, f.gDana, danaAt - 50, heard: [
        for (final c in f.kHub.changesSince(const {}))
          if (c.device == f.alex.deviceId && (c.rid == f.smithHome || c.rid == f.gDana || c.rid == f.invitation.parent.invite)) c.id,
      ]);
      await fork.ingest([p, fakeIn]);
      smithsEnded(f, fork);
      expect(fork.deviceCounts(evilId), isFalse);
      expect(fork.homeContested(f.smithHome), isTrue);
      expect(fork.homeEnd(f.smithHome)!.closings, containsAll([fakeIn.id, activation(f.dana, f.smithHome).id]));
      expect(fork.windowAdmissions(f.smithHome).where((a) => a.saidIn).map((a) => a.device), unorderedEquals([evilId, f.dana.deviceId]));
      // Nothing A's device writes as the Smiths counts, nor anything A does to them after.
      final start = clock.now + day;
      for (final c in [
        await forge(evil, counter: 3, millis: clock.now, type: RecordType.event, rid: newId(), actor: f.gDana,
            fields: {'title': 'Cancelled, don\'t come', 'start': start, 'end': start + hour}),
        await forge(evil, counter: 4, millis: clock.now + 1, type: RecordType.home, rid: f.smithHome, actor: f.gDana, fields: {'name': 'Smiths!'}),
        await forgeAs(f.alex, type: RecordType.home, rid: f.smithHome, actor: f.gAlex, fields: {'status': 'left'}),
        await forgeAs(f.alex, type: RecordType.member, rid: newId(), actor: f.gAlex, skip: 1, fields: {'name': 'Dana', 'role': 'parent', 'home': f.smithHome}),
      ]) {
        expect((await (await fork.fork()).ingest([c])).invalid[c.id], isNotNull, reason: c.type);
      }
      // Nor does the invitation let anyone in again (an ended family's own records are judged
      // as they were made, so this one is refused as any expired join is).
      final (_, again) = await joinWith(f, f.invitation.parent, clock.now + 5);
      expect((await fork.ingest([again])).invalid[again.id], isNotNull);
      expect(fork.deviceCounts(again.device), isFalse);
      // Every family's devices can tell, and the Smiths' own log says it wasn't them.
      expect(f.smith.groupAlarm(f.smith.groupLink(f.group)!, fork)?.kind, GroupAlarmKind.contested);
    });
  });

  group('an honest phone that hasn\'t heard', () {
    test('R6: a Kotvas parent whose phone hasn\'t heard that Dana is in leaves: the Smiths stay', () async {
      final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
      final f = await kotvasGroup(clock);
      await inviteSmiths(f);
      await exchange(f.priya, f.kHub);
      final stale = await f.priya.fork();
      await smithsJoin(f);
      clock.advance(const Duration(hours: 1));
      final leave = await stale.leaveGroup();
      final fork = await f.kHub.fork();
      final r = await fork.ingest(leave);
      smithsIntact(f, fork);
      // What it did to the Smiths is refused; the rest of the Kotvas family's leaving counts.
      final refused = [for (final c in leave) if (r.invalid.containsKey(c.id)) c];
      expect(refused.map((c) => c.rid), contains(f.smithHome));
      expect(fork.home(f.kotvasHome)!.left, isTrue);
    });

    test('R6b: "Cancel invitation" on a phone that hasn\'t heard Dana is in: harmless once it syncs', () async {
      final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
      final f = await kotvasGroup(clock);
      await inviteSmiths(f);
      await exchange(f.priya, f.kHub);
      final stale = await f.priya.fork();
      await smithsJoin(f);
      clock.advance(const Duration(hours: 2));
      expect(stale.invitationOpen(f.smithHome), isTrue);
      final before = {for (final c in stale.changesSince(const {})) c.id};
      await stale.cancelInvitation(f.smithHome);
      final cancel = [for (final c in stale.changesSince(const {})) if (!before.contains(c.id)) c];
      final fork = await f.kHub.fork();
      final r = await fork.ingest(cancel);
      expect(r.invalid.length, cancel.length);
      smithsIntact(f, fork);
      // Once the phone syncs, it sees it too.
      await stale.ingest(f.kHub.changesSince(stale.versionVector));
      expect(stale.home(f.smithHome)!.status, HomeStatus.active);
    });
  });

  test('R7: a driver who can\'t drive is never put on another leg or occurrence; the same leg may be said again', () async {
    final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
    final f = await bothFamilies(clock);
    final start = DateTime.utc(2026, 11, 5, 15).millisecondsSinceEpoch;
    final game = newId();
    final ev = await forgeAs(f.alex, type: RecordType.event, rid: game, actor: f.gAlex, fields: {
      'title': 'Game',
      'start': start,
      'end': start + hour,
      'rrule': 'FREQ=WEEKLY',
      'drivers': {'to': f.gDana, 'from': null},
    });
    expect((await f.kHub.ingest([ev])).invalid, isEmpty);
    await settle(f);
    clock.advance(const Duration(minutes: 1));
    await f.sHub.ingest(await f.dana.leaveGroup(family: f.smith));
    await settle(f);
    clock.advance(const Duration(minutes: 1));
    expect(f.kHub.home(f.smithHome)!.left, isTrue);
    Future<String?> judge(Change c) async => (await (await f.kHub.fork()).ingest([c])).invalid[c.id];
    final other = await forgeAs(f.alex, type: RecordType.event, rid: newId(), actor: f.gAlex, skip: 5, fields: {
      'title': 'Other',
      'start': start,
      'end': start + hour,
      'drivers': {'to': f.gDana, 'from': null},
    });
    expect(await judge(other), contains('left the group'));
    expect(await judge(await forgeAs(f.alex, type: RecordType.event, rid: game, actor: f.gAlex, fields: {'drivers.from': f.gDana})),
        contains('left the group'));
    final occ = start + 7 * day;
    expect(
        await judge(await forgeAs(f.alex, type: RecordType.eventException, rid: '$game@$occ', actor: f.gAlex, skip: 1,
            fields: {'event': game, 'occurrence': occ, 'patch.drivers.from': f.gDana})),
        contains('left the group'));
    // Saying the whole list again (as Den does for older versions) with her on the leg she has,
    // while Alex takes the other, counts.
    expect(
        await judge(await forgeAs(f.alex, type: RecordType.event, rid: game, actor: f.gAlex, fields: {
          'rides': [
            {'leg': 'to', 'driver': f.gDana},
            {'leg': 'from', 'driver': f.gAlex},
          ],
        })),
        isNull);
    expect(await judge(await forgeAs(f.alex, type: RecordType.event, rid: game, actor: f.gAlex, fields: {'drivers.from': f.gAlex})), isNull);
  });

  test('R8: no hub, nor anyone, holds a group person\'s own space: a group has none', () async {
    final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
    final f = await bothFamilies(clock);
    expect(f.kHub.spacesForDevice(f.kHub.deviceId), {Space.family, Space.parents});
    expect(f.alex.spacesForDevice(f.sHub.deviceId), {Space.family, Space.parents});
    expect(f.alex.spacesForDevice(f.leo.deviceId), {Space.family});
    expect(f.alex.spacesForDevice(f.dana.deviceId), {Space.family, Space.parents});
    final mine = await forgeAs(f.priya, type: RecordType.list, rid: newId(), actor: f.gPriya, space: Space.member(f.gPriya),
        fields: {'title': 'Mine'});
    expect(await refusal(f.kHub, mine), contains('no one\'s own space'));
    await expectLater(f.priya.addList(title: 'Mine', audience: Audience.justMe), throwsA(isA<InvalidInput>()));
    expect(f.alex.spaceKeyEpochs(Space.member(f.gAlex)), isEmpty, reason: 'and no key for one');
  });

  test('R9: a group\'s very first record carries no stars, server help or privacy settings', () async {
    final keys = await DeviceKeys.generate();
    final dev = await keys.deviceId();
    final t = DateTime.utc(2026, 10, 29, 15).millisecondsSinceEpoch;
    final id = familyIdFor(keys.pubkey, t);
    final words = (await RecoveryKey.generate()).publicKey;
    for (final extra in <Map<String, Object?>>[
      {'pointsEnabled': true},
      {'recovery': {'serverKey': words, 'kept': <String>[]}},
      {'oversight': <String, Object?>{}},
      {'assistant': {'enabled': true}},
    ]) {
      final m = Materializer(() => TrustRoot(familyId: id, founderPubkey: keys.pubkey));
      final fam = await forge(keys, counter: 1, millis: t, type: RecordType.family, rid: id, fields: {
        'name': 'G',
        'timezone': 'UTC',
        'weekStart': 0,
        'founderDevice': dev,
        'kind': 'group',
        ...extra,
      });
      expect(m.add([fam]), isNotEmpty, reason: '${extra.keys.single} at genesis');
    }
  });

  test('R10: an invitation lets in no hub, before or after; A can\'t make a spare key for one', () async {
    final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
    final f = await kotvasGroup(clock);
    await inviteSmiths(f);
    final spare = await InviteKey.generate();
    await expectLater(
        f.alex.createInviteKey(member: null, publicKey: spare.publicKey, expires: clock.now + 6 * day, modes: const {DeviceMode.hub}, home: f.smithHome),
        throwsA(isA<PermissionDenied>()));
    final madeAt = clock.now;
    final (_, inWindow) = await joinWith(f, f.invitation.parent, madeAt + 500, mode: DeviceMode.hub);
    expect(await refusal(f.kHub, inWindow), isNotNull);
    await smithsJoin(f);
    clock.advance(const Duration(days: 2));
    for (final at in [clock.now, madeAt + 1000]) {
      final (evilHub, j) = await joinWith(f, f.invitation.parent, at, mode: DeviceMode.hub);
      final judged = await f.kHub.fork();
      expect((await judged.ingest([j])).invalid[j.id], isNotNull, reason: 'joined ${at == clock.now ? 'now' : 'dated in the window'}');
      expect(judged.deviceCounts(await evilHub.deviceId()), isFalse);
    }
  });

  test('R11: the attacks give the same verdicts in every arrival order', () async {
    final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
    final f = await bothFamilies(clock);
    final invitedAt = f.kHub.home(f.smithHome)!.rec.created.millis;
    clock.advance(const Duration(days: 30));
    final base = f.kHub.changesSince(const {}).toList();
    final danaJoin = ownJoin(f.dana);
    final revoke = await forgeAs(f.alex, type: RecordType.device, rid: f.dana.deviceId, actor: f.gAlex,
        fields: {'revoked': true, 'revokedAfter': danaJoin.counter});
    final backdatedRevoke = await forgeAs(f.alex, type: RecordType.device, rid: f.dana.deviceId, actor: f.gAlex, skip: 1,
        millis: danaJoin.hlc.millis + 1, fields: {'revoked': true, 'revokedAfter': danaJoin.counter});
    final k = await InviteKey.generate();
    final made = await forgeAs(f.alex, type: RecordType.inviteKey, rid: k.id, actor: f.gAlex, skip: 2, fields: {
      'member': f.gDana,
      'home': f.smithHome,
      'key': k.publicKey,
      'by': f.gAlex,
      'device': f.alex.deviceId,
      'expires': clock.now + hour,
    });
    final w = await forgeAs(f.alex, type: RecordType.inviteKey, rid: f.invitation.parent.invite, actor: f.gAlex, skip: 3,
        fields: {'key': null, 'kept': <String>[]});
    final take = await forgeAs(f.alex, type: RecordType.home, rid: f.smithHome, actor: f.gAlex, skip: 4, millis: invitedAt + 500,
        fields: {'status': 'left'});
    final (_, fakeJoin) = await joinWith(f, f.invitation.parent, danaJoin.hlc.millis - 100);
    final attacks = [revoke, backdatedRevoke, made, w, take, fakeJoin];
    final pool = [...base, ...attacks];
    TrustRoot root() => TrustRoot(familyId: f.group, founderPubkey: f.alex.founderPubkey);
    final once = Materializer(root)..add(pool);
    for (final c in attacks) {
      expect(once.rejected.containsKey(c.id), isTrue, reason: 'attack ${attacks.indexOf(c)}');
    }
    expect(once.rejected.containsKey(danaJoin.id), isFalse);
    expect(once.rejected.containsKey(activation(f.dana, f.smithHome).id), isFalse);
    expect(once.store.liveAt(Space.family, RecordType.device, f.dana.deviceId)!.fields['revoked'], isNot(true));
    expect(once.store.at(Space.family, RecordType.home, f.smithHome)!.fields['status'], 'active');
    final want = (once.rejected.keys.toList()..sort()).join(',');
    for (final seed in [1, 2, 3, 4, 5, 6, 7, 8]) {
      final random = Random(seed);
      final shuffled = [...pool]..shuffle(random);
      final m = Materializer(root);
      var i = 0;
      while (i < shuffled.length) {
        final n = 1 + random.nextInt(8);
        m.add(shuffled.sublist(i, min(i + n, shuffled.length)));
        i += n;
      }
      expect((m.rejected.keys.toList()..sort()).join(','), want, reason: 'seed $seed');
    }
  });

  test('a contested home ends the same in every arrival order, from its invitation on', () async {
    final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
    final f = await bothFamilies(clock);
    clock.advance(const Duration(days: 3));
    final base = f.kHub.changesSince(const {}).toList();
    final danaAt = ownJoin(f.dana).hlc.millis;
    final (evil, p) = await joinWith(f, f.invitation.parent, danaAt - 100);
    // Dated after Dana's: the home still ends, from its invitation on.
    final fakeIn = await sayIn(evil, f.smithHome, f.gDana, clock.now);
    final pool = [...base, p, fakeIn];
    TrustRoot root() => TrustRoot(familyId: f.group, founderPubkey: f.alex.founderPubkey);
    final once = Materializer(root)..add(pool);
    final end = once.starts.ended[f.smithHome]!;
    expect(end.contested, isTrue);
    expect(end.firstIn, activation(f.dana, f.smithHome).hlc);
    expect(end.at, f.kHub.home(f.smithHome)!.rec.created);
    expect(once.rejected.containsKey(activation(f.dana, f.smithHome).id), isTrue);
    // Nothing let in with the invitation counts, then or now: the phones stay on record, as a
    // family's that left (endsJudgedPast), and none of what they wrote counts.
    for (final d in [f.dana.deviceId, p.device]) {
      final e = once.store.at(Space.family, RecordType.device, d);
      expect(e, isNotNull, reason: 'on record');
      expect(deviceOutOfGroup(once.store, Device(e!.rec)), isTrue);
    }
    expect([for (final c in base) if (c.device == f.dana.deviceId && c.type == RecordType.event) c].every((c) => once.rejected.containsKey(c.id)), isTrue);
    final want = (once.rejected.keys.toList()..sort()).join(',');
    for (final seed in [1, 2, 3, 4]) {
      final random = Random(seed);
      final shuffled = [...pool]..shuffle(random);
      final m = Materializer(root);
      var i = 0;
      while (i < shuffled.length) {
        final n = 1 + random.nextInt(8);
        m.add(shuffled.sublist(i, min(i + n, shuffled.length)));
        i += n;
      }
      expect((m.rejected.keys.toList()..sort()).join(','), want, reason: 'seed $seed');
    }
  });

  group('the second review (V1-V7)', () {
    test('V1: a device A lets in with the invitation\'s key, that Dana\'s phone heard of, isn\'t kept: "we\'re in" keeps only her phone', () async {
      final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
      final f = await kotvasGroup(clock);
      await inviteSmiths(f);
      clock.advance(const Duration(seconds: 1));
      final (evil, j) = await joinWith(f, f.invitation.parent, clock.now);
      expect((await f.kHub.ingest([j])).invalid, isEmpty, reason: 'while the window is open');
      // And with it as a hub: no invitation lets one in.
      final (_, asHub) = await joinWith(f, f.invitation.parent, clock.now + 1, mode: DeviceMode.hub);
      expect((await f.kHub.ingest([asHub])).invalid, isNotEmpty);
      // Dana's phone, knowing of the other, won't say the Smiths are in until Dana says it
      // wasn't hers (X3); then it does, and keeps only itself.
      await expectLater(smithsJoin(f), throwsA(isA<InvalidInput>()));
      await f.dana.updateHome(active: true, ownFamily: f.smith.familyId, hubs: const ['https://den.smith.example/ws'], family: f.smith, notOurs: true);
      await f.dana.addToGroup(family: f.smith, people: [f.sDana, f.sMia]);
      f.gMia = f.smith.groupLink(f.group)!.members[f.sMia]!;
      await exchange(f.dana, f.kHub);
      f.sHub = await admitFrom(f, f.sHubF, f.smith, f.kHub, name: 'Smith hub');
      await exchange(f.dana, f.sHub);
      f.mia = await admitFrom(f, f.miaF, f.smith, f.sHub, name: "Mia's tablet");
      await settle(f);
      final evilId = await evil.deviceId();
      expect(f.dana.windowAdmissions(f.smithHome).map((a) => a.device), contains(evilId), reason: 'Dana\'s phone heard of it');
      expect(activation(f.dana, f.smithHome).fields.containsKey('kept'), isFalse);
      clock.advance(const Duration(days: 30));
      expect(f.kHub.deviceCounts(evilId), isFalse);
      final start = clock.now + day;
      final ev = await forge(evil, counter: 2, millis: clock.now, type: RecordType.event, rid: newId(), actor: f.gDana,
          fields: {'title': 'Cancelled, don\'t come', 'start': start, 'end': start + hour});
      expect(await refusal(f.kHub, ev), isNotNull);
      smithsIntact(f, f.kHub);
      expect(f.smith.groupAlarm(f.smith.groupLink(f.group)!, f.kHub)?.kind, GroupAlarmKind.stranger);
    });

    test('V2: a gap A leaves in its counters below the invitation changes nothing: "we\'re in" names the changes it heard', () async {
      final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
      final f = await kotvasGroup(clock);
      clock.advance(const Duration(seconds: 1));
      f.smith = await foundFamily(clock, name: 'Dana');
      f.sDana = f.smith.actor!.id;
      f.sMia = await f.smith.addMember(name: 'Mia', role: Role.kid, tier: Tier.little);
      f.miaF = await joinDevice(f.smith, clock, member: f.sMia, name: "Mia's tablet");
      f.sHubF = await joinDevice(f.smith, clock, mode: DeviceMode.hub, name: 'Smith hub', kind: DeviceKind.hub);
      // A's modified app: the invitation, numbered after a counter it never uses.
      final n = maxCounter(f.alex);
      final k1 = await InviteKey.generate();
      final homeId = homeIdFor(k1.publicKey, f.alex.deviceId), memberId = newId();
      final exp = clock.now + day;
      Future<Change> a(int counter, String type, String rid, Map<String, Object?> fields) =>
          forge(f.alex.keys, counter: counter, millis: clock.now + counter - n, type: type, rid: rid, fields: fields, actor: f.gAlex);
      final inv = [
        await a(n + 2, RecordType.home, homeId, {'name': 'Smiths', 'status': 'invited', 'invitedBy': f.kotvasHome, 'key': k1.publicKey}),
        await a(n + 3, RecordType.member, memberId, {'name': 'Dana', 'role': 'parent', 'grants': <String>[], 'order': 9, 'home': homeId}),
        await a(n + 4, RecordType.inviteKey, k1.id,
            {'member': memberId, 'home': homeId, 'key': k1.publicKey, 'by': f.gAlex, 'device': f.alex.deviceId, 'expires': exp}),
      ];
      expect((await f.kHub.ingest(inv)).invalid, isEmpty);
      f.invitation = GroupInvitation(
        parent: GroupAdmission(
            group: f.group, founder: f.alex.founderPubkey!, name: 'Cousins soccer', home: homeId, member: memberId,
            mode: DeviceMode.personal, invite: k1.id, seed: await k1.seed(), expires: exp),
        homeName: 'Smiths',
        parentName: 'Dana',
        hubs: const [],
      );
      f.smithHome = homeId;
      f.gDana = memberId;
      await smithsJoin(f);
      expect(activation(f.dana, f.smithHome).fields['heard'], unorderedEquals([for (final c in inv) c.id]));
      expect(f.kHub.closureFor(f.smithHome)!.id, activation(f.dana, f.smithHome).id);
      clock.advance(const Duration(days: 30));
      // R4, a month later, dated just after the invitation: refused, the Smiths stay.
      final fork = await f.kHub.fork();
      final take = await forge(f.alex.keys, counter: maxCounter(f.alex) + 10, millis: inv.first.hlc.millis + 500, type: RecordType.home,
          rid: f.smithHome, actor: f.gAlex, fields: {'status': 'left'});
      expect((await fork.ingest([take])).invalid[take.id], contains('said it was in'));
      smithsIntact(f, fork);
    });

    test('V3: a floor A\'s hub vouches for (`through`) is never taken: no counter goes into "we\'re in", nor into a removal', () async {
      final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
      final f = await kotvasGroup(clock);
      await inviteSmiths(f);
      clock.advance(const Duration(seconds: 1));
      f.dana = await admit(f, f.invitation.parent, f.kHub, name: "Dana's phone");
      final n = maxCounter(f.alex);
      final held = f.dana.versionVector[f.alex.deviceId];
      // The Kotvas hub, serving Dana's phone, says it has passed on everything of Alex's phone up to n+1000.
      await f.dana.ingest(const [], through: {f.alex.deviceId: n + 1000});
      expect(f.dana.versionVector[f.alex.deviceId], held, reason: 'a parent\'s phone in a group takes no floor');
      clock.advance(const Duration(seconds: 1));
      await f.dana.updateHome(active: true, family: f.smith);
      await exchange(f.dana, f.kHub);
      final said = activation(f.dana, f.smithHome);
      expect(said.fields.containsKey('closed'), isFalse);
      expect(said.fields['heard'], hasLength(3));
      clock.advance(const Duration(days: 30));
      final fork = await f.kHub.fork();
      final take = await forge(f.alex.keys, counter: n + 500, millis: f.kHub.home(f.smithHome)!.rec.created.millis + 500, type: RecordType.home,
          rid: f.smithHome, actor: f.gAlex, fields: {'status': 'left'});
      expect((await fork.ingest([take])).invalid[take.id], contains('said it was in'));
      expect(fork.home(f.smithHome)!.status, HomeStatus.active);
    });

    test('V5: "we\'re in" said by a Smith device the invitation didn\'t let in is refused: the family stays invited until its phone says it', () async {
      final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
      final f = await kotvasGroup(clock);
      await inviteSmiths(f);
      clock.advance(const Duration(seconds: 1));
      f.dana = await admit(f, f.invitation.parent, f.kHub, name: "Dana's phone");
      // Dana's tablet, let in with a Smith key Dana's phone makes.
      final k = await InviteKey.generate();
      await f.dana.createInviteKey(member: f.gDana, publicKey: k.publicKey, expires: clock.now + hour);
      await exchange(f.dana, f.kHub);
      final tablet = await admit(
          f,
          GroupAdmission(group: f.group, founder: f.alex.founderPubkey!, name: 'x', home: f.smithHome, member: f.gDana,
              mode: DeviceMode.personal, invite: k.id, seed: await k.seed(), expires: clock.now + 30 * minute),
          f.kHub,
          name: "Dana's tablet");
      await expectLater(tablet.updateHome(active: true, family: null), throwsA(isA<PermissionDenied>()));
      final forged = await forgeAs(tablet, type: RecordType.home, rid: f.smithHome, actor: f.gDana, fields: {'status': 'active', 'heard': <String>[]});
      expect(await refusal(f.kHub, forged), contains('invitation let in'));
      expect(f.kHub.home(f.smithHome)!.status, HomeStatus.invited);
      // Dana's phone says it: now the window is shut, and R4 a month later counts for nothing.
      await exchange(f.dana, f.kHub);
      clock.advance(const Duration(seconds: 1));
      await f.dana.updateHome(active: true, family: f.smith);
      await exchange(f.dana, f.kHub);
      expect(f.kHub.home(f.smithHome)!.status, HomeStatus.active);
      clock.advance(const Duration(days: 30));
      final fork = await f.kHub.fork();
      final take = await forge(f.alex.keys, counter: maxCounter(f.alex) + 10, millis: f.kHub.home(f.smithHome)!.rec.created.millis + 500,
          type: RecordType.home, rid: f.smithHome, actor: f.gAlex, fields: {'status': 'left'});
      expect((await fork.ingest([take])).invalid[take.id], contains('said it was in'));
      expect(fork.home(f.smithHome)!.status, HomeStatus.active);
    });

    test('V6: whoever uses a leaked invitation first and says "we\'re in" is ended within a day by the phone that sent it; never Dana for good', () async {
      final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
      final f = await kotvasGroup(clock);
      await inviteSmiths(f);
      clock.advance(const Duration(seconds: 1));
      // Someone who saw the invitation link.
      final imp = await admit(f, f.invitation.parent, f.kHub, name: "Dana's phone");
      await imp.updateHome(active: true, family: null);
      await exchange(imp, f.kHub);
      await exchange(f.alex, f.kHub);
      clock.advance(const Duration(hours: 3));
      await f.alex.disownInvite(imp.deviceId);
      await exchange(f.alex, f.kHub);
      expect(f.kHub.deviceCounts(imp.deviceId), isFalse);
      expect(f.kHub.home(f.smithHome)!.ended, 'disowned');
      // The real Dana, with the same link, gets nowhere (her phone stays on record with the ended
      // home, which counts for nothing): the Smiths are invited again, as a new home.
      clock.advance(const Duration(minutes: 5));
      final real = await openDen(clock);
      await real.joinGroup(f.invitation.parent, deviceName: "Dana's phone", kind: DeviceKind.phone, family: null);
      final seen = await f.kHub.fork();
      await seen.ingest(real.changesSince(const {}));
      expect(seen.deviceCounts(real.deviceId), isFalse);
      expect(seen.home(f.smithHome)!.left, isTrue);
      final again = await f.alex.inviteFamily(familyName: 'Smiths', parentName: 'Dana');
      await exchange(f.alex, f.kHub);
      final dana = await admit(f, again.parent, f.kHub, name: "Dana's phone");
      expect(dana.isApproved, isTrue);
      expect(dana.myHome, again.home);
    });

    test('V7: refused "we\'re in" look-alikes cost no replays, in a family log or from a group device the invitation didn\'t let in', () async {
      final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
      final den = await foundFamily(clock);
      for (var i = 0; i < 300; i++) {
        clock.advance(const Duration(minutes: 1));
        await den.addEvent(title: 'E$i', start: clock.now + day, end: clock.now + day + hour);
      }
      final base = den.changesSince(const {}).toList();
      var n = base.where((c) => c.device == den.deviceId).map((c) => c.counter).reduce(max);
      Future<List<Change>> forged(bool closure) async => [
            for (var i = 0; i < 30; i++)
              await forge(den.keys, counter: ++n, millis: clock.now + i, type: RecordType.home, rid: newId(), actor: den.actor!.id, fields: {
                'name': 'x',
                'status': 'active',
                if (closure) 'heard': <String>[],
              }),
          ];
      final plain = await forged(false), shaped = await forged(true);
      TrustRoot root() => TrustRoot(familyId: den.familyId, founderPubkey: den.founderPubkey);
      (int, int) cost(List<Change> extra) {
        final m = Materializer(root)..add([...base, ...extra]);
        expect(m.rejected.keys.toSet().containsAll(extra.map((c) => c.id)), isTrue);
        final passes = m.passes;
        final sw = Stopwatch()..start();
        m.replay();
        return (m.passes - passes, sw.elapsedMilliseconds);
      }

      cost(plain);
      final (a, ta) = cost(plain);
      final (b, tb) = cost(shaped);
      // ignore: avoid_print
      print('a family log\'s replay with 30 refused plain changes: ${ta}ms; with 30 refused closure-shaped: ${tb}ms');
      expect(b, a, reason: 'one pass each');

      // In a group: 30 from Mia's tablet (not let in by the invitation) cost nothing either; 30
      // from Dana's own phone cost at most a few tries.
      final f = await bothFamilies(clock);
      final groupBase = f.kHub.changesSince(const {}).toList();
      var m = maxCounter(f.mia);
      final fromMia = [
        for (var i = 0; i < 30; i++)
          await forge(f.mia.keys, counter: ++m, millis: clock.now + i, type: RecordType.home, rid: f.smithHome, actor: f.gMia,
              fields: {'status': 'active', 'heard': <String>[]}),
      ];
      var d = maxCounter(f.dana);
      final fromDana = [
        for (var i = 0; i < 30; i++)
          await forge(f.dana.keys, counter: ++d, millis: clock.now + i, type: RecordType.home, rid: f.smithHome, actor: f.gDana,
              fields: {'status': 'active', 'heard': <String>[]}),
      ];
      TrustRoot groupRoot() => TrustRoot(familyId: f.group, founderPubkey: f.alex.founderPubkey);
      int groupCost(List<Change> extra) {
        final g = Materializer(groupRoot)..add([...groupBase, ...extra]);
        final passes = g.passes;
        g.replay();
        expect(g.starts.ended, isEmpty);
        expect(g.store.at(Space.family, RecordType.home, f.smithHome)!.fields['status'], 'active');
        return g.passes - passes;
      }

      final none = groupCost(const []);
      expect(groupCost(fromMia), none);
      expect(groupCost(fromDana), lessThanOrEqualTo(none + 2 * Materializer.maxClosureTries));
    });
  });

  group('alarms: what the Smiths\' own log lets them tell', () {
    final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
    late Families f;
    setUpAll(() async {
      f = await bothFamilies(clock);
    });

    GroupAlarm? alarm(Den group, [GroupLink? link]) => f.smith.groupAlarm(link ?? f.smith.groupLink(f.group)!, group);

    test('none when all is well, on every Smith device and the hub', () async {
      expect(alarm(f.sHub), isNull);
      expect(alarm(f.kHub), isNull);
    });

    test('contested: two phones said they were the Smiths; every family sees it', () async {
      final fork = await f.kHub.fork();
      final (evil, p) = await joinWith(f, f.invitation.parent, ownJoin(f.dana).hlc.millis - 100);
      await fork.ingest([p, await sayIn(evil, f.smithHome, f.gDana, clock.now)]);
      expect(alarm(fork)?.kind, GroupAlarmKind.contested);
      expect(fork.homeContested(f.smithHome), isTrue, reason: 'the Kotvas hub can flag it too');
    });

    test('disowned: the family that invited them said that wasn\'t them, within the day', () async {
      final alex = await f.alex.fork();
      await alex.disownInvite(f.dana.deviceId);
      final fork = await f.kHub.fork();
      await fork.ingest(alex.changesSince(fork.versionVector));
      expect(alarm(fork)?.kind, GroupAlarmKind.disowned);
    });

    test('removed: the group says they left, and their own log doesn\'t', () async {
      final dana = await f.dana.fork();
      final fork = await f.kHub.fork();
      await fork.ingest(await dana.leaveGroup());
      expect(alarm(fork)?.kind, GroupAlarmKind.removed);
    });

    test('notOurs: the group\'s "we\'re in" isn\'t the one their phone recorded', () async {
      final link = f.smith.groupLink(f.group)!;
      final smith = await f.smith.fork();
      await smith.writeGroupLink(group: f.group, founder: link.founder, name: link.name, closure: '${f.dana.deviceId}:999');
      expect(smith.groupAlarm(smith.groupLink(f.group)!, f.kHub)?.kind, GroupAlarmKind.notOurs);
    });

    test('deviceGone: the phone their log says brought them in no longer counts; none when they removed it themselves', () async {
      // Dana replaces her phone and removes the old one: the family did it, nothing to alarm.
      final dana = await f.dana.fork();
      final fork = await f.kHub.fork();
      await dana.revokeDevice(dana.deviceId);
      await fork.ingest(dana.changesSince(fork.versionVector));
      expect(fork.deviceCounts(f.dana.deviceId), isFalse);
      expect(alarm(fork), isNull);
      // The family's log names a phone the invitation let in that the group doesn't count, and
      // nobody of the family removed: something is wrong.
      final other = await f.kHub.fork();
      final (evil, p) = await joinWith(f, f.invitation.parent, ownJoin(f.dana).hlc.millis - 100);
      await other.ingest([p]);
      final link = f.smith.groupLink(f.group)!;
      final smith = await f.smith.fork();
      await smith.writeGroupLink(group: f.group, founder: link.founder, name: link.name, device: await evil.deviceId());
      expect(smith.groupAlarm(smith.groupLink(f.group)!, other)?.kind, GroupAlarmKind.deviceGone);
    });

    test('stranger, and backdated: someone else used the invitation before their "we\'re in", or the inviting family dated a change before it', () async {
      final fork = await f.kHub.fork();
      final take = await forgeAs(f.alex, type: RecordType.home, rid: f.smithHome, actor: f.gAlex,
          millis: f.kHub.home(f.smithHome)!.rec.created.millis + 500, fields: {'status': 'left'});
      await fork.ingest([take]);
      expect(alarm(fork)?.kind, GroupAlarmKind.backdated);
      // A phone of theirs opening the old invitation again, after they were in: refused, and
      // harmless, so no alarm.
      final (_, late) = await joinWith(f, f.invitation.parent, clock.now + 5000);
      final later = await f.kHub.fork();
      expect((await later.ingest([late])).invalid, isNotEmpty);
      expect(alarm(later), isNull);
      final (_, p) = await joinWith(f, f.invitation.parent, ownJoin(f.dana).hlc.millis - 100);
      await fork.ingest([p]);
      final a = alarm(fork)!;
      expect(a.kind, GroupAlarmKind.stranger);
      expect(a.devices, ['Evil']);
    });

    test('contested with their own phone among those that said it: a hint it may have been theirs twice', () async {
      final fork = await f.kHub.fork();
      final (evil, p) = await joinWith(f, f.invitation.parent, ownJoin(f.dana).hlc.millis - 100);
      await fork.ingest([p, await sayIn(evil, f.smithHome, f.gDana, clock.now)]);
      final a = alarm(fork)!;
      expect(a.kind, GroupAlarmKind.contested);
      expect(a.mayBeOurs, isTrue);
      expect(a.devices, unorderedEquals(['Evil', "Dana's phone"]));
    });

    test('unanchored: the group says the family is in, and its phone never said so in the family\'s own log', () async {
      final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
      final g = await kotvasGroup(clock);
      await inviteSmiths(g);
      g.dana = await admit(g, g.invitation.parent, g.kHub, name: "Dana's phone", family: g.smith);
      expect(g.smith.groupLink(g.group)!.home, g.smithHome, reason: 'joining wrote where, and as which phone');
      expect(g.smith.groupAlarm(g.smith.groupLink(g.group)!, g.kHub), isNull);
      clock.advance(const Duration(seconds: 1));
      await g.dana.updateHome(active: true, family: null);
      await exchange(g.dana, g.kHub);
      expect(g.smith.groupAlarm(g.smith.groupLink(g.group)!, g.kHub)?.kind, GroupAlarmKind.unanchored);
    });
  });

  group('the third review (X1-X4, R12)', () {
    final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
    late Families f;
    late String danaEvent;
    setUpAll(() async {
      f = await bothFamilies(clock);
      // What the Smiths shared after they were in.
      clock.advance(const Duration(hours: 1));
      danaEvent = await f.dana.addEvent(title: 'Smiths host practice', start: clock.now + day, end: clock.now + day + hour);
      await settle(f);
      clock.advance(const Duration(days: 30));
    });

    test('X1: A writes as Dana, dated inside the window, then contests: nothing it wrote as Dana counts; the Smiths\' history goes, and their devices can copy it home', () async {
      final fork = await f.kHub.fork();
      expect(fork.event(danaEvent), isNotNull);
      final danaAt = ownJoin(f.dana).hlc.millis;
      final (evil, j) = await joinWith(f, f.invitation.parent, danaAt - 300);
      final start = DateTime.utc(2026, 11, 7, 15).millisecondsSinceEpoch;
      final asDana = newId();
      final wrote = await forge(evil, counter: 2, millis: danaAt - 200, type: RecordType.event, rid: asDana, actor: f.gDana,
          fields: {'title': 'Smiths: we quit the carpool, find another driver', 'start': start, 'end': start + hour});
      final saysIn = await sayIn(evil, f.smithHome, f.gDana, clock.now, counter: 3);
      await fork.ingest([j, wrote, saysIn]);
      expect(fork.homeContested(f.smithHome), isTrue);
      // A never acts as B: what it wrote as Dana counts for nothing, ever.
      expect(fork.event(asDana), isNull);
      final evilId = await evil.deviceId();
      expect(fork.history().where((h) => h.device == evilId), isEmpty);
      // The price of joining at once: the Smiths' shared history in the group goes too.
      expect(fork.event(danaEvent), isNull);
      // Their devices still hold what they wrote, to copy into their own Den.
      final shared = fork.sharedByHome(f.smithHome);
      expect(shared.map((c) => c.rid), contains(danaEvent));
      expect(shared.where((c) => c.device == f.dana.deviceId), isNotEmpty);
    });

    test('X2: a device that never held the invitation key can\'t contest: its key-less "join" is refused on arrival, and never read as one', () async {
      final fork = await f.kHub.fork();
      final out = await DeviceKeys.generate();
      final outId = await out.deviceId();
      final ask = await forge(out, counter: 1, millis: clock.now, type: RecordType.device, rid: outId,
          fields: {'name': 'Outsider', 'kind': 'phone', 'pubkey': out.pubkey, 'mode': 'personal', 'approved': false, 'home': f.kotvasHome});
      final key = f.kHub.home(f.smithHome)!.key!;
      Map<String, Object?> junk() => {
            'invite': f.invitation.parent.invite,
            'member': f.gDana,
            'mode': 'personal',
            'key': key,
            'nonce': 'AAAAAAAAAAAAAAAAAAAAAA',
            'expires': clock.now + hour,
            'sig': 'AAAA',
          };
      final noKey = await forge(out, counter: 2, millis: clock.now + 1, type: RecordType.device, rid: outId, fields: {'home': f.smithHome, 'invite': junk()});
      final withKey = await forge(out, counter: 3, millis: clock.now + 2, type: RecordType.device, rid: outId,
          fields: {'home': f.smithHome, 'pubkey': out.pubkey, 'invite': junk()});
      final saysIn = await forge(out, counter: 4, millis: clock.now + 3, type: RecordType.home, rid: f.smithHome,
          fields: {'status': 'active', 'heard': <String>[]});
      final r = await fork.ingest([ask, noKey, withKey, saysIn]);
      expect(r.rejected.keys, containsAll([noKey.id, withKey.id]), reason: 'refused on arrival: no key of its own, or a proof the key didn\'t sign');
      expect(fork.homeContested(f.smithHome), isFalse);
      smithsIntact(f, fork);
      // And read straight into a materializer (past ingest), a key-less one is no window join.
      final starts = GroupStarts.of([...f.kHub.changesSince(const {}), ask, noKey, saysIn]..sort(changeOrder));
      expect(starts.windowJoins[f.smithHome]!.keys, isNot(contains(outId)));
      expect(starts.ended, isEmpty);
    });

    test('R12: contested beginnings converge, through snapshots and remove()', () async {
      final base = f.kHub.changesSince(const {}).toList();
      final danaAt = ownJoin(f.dana).hlc.millis;
      final (evil, j) = await joinWith(f, f.invitation.parent, danaAt - 300);
      final start = clock.now + day;
      final w = await forge(evil, counter: 2, millis: danaAt - 200, type: RecordType.event, rid: 'asdana', actor: f.gDana,
          fields: {'title': 'Forged', 'start': start, 'end': start + hour});
      final s = await sayIn(evil, f.smithHome, f.gDana, clock.now, counter: 3);
      final pool = [...base, j, w, s];
      TrustRoot root() => TrustRoot(familyId: f.group, founderPubkey: f.alex.founderPubkey);
      String digest(Materializer m) => jsonEncode({
            'rejected': (m.rejected.keys.toList()..sort()),
            'ended': {for (final e in m.store.endedHomes.entries) e.key: '${e.value.at} ${e.value.why}'},
            'forged': m.store.liveAt(Space.family, RecordType.event, 'asdana') != null,
          });
      final once = Materializer(root)..add(pool);
      final want = digest(once);
      expect(want, contains('contested'));
      expect(want, contains('"forged":false'), reason: 'what A wrote as Dana never counts');
      for (final seed in [1, 2, 3, 4]) {
        final random = Random(seed);
        final shuffled = [...pool]..shuffle(random);
        final m = Materializer(root);
        var i = 0;
        while (i < shuffled.length) {
          final n = 1 + random.nextInt(9);
          m.add(shuffled.sublist(i, min(i + n, shuffled.length)));
          i += n;
        }
        expect(digest(m), want, reason: 'seed $seed');
        final cut = shuffled.length ~/ 2;
        final first = Materializer(root)..add(shuffled.sublist(0, cut));
        final text = await first.capture(root: root(), windowFrom: clock.now - 40 * day, digest: const [0]).encode(breathe: () async {});
        final re = Materializer(root);
        final rest = re.restore(SnapshotHeader.parse(text)!, shuffled.sublist(0, cut), root: root());
        re.add([...?rest, ...shuffled.sublist(cut)]);
        expect(digest(re), want, reason: 'snapshot seed $seed');
      }
      final without = Materializer(root)..add([...base, j, w]);
      final m = Materializer(root)..add(pool);
      m.remove([s.id]);
      expect(digest(m), digest(without));
      expect(m.store.endedHomes, isEmpty);
    });

    test('X3: Dana opens the invitation twice (two browsers); the second, knowing of the first, won\'t say "we\'re in"', () async {
      final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
      final g = await kotvasGroup(clock);
      await inviteSmiths(g);
      final safari = await admit(g, g.invitation.parent, g.kHub, name: "Dana's phone (Safari)", family: g.smith);
      final homeScreen = await admit(g, g.invitation.parent, g.kHub, name: "Dana's phone (Home Screen)");
      // Each waits for a hub to hold its way in, and syncs once more, before saying it.
      expect(safari.joinHeldBy(g.kHub.versionVector), isTrue);
      expect(homeScreen.joinHeldBy(g.kHub.versionVector), isTrue);
      expect((await openDen(clock)).joinHeldBy(g.kHub.versionVector), isFalse);
      await exchange(safari, g.kHub);
      clock.advance(const Duration(seconds: 1));
      await expectLater(safari.updateHome(active: true, family: g.smith), throwsA(isA<InvalidInput>()));
      await expectLater(homeScreen.updateHome(active: true, family: null), throwsA(isA<InvalidInput>()));
      // Dana says which is hers: that one says it, the other is gone, nothing is contested.
      await safari.updateHome(active: true, family: g.smith, notOurs: true);
      await exchange(safari, g.kHub);
      expect(g.kHub.homeContested(g.smithHome), isFalse);
      expect(g.kHub.home(g.smithHome)!.status, HomeStatus.active);
      expect(g.kHub.deviceCounts(safari.deviceId), isTrue);
      expect(g.kHub.deviceCounts(homeScreen.deviceId), isFalse);
      // The other, hearing of it, can't say it now either, short of saying it wasn't Dana.
      await homeScreen.ingest(g.kHub.changesSince(homeScreen.versionVector));
      await expectLater(homeScreen.updateHome(active: true, family: null), throwsA(isA<InvalidInput>()));
    });

    test('X3: two phones saying it before either hears of the other: contested, with a hint it may have been the family twice', () async {
      final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
      final g = await kotvasGroup(clock);
      await inviteSmiths(g);
      final one = await admit(g, g.invitation.parent, g.kHub, name: "Dana's phone", family: g.smith);
      final two = await openDen(clock);
      await two.joinGroup(g.invitation.parent, deviceName: "Dana's tablet", kind: DeviceKind.tablet, family: null);
      await two.ingest(one.changesSince(const {}).where((c) => c.device != one.deviceId));
      clock.advance(const Duration(seconds: 1));
      await one.updateHome(active: true, family: g.smith);
      await two.updateHome(active: true, family: null);
      await g.kHub.ingest(two.changesSince(const {}));
      await exchange(one, g.kHub);
      expect(g.kHub.homeContested(g.smithHome), isTrue);
      final a = g.smith.groupAlarm(g.smith.groupLink(g.group)!, g.kHub)!;
      expect(a.kind, GroupAlarmKind.contested);
      expect(a.mayBeOurs, isTrue);
      expect(a.devices, unorderedEquals(["Dana's phone", "Dana's tablet"]));
    });

    test('a phone the invitation let in that someone else\'s "we\'re in" left out says so too, if it wasn\'t theirs: the family\'s place ends rather than someone else being them', () async {
      final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
      final g = await kotvasGroup(clock);
      await inviteSmiths(g);
      final dana = await admit(g, g.invitation.parent, g.kHub, name: "Dana's phone", family: g.smith);
      // The Kotvases, with the key, let in a device of their own and say the Smiths are in
      // before Dana's phone did.
      final (evil, p) = await joinWith(g, g.invitation.parent, ownJoin(dana).hlc.millis + 10);
      await g.kHub.ingest([p, await sayIn(evil, g.smithHome, g.gDana, ownJoin(dana).hlc.millis + 20, heard: [
        for (final c in g.kHub.changesSince(const {}))
          if (c.device == g.alex.deviceId && (c.rid == g.smithHome || c.rid == g.gDana || c.rid == g.invitation.parent.invite)) c.id,
      ])]);
      expect(g.kHub.closureFor(g.smithHome)!.author, await evil.deviceId());
      await dana.ingest(g.kHub.changesSince(dana.versionVector));
      clock.advance(const Duration(seconds: 1));
      expect(g.smith.groupAlarm(g.smith.groupLink(g.group)!, dana)?.kind, GroupAlarmKind.unanchored);
      await expectLater(dana.updateHome(active: true, family: g.smith), throwsA(isA<InvalidInput>()));
      await dana.updateHome(active: true, family: g.smith, notOurs: true);
      await g.kHub.ingest(dana.changesSince(g.kHub.versionVector));
      expect(g.kHub.homeContested(g.smithHome), isTrue);
      expect(g.kHub.deviceCounts(await evil.deviceId()), isFalse);
      expect(g.kHub.home(g.smithHome)!.ended, 'contested');
    });

    test('X4: look-alike families from a device the group never let in cost a replay nothing; one family\'s tries, and all retries, are capped', () async {
      final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
      final g = await bothFamilies(clock);
      final base = g.kHub.changesSince(const {}).toList();
      final out = await DeviceKeys.generate();
      final outId = await out.deviceId();
      var n = 0;
      final forged = <Change>[
        await forge(out, counter: ++n, millis: clock.now, type: RecordType.device, rid: outId,
            fields: {'name': 'X', 'kind': 'phone', 'pubkey': out.pubkey, 'mode': 'personal', 'approved': false, 'home': g.kotvasHome}),
      ];
      for (var i = 0; i < 30; i++) {
        final k = await InviteKey.generate();
        final h = homeIdFor(k.publicKey, outId);
        final proof = await k.prove(family: g.group, member: 'm$i', devicePubkey: out.pubkey, expires: clock.now + hour);
        forged
          ..add(await forge(out, counter: ++n, millis: clock.now + n, type: RecordType.home, rid: h,
              fields: {'name': 'Fake $i', 'status': 'invited', 'invitedBy': g.kotvasHome, 'key': k.publicKey}))
          ..add(await forge(out, counter: ++n, millis: clock.now + n, type: RecordType.device, rid: outId,
              fields: {'home': h, 'pubkey': out.pubkey, 'invite': proof.toJson()}))
          ..add(await forge(out, counter: ++n, millis: clock.now + n, type: RecordType.home, rid: h, fields: {'status': 'active', 'heard': <String>[]}));
      }
      TrustRoot root() => TrustRoot(familyId: g.group, founderPubkey: g.alex.founderPubkey);
      int passes(List<Change> pool) {
        final m = Materializer(root)..add(pool);
        final before = m.passes;
        m.replay();
        return m.passes - before;
      }

      final plain = passes(base), attacked = passes([...base, ...forged]);
      // ignore: avoid_print
      print('passes per full replay: $plain without, $attacked with 30 look-alike families (91 changes)');
      expect(attacked, plain);
    });
  });

  /// The fourth review of feat/groups-core (f63463b): Y2-Y5 and Y7, the reviewer's proofs with
  /// their assertions flipped where they showed bugs.
  group('the fourth review (Y2-Y5, Y7)', () {
    /// Both ways, each sending what the other lacks, without vouching for spaces (`through`): how
    /// a device syncs before the hub knows it (den_net sends `through` only to a peer whose
    /// spaces it knows).
    Future<void> swap(Den a, Den b) async {
      for (var round = 0; round < 2; round++) {
        await b.ingest(a.changesSince(b.versionVector));
        await a.ingest(b.changesSince(a.versionVector));
      }
    }

    /// A's contest of the Smiths, with the key it made: a device of its own let in as Dana just
    /// before her phone, saying the Smiths are in now.
    Future<List<Change>> contest(Families f, int now) async {
      final (evil, j) = await joinWith(f, f.invitation.parent, ownJoin(f.dana).hlc.millis - 100);
      return [j, await sayIn(evil, f.smithHome, f.gDana, now)];
    }

    group('ending the Smiths', () {
      final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
      late Families f;
      late Den kim, kimFamily, tam, tamFamily, jun;
      late GroupInvitation parks, tans, lees;
      late String kimEvent, junEvent;
      late int start;
      setUpAll(() async {
        f = await bothFamilies(clock);
        start = clock.now + 7 * day;
        // The Parks, invited by the Smiths (Dana), with their own anchor; Kim adds an event.
        await exchange(f.dana, f.kHub);
        clock.advance(const Duration(seconds: 1));
        parks = await f.dana.inviteFamily(familyName: 'Parks', parentName: 'Kim');
        await f.kHub.ingest(f.dana.changesSince(f.kHub.versionVector));
        kimFamily = await foundFamily(clock, name: 'Kim');
        clock.advance(const Duration(seconds: 1));
        kim = await openDen(clock);
        await kim.joinGroup(parks.parent, deviceName: "Kim's phone", kind: DeviceKind.phone, family: kimFamily);
        await f.kHub.ingest(kim.changesSince(const {}));
        await sync(f.kHub, kim);
        clock.advance(const Duration(seconds: 1));
        await kim.updateHome(active: true, family: kimFamily);
        kimEvent = await kim.addEvent(title: 'Park picnic', start: start, end: start + hour);
        await exchange(kim, f.kHub);
        // The Tans, invited by the Smiths too: Tam's phone lets itself in, and hasn't said they're in.
        clock.advance(const Duration(seconds: 1));
        tans = await f.dana.inviteFamily(familyName: 'Tans', parentName: 'Tam');
        await f.kHub.ingest(f.dana.changesSince(f.kHub.versionVector));
        tamFamily = await foundFamily(clock, name: 'Tam');
        tam = await admit(f, tans.parent, f.kHub, name: "Tam's phone", family: tamFamily);
        // The Lees, invited by the Kotvases; Jun names Dana as a driver on a Lee event.
        clock.advance(const Duration(seconds: 1));
        lees = await f.alex.inviteFamily(familyName: 'Lees', parentName: 'Jun');
        await exchange(f.alex, f.kHub);
        jun = await admit(f, lees.parent, f.kHub, name: "Jun's phone");
        clock.advance(const Duration(seconds: 1));
        await jun.updateHome(active: true, family: null);
        await exchange(jun, f.kHub);
        junEvent = newId();
        final ev = await forgeAs(jun, type: RecordType.event, rid: junEvent, actor: lees.member,
            fields: {'title': 'Lee party (Dana drives)', 'start': start, 'end': start + hour, 'drivers': {'to': f.gDana, 'from': null}});
        expect((await f.kHub.ingest([ev])).invalid, isEmpty);
        await exchange(kim, f.kHub);
        await exchange(tam, f.kHub);
        await settle(f);
        clock.advance(const Duration(days: 30));
      });

      test('Y2: a family the Smiths invited that said it was in (the Parks) stands: its place, its phone, its event; its alarm says nothing', () async {
        final fork = await f.kHub.fork();
        final link = kimFamily.groupLink(f.group)!;
        expect(link.home, parks.home);
        expect(kimFamily.groupAlarm(link, kim), isNull);
        final attack = await contest(f, clock.now);
        await fork.ingest(attack);
        expect(fork.homeContested(f.smithHome), isTrue);
        smithsEnded(f, fork);
        expect(fork.deviceCounts(kim.deviceId), isTrue, reason: 'the Parks were never contested');
        expect(fork.event(kimEvent), isNotNull);
        expect(fork.home(parks.home)!.status, HomeStatus.active);
        expect(fork.homeEnd(parks.home), isNull);
        expect(fork.closureFor(parks.home)!.author, kim.deviceId);
        // On Kim's own phone, once it hears: all is well.
        final kimView = await kim.fork();
        await kimView.ingest(fork.changesSince(kimView.versionVector));
        expect(kimView.deviceCounts(kim.deviceId), isTrue);
        expect(kimFamily.groupAlarm(link, kimView), isNull);
        // The Smiths' phones stay on record with their ended place; none of it shows or counts.
        expect(fork.history().where((h) => h.device == f.dana.deviceId), isEmpty);
        expect(fork.members.where((m) => m.home == f.smithHome), isEmpty);
      });

      test('Y2: a family the Smiths invited that hadn\'t said it was in (the Tans) ends with them, and its own alarm says why', () async {
        final fork = await f.kHub.fork();
        expect(fork.home(tans.home)!.status, HomeStatus.invited);
        final link = tamFamily.groupLink(f.group)!;
        expect(tamFamily.groupAlarm(link, tam), isNull);
        await fork.ingest(await contest(f, clock.now));
        final end = fork.homeEnd(tans.home)!;
        expect(end.began, isFalse);
        expect(end.invitedBy, f.smithHome);
        expect(end.at, fork.home(tans.home)!.rec.created);
        expect(fork.home(tans.home)!.ended, HomeEnd.inviterEnded);
        expect(fork.deviceCounts(tam.deviceId), isFalse);
        expect(fork.invitationOpen(tans.home), isFalse);
        // Tam's phone hears, and the Tans' own log tells it why.
        final tamView = await tam.fork();
        await tamView.ingest(fork.changesSince(tamView.versionVector));
        final alarm = tamFamily.groupAlarm(link, tamView)!;
        expect(alarm.kind, GroupAlarmKind.inviterEnded);
        expect(alarm.message, contains('Smiths'));
        await expectLater(tamView.updateHome(active: true, family: tamFamily), throwsA(isA<InvalidInput>()));
      });

      test('Y2: a device A let in with the Smiths\' key can\'t take the Parks down: removing Dana\'s phone, dated before she invited them, counts for nothing', () async {
        final fork = await f.kHub.fork();
        final (evil, j) = await joinWith(f, f.invitation.parent, ownJoin(f.dana).hlc.millis - 100);
        final parksAt = fork.home(parks.home)!.rec.created.millis;
        final removal = await forge(evil, counter: 2, millis: parksAt - 10, type: RecordType.device, rid: f.dana.deviceId, actor: f.gDana,
            fields: {'revoked': true, 'revokedAfter': ownJoin(f.dana).counter});
        final made = await forge(evil, counter: 3, millis: parksAt - 5, type: RecordType.member, rid: f.gDana, actor: f.gDana, fields: {'role': 'kid'});
        final r = await fork.ingest([j, removal, made, await sayIn(evil, f.smithHome, f.gDana, clock.now, counter: 4)]);
        expect(fork.homeContested(f.smithHome), isTrue);
        expect(r.invalid.keys, containsAll([removal.id, made.id]), reason: 'an ended family\'s records stay as they were made');
        expect(fork.deviceCounts(kim.deviceId), isTrue);
        expect(fork.event(kimEvent), isNotNull);
      });

      test('Y3: a third family\'s event that named Dana as a driver (the Lees\') stands; views drop her, and the leg needs a driver again', () async {
        final fork = await f.kHub.fork();
        Occurrence party(Den d) => d.occurrences(start - hour, start + 2 * hour).firstWhere((o) => o.event.id == junEvent);
        bool noDriver(Den d) => d.gaps(start - day, start + day).any((g) => g.kind == GapKind.noDriver && g.leg == 'to' && g.occurrences.single.event.id == junEvent);
        expect(party(fork).rides.firstWhere((r) => r.leg == 'to').driver, f.gDana);
        expect(noDriver(fork), isFalse);
        await fork.ingest(await contest(f, clock.now));
        expect(fork.deviceCounts(jun.deviceId), isTrue, reason: 'the Lees themselves are fine');
        expect(fork.event(junEvent), isNotNull, reason: 'and so is their event, for everyone');
        expect(party(fork).rides.firstWhere((r) => r.leg == 'to').driver, isNull, reason: 'the Smiths aren\'t in the group: Dana drives nobody');
        expect(noDriver(fork), isTrue);
        // Named once the Smiths are gone, she isn't someone of the group who drives (the engine
        // says so before it signs: the Smiths read as left).
        final junView = await jun.fork();
        await junView.ingest(fork.changesSince(junView.versionVector));
        await expectLater(junView.claimRide(junEvent, occurrence: start, leg: 'from', driver: f.gDana), throwsA(isA<InvalidInput>()));
      });

      test('Y4: an item the Lees added to a Smith list goes with the Smiths; attachedToHome lists it for the Lees to keep', () async {
        final list = await f.dana.addList(title: 'Snacks', kind: ListKind.shopping);
        await exchange(f.dana, f.kHub);
        await sync(f.kHub, jun);
        final item = await jun.addItem(list, text: 'Juice boxes (from the Lees)');
        await jun.setItemChecked(item, true);
        await exchange(jun, f.kHub);
        final fork = await f.kHub.fork();
        expect(fork.list(list)!.items.map((i) => i.id), contains(item));
        await fork.ingest(await contest(f, clock.now));
        expect(fork.list(list), isNull, reason: 'what hangs on the Smiths\' records goes with them');
        expect(fork.deviceCounts(jun.deviceId), isTrue);
        final attached = fork.attachedToHome(f.smithHome);
        expect(attached.where((c) => c.rid == item), hasLength(2), reason: 'the item, and checking it');
        expect(attached.every((c) => c.device != f.dana.deviceId), isTrue);
        expect(fork.sharedByHome(f.smithHome).map((c) => c.rid), contains(list));
        expect(fork.sharedByHome(f.smithHome).map((c) => c.rid), isNot(contains(item)));
      });

      test('a family\'s anchor to a home the group has no record of raises "missing", once the group\'s log is there', () async {
        final other = await foundFamily(clock, name: 'Pat');
        await other.writeGroupLink(group: f.group, founder: f.alex.founderPubkey!, name: 'Cousins soccer', home: 'NOSUCHHOME', device: 'x');
        final link = other.groupLink(f.group)!;
        expect(other.groupAlarm(link, f.kHub)?.kind, GroupAlarmKind.missing);
        expect(other.groupAlarm(link, await openDen(clock)), isNull, reason: 'before the group\'s log arrives there is nothing to compare');
      });
    });

    test('Y5: a device that took the group\'s changes before it joined reads them as every other replica does, then and after reopening', () async {
      final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
      final f = await bothFamilies(clock);
      // A new Kotvas tablet: the app shows the group before it joins (it syncs first).
      final storage = MemoryStorage();
      final keys = await DeviceKeys.generate();
      final tablet = await openDen(clock, storage: storage, keys: keys);
      final early = await tablet.ingest(f.kHub.changesSince(const {}));
      expect(early.pending, greaterThan(0), reason: 'the proofs wait for the group\'s id (Y5b)');
      final k = await InviteKey.generate();
      await f.alex.createInviteKey(member: f.gAlex, publicKey: k.publicKey, expires: clock.now + hour);
      await exchange(f.alex, f.kHub);
      clock.advance(const Duration(seconds: 1));
      await tablet.joinGroup(
          GroupAdmission(group: f.group, founder: f.alex.founderPubkey!, name: 'x', home: f.kotvasHome, member: f.gAlex,
              mode: DeviceMode.personal, invite: k.id, seed: await k.seed(), expires: clock.now + 30 * minute),
          deviceName: 'Tablet',
          kind: DeviceKind.tablet,
          family: null);
      expect(tablet.isGroup, isTrue);
      await swap(tablet, f.kHub);
      expect(f.kHub.home(f.smithHome)!.status, HomeStatus.active);
      expect(tablet.closureFor(f.smithHome)?.id, f.kHub.closureFor(f.smithHome)!.id);
      expect(tablet.home(f.smithHome)!.status, HomeStatus.active);
      for (final d in [...f.kotvasDevices, ...f.smithDevices, tablet]) {
        expect(tablet.deviceCounts(d.deviceId), f.kHub.deviceCounts(d.deviceId), reason: d.deviceId);
      }
      expect(jsonEncode(tablet.exportJson()), jsonEncode(f.kHub.exportJson()));
      // Reopened, and as a replica that took everything at once after a root.
      final reopened = await openDen(clock, storage: storage, keys: keys);
      expect(jsonEncode(reopened.exportJson()), jsonEncode(f.kHub.exportJson()));
      TrustRoot root() => TrustRoot(familyId: f.group, founderPubkey: f.alex.founderPubkey);
      final fresh = Materializer(root)..add(f.kHub.changesSince(const {}));
      expect(fresh.starts.ended, isEmpty);
      expect(fresh.validator.retiredRecoveryKeys.closures.map((w) => w.id), contains(f.kHub.closureFor(f.smithHome)!.id));
    });

    test('Y5b: a proof that arrives before this device knows the group is held back, not stored unchecked; after joining and reopening it sees what every replica sees', () async {
      final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
      final f = await bothFamilies(clock);
      clock.advance(const Duration(days: 1));
      // An outsider's junk-signed "join" with the Smiths' invitation key, and its "we're in".
      final out = await DeviceKeys.generate();
      final outId = await out.deviceId();
      final key = f.kHub.home(f.smithHome)!.key!;
      final junk = await forge(out, counter: 1, millis: clock.now, type: RecordType.device, rid: outId, fields: {
        'name': 'X', 'kind': 'phone', 'pubkey': out.pubkey, 'member': f.gDana, 'mode': 'personal', 'approved': true, 'home': f.smithHome, //
        'invite': {'invite': f.invitation.parent.invite, 'member': f.gDana, 'mode': 'personal', 'key': key, 'nonce': 'AAAAAAAAAAAAAAAAAAAAAA', 'expires': clock.now + hour, 'sig': 'AAAA'},
      });
      final saysIn = await forge(out, counter: 2, millis: clock.now + 1, type: RecordType.home, rid: f.smithHome, actor: f.gDana,
          fields: {'status': 'active', 'heard': <String>[]});
      expect((await (await f.kHub.fork()).ingest([junk, saysIn])).rejected, contains(junk.id), reason: 'a replica with a root refuses it');
      // A new Kotvas tablet syncs the group (and these) before it joins.
      final storage = MemoryStorage();
      final keys = await DeviceKeys.generate();
      final tablet = await openDen(clock, storage: storage, keys: keys);
      final r = await tablet.ingest([...f.kHub.changesSince(const {}), junk, saysIn]);
      expect(r.rejected, isEmpty);
      expect(r.pending, greaterThan(0), reason: 'held back until it knows the group');
      expect((await storage.loadChanges()).map((c) => c.id), isNot(contains(junk.id)), reason: 'never stored unchecked');
      final k = await InviteKey.generate();
      await f.alex.createInviteKey(member: f.gAlex, publicKey: k.publicKey, expires: clock.now + hour);
      await exchange(f.alex, f.kHub);
      clock.advance(const Duration(seconds: 1));
      await tablet.ingest(f.kHub.changesSince(tablet.versionVector));
      await tablet.joinGroup(
          GroupAdmission(group: f.group, founder: f.alex.founderPubkey!, name: 'x', home: f.kotvasHome, member: f.gAlex,
              mode: DeviceMode.personal, invite: k.id, seed: await k.seed(), expires: clock.now + 30 * 60000),
          deviceName: 'Tablet',
          kind: DeviceKind.tablet,
          family: null);
      await swap(tablet, f.kHub);
      expect((await storage.loadChanges()).map((c) => c.id), isNot(contains(junk.id)), reason: 'checked once it knew the group: refused');
      final reopened = await openDen(clock, storage: storage, keys: keys);
      expect(reopened.homeContested(f.smithHome), isFalse);
      expect(f.kHub.homeContested(f.smithHome), isFalse);
      expect(jsonEncode(reopened.exportJson()), jsonEncode(f.kHub.exportJson()));
    });

    test('a change refused on arrival for the proof it carries counts as held, so it isn\'t sent again; one whose own signature fails never does', () async {
      final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
      final f = await bothFamilies(clock);
      final fork = await f.kHub.fork();
      final out = await DeviceKeys.generate();
      final outId = await out.deviceId();
      final junk = await forge(out, counter: 1, millis: clock.now, type: RecordType.device, rid: outId, fields: {
        'name': 'X', 'kind': 'phone', 'pubkey': out.pubkey, 'member': f.gDana, 'mode': 'personal', 'approved': true, 'home': f.smithHome, //
        'invite': {'invite': f.invitation.parent.invite, 'member': f.gDana, 'mode': 'personal', 'key': f.kHub.home(f.smithHome)!.key, 'nonce': 'AAAAAAAAAAAAAAAAAAAAAA', 'expires': clock.now + hour, 'sig': 'AAAA'},
      });
      final next = await forge(out, counter: 2, millis: clock.now + 1, type: RecordType.device, rid: outId, fields: {'name': 'Y'});
      final r = await fork.ingest([junk, next]);
      expect(r.rejected.keys, [junk.id]);
      expect(fork.versionVector[outId], 2, reason: 'the refused one counts as held: its senders don\'t send it again');
      expect(fork.changesSince(const {}).map((c) => c.id), isNot(contains(junk.id)), reason: 'verdicts untouched: it is never in the log');
      // One whose signature fails could be anyone's: counting it would keep the real one out.
      final real = await forgeAs(f.alex, type: RecordType.event, rid: newId(), actor: f.gAlex,
          fields: {'title': 'Real', 'start': clock.now + day, 'end': clock.now + day + hour});
      final fake = Change(id: real.id, space: real.space, hlc: real.hlc, type: real.type, rid: real.rid, fields: {...real.fields, 'title': 'Fake'},
          device: real.device, actor: real.actor, sig: real.sig);
      final before = fork.versionVector[f.alex.deviceId];
      expect((await fork.ingest([fake])).rejected.keys, [fake.id]);
      expect(fork.versionVector[f.alex.deviceId], before);
      expect((await fork.ingest([real])).added, 1);
    });

    test('Y7: contested endings, and the family they invited that stands, converge through shuffles, snapshots and remove()', () async {
      final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
      final f = await bothFamilies(clock);
      final parks = await f.dana.inviteFamily(familyName: 'Parks', parentName: 'Kim');
      await exchange(f.dana, f.kHub);
      final kim = await admit(f, parks.parent, f.kHub, name: "Kim's phone");
      clock.advance(const Duration(seconds: 1));
      await kim.updateHome(active: true, family: null);
      await exchange(kim, f.kHub);
      clock.advance(const Duration(days: 30));
      final base = f.kHub.changesSince(const {}).toList();
      final danaAt = ownJoin(f.dana).hlc.millis;
      final (evil, j) = await joinWith(f, f.invitation.parent, danaAt - 300);
      final start = clock.now + day;
      // A writes as Dana inside the window (X1), then contests.
      final w = await forge(evil, counter: 2, millis: danaAt - 200, type: RecordType.event, rid: 'asdana', actor: f.gDana,
          fields: {'title': 'Forged', 'start': start, 'end': start + hour});
      final s = await sayIn(evil, f.smithHome, f.gDana, clock.now, counter: 3);
      final pool = [...base, j, w, s];
      TrustRoot root() => TrustRoot(familyId: f.group, founderPubkey: f.alex.founderPubkey);
      String digest(Materializer m) => jsonEncode({
            'rejected': (m.rejected.keys.toList()..sort()),
            'ended': {for (final e in m.store.endedHomes.entries) e.key: '${e.value.at} ${e.value.why}'},
            'forged': m.store.liveAt(Space.family, RecordType.event, 'asdana') != null,
            'parks': m.store.at(Space.family, RecordType.home, parks.home)?.fields['status'],
            'closures': [for (final c in m.validator.retiredRecoveryKeys.closures) c.id]..sort(),
          });
      final want = digest(Materializer(root)..add(pool));
      expect(want, contains('contested'));
      expect(want, contains('"forged":false'));
      expect(want, contains('"parks":"active"'));
      for (final seed in [1, 2, 3, 4]) {
        final random = Random(seed);
        final shuffled = [...pool]..shuffle(random);
        final m = Materializer(root);
        var i = 0;
        while (i < shuffled.length) {
          final n = 1 + random.nextInt(9);
          m.add(shuffled.sublist(i, min(i + n, shuffled.length)));
          i += n;
        }
        expect(digest(m), want, reason: 'seed $seed');
        // A snapshot taken part way, reopened, then the rest.
        final cut = shuffled.length ~/ 2;
        final first = Materializer(root)..add(shuffled.sublist(0, cut));
        final text = await first.capture(root: root(), windowFrom: clock.now - 40 * day, digest: const [0]).encode(breathe: () async {});
        final re = Materializer(root);
        final rest = re.restore(SnapshotHeader.parse(text)!, shuffled.sublist(0, cut), root: root());
        re.add([...?rest, ...shuffled.sublist(cut)]);
        expect(digest(re), want, reason: 'snapshot seed $seed');
      }
      // remove(): taking A's "we're in" back gives what a log without it gives.
      final without = Materializer(root)..add([...base, j, w]);
      final m = Materializer(root)..add(pool);
      m.remove([s.id]);
      expect(digest(m), digest(without));
      expect(m.store.endedHomes, isEmpty);
    });
  });
}
