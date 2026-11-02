import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// `member.account`: which Google or Apple account signs in as someone (account.dart). Binding
/// one is a trust decision a parent makes for themselves on their own personal device, with the
/// hub's proof that the account really signed in for them; the hub, a connection through it, a
/// shared screen and other people can't.
void main() {
  late TestClock clock;
  late Den phone;
  late Den hub;
  late String dana;
  late String sam;
  late String leo;
  late AccountRef google;

  /// The hub's proof that [member] signed in with the [provider] account [sub].
  Future<AccountRef> proved(String member, String sub, {String provider = 'google', Den? by, int? expires}) {
    final signer = by ?? hub;
    return AccountProof.sign(
      keys: signer.keys,
      hub: signer.deviceId,
      family: phone.familyId!,
      member: member,
      provider: provider,
      hash: accountHash(phone.familyId!, provider, sub),
      nonce: b64e(randomBytes(32)),
      expires: expires ?? clock.now + accountProofLife.inMilliseconds,
    );
  }

  Future<Change> forged(Den by, String rid, Map<String, Object?> fields, {String? actor, int counter = 900, int? millis}) => forge(
        by.keys,
        counter: counter,
        millis: millis ?? clock.now + 10,
        type: RecordType.member,
        rid: rid,
        fields: fields,
        actor: actor ?? by.actor?.id ?? by.owner?.id,
      );

  setUp(() async {
    clock = TestClock.at(DateTime.utc(2026, 10, 30, 15));
    phone = await foundFamily(clock);
    dana = phone.actor!.id;
    sam = await phone.addMember(name: 'Sam', role: Role.parent);
    leo = await phone.addMember(name: 'Leo', role: Role.kid, tier: Tier.big);
    hub = await joinDevice(phone, clock, mode: DeviceMode.hub, name: 'Hub', kind: DeviceKind.hub);
    google = await proved(dana, '1088123');
  });

  group('the hash', () {
    test('is keyed by the family, so two families can\'t match up the same person', () {
      final a = accountHash('family-a', 'google', '1088123');
      final b = accountHash('family-b', 'google', '1088123');
      expect(a, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(a, isNot(b));
      expect(accountHash('family-a', 'google', '1088123'), a, reason: 'every replica computes the same one');
      expect(accountHash('family-a', 'apple', '1088123'), isNot(a), reason: 'the provider is part of it');
      expect(accountHash('family-a', 'google', '10881234'), isNot(a));
    });

    test('frames the provider and the subject apart', () {
      // "google" + "x\0y" can't collide with "googlex" + "y": the parts are separated by NUL.
      expect(accountHash('f', 'google', 'a'), isNot(accountHash('f', 'googlea', '')));
    });
  });

  test('a parent binds their own account on their own phone, with the hub\'s proof, and every replica sees it', () async {
    final tablet = await joinDevice(phone, clock, member: dana, name: 'Dana tablet');
    await phone.setAccount(dana, google);
    expect(phone.member(dana)!.account, google);
    expect(phone.member(dana)!.account!.proof!.hub, hub.deviceId);
    await sync(phone, tablet);
    expect(tablet.member(dana)!.account, google);
    expect(tablet.memberWithAccount(google)?.id, dana);
    // And takes it away again.
    await tablet.setAccount(dana, null);
    await sync(tablet, phone);
    expect(phone.member(dana)!.account, isNull);
    expect(phone.memberWithAccount(google), isNull);
  });

  test('the field holds a provider, a hash and the hub\'s proof, never an email', () async {
    final good = google.toJson();
    final bad = <Object?>[
      {...good, 'email': 'dana@example.com'},
      {...good, 'hash': 'dana@example.com'},
      {...good, 'provider': 'github'},
      {'provider': 'google', 'hash': google.hash},
      {...good}..remove('sig'),
      'dana@example.com',
    ];
    for (final value in bad) {
      expect(checkFields(RecordType.member, {'account': value}, creating: false), isNotNull, reason: '$value');
    }
    expect(checkFields(RecordType.member, {'account': good}, creating: false), isNull);
    expect(checkFields(RecordType.member, {'account': null}, creating: false), isNull);
  });

  group('the hub\'s proof (review finding F3)', () {
    test('a hash someone computed, with no sign-in behind it, binds nothing, however it is clocked', () async {
      // Sam knows the family id and Dana's Google id, and Dana bound her account honestly.
      final samPhone = await joinDevice(phone, clock, member: sam, name: 'Sam phone');
      clock.advance(const Duration(hours: 1));
      await phone.setAccount(dana, await proved(dana, 'dana-gaia-id'));
      await sync(phone, samPhone);
      final danas = AccountRef('google', accountHash(phone.familyId!, 'google', 'dana-gaia-id'));
      expect(samPhone.memberWithAccount(danas)?.id, dana);
      final before = clock.now - const Duration(minutes: 30).inMilliseconds;
      // Without a proof: refused by every replica.
      final bare = await forged(samPhone, sam, {'account': {'provider': 'google', 'hash': danas.hash}}, millis: before, counter: 500);
      expect((await phone.ingest([bare])).invalid.keys, [bare.id]);
      // With Dana's own proof copied across: it is for Dana, so its signature doesn't hold for Sam.
      final copied = await forged(samPhone, sam, {'account': phone.member(dana)!.account!.toJson()}, millis: before, counter: 501);
      expect((await phone.ingest([copied])).rejected.keys, [copied.id]);
      // With a proof Sam's own phone signed, pretending to be the hub.
      final selfMade = await proved(sam, 'dana-gaia-id', by: samPhone);
      final fake = await forged(samPhone, sam, {'account': selfMade.toJson()}, millis: before, counter: 502);
      expect((await phone.ingest([fake])).invalid.keys, [fake.id]);
      await expectLater(samPhone.setAccount(sam, danas), throwsA(isA<PermissionDenied>()));
      // Dana keeps hers, and her sign-in is still hers.
      expect(phone.member(dana)!.account, danas);
      expect(phone.member(sam)!.account, isNull);
      expect(phone.memberWithAccount(danas)?.id, dana);
    });

    test('a proof whose hash or member was changed doesn\'t hold', () async {
      final json = google.toJson();
      final other = await forged(phone, dana, {'account': {...json, 'hash': accountHash(phone.familyId!, 'google', 'x')}});
      expect((await hub.ingest([other])).rejected.keys, [other.id]);
      await expectLater(phone.setAccount(dana, AccountRef('apple', google.hash, proof: google.proof)), throwsA(isA<PermissionDenied>()));
    });

    test('only an approved hub of the family vouches, and not once it is removed', () async {
      await phone.revokeDevice(hub.deviceId);
      final afterRemoval = await proved(dana, '1088123');
      await expectLater(phone.setAccount(dana, afterRemoval), throwsA(isA<PermissionDenied>()));
      final f = await forged(phone, dana, {'account': afterRemoval.toJson()});
      final tablet = await joinDevice(phone, clock, member: dana, name: 'Dana tablet');
      expect((await tablet.ingest([f])).invalid.keys, [f.id]);
    });

    test('a proof is good for a while, not forever', () async {
      final stale = await proved(dana, '1088123', expires: clock.now + 1000);
      clock.advance(const Duration(seconds: 2));
      await expectLater(phone.setAccount(dana, stale), throwsA(isA<PermissionDenied>()));
      final tooLong = await proved(dana, '1088123', expires: clock.now + const Duration(days: 2).inMilliseconds);
      await expectLater(phone.setAccount(dana, tooLong), throwsA(isA<PermissionDenied>()));
    });
  });

  test('nobody binds someone else\'s account, a parent included', () async {
    final samAccount = await proved(sam, 'sam-sub');
    await expectLater(phone.setAccount(sam, samAccount), throwsA(isA<PermissionDenied>()));
    // Forged past the engine's own check: every replica refuses it.
    final f = await forged(phone, sam, {'account': samAccount.toJson()}, actor: dana);
    final other = await joinDevice(phone, clock, member: dana, name: 'Dana tablet');
    expect((await other.ingest([f])).invalid.keys, [f.id]);
    expect(other.member(sam)!.account, isNull);
  });

  test('a kid can\'t bind one, even their own, on their own phone', () async {
    final kidPhone = await joinDevice(phone, clock, member: leo, name: 'Leo phone');
    final leoAccount = await proved(leo, 'leo-sub');
    await expectLater(kidPhone.setAccount(leo, leoAccount), throwsA(isA<PermissionDenied>()));
    final f = await forged(kidPhone, leo, {'account': leoAccount.toJson()}, actor: leo);
    expect((await phone.ingest([f])).invalid.keys, [f.id]);
  });

  group('the hub can never write it', () {
    late Den ownHub;

    setUp(() async {
      // A parent's own phone running as the family's hub: its owner using it still can't, since
      // the hub is what checks the sign-in.
      ownHub = await joinDevice(phone, clock, member: dana, mode: DeviceMode.hub, name: 'Dana phone (hub)');
    });

    test('through the engine', () async {
      for (final den in [hub, ownHub]) {
        den.actAs(dana);
        await expectLater(den.setAccount(dana, google), throwsA(isA<PermissionDenied>()));
        den.actAs(dana, via: 'Claude');
        await expectLater(den.setAccount(dana, google), throwsA(isA<PermissionDenied>()));
        await expectLater(den.updateMember(dana, {'account': google.toJson()}), throwsA(isA<InvalidInput>()));
        den.actAs(null);
      }
    });

    test('forged, as its owner or for a connection (_via), it is invalid on every replica', () async {
      var counter = 900;
      for (final den in [hub, ownHub]) {
        for (final via in [null, 'Claude']) {
          final f = await forged(den, dana, {'account': google.toJson(), '_via': ?via}, actor: dana, counter: counter++, millis: clock.now + counter);
          final result = await phone.ingest([f]);
          expect(result.invalid.keys, [f.id], reason: '${den.thisDevice!.name} via $via');
        }
      }
      // Nor can it take one away.
      await phone.setAccount(dana, google);
      await sync(phone, hub);
      final unbind = await forged(hub, dana, {'account': null}, actor: dana, counter: counter++, millis: clock.now + counter);
      expect((await phone.ingest([unbind])).invalid.keys, [unbind.id]);
      expect(phone.member(dana)!.account, google);
    });
  });

  test('a shared screen can\'t, whoever verified on it', () async {
    final display = await joinDevice(phone, clock, mode: DeviceMode.shared, name: 'Kitchen', kind: DeviceKind.display);
    display.actAs(dana);
    await expectLater(display.setAccount(dana, google), throwsA(isA<PermissionDenied>()));
    final f = await forged(display, dana, {'account': google.toJson()}, actor: dana);
    expect((await phone.ingest([f])).invalid.keys, [f.id]);
  });

  test('a binding change does nothing else', () async {
    final f = await forged(phone, dana, {'account': google.toJson(), 'name': 'Boss'});
    final other = await joinDevice(phone, clock, member: dana, name: 'Dana tablet');
    expect((await other.ingest([f])).invalid.keys, [f.id]);
  });

  test('a new member can\'t arrive with an account', () async {
    final newcomer = await proved('newcomer', 'n');
    final f = await forged(phone, 'newcomer', {'name': 'Newcomer', 'role': 'parent', 'account': newcomer.toJson()});
    final other = await joinDevice(phone, clock, member: dana, name: 'Dana tablet');
    expect((await other.ingest([f])).invalid.keys, [f.id]);
    expect(other.member('newcomer'), isNull);
  });

  test('two parents binding one account while apart both stand: it signs in as neither, and parents hear of it', () async {
    final samPhone = await joinDevice(phone, clock, member: sam, name: 'Sam phone');
    await phone.setAccount(dana, google);
    clock.advance(const Duration(seconds: 5));
    await samPhone.setAccount(sam, await proved(sam, '1088123'));
    await exchange(phone, samPhone);
    for (final den in [phone, samPhone]) {
      expect(den.member(dana)!.account, google, reason: 'nobody\'s binding is dropped');
      expect(den.member(sam)!.account, google);
      expect(den.memberWithAccount(google), isNull, reason: 'a shared account signs in as nobody');
      expect([for (final m in den.sharedAccounts().single) m.id]..sort(), ([dana, sam]..sort()));
    }
    // One of them takes it away, and it is the other's again.
    await samPhone.setAccount(sam, null);
    await exchange(phone, samPhone);
    expect(phone.memberWithAccount(google)?.id, dana);
    expect(phone.sharedAccounts(), isEmpty);
  });

  test('any parent may take someone\'s account away on their own phone; others can\'t', () async {
    await phone.setAccount(dana, google);
    final samPhone = await joinDevice(phone, clock, member: sam, name: 'Sam phone');
    await samPhone.setAccount(dana, null);
    await sync(samPhone, phone);
    expect(phone.member(dana)!.account, isNull);

    await phone.setAccount(dana, google);
    final kidPhone = await joinDevice(phone, clock, member: leo, name: 'Leo phone');
    await expectLater(kidPhone.setAccount(dana, null), throwsA(isA<PermissionDenied>()));
  });

  test('someone no longer a parent may still take their own away, not bind a new one', () async {
    final samPhone = await joinDevice(phone, clock, member: sam, name: 'Sam phone');
    await samPhone.setAccount(sam, await proved(sam, '001234.abc', provider: 'apple'));
    await sync(samPhone, phone);
    await phone.updateMember(sam, {'role': Role.adult});
    await sync(phone, samPhone);
    await expectLater(samPhone.setAccount(sam, await proved(sam, 'sam-google')), throwsA(isA<PermissionDenied>()));
    await samPhone.setAccount(sam, null);
    await sync(samPhone, phone);
    expect(phone.member(sam)!.account, isNull);
  });

  test('removing someone takes their account with them', () async {
    final samPhone = await joinDevice(phone, clock, member: sam, name: 'Sam phone');
    final samAccount = await proved(sam, 'sam-sub');
    await samPhone.setAccount(sam, samAccount);
    await sync(samPhone, phone);
    expect(phone.memberWithAccount(samAccount)?.id, sam);
    await phone.removeMember(sam);
    expect(phone.memberWithAccount(samAccount), isNull);
  });

  test('replaying the log in another order reaches the same bindings', () async {
    final samPhone = await joinDevice(phone, clock, member: sam, name: 'Sam phone');
    await phone.setAccount(dana, google);
    await samPhone.setAccount(sam, await proved(sam, '1088123'));
    final all = [...phone.changesSince(const {}), ...samPhone.changesSince(const {})];
    final fresh = await openDen(clock);
    await fresh.requestJoin(familyId: phone.familyId!, founderPubkey: phone.founderPubkey!, deviceName: 'Late', kind: DeviceKind.tablet, mode: DeviceMode.personal);
    await fresh.ingest(all.reversed.toList());
    expect(fresh.member(dana)!.account, google);
    expect(fresh.member(sam)!.account, google);
    expect(fresh.memberWithAccount(google), isNull);
  });
}
