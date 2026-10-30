import 'dart:convert';
import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'group_support.dart';
import 'support.dart';

/// Groups of families (groups.dart): a group is a log of its own whose people and devices come
/// from several families. These follow the flows (start, bring the family in, invite a family,
/// join, leave) and check what each rule allows; groups_trust_test.dart checks what each refuses.
void main() {
  late TestClock clock;
  const minute = 60000;

  setUp(() {
    clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
  });

  group('starting a group', () {
    test('its genesis: a group, no stars, the founder\'s family in from the start, and the founder as one of it', () async {
      final f = await kotvasGroup(clock);
      final g = f.alex;
      expect(g.isGroup, isTrue);
      expect(g.family!.kind, LogKind.group);
      expect(g.family!.pointsEnabled, isFalse);
      expect(g.homes.single.name, 'Kotvas');
      expect(g.homes.single.status, HomeStatus.active);
      expect(g.homes.single.invitedBy, isNull);
      expect(g.homes.single.family, f.kotvas.familyId);
      expect(g.homes.single.hubs, ['https://den.kotvas.app/ws']);
      final alex = g.member(f.gAlex)!;
      expect(alex.home, f.kotvasHome);
      expect(alex.link, f.kAlex);
      expect(alex.isParent, isTrue);
      expect(g.thisDevice!.home, f.kotvasHome);
      expect(g.myHome, f.kotvasHome);
      // The family's own log isn't a group, and its engine keeps its own keys.
      expect(f.kotvas.isGroup, isFalse);
      expect(g.deviceId, isNot(f.kotvas.deviceId));
      expect(g.familyId, isNot(f.kotvas.familyId));
    });

    test('bringing the family in: a person each, linked, with their look, and no permissions yet', () async {
      final f = await kotvasGroup(clock);
      final leo = f.alex.member(f.gLeo)!;
      expect(leo.name, 'Leo');
      expect(leo.role, Role.kid);
      expect(leo.tier, Tier.big);
      expect(leo.home, f.kotvasHome);
      expect(leo.link, f.kLeo);
      expect(leo.marker, f.kotvas.member(f.kLeo)!.marker);
      expect(leo.grants, isEmpty);
      final link = f.kotvas.groupLink(f.group)!;
      expect(link.name, 'Cousins soccer');
      expect(link.founder, f.alex.founderPubkey);
      expect(link.members, {f.kAlex: f.gAlex, f.kPriya: f.gPriya, f.kLeo: f.gLeo});
      expect(link.status, GroupLinkStatus.active);
      // Every chosen device, and the hub, let itself in with its own sealed admission.
      for (final d in [f.priya, f.leo, f.kHub]) {
        expect(d.isApproved, isTrue);
        expect(d.thisDevice!.home, f.kotvasHome);
      }
      expect(f.leo.owner?.id, f.gLeo);
      expect(f.kHub.thisDevice!.mode, DeviceMode.hub);
      expect(f.kHub.thisDevice!.member, isNull);
    });

    test('a photo comes along as a photo of their own in the group', () async {
      final f = await kotvasGroup(clock);
      final bytes = File('test/fixtures/canvas_photo.jpg').readAsBytesSync();
      final teo = await f.kotvas.addMember(name: 'Teo', role: Role.kid);
      await f.kotvas.setPhoto(teo, bytes);
      await f.alex.addToGroup(family: f.kotvas, people: [teo]);
      final gTeo = f.kotvas.groupLink(f.group)!.members[teo]!;
      final photo = f.alex.member(gTeo)!.photo;
      expect(photo, isNotNull);
      expect(base64.decode(f.alex.photo(photo!)!.data), bytes);
    });

    test('each admission opens only on the device it is sealed to', () async {
      final f = await kotvasGroup(clock);
      await sync(f.kotvas, f.leoF);
      final mine = await f.leoF.openGroupInvite(f.group);
      expect(mine, isNotNull);
      expect(mine!.member, f.gLeo);
      expect(mine.mode, DeviceMode.personal);
      expect(mine.home, f.kotvasHome);
      expect(mine.device, f.leoF.deviceId);
      // Another device of the family holds the record and can't open it.
      final theirs = f.kotvas.groupInvite(f.group, f.leoF.deviceId)!;
      expect(theirs.sealed['to'], f.leoF.deviceId);
      expect(jsonEncode(theirs.sealed), isNot(contains(b64e(mine.seed))));
      await expectLater(openSealed(theirs.sealed, recipient: f.priyaF.keys, senderPubkey: f.kotvas.keys.pubkey), throwsA(isA<SealException>()));
      // History shows that it was written, never what it holds.
      final entry = f.kotvas.history(type: RecordType.groupInvite).firstWhere((h) => h.rid == theirs.id);
      expect(entry.diffs.firstWhere((d) => d.field == 'sealed').after, '•••');
      // A parent finds the group device a family device's admission let in, to remove it with it.
      expect(f.alex.usedInvite(theirs.invite!)?.id, f.leo.deviceId);
    });

    test('a device the family adds later, or whose admission ran out unused, gets one when a parent runs it again', () async {
      final f = await kotvasGroup(clock);
      final ipadF = await joinDevice(f.kotvas, clock, member: f.kLeo, name: "Leo's iPad");
      final laptopF = await joinDevice(f.kotvas, clock, member: f.kAlex, name: "Alex's laptop", kind: DeviceKind.desktop);
      final first = await f.alex.addToGroup(family: f.kotvas, people: const []);
      expect({for (final a in first) a.device}, {ipadF.deviceId, laptopF.deviceId}, reason: 'only devices without an admission');
      // The laptop stays offline past its admission's week.
      await exchange(f.alex, f.kHub);
      final ipad = await admitFrom(f, ipadF, f.kotvas, f.kHub, name: "Leo's iPad");
      expect(ipad.owner?.id, f.gLeo);
      await exchange(f.alex, f.kHub);
      clock.advance(const Duration(days: 8));
      final second = await f.alex.addToGroup(family: f.kotvas, people: const []);
      expect([for (final a in second) a.device], [laptopF.deviceId]);
      await exchange(f.alex, f.kHub);
      final laptop = await admitFrom(f, laptopF, f.kotvas, f.kHub, name: "Alex's laptop");
      expect(laptop.owner?.id, f.gAlex);
    });

    test('an admission doesn\'t open when it was passed off from another device, family or group', () async {
      final f = await kotvasGroup(clock);
      await sync(f.kotvas, f.leoF);
      final real = f.kotvas.groupInvite(f.group, f.leoF.deviceId)!;
      // A parent's device copies Leo's sealed admission onto another record: it names Leo's
      // tablet inside, so the tablet it is written for can't open it, and validity refuses it.
      final copied = await forgeAs(f.kotvas, type: RecordType.groupInvite, rid: '${f.group}@${f.priyaF.deviceId}', actor: f.kAlex, fields: {
        'group': f.group,
        'device': f.priyaF.deviceId,
        'sealed': real.sealed,
      });
      expect(await refusal(f.kotvas, copied), contains('sealed to its own device'));
      // Sealed by one parent's device, written by another: refused too.
      final relayed = await forgeAs(f.priyaF, type: RecordType.groupInvite, rid: real.id, actor: f.kPriya, fields: {'sealed': real.sealed});
      expect(await refusal(f.kotvas, relayed), contains('sealed by the device that writes it'));
      // An admission for another group, under this group's name, doesn't open as this group's.
      expect(await f.leoF.openGroupInvite('anothergroup'), isNull);
    });
  });

  group('another family joins', () {
    test('an invitation: the family, its first parent, and one-use keys for their phone and hub', () async {
      final f = await kotvasGroup(clock);
      await inviteSmiths(f);
      final smiths = f.alex.home(f.smithHome)!;
      expect(smiths.status, HomeStatus.invited);
      expect(smiths.invitedBy, f.kotvasHome);
      expect(f.alex.member(f.gDana)!.home, f.smithHome);
      expect(f.alex.invitationOpen(f.smithHome), isTrue);
      final keys = [for (final k in f.alex.inviteKeys) if (k.rec.strOrNull('home') == f.smithHome) k];
      expect(keys, hasLength(2));
      expect(keys.every((k) => k.uses == 1), isTrue);
      expect({for (final k in keys) k.modes.single}, {DeviceMode.personal, DeviceMode.hub});
      expect(f.invitation.parent.member, f.gDana);
      expect(f.invitation.hub.member, isNull);
      expect(f.invitation.hubs, ['https://den.kotvas.app/ws']);
    });

    test('Dana\'s phone lets itself in at once; then the window closes, and the Smith hub still gets in', () async {
      final f = await kotvasGroup(clock);
      await inviteSmiths(f);
      f.dana = await admit(f, f.invitation.parent, f.kHub, name: "Dana's phone");
      expect(f.dana.isApproved, isTrue);
      expect(f.dana.owner?.id, f.gDana);
      expect(f.dana.myHome, f.smithHome);
      // In, but the window stays open until Dana says the Smiths are in: the hub's key still works.
      expect(f.kHub.invitationOpen(f.smithHome), isTrue);
      f.sHub = await admit(f, f.invitation.hub, f.kHub, name: 'Smith hub', kind: DeviceKind.hub);
      expect(f.sHub.isApproved, isTrue);
      expect(f.sHub.thisDevice!.home, f.smithHome);
      // Dana says they're in: that shuts the window, keeping her phone and the hub it let in.
      await exchange(f.dana, f.kHub);
      await f.dana.updateHome(active: true);
      final said = f.dana.changesSince(const {}).lastWhere((c) => c.type == RecordType.home);
      expect(said.fields['kept'], unorderedEquals([f.dana.deviceId, f.sHub.deviceId]));
      expect((said.fields['closed'] as Map).keys, containsAll([f.alex.deviceId, f.kHub.deviceId]));
      await exchange(f.dana, f.kHub);
      expect(f.kHub.invitationOpen(f.smithHome), isFalse);
      expect(f.kHub.home(f.smithHome)!.status, HomeStatus.active);
      expect(f.kHub.deviceCounts(f.sHub.deviceId), isTrue);
      expect(f.kHub.deviceCounts(f.dana.deviceId), isTrue);
      // History tells the inviting family who joined, and how.
      await exchange(f.alex, f.kHub);
      final joined = f.alex.history(type: RecordType.device).firstWhere((h) => h.rid == f.dana.deviceId);
      expect(joined.verb, 'approved');
    });

    test('the Smith family fills itself in: in, its hubs, its people and their devices', () async {
      final f = await bothFamilies(clock);
      for (final d in [...f.kotvasDevices, ...f.smithDevices]) {
        expect(d.isApproved, isTrue, reason: d.thisDevice?.name);
        expect(d.homes.map((h) => h.name), ['Kotvas', 'Smiths']);
      }
      final smiths = f.alex.home(f.smithHome)!;
      expect(smiths.status, HomeStatus.active);
      expect(smiths.family, f.smith.familyId);
      expect(smiths.hubs, ['https://den.smith.example/ws']);
      expect(f.alex.membersOf(f.smithHome).map((m) => m.name), unorderedEquals(['Dana', 'Mia']));
      expect(f.mia.owner?.id, f.gMia);
      expect(f.smith.groupLink(f.group)!.members, {f.sDana: f.gDana, f.sMia: f.gMia});
      expect(f.alex.history(type: RecordType.home).map((h) => h.verb), containsAll(['added', 'invited', 'joined']));
    });

    test('a third family can be invited by a parent of either family', () async {
      final f = await bothFamilies(clock);
      final lees = await f.dana.inviteFamily(familyName: 'Lees', parentName: 'Jun');
      expect(f.dana.home(lees.home)!.invitedBy, f.smithHome);
      await exchange(f.dana, f.sHub);
      final jun = await admit(f, lees.parent, f.sHub, name: "Jun's phone");
      expect(jun.isApproved, isTrue);
      expect(jun.myHome, lees.home);
    });
  });

  group('G5: who reads what', () {
    test('f is everyone\'s, p every family\'s parents\'; nobody has a space of their own; hubs hold the whole group', () async {
      final f = await bothFamilies(clock);
      final g = f.alex;
      final alex = g.member(f.gAlex)!, dana = g.member(f.gDana)!, leo = g.member(f.gLeo)!;
      final fam = g.family;
      expect(canRead(dana, Space.parents, fam), isTrue);
      expect(canRead(leo, Space.parents, fam), isFalse);
      // A group has no "Just me" (review finding 5): nobody reads one, the person included.
      expect(canRead(leo, Space.member(f.gLeo), fam), isFalse);
      expect(canRead(alex, Space.member(f.gLeo), fam), isFalse);
      expect(canRead(dana, Space.member(f.gLeo), fam), isFalse);
      expect(f.alex.spacesForDevice(f.alex.deviceId), {Space.family, Space.parents});
      expect(f.alex.spacesForDevice(f.leo.deviceId), {Space.family});
      expect(f.alex.spacesForDevice(f.dana.deviceId), {Space.family, Space.parents});
      expect(f.alex.spacesForDevice(f.sHub.deviceId), {Space.family, Space.parents});
      expect(f.alex.spacesForDevice(f.kHub.deviceId), {Space.family, Space.parents});
      expect(f.dana.readableSpaces, {Space.family, Space.parents});
      // In a family's own log, parents still see their kids' "Just me" by default.
      expect(canRead(f.kotvas.member(f.kAlex)!, Space.member(f.kLeo), f.kotvas.family), isTrue);
      expect(canRead(f.kotvas.member(f.kLeo)!, Space.member(f.kLeo), f.kotvas.family), isTrue);
    });

    test('"Just me" stays in each family\'s own Den: a group refuses it', () async {
      final f = await bothFamilies(clock);
      await expectLater(f.priya.addList(title: 'My secret list', audience: Audience.justMe), throwsA(isA<InvalidInput>()));
      final start = clock.now + 86400000;
      await expectLater(f.dana.addEvent(title: 'Dentist', start: start, end: start + 3600000, audience: Audience.justMe),
          throwsA(isA<InvalidInput>()));
      // Nor does a group key any space of one person.
      for (final d in [f.alex, f.priya, f.leo, f.kHub, f.dana, f.mia, f.sHub]) {
        expect(d.changesSince(const {}).where((c) => Space.isMember(c.space)), isEmpty, reason: d.thisDevice!.name);
      }
      // In the family's own Den it's as it was.
      final mine = await f.priyaF.addList(title: 'My secret list', audience: Audience.justMe);
      expect(f.priyaF.list(mine), isNotNull);
    });
  });

  group('what people may do in a group', () {
    test('parents of either family edit shared events and lists, and claim ride legs', () async {
      final f = await bothFamilies(clock);
      final start = clock.now + 86400000;
      final game = await f.alex.addEvent(title: 'Soccer game', start: start, end: start + 3600000, rides: const [Ride('to', null), Ride('from', null)]);
      await settle(f);
      await f.dana.updateEvent(game, {'location': 'Field 3'});
      await f.dana.claimRide(game, occurrence: start, leg: 'to', driver: f.gDana);
      await f.alex.claimRide(game, occurrence: start, leg: 'from', driver: f.gAlex);
      await settle(f);
      final e = f.mia.event(game)!;
      expect(e.location, 'Field 3');
      expect({for (final r in e.rides) r.leg: r.driver}, {'to': f.gDana, 'from': f.gAlex});
      final list = await f.dana.addList(title: 'Snacks', kind: ListKind.shopping);
      await f.dana.addItem(list, text: 'Oranges');
      await settle(f);
      await f.priya.addItem(list, text: 'Water');
      await settle(f);
      expect(f.dana.list(list)!.items.map((i) => i.text), unorderedEquals(['Oranges', 'Water']));
    });

    test('kids see everything and check off items; editing needs a grant from their own parents', () async {
      final f = await bothFamilies(clock);
      final list = await f.dana.addList(title: 'Packing', kind: ListKind.packing);
      final item = await f.dana.addItem(list, text: 'Shin guards');
      final start = clock.now + 86400000;
      final game = await f.dana.addEvent(title: 'Soccer game', start: start, end: start + 3600000, rides: const [Ride('to', null)]);
      await settle(f);
      // Leo sees the other family's things and checks an item.
      expect(f.leo.events.map((e) => e.id), contains(game));
      await f.leo.setItemChecked(item, true);
      await settle(f);
      expect(f.dana.list(list)!.items.single.checked, isTrue);
      expect(f.dana.list(list)!.items.single.checkedBy, f.gLeo);
      // Mia (the other family's kid) too.
      await f.mia.setItemChecked(item, false);
      // Without a grant, no event or list edits.
      await expectLater(f.leo.updateEvent(game, {'title': 'Party'}), throwsA(isA<PermissionDenied>()));
      await expectLater(f.leo.updateItem(item, {'text': 'Cleats'}), throwsA(isA<PermissionDenied>()));
      // Leo's own parent grants events, on their own phone: now he edits and claims a leg for one.
      await f.priya.updateMember(f.gLeo, {'grants': [Grant.events]});
      await settle(f);
      await f.leo.updateEvent(game, {'notes': 'Bring water'});
      await f.leo.claimRide(game, occurrence: start, leg: 'to', driver: f.gPriya);
      // But a kid never drives, granted or not (canDrive, held by validity in a group).
      await expectLater(f.leo.claimRide(game, occurrence: start, leg: 'to', driver: f.gLeo), throwsA(isA<InvalidInput>()));
      await settle(f);
      expect(f.dana.event(game)!.notes, 'Bring water');
      expect(f.dana.event(game)!.rides.single.driver, f.gPriya);
      // Lists edits need the lists grant, from Mia's own parent.
      await f.dana.updateMember(f.gMia, {'grants': [Grant.lists]});
      await settle(f);
      await f.mia.updateItem(item, {'text': 'Shin guards and socks'});
      await settle(f);
      expect(f.alex.list(list)!.items.single.text, 'Shin guards and socks');
    });

    test('G4: a family\'s hub acts through a connection for its own family\'s people', () async {
      final f = await bothFamilies(clock);
      f.kHub.actAs(f.gAlex, via: 'Claude');
      final start = clock.now + 86400000;
      final id = await f.kHub.addEvent(title: 'Practice', start: start, end: start + 3600000);
      f.kHub.actAs(null);
      await settle(f);
      final entry = f.dana.history(type: RecordType.event).firstWhere((h) => h.rid == id);
      expect(entry.via, 'Claude');
      expect(entry.actor, f.gAlex);
    });

    test('a family\'s parent approves its own device that asked to join; it is of that family', () async {
      final f = await bothFamilies(clock);
      final laptop = await openDen(clock);
      await laptop.requestJoin(familyId: f.group, founderPubkey: f.alex.founderPubkey!, deviceName: 'Laptop', kind: DeviceKind.desktop);
      await f.dana.ingest(laptop.changesSince(const {}));
      await f.dana.approveDevice(laptop.deviceId, member: f.gDana, mode: DeviceMode.personal);
      expect(f.dana.device(laptop.deviceId)!.home, f.smithHome);
      await sync(f.dana, laptop);
      expect(laptop.isApproved, isTrue);
    });
  });

  group('G6: recovery words into a group', () {
    test('a parent\'s copied words bring a new phone back as theirs, of their family', () async {
      final f = await bothFamilies(clock);
      final words = await RecoveryKey.generate();
      // The parent's own phone copies the public half of their family's words into the group.
      await f.dana.setRecoveryKey(f.gDana, words.publicKey);
      await settle(f);
      expect(recoveryKeyOf(f.alex.member(f.gDana)!), words.publicKey);
      clock.advance(const Duration(minutes: 5));
      final phone = await openDen(clock);
      final proof = await words.prove(
        family: f.group,
        kind: RecoveryKind.words,
        member: f.gDana,
        devicePubkey: phone.keys.pubkey,
        expires: clock.now + 10 * minute,
      );
      await phone.requestRecovery(
        familyId: f.group,
        founderPubkey: f.alex.founderPubkey!,
        deviceName: "Dana's new phone",
        kind: DeviceKind.phone,
        proof: proof,
        home: f.smithHome,
      );
      final result = await f.sHub.ingest(phone.changesSince(const {}));
      expect(result.invalid, isEmpty);
      await sync(f.sHub, phone);
      expect(phone.isApproved, isTrue);
      expect(phone.owner?.id, f.gDana);
      expect(phone.myHome, f.smithHome);
    });
  });

  group('"That wasn\'t them"', () {
    test('the inviting family removes the phone its invitation let in, and the key; the invitation opens again', () async {
      final f = await kotvasGroup(clock);
      await inviteSmiths(f);
      final impostor = await admit(f, f.invitation.parent, f.kHub, name: 'Not Dana');
      final words = await RecoveryKey.generate();
      await impostor.setRecoveryKey(f.gDana, words.publicKey);
      await exchange(impostor, f.kHub);
      await exchange(f.alex, f.kHub);
      // Whoever it was hasn't said the Smiths are in (and once a Smith has, it's theirs alone).
      expect(f.alex.invitationOpen(f.smithHome), isTrue);
      final disowned = await f.alex.disownInvite(impostor.deviceId);
      expect(disowned.member, f.gDana);
      expect(f.alex.device(impostor.deviceId)!.revoked, isTrue);
      expect(f.alex.inviteKey(f.invitation.parent.invite)!.key, isNull);
      expect(f.alex.inviteKey(f.invitation.hub.invite)!.key, isNull, reason: 'the rest of the invitation goes too');
      expect(recoveryKeyOf(f.alex.member(f.gDana)!), isNull, reason: 'whoever it was can\'t come back with their words');
      // Nobody of the Smiths is in, so Alex can invite Dana again into the same family.
      expect(f.alex.invitationOpen(f.smithHome), isTrue);
      final again = await InviteKey.generate();
      await f.alex.createInviteKey(member: f.gDana, publicKey: again.publicKey, expires: clock.now + 3600000, home: f.smithHome);
      await exchange(f.alex, f.kHub);
      final dana = await admit(
        f,
        GroupAdmission(
          group: f.group,
          founder: f.alex.founderPubkey!,
          name: 'Cousins soccer',
          home: f.smithHome,
          member: f.gDana,
          mode: DeviceMode.personal,
          invite: again.id,
          seed: await again.seed(),
          expires: clock.now + 3600000,
        ),
        f.kHub,
        name: "Dana's phone",
      );
      expect(dana.isApproved, isTrue);
    });

    test('a family removes a device its own key let in, the usual way', () async {
      final f = await bothFamilies(clock);
      final disowned = await f.dana.disownInvite(f.mia.deviceId);
      expect(disowned.member, f.gMia);
      expect(f.dana.device(f.mia.deviceId)!.revoked, isTrue);
    });
  });

  group('G8: leaving', () {
    test('a family leaves in one commit: its devices and people go, the rest carry on, keys rotate', () async {
      final f = await bothFamilies(clock);
      final before = f.alex.spaceKeyEpoch(Space.family)!;
      clock.advance(const Duration(minutes: 1));
      final commit = await f.dana.leaveGroup(family: f.smith);
      // One commit by Dana's phone, ending with the phone itself, naming the change before.
      final last = commit.last;
      expect(last.rid, f.dana.deviceId);
      expect(last.fields['revoked'], isTrue);
      expect(last.fields['revokedAfter'], commit[commit.length - 2].counter);
      expect(commit.where((c) => c.type == RecordType.device && c.fields['revoked'] == true).map((c) => c.rid),
          containsAll([f.mia.deviceId, f.sHub.deviceId, f.dana.deviceId]));
      expect(commit.where((c) => c.type == RecordType.member && c.isDelete).map((c) => c.rid), [f.gMia]);
      expect(f.dana.home(f.smithHome)!.status, HomeStatus.left);
      expect(f.dana.isApproved, isFalse);
      // By its own view the phone has nobody to sync with: the app hands the commit to its hub.
      expect(f.dana.spacesForDevice(f.sHub.deviceId), isEmpty);
      expect((await f.sHub.ingest(commit)).invalid, isEmpty);
      await settle(f);
      for (final d in f.kotvasDevices) {
        expect(d.home(f.smithHome)!.left, isTrue);
        expect(d.members.map((m) => m.name), unorderedEquals(['Alex', 'Priya', 'Leo']));
        for (final s in f.smithDevices) {
          expect(d.device(s.deviceId)!.revoked, isTrue, reason: '${s.thisDevice?.name} on ${d.thisDevice?.name}');
        }
      }
      expect(f.dana.isApproved, isFalse);
      expect(f.sHub.isApproved, isFalse);
      for (final s in f.smithDevices) {
        expect(f.kHub.deviceCounts(s.deviceId), isFalse);
      }
      expect(f.kHub.deviceCounts(f.leo.deviceId), isTrue);
      // Nobody serves a removed device any more, so Mia's tablet hears it from its own family's
      // log: the link says the family left, and its engine for the group goes.
      expect(f.smith.spacesForDevice(f.miaF.deviceId), isNotEmpty);
      expect(f.sHub.spacesForDevice(f.mia.deviceId), isEmpty);
      await sync(f.smith, f.miaF);
      expect(f.miaF.groupLink(f.group)!.status, GroupLinkStatus.left);
      // The Kotvas key makers rotated every key the Smiths held, and agree on the one in use.
      final epoch = f.alex.spaceKeyEpoch(Space.family)!;
      expect(epoch, greaterThan(before));
      expect(f.alex.currentSpaceKey(Space.family)!.revoked, containsAll([f.dana.deviceId, f.mia.deviceId, f.sHub.deviceId]));
      expect(f.alex.staleSpaceKeys, isEmpty);
      expect(f.dana.makesSpaceKeys, isFalse);
      // The Kotvas family carries on.
      final start = clock.now + 86400000;
      await f.alex.addEvent(title: 'Practice', start: start, end: start + 3600000);
      expect(f.alex.groupEnded, isFalse);
      // The Smith family's own log says it left, and its admissions are gone.
      expect(f.smith.groupLink(f.group)!.status, GroupLinkStatus.left);
      expect(f.smith.groupInvites.where((g) => g.group == f.group), isEmpty);
    });

    test('the last family to leave ends the group', () async {
      final f = await bothFamilies(clock);
      await f.sHub.ingest(await f.dana.leaveGroup(family: f.smith));
      await settle(f);
      expect(f.alex.groupEnded, isFalse);
      await f.kHub.ingest(await f.alex.leaveGroup(family: f.kotvas));
      expect(f.kHub.groupEnded, isTrue);
      expect(f.kHub.isApproved, isFalse);
      expect(f.kotvas.groupLink(f.group)!.status, GroupLinkStatus.left);
    });

    test('leaving takes back the invitations the family sent that nobody used', () async {
      final f = await kotvasGroup(clock);
      await inviteSmiths(f);
      await f.alex.leaveGroup();
      expect(f.alex.home(f.smithHome)!.status, HomeStatus.left);
      expect(f.alex.inviteKey(f.invitation.parent.invite)!.key, isNull);
      expect(f.alex.groupEnded, isTrue);
    });

    test('an invitation nobody used yet can be taken back', () async {
      final f = await kotvasGroup(clock);
      await inviteSmiths(f);
      await f.alex.cancelInvitation(f.smithHome);
      expect(f.alex.home(f.smithHome)!.status, HomeStatus.left);
      expect(f.alex.inviteKey(f.invitation.hub.invite)!.key, isNull);
    });
  });
}
