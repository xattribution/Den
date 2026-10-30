import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'group_support.dart';
import 'support.dart';

/// The trust rules of a group of families (groups.dart, G1-G8), each refused case: what
/// another family, a hub, a kid, a shared screen or a family that left may not do. Each change is
/// signed by the device that would send it, past its engine's own checks, and judged by a replica
/// the way every replica judges it (on a fork, so nothing sticks). groups_test.dart has the
/// allowed cases.
void main() {
  const minute = 60000;
  const hour = 60 * minute;

  group('with both families in', () {
    final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
    late Families f;
    late Den display;
    late String kotvasKey;
    late String priyaWords;

    setUpAll(() async {
      f = await bothFamilies(clock);
      // The Kotvas kitchen display, in the group too.
      final kitchen = await joinDevice(f.kotvas, clock, mode: DeviceMode.shared, name: 'Kitchen', kind: DeviceKind.display);
      await f.alex.addToGroup(family: f.kotvas, people: const [], hubs: false);
      await exchange(f.alex, f.kHub);
      display = await admitFrom(f, kitchen, f.kotvas, f.kHub, name: 'Kitchen');
      // A live invite of the Kotvas family, and Priya's recovery words in the group.
      final k = await InviteKey.generate();
      kotvasKey = await f.alex.createInviteKey(member: f.gLeo, publicKey: k.publicKey, expires: clock.now + hour);
      priyaWords = (await RecoveryKey.generate()).publicKey;
      await f.priya.setRecoveryKey(f.gPriya, priyaWords);
      await settle(f);
      clock.advance(const Duration(minutes: 1));
    });

    Future<String?> refused(Den by, String type, String rid, Map<String, Object?> fields,
            {String? actor, String space = Space.family, Den? at}) async =>
        refusal(at ?? f.kHub, await forgeAs(by, type: type, rid: rid, fields: fields, actor: actor, space: space));

    group('G2: another family\'s parent never touches your people or devices', () {
      test('adding someone to your family', () async {
        expect(await refused(f.dana, RecordType.member, newId(), {'name': 'Mallory', 'role': 'parent', 'home': f.kotvasHome}, actor: f.gDana),
            contains('Kotvas\'s own parents'));
      });

      test('removing, re-roling or granting one of your people', () async {
        expect(await refused(f.dana, RecordType.member, f.gLeo, {'_deleted': true}, actor: f.gDana), contains('Kotvas\'s own parents'));
        expect(await refused(f.dana, RecordType.member, f.gPriya, {'role': 'adult'}, actor: f.gDana), contains('Kotvas\'s own parents'));
        expect(await refused(f.dana, RecordType.member, f.gLeo, {'grants': ['events']}, actor: f.gDana), contains('Kotvas\'s own parents'));
        expect(await refused(f.dana, RecordType.member, f.gLeo, {'until': '2026-11-01'}, actor: f.gDana), contains('Kotvas\'s own parents'));
        // The other way round too.
        expect(await refused(f.alex, RecordType.member, f.gMia, {'_deleted': true}, actor: f.gAlex), contains('Smiths\'s own parents'));
      });

      test('changing their name, picture, photo or recovery words', () async {
        expect(await refused(f.dana, RecordType.member, f.gLeo, {'name': 'Leonardo'}, actor: f.gDana), contains('Kotvas\'s own parents'));
        expect(await refused(f.dana, RecordType.member, f.gLeo, {'picture': 'fox'}, actor: f.gDana), contains('Kotvas\'s own parents'));
        expect(
            await refused(f.dana, RecordType.member, f.gPriya, {
              'recovery': {'key': null, 'kept': <String>[]},
            }, actor: f.gDana),
            contains('Kotvas\'s own parents'));
        expect(
            await refused(f.dana, RecordType.photo, newId(), {'member': f.gLeo, 'mime': Photo.jpeg, 'data': _tinyJpeg}, actor: f.gDana),
            anyOf(contains('own family can change'), contains('photo')));
      });

      test('revoking, re-moding or renaming one of your devices', () async {
        expect(await refused(f.dana, RecordType.device, f.leo.deviceId, {'revoked': true, 'revokedAfter': 1}, actor: f.gDana),
            contains('Kotvas\'s own parents'));
        expect(await refused(f.dana, RecordType.device, f.kHub.deviceId, {'mode': 'personal', 'member': f.gDana}, actor: f.gDana),
            anyOf(contains('Kotvas\'s own parents'), contains('owner\'s family')));
        expect(await refused(f.dana, RecordType.device, display.deviceId, {'name': 'Mine now'}, actor: f.gDana),
            contains('Kotvas\'s own parents'));
      });

      test('approving a device that asked to join as one of yours', () async {
        // It asks to join as one of the Kotvas family's.
        final tablet = await DeviceKeys.generate();
        final tabletId = await tablet.deviceId();
        final asked = await forge(tablet, counter: 1, millis: clock.now + 500, type: RecordType.device, rid: tabletId, fields: {
          'name': 'Tablet',
          'kind': 'tablet',
          'pubkey': tablet.pubkey,
          'mode': 'personal',
          'approved': false,
          'home': f.kotvasHome,
        });
        final fork = await f.kHub.fork();
        expect((await fork.ingest([asked])).invalid, isEmpty);
        final approval = await forgeAs(f.dana, type: RecordType.device, rid: tabletId, actor: f.gDana, fields: {
          'approved': true,
          'approvedBy': f.gDana,
          'member': f.gLeo,
          'mode': 'personal',
        });
        expect((await fork.ingest([approval])).invalid[approval.id], contains('Kotvas\'s own parents'));
        // Nor may Dana approve it as hers: it asked to be a Kotvas device.
        final asHers = await forgeAs(f.dana, type: RecordType.device, rid: tabletId, actor: f.gDana, skip: 1, fields: {
          'approved': true,
          'approvedBy': f.gDana,
          'member': f.gDana,
          'mode': 'personal',
        });
        expect((await fork.ingest([asHers])).invalid[asHers.id], contains('owner\'s family'));
        // Kotvas's own parent may.
        final byAlex = await forgeAs(f.alex, type: RecordType.device, rid: tabletId, actor: f.gAlex, fields: {
          'approved': true,
          'approvedBy': f.gAlex,
          'member': f.gLeo,
          'mode': 'personal',
        });
        expect((await fork.ingest([byAlex])).invalid, isEmpty);
      });

      test('making or taking back an invite for your family', () async {
        final k = await InviteKey.generate();
        expect(
            await refused(f.dana, RecordType.inviteKey, k.id, {
              'member': f.gLeo,
              'home': f.kotvasHome,
              'key': k.publicKey,
              'by': f.gDana,
              'device': f.dana.deviceId,
              'expires': clock.now + hour,
            }, actor: f.gDana),
            contains('Kotvas\'s own parents'));
        // Nor one for its own family naming someone of yours.
        expect(
            await refused(f.dana, RecordType.inviteKey, k.id, {
              'member': f.gLeo,
              'home': f.smithHome,
              'key': k.publicKey,
              'by': f.gDana,
              'device': f.dana.deviceId,
              'expires': clock.now + hour,
            }, actor: f.gDana),
            contains('another family'));
        expect(await refused(f.dana, RecordType.inviteKey, kotvasKey, {'key': null, 'kept': <String>[]}, actor: f.gDana),
            contains('Kotvas\'s own parents'));
      });

      test('a trust decision through a hub, even its own family\'s, is refused: own devices only', () async {
        expect(
            await refused(f.kHub, RecordType.member, newId(), {'name': 'Cousin', 'role': 'kid', 'home': f.kotvasHome, '_via': 'Claude'},
                actor: f.gAlex),
            contains('own device'));
      });
    });

    group('G3: a family in the group changes only by its own parents', () {
      test('another family can\'t change your hubs, color or name, or take you out', () async {
        expect(await refused(f.dana, RecordType.home, f.kotvasHome, {'hubs': ['https://evil.example/ws']}, actor: f.gDana),
            contains('Kotvas\'s own parents'));
        expect(await refused(f.dana, RecordType.home, f.kotvasHome, {'color': 'coral'}, actor: f.gDana), contains('Kotvas\'s own parents'));
        expect(await refused(f.dana, RecordType.home, f.kotvasHome, {'status': 'left'}, actor: f.gDana), contains('Kotvas\'s own parents'));
      });

      test('a family joins only by invitation, naming who invited it, by an id bound to its key and the device that sends it', () async {
        final key = (await InviteKey.generate()).publicKey;
        final id = homeIdFor(key, f.alex.deviceId);
        Map<String, Object?> lees([Map<String, Object?> extra = const {}]) =>
            {'name': 'Lees', 'status': 'invited', 'invitedBy': f.kotvasHome, 'key': key, ...extra};
        expect(await refused(f.alex, RecordType.home, id, lees({'status': 'active'}), actor: f.gAlex), contains('invited'));
        expect(await refused(f.alex, RecordType.home, id, lees({'invitedBy': f.smithHome}), actor: f.gAlex), contains('names the family that sent it'));
        // Where the invited family's Den is (its own log's id, fixed once said, and its hubs) is
        // for that family to say.
        for (final extra in [
          {'family': 'somefamily'},
          {'hubs': ['https://evil.example/ws']},
        ]) {
          expect(await refused(f.alex, RecordType.home, id, lees(extra), actor: f.gAlex), contains('says where its Den is itself'));
        }
        // Its id is its invitation's: another id, another key, or another device's, is refused,
        // so nobody else makes a home by that id first.
        expect(await refused(f.alex, RecordType.home, newId(), lees(), actor: f.gAlex), contains('invitation\'s'));
        expect(await refused(f.alex, RecordType.home, id, lees({'key': (await InviteKey.generate()).publicKey}), actor: f.gAlex),
            contains('invitation\'s'));
        final dana = lees({'invitedBy': f.smithHome});
        expect(await refused(f.dana, RecordType.home, id, dana, actor: f.gDana), contains('invitation\'s'));
        expect(await refused(f.alex, RecordType.home, id, lees(), actor: f.gAlex), isNull);
      });

      test('a family\'s record stays, its id is fixed once set, and in is in', () async {
        expect(await refused(f.dana, RecordType.home, f.smithHome, {'_deleted': true}, actor: f.gDana), contains('record stays'));
        expect(await refused(f.dana, RecordType.home, f.smithHome, {'family': 'someotherfamily'}, actor: f.gDana), contains('can\'t change'));
        expect(await refused(f.dana, RecordType.home, f.smithHome, {'status': 'invited'}, actor: f.gDana), contains('back to invited'));
        expect(await refused(f.dana, RecordType.home, f.smithHome, {'invitedBy': f.smithHome}, actor: f.gDana), contains('can\'t be changed'));
      });

      test('the inviting family can\'t take back an invitation once the other family is in', () async {
        expect(await refused(f.alex, RecordType.home, f.smithHome, {'status': 'left'}, actor: f.gAlex), contains('Smiths\'s own parents'));
      });

      test('home changes are a parent\'s, on their own device', () async {
        expect(await refused(f.leo, RecordType.home, f.kotvasHome, {'color': 'grass'}, actor: f.gLeo), contains('Only parents'));
        expect(await refused(f.kHub, RecordType.home, f.kotvasHome, {'color': 'grass', '_via': 'Claude'}, actor: f.gAlex), contains('own device'));
      });
    });

    group('G4: a hub acts only for its own family\'s people, never for nobody', () {
      final start = DateTime.utc(2026, 11, 1, 15).millisecondsSinceEpoch;
      Map<String, Object?> event(Map<String, Object?> extra) => {'title': 'Practice', 'start': start, 'end': start + hour, ...extra};

      test('the Smith hub acting for a Kotvas parent', () async {
        expect(await refused(f.sHub, RecordType.event, newId(), event({'_via': 'Claude'}), actor: f.gAlex),
            contains('its own family\'s people'));
      });

      test('a hub acting for nobody, through a connection or not', () async {
        expect(await refused(f.sHub, RecordType.event, newId(), event({'_via': 'Claude'})), contains('never for nobody'));
        expect(await refused(f.kHub, RecordType.event, newId(), event({})), contains('never for nobody'));
      });

      test('a hub acting for someone without saying which connection', () async {
        expect(await refused(f.kHub, RecordType.event, newId(), event({}), actor: f.gAlex), contains('which connection'));
      });

      test('a hub acting for its own people never touches a device record, nor writes where they can\'t read', () async {
        expect(await refused(f.kHub, RecordType.device, f.leo.deviceId, {'name': 'X', '_via': 'Claude'}, actor: f.gAlex),
            contains('own device'));
        expect(await refused(f.kHub, RecordType.device, f.kHub.deviceId, {'name': 'X', '_via': 'Claude'}, actor: f.gAlex),
            contains('own device'));
        expect(await refused(f.kHub, RecordType.list, newId(), {'title': 'Leo\'s', '_via': 'Claude'}, actor: f.gAlex, space: Space.member(f.gLeo)),
            contains('no one\'s own space'));
        expect(await refused(f.kHub, RecordType.list, newId(), {'title': 'Alex\'s', '_via': 'Claude'}, actor: f.gAlex, space: Space.member(f.gAlex)),
            contains('no one\'s own space'));
      });

      test('a shared screen only shows a group: no check-off, for nobody or anyone', () async {
        final list = f.kHub.lists.isEmpty ? null : f.kHub.lists.first.list.id;
        expect(await refused(display, RecordType.list, list ?? newId(), {'title': 'From the kitchen'}), contains('shared screen'));
        expect(await refused(display, RecordType.list, newId(), {'title': 'From the kitchen'}, actor: f.gLeo), contains('shared screen'));
      });
    });

    group('G5: a group has no one\'s own space', () {
      test('nobody writes into one, the person themself included', () async {
        // "Just me" things stay in each family's own Den: a group's people are seen by other
        // families' parents and hubs, so a group holds none (review finding 5).
        expect(await refused(f.dana, RecordType.list, newId(), {'title': 'For Leo'}, actor: f.gDana, space: Space.member(f.gLeo)),
            contains('no one\'s own space'));
        expect(await refused(f.alex, RecordType.list, newId(), {'title': 'For Leo'}, actor: f.gAlex, space: Space.member(f.gLeo)),
            contains('no one\'s own space'));
        expect(await refused(f.alex, RecordType.list, newId(), {'title': 'Mine'}, actor: f.gAlex, space: Space.member(f.gAlex)),
            contains('no one\'s own space'));
        expect(await refused(f.dana, RecordType.event, newId(), {'title': 'Mine', 'start': clock.now, 'end': clock.now + hour}, actor: f.gDana,
                space: Space.member(f.gDana)),
            contains('no one\'s own space'));
      });

      test('a kid never writes into the parents\' space', () async {
        expect(await refused(f.leo, RecordType.list, newId(), {'title': 'Parents'}, actor: f.gLeo, space: Space.parents),
            contains('Only parents'));
      });
    });

    group('G7: what stays in each family\'s own log', () {
      test('chores, stars, feeds, connections, sign-in tries and family records about groups', () async {
        final cases = <String, (Map<String, Object?>, String)>{
          RecordType.chore: ({'title': 'Dishes', 'owner': {'kind': 'anyone'}, 'schedule': {'once': '2026-11-01'}}, Space.family),
          RecordType.completion: ({'chore': 'c1', 'date': '2026-11-01', 'done': true}, Space.family),
          RecordType.adjustment: ({'member': f.gLeo, 'delta': 5, 'by': f.gAlex}, Space.family),
          RecordType.goal: ({'title': 'Read', 'target': 5, 'start': '2026-11-01'}, Space.family),
          RecordType.reward: ({'title': 'Movie', 'cost': 5}, Space.family),
          RecordType.redemption: ({'reward': 'r1', 'member': f.gLeo, 'cost': 5, 'status': 'requested'}, Space.family),
          RecordType.subscription: ({'url': 'https://example.com/cal.ics'}, Space.parents),
          RecordType.connection: ({'label': 'Claude', 'kind': 'token', 'scopes': ['read'], 'status': 'active'}, Space.parents),
          RecordType.groupLink: ({'group': 'g1', 'founder': priyaWords, 'name': 'X', 'status': 'active'}, Space.family),
        };
        for (final e in cases.entries) {
          final rid = e.key == RecordType.groupLink ? 'g1' : (e.key == RecordType.completion ? 'c1@2026-11-01' : newId());
          expect(await refused(f.alex, e.key, rid, e.value.$1, actor: f.gAlex, space: e.value.$2), contains('doesn\'t hold'), reason: e.key);
        }
        expect(
            await refused(display, RecordType.signInTries, newId(), {'device': display.deviceId, 'member': f.gLeo, 'tries': 10}),
            contains('doesn\'t hold'));
        await expectLater(
          f.alex.addChore(title: 'Dishes', owner: const OwnerAnyone(), schedule: const ChoreSchedule.once('2026-11-01')),
          throwsA(isA<InvalidInput>()),
        );
      });

      test('a group has no privacy settings, assistant, server help or stars; PINs stay home', () async {
        final group = f.group;
        expect(await refused(f.alex, RecordType.family, group, {'oversight.${f.gLeo}': {'parentsSeePrivate': true}}, actor: f.gAlex),
            contains('privacy'));
        expect(await refused(f.alex, RecordType.family, group, {'assistant': {'enabled': true}}, actor: f.gAlex), contains('assistant'));
        expect(await refused(f.alex, RecordType.family, group, {'recovery': {'serverKey': priyaWords, 'kept': <String>[]}}, actor: f.gAlex),
            contains('server help'));
        expect(await refused(f.alex, RecordType.family, group, {'pointsEnabled': true}, actor: f.gAlex), contains('Stars'));
        expect(await refused(f.alex, RecordType.family, group, {'_deleted': true}, actor: f.gAlex), contains('last family leaves'));
        expect(await refused(f.alex, RecordType.family, group, {'kind': 'family'}, actor: f.gAlex), contains('can\'t be changed'));
        expect(
            await refused(f.alex, RecordType.member, f.gAlex, {
              'signIn': {'kind': 'pin', 'salt': 'abc', 'hash': 'def'},
            }, actor: f.gAlex),
            contains('PINs'));
      });

      test('a family\'s own log refuses what only a group holds', () async {
        final kotvas = f.kotvas;
        final alex = f.kAlex;
        Future<String?> inFamily(String type, String rid, Map<String, Object?> fields) async =>
            refusal(kotvas, await forgeAs(kotvas, type: type, rid: rid, fields: fields, actor: alex));
        expect(await inFamily(RecordType.home, newId(), {'name': 'Kotvas', 'status': 'active'}), contains('Only a group'));
        expect(await inFamily(RecordType.member, newId(), {'name': 'X', 'role': 'kid', 'home': 'h1'}), contains('Only a person in a group'));
        expect(await inFamily(RecordType.member, f.kLeo, {'link': 'x1'}), contains('Only a person in a group'));
        expect(await inFamily(RecordType.device, f.leoF.deviceId, {'home': 'h1'}), contains('Only a device in a group'));
        expect(await inFamily(RecordType.family, kotvas.familyId!, {'kind': 'group'}), contains('can\'t be changed'));
        final k = await InviteKey.generate();
        expect(
            await inFamily(RecordType.inviteKey, k.id, {
              'member': f.kLeo,
              'home': 'h1',
              'key': k.publicKey,
              'by': alex,
              'device': kotvas.deviceId,
              'expires': clock.now + hour,
            }),
            contains('Only a group\'s invite'));
        // And a family's group records are a parent's, on their own device.
        final leo = f.leoF;
        expect(
            await refusal(kotvas, await forgeAs(leo, type: RecordType.groupLink, rid: 'g2', actor: f.kLeo, fields: {
              'group': 'g2',
              'founder': priyaWords,
              'name': 'X',
              'status': 'active',
            })),
            contains('own device'));
      });
    });

    group('G1: a person\'s family and a device\'s are fixed', () {
      test('a person needs a family, and keeps theirs', () async {
        expect(await refused(f.alex, RecordType.member, newId(), {'name': 'X', 'role': 'kid'}, actor: f.gAlex), contains('belongs to one of its families'));
        expect(await refused(f.alex, RecordType.member, f.gLeo, {'home': f.smithHome}, actor: f.gAlex), contains('can\'t be changed'));
        expect(await refused(f.alex, RecordType.member, newId(), {'name': 'X', 'role': 'kid', 'home': 'nowhere'}, actor: f.gAlex),
            contains('isn\'t in the group'));
      });

      test('a device keeps its family, and a personal one is its owner\'s', () async {
        expect(await refused(f.alex, RecordType.device, f.leo.deviceId, {'home': f.smithHome}, actor: f.gAlex), contains('can\'t change'));
        expect(await refused(f.leo, RecordType.device, f.leo.deviceId, {'home': f.smithHome}, actor: f.gLeo), contains('can\'t change'));
      });
    });

    group('G8: every family keeps a parent until it leaves', () {
      test('the last parent of a family can\'t be removed or made anything else', () async {
        expect(await refused(f.dana, RecordType.member, f.gDana, {'_deleted': true}, actor: f.gDana), contains('at least one parent'));
        expect(await refused(f.dana, RecordType.member, f.gDana, {'role': 'adult'}, actor: f.gDana), contains('at least one parent'));
      });
    });

    group('kids, by their own parents\' grants', () {
      final start = DateTime.utc(2026, 11, 1, 15).millisecondsSinceEpoch;

      test('without a grant a kid adds no event or list, and edits no item', () async {
        expect(await refused(f.leo, RecordType.event, newId(), {'title': 'Party', 'start': start, 'end': start + hour}, actor: f.gLeo),
            contains('can\'t add or change events'));
        expect(await refused(f.leo, RecordType.list, newId(), {'title': 'Mine'}, actor: f.gLeo), contains('can\'t add or change lists'));
      });

      test('a kid never drives, and a driver must be someone of the group who does', () async {
        final game = newId();
        final fork = await f.kHub.fork();
        await fork.ingest([
          await forgeAs(f.alex, type: RecordType.event, rid: game, actor: f.gAlex, fields: {
            'title': 'Game',
            'start': start,
            'end': start + hour,
            'drivers': {'to': null, 'from': null},
          }),
        ]);
        Future<String?> claim(Den by, String actor, String? driver) async {
          final c = await forgeAs(by, type: RecordType.event, rid: game, actor: actor, fields: {'drivers.to': driver}, millis: clock.now + 5000, skip: 1);
          return (await (await fork.fork()).ingest([c])).invalid[c.id];
        }

        expect(await claim(f.alex, f.gAlex, f.gLeo), contains('Leo can\'t drive'));
        expect(await claim(f.dana, f.gDana, f.gMia), contains('Mia can\'t drive'));
        expect(await claim(f.alex, f.gAlex, 'nobodyhere'), contains('isn\'t in the group'));
        expect(await claim(f.leo, f.gLeo, f.gAlex), contains('can\'t add or change events'), reason: 'no grant yet');
        expect(await claim(f.dana, f.gDana, f.gAlex), isNull, reason: 'a parent of either family names any parent');
      });
    });
  });

  group('G2: the invited family\'s window', () {
    final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
    late Families f;
    late GroupInvitation lees;
    late Den jun;

    setUpAll(() async {
      f = await kotvasGroup(clock);
      // The Lees are in already; then Alex invites the Smiths, and nobody of them is in yet.
      lees = await f.alex.inviteFamily(familyName: 'Lees', parentName: 'Jun');
      await exchange(f.alex, f.kHub);
      jun = await admit(f, lees.parent, f.kHub, name: "Jun's phone");
      await inviteSmiths(f);
      await exchange(jun, f.kHub);
      clock.advance(const Duration(minutes: 1));
    });

    Future<Change> key(Den by, String actor, {String? member, List<String>? modes, int? uses}) async {
      final k = await InviteKey.generate();
      return forgeAs(by, type: RecordType.inviteKey, rid: k.id, actor: actor, fields: {
        'member': member,
        'home': f.smithHome,
        'modes': ?modes,
        'uses': ?uses,
        'key': k.publicKey,
        'by': actor,
        'device': by.deviceId,
        'expires': clock.now + hour,
      });
    }

    test('only the family that sent the invitation stands in for the invited one', () async {
      expect(await refusal(f.kHub, await key(jun, lees.member, member: f.gDana)), contains('Smiths\'s own parents'));
      expect(
          await refusal(f.kHub, await forgeAs(jun, type: RecordType.member, rid: newId(), actor: lees.member, fields: {
            'name': 'Mallory',
            'role': 'parent',
            'home': f.smithHome,
          })),
          contains('Smiths\'s own parents'));
      expect(await refusal(f.kHub, await forgeAs(jun, type: RecordType.home, rid: f.smithHome, actor: lees.member, fields: {'status': 'left'})),
          contains('Smiths\'s own parents'));
      // The inviting family may take it back, while the window is open.
      expect(await refusal(f.kHub, await forgeAs(f.alex, type: RecordType.home, rid: f.smithHome, actor: f.gAlex, fields: {'status': 'left'})),
          isNull);
    });

    test('it adds the first parent only, and the one key the invitation is bound to, for that parent\'s phone', () async {
      Future<String?> person(String role) async => refusal(
          f.kHub,
          await forgeAs(f.alex, type: RecordType.member, rid: newId(), actor: f.gAlex, fields: {
            'name': 'Second',
            'role': role,
            'home': f.smithHome,
          }));
      expect(await person('parent'), contains('add the rest of their family themselves'));
      expect(await person('kid'), contains('first person of an invited family is a parent'));
      // No second key, for that parent, a hub or a shared screen: the home's id is bound to one.
      expect(await refusal(f.kHub, await key(f.alex, f.gAlex, member: f.gDana)), contains('its own key'));
      expect(await refusal(f.kHub, await key(f.alex, f.gAlex, member: f.gDana, uses: 2)), contains('its own key'));
      expect(await refusal(f.kHub, await key(f.alex, f.gAlex, modes: ['hub'])), contains('its own key'));
      expect(await refusal(f.kHub, await key(f.alex, f.gAlex, modes: ['shared'])), contains('its own key'));
    });

    /// Dana's phone, let in on a fork of the Kotvas hub with the invitation, and then saying the
    /// Smiths are in (which shuts the window): the fork and her engine.
    Future<(Den, Den)> danaIn(Den fork, {bool active = true}) async {
      clock.advance(const Duration(seconds: 1));
      final dana = await openDen(clock);
      await dana.joinGroup(f.invitation.parent, deviceName: "Dana's phone", kind: DeviceKind.phone);
      expect((await fork.ingest(dana.changesSince(const {}))).invalid, isEmpty);
      if (active) {
        await dana.ingest(fork.changesSince(dana.versionVector));
        clock.advance(const Duration(seconds: 1));
        await dana.updateHome(active: true);
        expect((await fork.ingest(dana.changesSince(fork.versionVector))).invalid, isEmpty);
      }
      return (fork, dana);
    }

    test('once the first parent is in, the inviting family adds nobody else; once they say they\'re in, the window shuts', () async {
      final (fork, _) = await danaIn(await f.kHub.fork(), active: false);
      Future<String?> later(Change c) async => (await (await fork.fork()).ingest([c])).invalid[c.id];
      expect(fork.invitationOpen(f.smithHome), isTrue, reason: 'until Dana says the Smiths are in');
      expect(
          await later(await forgeAs(f.alex, type: RecordType.member, rid: newId(), actor: f.gAlex, fields: {
            'name': 'Second',
            'role': 'parent',
            'home': f.smithHome,
          })),
          contains('add the rest'));
      // Still theirs to take back, until the Smiths say they're in.
      expect(await later(await forgeAs(f.alex, type: RecordType.home, rid: f.smithHome, actor: f.gAlex, fields: {'status': 'left'})), isNull);

      final (shut, dana) = await danaIn(await f.kHub.fork());
      expect(shut.invitationOpen(f.smithHome), isFalse);
      expect(shut.home(f.smithHome)!.status, HomeStatus.active);
      Future<String?> after(Change c) async => (await (await shut.fork()).ingest([c])).invalid[c.id];
      expect(await after(await key(f.alex, f.gAlex, member: f.gDana)), contains('Smiths\'s own parents'));
      expect(
          await after(await forgeAs(f.alex, type: RecordType.home, rid: f.smithHome, actor: f.gAlex, fields: {'status': 'left'})),
          contains('Smiths\'s own parents'));
      expect(
          await after(await forgeAs(f.alex, type: RecordType.device, rid: dana.deviceId, actor: f.gAlex,
              fields: {'revoked': true, 'revokedAfter': 1})),
          contains('Smiths\'s own parents'));
    });

    test('"we\'re in" is said by the phone the invitation let in, names what it heard, and counts only if it holds', () async {
      final (fork, dana) = await danaIn(await f.kHub.fork(), active: false);
      await dana.ingest(fork.changesSince(dana.versionVector));
      Future<String?> judged(Change c) async => (await (await fork.fork()).ingest([c])).invalid[c.id];
      final bare = await forgeAs(dana, type: RecordType.home, rid: f.smithHome, actor: f.gDana, fields: {'status': 'active'});
      expect(await judged(bare), contains('names what it heard'));
      // Naming none of the invitation it came in with: it would void its own phone's way in.
      final deaf = await forgeAs(dana, type: RecordType.home, rid: f.smithHome, actor: f.gDana, fields: {'status': 'active', 'heard': <String>[]});
      expect(await judged(deaf), contains('doesn\'t hold'));
      // Nobody else names a window's closing: the inviting family least of all.
      final byAlex = await forgeAs(f.alex, type: RecordType.home, rid: f.smithHome, actor: f.gAlex, fields: {'status': 'active', 'heard': <String>[]});
      expect(await judged(byAlex), contains('Smiths\'s own parents'));
      final onKotvas = await forgeAs(f.alex, type: RecordType.home, rid: f.kotvasHome, actor: f.gAlex, fields: {'name': 'Kotvas', 'heard': <String>[]});
      expect(await judged(onKotvas), contains('Only saying an invited family is in'));
    });

    test('another phone with the invitation\'s key counts only until the family says it\'s in: the phone that says so is the one that stays', () async {
      final fork = await f.kHub.fork();
      final (_, dana) = await danaIn(fork, active: false);
      clock.advance(const Duration(seconds: 5));
      // Another "Dana" with the same key, while the window is still open: it counts for now.
      final other = await openDen(clock);
      await other.joinGroup(f.invitation.parent, deviceName: 'Another "Dana"', kind: DeviceKind.phone);
      expect((await fork.ingest(other.changesSince(const {}))).invalid, isEmpty);
      expect(fork.deviceCounts(other.deviceId), isTrue);
      expect(fork.windowAdmissions(f.smithHome).map((a) => a.device), [dana.deviceId, other.deviceId]);
      // The real Dana's phone, knowing of the other, says the Smiths are in only once Dana says
      // the other isn't hers: then the other is gone.
      await dana.ingest(fork.changesSince(dana.versionVector));
      clock.advance(const Duration(seconds: 1));
      await expectLater(dana.updateHome(active: true), throwsA(isA<InvalidInput>()));
      await dana.updateHome(active: true, notOurs: true);
      expect((await fork.ingest(dana.changesSince(fork.versionVector))).invalid, isEmpty);
      expect(fork.deviceCounts(other.deviceId), isFalse);
      expect(fork.deviceCounts(dana.deviceId), isTrue);
      expect(fork.windowAdmissions(f.smithHome).map((a) => (a.device, a.counts)), [(dana.deviceId, true), (other.deviceId, false)]);
      // And the key lets nobody in after.
      clock.advance(const Duration(seconds: 5));
      final third = await openDen(clock);
      await third.joinGroup(f.invitation.parent, deviceName: 'A third "Dana"', kind: DeviceKind.phone);
      expect((await fork.ingest(third.changesSince(const {}))).invalid.values.single, contains('in the group already'));
    });

    test('an invitation lets in no hub and no shared screen: the family\'s hub joins after, with a key of its own', () async {
      final fork = await f.kHub.fork();
      Future<String?> joinAs(DeviceMode mode) async {
        clock.advance(const Duration(seconds: 1));
        final d = await openDen(clock);
        final p = f.invitation.parent;
        await d.joinGroup(
          GroupAdmission(group: p.group, founder: p.founder, name: p.name, home: p.home, member: null, mode: mode, invite: p.invite, seed: p.seed, expires: p.expires),
          deviceName: 'Hub?',
          kind: mode == DeviceMode.hub ? DeviceKind.hub : DeviceKind.display,
        );
        return (await (await fork.fork()).ingest(d.changesSince(const {}))).invalid.values.firstOrNull;
      }

      expect(await joinAs(DeviceMode.hub), isNotNull);
      expect(await joinAs(DeviceMode.shared), isNotNull);
      // Once Dana says they're in, her phone makes the hub's key.
      final (_, dana) = await danaIn(fork);
      final hubKey = await InviteKey.generate();
      await dana.createInviteKey(member: null, publicKey: hubKey.publicKey, expires: clock.now + hour, modes: const {DeviceMode.hub});
      expect((await fork.ingest(dana.changesSince(fork.versionVector))).invalid, isEmpty);
      clock.advance(const Duration(seconds: 1));
      final hub = await openDen(clock);
      await hub.joinGroup(
        GroupAdmission(group: f.group, founder: f.alex.founderPubkey!, name: 'x', home: f.smithHome, member: null, mode: DeviceMode.hub,
            invite: hubKey.id, seed: await hubKey.seed(), expires: clock.now + 30 * minute),
        deviceName: 'Smith hub',
        kind: DeviceKind.hub,
      );
      expect((await fork.ingest(hub.changesSince(const {}))).invalid, isEmpty);
      expect(fork.deviceCounts(hub.deviceId), isTrue);
    });

    test('before "we\'re in", the inviting family only takes the invitation back: it never removes a device or turns off words', () async {
      final fork = await f.kHub.fork();
      final (_, dana) = await danaIn(fork, active: false);
      Future<String?> later(Change c) async => (await (await fork.fork()).ingest([c])).invalid[c.id];
      final removal = {'revoked': true, 'revokedAfter': 1};
      expect(await later(await forgeAs(jun, type: RecordType.device, rid: dana.deviceId, actor: lees.member, fields: removal)),
          contains('Smiths\'s own parents'));
      expect(await later(await forgeAs(f.alex, type: RecordType.device, rid: dana.deviceId, actor: f.gAlex, fields: removal)),
          contains('Smiths\'s own parents'));
      expect(
          await later(await forgeAs(f.alex, type: RecordType.member, rid: f.gDana, actor: f.gAlex, fields: {
            'recovery': {'key': null, 'kept': <String>[]},
          })),
          contains('Smiths\'s own parents'));
      expect(await later(await forgeAs(f.alex, type: RecordType.inviteKey, rid: f.invitation.parent.invite, actor: f.gAlex,
              fields: {'key': null, 'kept': <String>[]})),
          contains('Smiths\'s own parents'));
      // "That wasn't them" before they say they're in is taking it back; disowning is for after.
      expect(await later(await forgeAs(f.alex, type: RecordType.home, rid: f.smithHome, actor: f.gAlex, fields: {'disowned': true})),
          contains('within a day'));
      expect(await later(await forgeAs(f.alex, type: RecordType.home, rid: f.smithHome, actor: f.gAlex, fields: {'status': 'left'})), isNull);
    });
  });

  group('G6: letting yourself in', () {
    final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
    late Families f;

    setUpAll(() async {
      f = await bothFamilies(clock);
      clock.advance(const Duration(minutes: 1));
    });

    /// A key Alex makes for the Kotvas family, synced to the hub.
    Future<(InviteKey, Den)> kotvasKey({String? member, Set<DeviceMode> modes = const {DeviceMode.personal}, Duration life = const Duration(hours: 1)}) async {
      final k = await InviteKey.generate();
      final fork = await f.kHub.fork();
      final alex = await f.alex.fork();
      await alex.createInviteKey(member: member, publicKey: k.publicKey, expires: clock.now + life.inMilliseconds, modes: modes);
      await fork.ingest(alex.changesSince(fork.versionVector));
      clock.advance(const Duration(seconds: 2));
      return (k, fork);
    }

    Future<Change> join(InviteKey k, {String? member, DeviceMode mode = DeviceMode.personal, String? home, int? expires, int? millis, String? nonce}) async {
      final device = await DeviceKeys.generate();
      final at = millis ?? clock.now;
      final exp = expires ?? at + 10 * minute;
      final n = nonce ?? b64e(randomBytes(16));
      final sig = await k.sign(InviteProof.bytes(
        family: f.group,
        invite: k.id,
        member: member,
        mode: mode,
        devicePubkey: device.pubkey,
        nonce: n,
        expires: exp,
      ));
      return forge(device, counter: 1, millis: at, type: RecordType.device, rid: await device.deviceId(), fields: {
        'name': 'New',
        'kind': 'tablet',
        'pubkey': device.pubkey,
        'xpub': device.xpub,
        'member': member,
        'mode': mode.name,
        'approved': true,
        'home': home ?? f.kotvasHome,
        'invite': InviteProof(invite: k.id, member: member, mode: mode, key: k.publicKey, nonce: n, expires: exp, sig: sig).toJson(),
      });
    }

    test('a key of your family lets you in as one of it, and only of it', () async {
      final (k, fork) = await kotvasKey(member: f.gLeo);
      expect((await (await fork.fork()).ingest([await join(k, member: f.gLeo)])).invalid, isEmpty);
      expect((await fork.ingest([await join(k, member: f.gLeo, home: f.smithHome)])).invalid.values.single, contains('another family'));
    });

    test('a key bound to a mode lets in only that kind of device', () async {
      final (k, fork) = await kotvasKey(modes: const {DeviceMode.hub});
      expect((await fork.ingest([await join(k, mode: DeviceMode.shared)])).invalid.values.single, contains('kind of device'));
    });

    test('an expired, used-up or reused key lets nobody in', () async {
      final (short, fork) = await kotvasKey(member: f.gLeo, life: const Duration(minutes: 5));
      expect((await (await fork.fork()).ingest([await join(short, member: f.gLeo, millis: clock.now + 10 * minute)])).invalid.values.single,
          contains('expired'));
      final (k, fork2) = await kotvasKey(member: f.gLeo);
      final first = await join(k, member: f.gLeo);
      expect((await fork2.ingest([first])).invalid, isEmpty);
      clock.advance(const Duration(seconds: 2));
      expect((await (await fork2.fork()).ingest([await join(k, member: f.gLeo)])).invalid.values.single, contains('used already'));
      // The same proof's nonce on another device, even for a key with uses left.
      final (multi, fork3) = await kotvasKey(member: f.gLeo);
      final nonce = b64e(randomBytes(16));
      expect((await fork3.ingest([await join(multi, member: f.gLeo, nonce: nonce)])).invalid, isEmpty);
      clock.advance(const Duration(seconds: 2));
      expect((await fork3.ingest([await join(multi, member: f.gLeo, nonce: nonce)])).invalid.values.single, contains('used already'));
    });

    test('recovery words never the hub\'s, and only as a phone of the person\'s family', () async {
      final words = await RecoveryKey.generate();
      final fork = await f.kHub.fork();
      final dana = await f.dana.fork();
      await dana.setRecoveryKey(f.gDana, words.publicKey);
      await fork.ingest(dana.changesSince(fork.versionVector));
      clock.advance(const Duration(seconds: 2));
      Future<Change> recover(RecoveryKind kind, String home) async {
        final device = await DeviceKeys.generate();
        final proof = await words.prove(family: f.group, kind: kind, member: f.gDana, devicePubkey: device.pubkey, expires: clock.now + 10 * minute);
        return forge(device, counter: 1, millis: clock.now, type: RecordType.device, rid: await device.deviceId(), fields: {
          'name': 'New phone',
          'kind': 'phone',
          'pubkey': device.pubkey,
          'member': f.gDana,
          'mode': 'personal',
          'approved': true,
          'home': home,
          'recovery': proof.toJson(),
        });
      }

      expect((await (await fork.fork()).ingest([await recover(RecoveryKind.words, f.smithHome)])).invalid, isEmpty);
      expect((await (await fork.fork()).ingest([await recover(RecoveryKind.hub, f.smithHome)])).invalid.values.single, contains('server help'));
      expect((await (await fork.fork()).ingest([await recover(RecoveryKind.words, f.kotvasHome)])).invalid.values.single,
          contains('person\'s family'));
    });
  });

  group('G8: after a family leaves', () {
    final clock = TestClock.at(DateTime.utc(2026, 10, 29, 15));
    late Families f;
    late List<Change> leave;
    late RecoveryKey words;
    late InviteKey spare;

    setUpAll(() async {
      f = await bothFamilies(clock);
      // Before leaving, Dana copied her words into the group and made a key nobody used.
      words = await RecoveryKey.generate();
      await f.dana.setRecoveryKey(f.gDana, words.publicKey);
      spare = await InviteKey.generate();
      await f.dana.createInviteKey(member: f.gMia, publicKey: spare.publicKey, expires: clock.now + 2 * hour);
      await settle(f);
      clock.advance(const Duration(minutes: 1));
      leave = await f.dana.leaveGroup(family: f.smith);
      await f.sHub.ingest(leave);
      await settle(f);
      clock.advance(const Duration(minutes: 1));
    });

    test('nothing of it counts: its devices, its hub through a connection, its people', () async {
      final start = clock.now + 86400000;
      final event = {'title': 'Party', 'start': start, 'end': start + hour};
      expect(await refusal(f.kHub, await forgeAs(f.mia, type: RecordType.event, rid: newId(), fields: event, actor: f.gMia)),
          anyOf(contains('removed'), contains('left the group')));
      expect(await refusal(f.kHub, await forgeAs(f.sHub, type: RecordType.event, rid: newId(), fields: {...event, '_via': 'Claude'}, actor: f.gDana)),
          anyOf(contains('removed'), contains('left the group')));
      // Nor does anything another family writes bring it back.
      expect(
          await refusal(f.kHub, await forgeAs(f.alex, type: RecordType.home, rid: f.smithHome, fields: {'status': 'active'}, actor: f.gAlex)),
          contains('left the group'));
      expect(
          await refusal(f.kHub, await forgeAs(f.alex, type: RecordType.member, rid: f.gDana, fields: {'_deleted': false}, actor: f.gAlex)),
          contains('left the group'));
    });

    test('the leaving phone\'s later changes count for nothing, whatever clock they claim', () async {
      final last = leave.last;
      final backdated = await forge(f.dana.keys, counter: last.counter + 1, millis: leave.first.hlc.millis - 60000, type: RecordType.list, rid: newId(),
          fields: {'title': 'Backdated'}, actor: f.gDana);
      expect(await refusal(f.kHub, backdated), contains('removed'));
      final after = await forge(f.dana.keys, counter: last.counter + 2, millis: clock.now, type: RecordType.list, rid: newId(),
          fields: {'title': 'After'}, actor: f.gDana);
      expect(await refusal(f.kHub, after), contains('removed'));
    });

    test('its parents\' words let no new phone in, backdated or not', () async {
      Future<Change> recover(int millis) async {
        final device = await DeviceKeys.generate();
        final proof = await words.prove(family: f.group, kind: RecoveryKind.words, member: f.gDana, devicePubkey: device.pubkey, expires: millis + 10 * minute);
        return forge(device, counter: 1, millis: millis, type: RecordType.device, rid: await device.deviceId(), fields: {
          'name': 'New phone',
          'kind': 'phone',
          'pubkey': device.pubkey,
          'member': f.gDana,
          'mode': 'personal',
          'approved': true,
          'home': f.smithHome,
          'recovery': proof.toJson(),
        });
      }

      expect(await refusal(f.kHub, await recover(clock.now)), contains('left the group'));
      // Clocked before the leave, when the family was in: the leave turned the words off, keeping
      // no phone they let in, so it counts for nothing all the same.
      expect(await refusal(f.kHub, await recover(leave.first.hlc.millis - 1000)), contains('replaced'));
    });

    test('a key its family made lets nobody in, backdated or not', () async {
      Future<Change> join(int millis) async {
        final device = await DeviceKeys.generate();
        final proof = await spare.prove(family: f.group, member: f.gMia, devicePubkey: device.pubkey, expires: millis + 10 * minute);
        return forge(device, counter: 1, millis: millis, type: RecordType.device, rid: await device.deviceId(), fields: {
          'name': 'New tablet',
          'kind': 'tablet',
          'pubkey': device.pubkey,
          'member': f.gMia,
          'mode': 'personal',
          'approved': true,
          'home': f.smithHome,
          'invite': proof.toJson(),
        });
      }

      expect(await refusal(f.kHub, await join(clock.now)), contains('left the group'));
      expect(await refusal(f.kHub, await join(leave.first.hlc.millis - 1000)), contains('withdrawn'));
    });

    test('another family can\'t invite people into it', () async {
      final k = await InviteKey.generate();
      final made = await forgeAs(f.alex, type: RecordType.inviteKey, rid: k.id, actor: f.gAlex, fields: {
        'member': null,
        'home': f.smithHome,
        'modes': ['hub'],
        'key': k.publicKey,
        'by': f.gAlex,
        'device': f.alex.deviceId,
        'expires': clock.now + hour,
      });
      expect(await refusal(f.kHub, made), contains('left the group'));
    });
  });
}

/// A 256 px JPEG header is enough to be refused for whose photo it is before anything reads it.
const String _tinyJpeg = '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP////////////////////////////////////////////////////////////////////////////////////wAALCAEAAQABAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==';
