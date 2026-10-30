import 'dart:math';

import 'package:den_core/den_core.dart';
import 'package:den_core/src/materializer.dart';
import 'package:den_core/src/validity.dart';
import 'package:test/test.dart';

import 'group_support.dart';
import 'support.dart';

/// Attacks by the inviting family (the Kotvases, "A") on the family it invited (the Smiths, "B"),
/// from the independent review of feat/groups-core (R1-R11), each now refused: once B's own
/// parent says B is in, A's window over B is shut (groups.dart, WindowClosure), and nothing A
/// does after, or dates before without B having held it, counts. Signed past the engines' own
/// checks, the way a misbehaving device would, and judged by a replica.
void main() {
  const minute = 60000;
  const hour = 60 * minute;
  const day = 24 * hour;

  Change ownJoin(Den d) =>
      d.changesSince(const {}).firstWhere((c) => c.device == d.deviceId && c.type == RecordType.device && c.rid == d.deviceId);

  /// The change that said B is in (and closed A's window).
  Change activation(Families f) =>
      f.dana.changesSince(const {}).firstWhere((c) => c.type == RecordType.home && c.rid == f.smithHome && c.fields.containsKey('closed'));

  /// A fresh device joining with [admission]'s key, clocked at [millis] (forged: no engine checks).
  Future<(DeviceKeys, Change)> joinWith(Families f, GroupAdmission admission, int millis) async {
    final keys = await DeviceKeys.generate();
    final key = await admission.key();
    final nonce = b64e(randomBytes(16));
    final exp = admission.expires;
    final sig = await key.sign(InviteProof.bytes(
      family: f.group,
      invite: key.id,
      member: admission.member,
      mode: admission.mode,
      devicePubkey: keys.pubkey,
      nonce: nonce,
      expires: exp,
    ));
    final c = await forge(keys, counter: 1, millis: millis, type: RecordType.device, rid: await keys.deviceId(), fields: {
      'name': 'Evil',
      'kind': admission.mode == DeviceMode.hub ? 'hub' : 'phone',
      'pubkey': keys.pubkey,
      'xpub': keys.xpub,
      'member': admission.member,
      'mode': admission.mode.name,
      'approved': true,
      'home': admission.home,
      'invite': InviteProof(invite: key.id, member: admission.member, mode: admission.mode, key: key.publicKey, nonce: nonce, expires: exp, sig: sig)
          .toJson(),
    });
    return (keys, c);
  }

  void smithsIntact(Families f, Den replica) {
    expect(replica.deviceCounts(f.dana.deviceId), isTrue, reason: 'Dana\'s phone');
    expect(replica.deviceCounts(f.sHub.deviceId), isTrue, reason: 'the Smith hub');
    expect(replica.deviceCounts(f.mia.deviceId), isTrue, reason: 'Mia\'s tablet');
    expect(replica.home(f.smithHome)!.status, HomeStatus.active);
    expect(replica.members.where((m) => m.id == f.gMia), isNotEmpty);
    expect(replica.invitationOpen(f.smithHome), isFalse);
  }

  group('A, a month after B is in', () {
    final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
    late Families f;
    late int joinedAt;
    setUpAll(() async {
      f = await bothFamilies(clock);
      joinedAt = ownJoin(f.dana).hlc.millis;
      clock.advance(const Duration(days: 30));
    });

    /// [c] on a fork of the Kotvas hub; its reason, or null when it counted.
    Future<(Den, String?)> judge(Change c) async {
      final fork = await f.kHub.fork();
      final r = await fork.ingest([c]);
      return (fork, r.invalid[c.id]);
    }

    test('R1: taking the window keys back, now or dated inside the window, erases nothing', () async {
      for (final millis in [null, joinedAt + 1]) {
        final fork = await f.kHub.fork();
        final w1 = await forgeAs(f.alex, type: RecordType.inviteKey, rid: f.invitation.parent.invite, actor: f.gAlex, millis: millis,
            fields: {'key': null, 'kept': <String>[]});
        final w2 = await forgeAs(f.alex, type: RecordType.inviteKey, rid: f.invitation.hub.invite, actor: f.gAlex, skip: 1,
            millis: millis == null ? null : millis + 1, fields: {'key': null, 'kept': <String>[]});
        final r = await fork.ingest([w1, w2]);
        expect(r.invalid.keys, containsAll([w1.id, w2.id]), reason: 'dated ${millis == null ? 'now' : 'in the window'}');
        smithsIntact(f, fork);
      }
    });

    test('R2: "That wasn\'t them", now or dated inside the window, erases nothing, and A gets no new key in', () async {
      final join = ownJoin(f.dana);
      final (now, why) = await judge(await forgeAs(f.alex, type: RecordType.device, rid: f.dana.deviceId, actor: f.gAlex,
          fields: {'revoked': true, 'revokedAfter': join.counter}));
      expect(why, contains('own parents'));
      smithsIntact(f, now);
      final (backdated, why2) = await judge(await forgeAs(f.alex, type: RecordType.device, rid: f.dana.deviceId, actor: f.gAlex,
          millis: joinedAt + 1, fields: {'revoked': true, 'revokedAfter': join.counter}));
      expect(why2, contains('said it was in'));
      smithsIntact(f, backdated);
      // Nor may A make a fresh window key for Dana, now or dated inside the window.
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
        final adm = GroupAdmission(
            group: f.group,
            founder: f.alex.founderPubkey!,
            name: 'x',
            home: f.smithHome,
            member: f.gDana,
            mode: DeviceMode.personal,
            invite: k.id,
            seed: await k.seed(),
            expires: (millis ?? clock.now) + 30 * minute);
        final (evil, joinC) = await joinWith(f, adm, (millis ?? clock.now) + 5);
        expect((await fork.ingest([joinC])).invalid[joinC.id], isNotNull);
        final hijack = await forge(evil, counter: 2, millis: clock.now + 10, type: RecordType.home, rid: f.smithHome, actor: f.gDana,
            fields: {'hubs': ['https://evil.example/ws']});
        expect((await fork.ingest([hijack])).invalid[hijack.id], isNotNull);
        expect(fork.home(f.smithHome)!.hubs, ['https://den.smith.example/ws']);
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
    });

    test('R5: devices let in with the invitation\'s own keys, dated before B\'s, count for nothing; B\'s real ones stay', () async {
      final fork = await f.kHub.fork();
      final danaAt = ownJoin(f.dana).hlc.millis;
      final hubAt = ownJoin(f.sHub).hlc.millis;
      final (evil, p) = await joinWith(f, f.invitation.parent, danaAt - 100);
      final (evilHub, h) = await joinWith(f, f.invitation.hub, hubAt - 100);
      final r = await fork.ingest([p, h]);
      expect(r.invalid.keys, containsAll([p.id, h.id]));
      expect(fork.deviceCounts(await evil.deviceId()), isFalse);
      expect(fork.deviceCounts(await evilHub.deviceId()), isFalse);
      smithsIntact(f, fork);
      final list = await forge(evilHub, counter: 2, millis: clock.now, type: RecordType.list, rid: newId(), actor: f.gDana,
          fields: {'title': 'Planted', '_via': 'Claude'});
      expect((await fork.ingest([list])).invalid[list.id], isNotNull);
      // And the same with a window key A makes afresh, dated inside the window too.
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

    test('known limit: a forged join AND a forged "we\'re in", both dated inside the window, still replace B\'s beginning', () async {
      // With keys the inviting family made and kept (the invitation's bearer key), it can still
      // write an alternative beginning for the invited family: a device of its own let in with
      // the key, saying the family is in before the real parent's phone did. No rule that reads
      // only the log tells it from the real beginning. ARCHITECTURE.md, "Groups of families",
      // says so; closing it needs the invited parent's own key in the invitation before it is
      // used. This test records the limit, so a change to it is noticed.
      final fork = await f.kHub.fork();
      final danaAt = ownJoin(f.dana).hlc.millis;
      final (evil, p) = await joinWith(f, f.invitation.parent, danaAt - 100);
      final evilId = await evil.deviceId();
      final inviter = [for (final d in f.kHub.devices) if (d.home == f.kotvasHome) d.id];
      final fakeIn = await forge(evil, counter: 2, millis: danaAt - 50, type: RecordType.home, rid: f.smithHome, actor: f.gDana, fields: {
        'status': 'active',
        'closed': {for (final d in inviter) d: 1000000},
        'kept': [evilId],
      });
      await fork.ingest([p, fakeIn]);
      expect(fork.deviceCounts(evilId), isTrue);
      expect(fork.deviceCounts(f.dana.deviceId), isFalse);
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
      expect(refused.where((c) => c.rid == f.smithHome || c.fields['key'] == null), isNotEmpty);
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

  test('R10: a spare hub key A made in the window lets nothing in once the Smiths are in', () async {
    final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
    final f = await kotvasGroup(clock);
    await inviteSmiths(f);
    final spare = await InviteKey.generate();
    await f.alex.createInviteKey(
        member: null, publicKey: spare.publicKey, expires: clock.now + 6 * day, modes: const {DeviceMode.hub}, home: f.smithHome);
    await exchange(f.alex, f.kHub);
    final spareMadeAt = clock.now;
    await smithsJoin(f);
    clock.advance(const Duration(days: 2));
    final fork = await f.kHub.fork();
    // The Smiths remove their own hub (to replace it).
    final hubLast = f.sHub.changesSince(const {}).where((c) => c.device == f.sHub.deviceId).map((c) => c.counter).reduce(max);
    final rm = await forgeAs(f.dana, type: RecordType.device, rid: f.sHub.deviceId, actor: f.gDana,
        fields: {'revoked': true, 'revokedAfter': hubLast});
    expect((await fork.ingest([rm])).invalid, isEmpty);
    clock.advance(const Duration(minutes: 1));
    for (final at in [clock.now, spareMadeAt + 1000]) {
      final adm = GroupAdmission(group: f.group, founder: f.alex.founderPubkey!, name: 'x', home: f.smithHome, member: null,
          mode: DeviceMode.hub, invite: spare.id, seed: await spare.seed(), expires: clock.now + hour);
      final (evilHub, j) = await joinWith(f, adm, at);
      final judged = await fork.fork();
      expect((await judged.ingest([j])).invalid[j.id], isNotNull, reason: 'joined ${at == clock.now ? 'now' : 'dated in the window'}');
      expect(judged.deviceCounts(await evilHub.deviceId()), isFalse);
    }
  });

  test('R11: the attacks give the same verdicts in every arrival order', () async {
    final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
    final f = await bothFamilies(clock);
    final invitedAt = f.kHub.home(f.smithHome)!.rec.created.millis;
    clock.advance(const Duration(days: 30));
    const hour = 3600000;
    final base = f.kHub.changesSince(const {}).toList();
    final danaJoin = ownJoin(f.dana);
    final sHubJoin = ownJoin(f.sHub);
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
    final w2 = await forgeAs(f.alex, type: RecordType.inviteKey, rid: f.invitation.hub.invite, actor: f.gAlex, skip: 3,
        fields: {'key': null, 'kept': <String>[]});
    final take = await forgeAs(f.alex, type: RecordType.home, rid: f.smithHome, actor: f.gAlex, skip: 4, millis: invitedAt + 500,
        fields: {'status': 'left'});
    final (_, fakeJoin) = await joinWith(f, f.invitation.parent, danaJoin.hlc.millis - 100);
    final attacks = [revoke, backdatedRevoke, made, w2, take, fakeJoin];
    final pool = [...base, ...attacks];
    TrustRoot root() => TrustRoot(familyId: f.group, founderPubkey: f.alex.founderPubkey);
    final once = Materializer(root)..add(pool);
    for (final c in attacks) {
      expect(once.rejected.containsKey(c.id), isTrue, reason: 'attack ${attacks.indexOf(c)}');
    }
    expect(once.rejected.containsKey(danaJoin.id), isFalse);
    expect(once.rejected.containsKey(sHubJoin.id), isFalse);
    expect(once.rejected.containsKey(activation(f).id), isFalse);
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
}
