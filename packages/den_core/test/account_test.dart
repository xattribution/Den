import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// `member.account`: which Google or Apple account signs in as someone (account.dart). Binding
/// one is a trust decision a parent makes for themselves on their own personal device; the hub,
/// a connection through it, a shared screen and other people can't.
void main() {
  late TestClock clock;
  late Den phone;
  late String dana;
  late String sam;
  late String leo;
  late AccountRef google;

  setUp(() async {
    clock = TestClock.at(DateTime.utc(2026, 10, 30, 15));
    phone = await foundFamily(clock);
    dana = phone.actor!.id;
    sam = await phone.addMember(name: 'Sam', role: Role.parent);
    leo = await phone.addMember(name: 'Leo', role: Role.kid, tier: Tier.big);
    google = AccountRef('google', accountHash(phone.familyId!, 'google', '1088123'));
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

  test('a parent binds their own account on their own phone, and every replica sees it', () async {
    final tablet = await joinDevice(phone, clock, member: dana, name: 'Dana tablet');
    await phone.setAccount(dana, google);
    expect(phone.member(dana)!.account, google);
    await sync(phone, tablet);
    expect(tablet.member(dana)!.account, google);
    expect(tablet.memberWithAccount(google)?.id, dana);
    // And takes it away again.
    await tablet.setAccount(dana, null);
    await sync(tablet, phone);
    expect(phone.member(dana)!.account, isNull);
    expect(phone.memberWithAccount(google), isNull);
  });

  test('the field holds only a provider and a hash, never an email', () async {
    final bad = <Object?>[
      {'provider': 'google', 'hash': google.hash, 'email': 'dana@example.com'},
      {'provider': 'google', 'hash': 'dana@example.com'},
      {'provider': 'github', 'hash': google.hash},
      {'provider': 'google'},
      'dana@example.com',
    ];
    for (final value in bad) {
      expect(checkFields(RecordType.member, {'account': value}, creating: false), isNotNull, reason: '$value');
    }
    expect(checkFields(RecordType.member, {'account': google.toJson()}, creating: false), isNull);
    expect(checkFields(RecordType.member, {'account': null}, creating: false), isNull);
  });

  test('nobody binds someone else\'s account, a parent included', () async {
    await expectLater(phone.setAccount(sam, google), throwsA(isA<PermissionDenied>()));
    // Forged past the engine's own check: every replica refuses it.
    final forged = await forge(
      phone.keys,
      counter: 900,
      millis: clock.now + 10,
      type: RecordType.member,
      rid: sam,
      fields: {'account': google.toJson()},
      actor: dana,
    );
    final other = await joinDevice(phone, clock, member: dana, name: 'Dana tablet');
    final result = await other.ingest([forged]);
    expect(result.invalid.keys, [forged.id]);
    expect(other.member(sam)!.account, isNull);
  });

  test('a kid can\'t bind one, even their own, on their own phone', () async {
    final kidPhone = await joinDevice(phone, clock, member: leo, name: 'Leo phone');
    final leoAccount = AccountRef('google', accountHash(phone.familyId!, 'google', 'leo-sub'));
    await expectLater(kidPhone.setAccount(leo, leoAccount), throwsA(isA<PermissionDenied>()));
    final forged = await forge(
      kidPhone.keys,
      counter: 900,
      millis: clock.now + 10,
      type: RecordType.member,
      rid: leo,
      fields: {'account': leoAccount.toJson()},
      actor: leo,
    );
    final result = await phone.ingest([forged]);
    expect(result.invalid.keys, [forged.id]);
  });

  group('the hub can never write it', () {
    late Den hub;
    late Den ownHub;

    setUp(() async {
      hub = await joinDevice(phone, clock, mode: DeviceMode.hub, name: 'Hub', kind: DeviceKind.hub);
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
          final forged = await forge(
            den.keys,
            counter: counter++,
            millis: clock.now + counter,
            type: RecordType.member,
            rid: dana,
            fields: {'account': google.toJson(), '_via': ?via},
            actor: dana,
          );
          final result = await phone.ingest([forged]);
          expect(result.invalid.keys, [forged.id], reason: '${den.thisDevice!.name} via $via');
        }
      }
      // Nor can it take one away.
      await phone.setAccount(dana, google);
      await sync(phone, hub);
      final unbind = await forge(
        hub.keys,
        counter: counter++,
        millis: clock.now + counter,
        type: RecordType.member,
        rid: dana,
        fields: {'account': null},
        actor: dana,
      );
      expect((await phone.ingest([unbind])).invalid.keys, [unbind.id]);
      expect(phone.member(dana)!.account, google);
    });
  });

  test('a shared screen can\'t, whoever verified on it', () async {
    final display = await joinDevice(phone, clock, mode: DeviceMode.shared, name: 'Kitchen', kind: DeviceKind.display);
    display.actAs(dana);
    await expectLater(display.setAccount(dana, google), throwsA(isA<PermissionDenied>()));
    final forged = await forge(
      display.keys,
      counter: 900,
      millis: clock.now + 10,
      type: RecordType.member,
      rid: dana,
      fields: {'account': google.toJson()},
      actor: dana,
    );
    expect((await phone.ingest([forged])).invalid.keys, [forged.id]);
  });

  test('a binding change does nothing else', () async {
    final forged = await forge(
      phone.keys,
      counter: 900,
      millis: clock.now + 10,
      type: RecordType.member,
      rid: dana,
      fields: {'account': google.toJson(), 'name': 'Boss'},
      actor: dana,
    );
    final other = await joinDevice(phone, clock, member: dana, name: 'Dana tablet');
    expect((await other.ingest([forged])).invalid.keys, [forged.id]);
  });

  test('a new member can\'t arrive with an account', () async {
    final forged = await forge(
      phone.keys,
      counter: 900,
      millis: clock.now + 10,
      type: RecordType.member,
      rid: 'newcomer',
      fields: {'name': 'Newcomer', 'role': 'parent', 'account': google.toJson()},
      actor: dana,
    );
    final other = await joinDevice(phone, clock, member: dana, name: 'Dana tablet');
    expect((await other.ingest([forged])).invalid.keys, [forged.id]);
    expect(other.member('newcomer'), isNull);
  });

  test('one account signs in as one person: the later of two bindings is refused everywhere', () async {
    final samPhone = await joinDevice(phone, clock, member: sam, name: 'Sam phone');
    // Both parents bind the same account while apart.
    await phone.setAccount(dana, google);
    clock.advance(const Duration(seconds: 5));
    await samPhone.setAccount(sam, google);
    await exchange(phone, samPhone);
    for (final den in [phone, samPhone]) {
      expect(den.member(dana)!.account, google);
      expect(den.member(sam)!.account, isNull);
      expect(den.memberWithAccount(google)?.id, dana);
    }
    // Once in step, the engine refuses it outright.
    await expectLater(samPhone.setAccount(sam, google), throwsA(isA<PermissionDenied>()));
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
    final samAccount = AccountRef('apple', accountHash(phone.familyId!, 'apple', '001234.abc'));
    await samPhone.setAccount(sam, samAccount);
    await sync(samPhone, phone);
    await phone.updateMember(sam, {'role': Role.adult});
    await sync(phone, samPhone);
    await expectLater(samPhone.setAccount(sam, AccountRef('google', google.hash)), throwsA(isA<PermissionDenied>()));
    await samPhone.setAccount(sam, null);
    await sync(samPhone, phone);
    expect(phone.member(sam)!.account, isNull);
  });

  test('removing someone takes their account with them', () async {
    final samPhone = await joinDevice(phone, clock, member: sam, name: 'Sam phone');
    final samAccount = AccountRef('google', accountHash(phone.familyId!, 'google', 'sam-sub'));
    await samPhone.setAccount(sam, samAccount);
    await sync(samPhone, phone);
    expect(phone.memberWithAccount(samAccount)?.id, sam);
    await phone.removeMember(sam);
    expect(phone.memberWithAccount(samAccount), isNull);
  });
}
