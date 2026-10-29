import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'support.dart';

int maxCounter(Den den) =>
    den.changesSince(const {}).where((c) => c.device == den.deviceId).fold(0, (m, c) => c.counter > m ? c.counter : m);

void main() {
  late TestClock clock;
  late Den den;
  late String dana;

  setUp(() async {
    clock = TestClock.at(DateTime.utc(2026, 9, 1, 15));
    den = await foundFamily(clock);
    dana = den.actor!.id;
  });

  group('members and devices', () {
    test('add, change and remove people; removing one revokes their devices', () async {
      final leo = await den.addMember(name: 'Leo', role: Role.kid, tier: Tier.little, marker: Marker.aqua, animal: Animal.fish);
      final maya = await den.addMember(name: 'Maya', role: Role.kid, tier: Tier.teen, grants: {Grant.events});
      expect(den.members.map((m) => m.name), ['Dana', 'Leo', 'Maya']);
      expect(den.member(maya)!.grants, {Grant.events});
      await den.updateMember(leo, {'name': 'Leonardo', 'tier': Tier.big, 'animal': Animal.horse});
      expect(den.member(leo)!.name, 'Leonardo');
      expect(den.member(leo)!.tier, Tier.big);
      expect(den.member(leo)!.animal, Animal.horse);
      final tablet = await joinDevice(den, clock, member: leo);
      await den.removeMember(leo);
      expect(den.member(leo), isNull);
      expect(den.members.map((m) => m.name), ['Dana', 'Maya']);
      expect(den.device(tablet.deviceId)!.revoked, isTrue);
      expect(den.spacesForDevice(tablet.deviceId), isEmpty, reason: 'a revoked device gets nothing more');
      await tablet.ingest(den.changesSince(tablet.versionVector).where((c) => c.rid == tablet.deviceId));
      expect(tablet.isApproved, isFalse);
      expect(tablet.readableSpaces, isEmpty);
    });

    test('pending devices, approval and renaming', () async {
      final joiner = await joinDevice(den, clock, member: dana, approve: false, name: 'New phone');
      expect(den.pendingDevices.single.name, 'New phone');
      expect(joiner.isApproved, isFalse);
      expect(joiner.readableSpaces, isEmpty);
      await den.approveDevice(joiner.deviceId);
      await den.updateDevice(joiner.deviceId, {'name': 'Dana\'s iPad', 'kind': DeviceKind.tablet});
      await sync(den, joiner);
      expect(joiner.isApproved, isTrue);
      expect(joiner.owner?.name, 'Dana');
      expect(joiner.thisDevice!.name, 'Dana\'s iPad');
      expect(den.pendingDevices, isEmpty);
      expect(den.device(joiner.deviceId)!.approvedBy, dana);
    });

    test('categories', () async {
      final sports = await den.addCategory(name: 'Sports', icon: 'soccer-ball');
      await den.addCategory(name: 'Appointments');
      expect(den.categories.map((c) => c.name), ['Appointments', 'Sports']);
      await den.updateCategory(sports, {'name': 'Games'});
      expect(den.category(sports)!.name, 'Games');
      await den.deleteCategory(sports);
      expect(den.category(sports), isNull);
    });

    test('family settings', () async {
      await den.updateFamily({'name': 'The Riveras', 'timezone': 'America/Denver', 'weekStart': 1});
      expect(den.family!.name, 'The Riveras');
      expect(den.family!.weekStart, 1);
      expect(den.todayDate(), '2026-09-01');
      await expectLater(den.updateFamily({'timezone': 'Mars/Olympus'}), throwsA(isA<InvalidInput>()));
      await expectLater(den.updateFamily({'founderDevice': 'someone'}), throwsA(isA<InvalidInput>()));
    });

    test('parents change one person\'s oversight at a time, so changes made at once both count', () async {
      final leo = await den.addMember(name: 'Leo', role: Role.kid);
      final maya = await den.addMember(name: 'Maya', role: Role.kid);
      final sam = await den.addMember(name: 'Sam', role: Role.parent);
      final samPhone = await joinDevice(den, clock, member: sam);
      await den.updateFamily({'oversight.$leo': {'parentsSeePrivate': false}});
      await samPhone.updateFamily({'oversight.$maya': {'parentsSeePrivate': false}});
      await exchange(den, samPhone);
      for (final d in [den, samPhone]) {
        expect(d.family!.parentsSeePrivate(leo), isFalse);
        expect(d.family!.parentsSeePrivate(maya), isFalse);
        expect(d.family!.parentsSeePrivate(sam), isTrue);
      }
      await expectLater(den.updateFamily({'oversight.$leo': {'parentsSeePrivate': 'no'}}), throwsA(isA<InvalidInput>()));
    });
  });

  group('sign-in on shared screens', () {
    test('PINs and picture patterns are salted and hashed, and verify', () async {
      final zoe = await den.addMember(name: 'Zoe', role: Role.kid, tier: Tier.preReader);
      await den.setSignIn(dana, kind: 'pin', secret: '2468');
      await den.setSignIn(zoe, kind: 'pattern', secret: '0123');
      final stored = den.member(dana)!.signIn;
      expect(stored.kind, 'pin');
      expect(stored.salt, isNotNull);
      expect(stored.hash, isNot(contains('2468')));
      expect(jsonEncode(den.changesSince({}).map((c) => c.toJson()).toList()), isNot(contains('"2468"')));
      expect(await den.verifySignIn(dana, '2468'), isTrue);
      expect(await den.verifySignIn(dana, '2469'), isFalse);
      expect(await den.verifySignIn(zoe, '0123'), isTrue);
      expect(await den.verifySignIn(zoe, '3210'), isFalse);
      await den.setSignIn(zoe, kind: 'pin', secret: '0123');
      expect(den.member(zoe)!.signIn.salt, isNot(stored.salt));
      await expectLater(den.setSignIn(zoe, kind: 'pin', secret: '12'), throwsA(isA<InvalidInput>()));
      await expectLater(den.setSignIn(zoe, kind: 'pattern', secret: '9999'), throwsA(isA<InvalidInput>()));
      await den.setSignIn(zoe, kind: 'none');
      expect(await den.verifySignIn(zoe, ''), isTrue);
    });

    test('new sign-ins stretch with Argon2id, versioned in signIn, and a PIN may have 6 digits', () async {
      await den.setSignIn(dana, kind: 'pin', secret: '246813');
      final s = den.member(dana)!.signIn;
      expect(s.kdf, SignInKdf.argon2id);
      expect([s.memoryKiB, s.iterations, s.parallelism], [SignInKdf.memoryKiB, SignInKdf.iterations, SignInKdf.parallelism]);
      expect(s.digits, 6);
      expect(s.stretchedOld, isFalse);
      expect(await den.verifySignIn(dana, '246813'), isTrue);
      expect(await den.verifySignIn(dana, '246812'), isFalse);
      expect(await den.verifySignIn(dana, '2468'), isFalse, reason: 'its first four digits are not the PIN');
      await expectLater(den.setSignIn(dana, kind: 'pin', secret: '24681'), throwsA(isA<InvalidInput>()));
      await expectLater(den.setSignIn(dana, kind: 'pin', secret: '2468135'), throwsA(isA<InvalidInput>()));
      await expectLater(den.setSignIn(dana, kind: 'pattern', secret: '012345'), throwsA(isA<InvalidInput>()));
      await den.setSignIn(dana, kind: 'pin', secret: '2468');
      expect(den.member(dana)!.signIn.digits, 4);
      expect(await den.verifySignIn(dana, '2468'), isTrue);
    });

    test('a PBKDF2 sign-in from before Argon2id still verifies until it is set again', () async {
      clock.advance(const Duration(seconds: 1));
      final salt = randomBytes(16);
      final key = await Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 20000, bits: 256)
          .deriveKeyFromPassword(password: '2468', nonce: salt);
      final old = await forge(
        den.keys,
        counter: maxCounter(den) + 1,
        millis: clock.now,
        type: RecordType.member,
        rid: dana,
        fields: {
          'signIn': {'kind': 'pin', 'salt': b64e(salt), 'hash': b64e(await key.extractBytes())},
        },
        actor: dana,
      );
      expect((await den.ingest([old])).invalid, isEmpty);
      final s = den.member(dana)!.signIn;
      expect(s.kdf, isNull);
      expect(s.digits, 4);
      expect(s.stretchedOld, isTrue);
      expect(await den.verifySignIn(dana, '2468'), isTrue);
      expect(await den.verifySignIn(dana, '2469'), isFalse);
      clock.advance(const Duration(seconds: 1));
      await den.setSignIn(dana, kind: 'pin', secret: '2468');
      expect(den.member(dana)!.signIn.stretchedOld, isFalse);
      expect(den.member(dana)!.signIn.kdf, SignInKdf.argon2id);
      expect(await den.verifySignIn(dana, '2468'), isTrue);
    });

    test('the schema bounds how a sign-in is stretched, and one it can\'t read never verifies', () async {
      clock.advance(const Duration(seconds: 1));
      Map<String, Object?> argon(Map<String, Object?> params) => {
            'signIn': {'kind': 'pin', 'salt': b64e(randomBytes(16)), 'hash': 'x' * 43, 'kdf': SignInKdf.argon2id, ...params},
          };
      final bad = [
        {'signIn': {'kind': 'pin', 'salt': 'a', 'hash': 'b', 'kdf': 'scrypt'}},
        argon({'memoryKiB': 1 << 20, 'iterations': 2, 'parallelism': 1}),
        argon({'memoryKiB': 6144, 'iterations': 0, 'parallelism': 1}),
        argon({'memoryKiB': 6144, 'iterations': 2, 'parallelism': 1, 'digits': 8}),
      ];
      final forged = [
        for (final (i, fields) in bad.indexed)
          await forge(den.keys, counter: maxCounter(den) + 1 + i, millis: clock.now + i, type: RecordType.member, rid: dana, fields: fields, actor: dana),
      ];
      final result = await den.ingest(forged);
      expect(result.invalid.keys, unorderedEquals(forged.map((c) => c.id)));
      expect(den.member(dana)!.signIn.kind, 'none');
      // No parameters, no check: it fails closed rather than guessing them.
      final missing = await forge(den.keys,
          counter: maxCounter(den) + 1, millis: clock.now + 10, type: RecordType.member, rid: dana, fields: argon({}), actor: dana);
      expect((await den.ingest([missing])).invalid, isEmpty);
      expect(await den.verifySignIn(dana, '1234'), isFalse);
    });

    test('a parent with no sign-in never verifies on a shared screen', () async {
      final leo = await den.addMember(name: 'Leo', role: Role.kid);
      final display = await joinDevice(den, clock, mode: DeviceMode.shared, name: 'Kitchen', kind: DeviceKind.display);
      expect(await display.verifySignIn(dana, ''), isFalse, reason: 'anyone at the screen could act as Dana');
      expect(await display.verifySignIn(leo, ''), isTrue);
      expect(await den.verifySignIn(dana, ''), isTrue, reason: 'her own phone is hers');
      await den.setSignIn(dana, kind: 'pin', secret: '2468');
      await sync(den, display);
      expect(await display.verifySignIn(dana, '2468'), isTrue);
      expect(await display.verifySignIn(dana, ''), isFalse);
    });

    test('a member sets their own sign-in; only parents set others\'', () async {
      final leo = await den.addMember(name: 'Leo', role: Role.kid);
      final maya = await den.addMember(name: 'Maya', role: Role.kid);
      final tablet = await joinDevice(den, clock, member: leo);
      await tablet.setSignIn(leo, kind: 'pin', secret: '1111');
      await expectLater(tablet.setSignIn(maya, kind: 'pin', secret: '2222'), throwsA(isA<PermissionDenied>()));
      await sync(tablet, den);
      expect(await den.verifySignIn(leo, '1111'), isTrue);
    });

    test('acting on a shared screen lasts for its window', () async {
      final leo = await den.addMember(name: 'Leo', role: Role.kid);
      final display = await joinDevice(den, clock, mode: DeviceMode.shared, name: 'Kitchen', kind: DeviceKind.display);
      expect(display.actor, isNull);
      display.actAs(leo, window: const Duration(seconds: 30));
      expect(display.actor?.name, 'Leo');
      expect(display.actingUntil, clock.now + 30000);
      clock.advance(const Duration(seconds: 31));
      expect(display.actor, isNull);
      expect(display.actingUntil, isNull);
      display.actAs(leo);
      display.actAs(null);
      expect(display.actor, isNull);
    });
  });

  group('AI and automation connections', () {
    test('tokens are shown once and stored only as a hash', () async {
      final token = await den.addTokenConnection(label: 'Home Assistant', scopes: {Scope.read, Scope.chores});
      expect(token, startsWith('den_'));
      expect(b64d(token.substring(4)), hasLength(32));
      final connection = den.connections.single;
      expect(connection.tokenHash, hashToken(token));
      expect(connection.tokenHash, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(connection.scopes, {Scope.read, Scope.chores});
      expect(connection.status, ConnectionStatus.active);
      expect(jsonEncode(den.changesSince({}).map((c) => c.toJson()).toList()), isNot(contains(token)));
      expect(den.connectionForToken(token)?.label, 'Home Assistant');
      expect(den.connectionForToken('den_wrong'), isNull);
      await den.revokeConnection(connection.id);
      expect(den.connectionForToken(token), isNull);
    });

    test('expired tokens stop working', () async {
      final token = await den.addTokenConnection(
        label: 'Script',
        scopes: {Scope.read},
        expires: clock.now + 60000,
      );
      expect(den.connectionForToken(token), isNotNull);
      clock.advance(const Duration(minutes: 2));
      expect(den.connectionForToken(token), isNull);
    });

    test('only parents create tokens', () async {
      final leo = await den.addMember(name: 'Leo', role: Role.kid);
      final adult = await den.addMember(name: 'Rosa', role: Role.adult);
      final tablet = await joinDevice(den, clock, member: leo);
      final phone = await joinDevice(den, clock, member: adult, name: 'Rosa phone');
      await expectLater(tablet.addTokenConnection(label: 'x', scopes: {Scope.admin}), throwsA(isA<PermissionDenied>()));
      await expectLater(phone.addTokenConnection(label: 'x', scopes: {Scope.read}), throwsA(isA<PermissionDenied>()));
    });

    test('OAuth: the hub asks, a parent approves, the hub records the token', () async {
      final hub = await joinDevice(den, clock, mode: DeviceMode.hub, name: 'Hub', kind: DeviceKind.hub);
      final id = await hub.requestOAuthConnection(label: 'Claude', client: 'https://claude.ai', scopes: {Scope.read, Scope.lists});
      await expectLater(hub.setConnectionToken(id, hashToken('t1')), throwsA(isA<PermissionDenied>()),
          reason: 'not approved yet');
      await sync(hub, den);
      expect(den.connections.single.status, ConnectionStatus.pending);
      await expectLater(den.setConnectionToken(id, hashToken('t1')), throwsA(isA<PermissionDenied>()),
          reason: 'only hubs issue tokens');
      await den.approveConnection(id, scopes: {Scope.read});
      await sync(den, hub);
      await hub.setConnectionToken(id, hashToken('t1'), expires: clock.now + 3600000);
      expect(hub.connectionForToken('t1')?.scopes, {Scope.read});
      hub.actAs(null, via: 'Claude');
      await expectLater(hub.approveConnection(id, scopes: {Scope.admin}), throwsA(isA<PermissionDenied>()));
      await hub.revokeConnection(id);
      expect(hub.connectionForToken('t1'), isNull);
    });
  });

  group('sync surface and storage', () {
    test('space keys exist for each space from genesis and for each new member', () async {
      for (final s in [Space.family, Space.parents, Space.member(dana)]) {
        expect(await den.spaceKey(s), hasLength(32));
      }
      final leo = await den.addMember(name: 'Leo', role: Role.kid);
      expect(await den.spaceKey(Space.member(leo)), hasLength(32));
      expect(await den.spaceKey('m:nobody'), isNull);
      final joiner = await joinDevice(den, clock, member: leo);
      expect(await joiner.spaceKey(Space.family), isNull);
      await joiner.setSpaceKey(Space.family, (await den.spaceKey(Space.family))!);
      expect(await joiner.spaceKey(Space.family), await den.spaceKey(Space.family));
      await expectLater(joiner.setSpaceKey(Space.family, [1, 2, 3]), throwsA(isA<InvalidInput>()));
    });

    test('reopening from storage restores the same state and keeps counting', () async {
      final storage = MemoryStorage();
      final keys = await DeviceKeys.generate();
      final first = await openDen(clock, storage: storage, keys: keys);
      await first.createFamily(
        familyName: 'Lee family',
        timezone: 'America/Chicago',
        yourName: 'Sam',
        marker: Marker.sunshine,
        animal: Animal.cow,
        deviceName: 'Sam\'s laptop',
        deviceKind: DeviceKind.desktop,
      );
      await first.addEvent(title: 'Bake sale', start: clock.now, end: clock.now + 3600000);
      final before = jsonEncode(first.exportJson());
      final second = await openDen(clock, storage: storage, keys: keys);
      expect(jsonEncode(second.exportJson()), before);
      expect(second.familyId, first.familyId);
      expect(second.actor?.name, 'Sam');
      expect(await second.spaceKey(Space.family), await first.spaceKey(Space.family));
      await second.addCategory(name: 'School');
      final ids = second.changesSince({}).map((c) => c.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
      expect(second.versionVector[second.deviceId], 5);
      expect(second.history().first.title, 'School');
    });

    test('changesSince sends only what the other side lacks, in clock order', () async {
      final other = await joinDevice(den, clock, member: dana, name: 'Second');
      final mark = other.versionVector;
      clock.advance(const Duration(seconds: 1));
      await den.addCategory(name: 'One');
      await den.addCategory(name: 'Two');
      final missing = den.changesSince(mark);
      expect(missing.map((c) => c.fields['name']), ['One', 'Two']);
      expect(den.changesSince(den.versionVector), isEmpty);
      final all = den.changesSince({});
      final sorted = [...all]..sort((a, b) => a.hlc.compareTo(b.hlc));
      expect(all.map((c) => c.id), sorted.map((c) => c.id));
    });

    test('onChange reports the record types that changed', () async {
      final seen = <Set<String>>[];
      final sub = den.onChange.listen(seen.add);
      await den.addCategory(name: 'Sports');
      final list = await den.addList(title: 'Groceries');
      await den.addItem(list, text: 'Milk');
      await Future<void>.delayed(Duration.zero);
      expect(seen, [
        {RecordType.category},
        {RecordType.list},
        {RecordType.item},
      ]);
      await sub.cancel();
    });

    test('export lists every live record by type with sorted keys', () async {
      final list = await den.addList(title: 'Groceries');
      final milk = await den.addItem(list, text: 'Milk');
      await den.removeItem(milk);
      final export = den.exportJson();
      expect(export['family'], den.familyId);
      final records = export['records']! as Map<String, Object?>;
      expect(records.keys.toList(), [...records.keys]..sort());
      expect((records[RecordType.list]! as Map)[list], {
        'space': Space.family,
        'fields': containsPair('title', 'Groceries'),
      });
      expect(records.containsKey(RecordType.item), isFalse, reason: 'removed records are left out');
    });
  });
}
