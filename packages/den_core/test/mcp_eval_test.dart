/// Regressions for what an assistant found testing Den's MCP server end to end against a live
/// hub (MCP-EVAL, numbered as that report numbers them), where the fix is the engine's.
library;

import 'package:den_core/den_core.dart';
import 'package:den_core/src/time.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  const zone = 'America/New_York';
  late TestClock clock;
  late Den den;
  late String james;
  late String ann;
  late String elsie;
  late String jimmy;

  int at(String date, String time) => dateTimeIn(zone, date, time);

  setUp(() async {
    clock = TestClock(dateTimeIn(zone, '2026-10-28', '16:00'));
    den = await foundFamily(clock, timezone: zone, name: 'James');
    james = den.actor!.id;
    ann = await den.addMember(name: 'Ann', role: Role.parent);
    elsie = await den.addMember(name: 'Elsie', role: Role.kid);
    jimmy = await den.addMember(name: 'Jimmy', role: Role.kid);
  });

  tearDown(() => den.close());

  group('#4 and #21: every connection acts as someone', () {
    test('a token, or an approval, acts as the parent who made it unless they choose someone', () async {
      await den.addTokenConnection(label: 'Script', scopes: {Scope.read});
      final script = den.connections.single;
      expect(script.member, james);
      expect(den.connectionActsAs(script), james);

      final id = await den.requestOAuthConnection(label: 'Grok', client: 'https://grok.example/client', scopes: {Scope.read});
      await den.approveConnection(id);
      expect(den.connectionWithId(id)!.member, james);
      final kid = await den.requestOAuthConnection(label: 'Elsie\'s helper', client: 'https://x.example/c', scopes: {Scope.read});
      await den.approveConnection(kid, member: elsie);
      expect(den.connectionActsAs(den.connectionWithId(kid)!), elsie);
    });

    test('a connection approved before then acts as the parent whose own device approved it', () async {
      final id = await den.requestOAuthConnection(label: 'Grok', client: 'https://grok.example/client', scopes: {Scope.read});
      clock.advance(const Duration(minutes: 1));
      // What an older app wrote: active, and nobody named.
      final old = await forge(
        den.keys,
        counter: 900,
        millis: clock.now,
        type: RecordType.connection,
        rid: id,
        space: Space.parents,
        actor: james,
        fields: {'status': ConnectionStatus.active.name},
      );
      expect((await den.ingest([old])).invalid, isEmpty);
      final c = den.connectionWithId(id)!;
      expect(c.member, isNull);
      expect(den.connectionActsAs(c), james);

      // One nobody approved acts as nobody: the hub lets such a connection only read.
      final pending = await den.requestOAuthConnection(label: 'Later', client: 'https://l.example/c', scopes: {Scope.read});
      expect(den.connectionActsAs(den.connectionWithId(pending)!), isNull, reason: 'not active yet');
    });

    test('a connection keeps the time zone its person lives in, and a parent can change who it acts as', () async {
      final id = await den.requestOAuthConnection(label: 'Grok', client: 'https://grok.example/client', scopes: {Scope.read});
      await den.approveConnection(id, tz: 'Pacific/Honolulu');
      expect(den.connectionWithId(id)!.tz, 'Pacific/Honolulu');
      await den.updateConnection(id, member: ann, tz: zone);
      final c = den.connectionWithId(id)!;
      expect(c.member, ann);
      expect(c.tz, isNull, reason: 'the family\'s own zone is no zone of its own');
      await expectLater(den.approveConnection(id, tz: 'Mars/Olympus'), throwsA(isA<InvalidInput>()));
    });
  });

  group('#4: whoever asked for a reward doesn\'t approve it', () {
    test('a parent asking on a kid\'s behalf waits for the other parent', () async {
      await den.adjustPoints(elsie, 20, 'Chores');
      final reward = await den.addReward(title: 'Movie night', cost: 10);
      final request = await den.requestReward(reward, member: elsie);
      await expectLater(den.decideRedemption(request, approve: true), throwsA(isA<PermissionDenied>()));
      expect(den.points().pending.single.id, request);
      final annPhone = await joinDevice(den, clock, member: ann, name: 'Ann\'s phone', kind: DeviceKind.phone);
      await annPhone.decideRedemption(request, approve: true);
      expect(annPhone.points().totals[elsie], 10);
      await annPhone.close();
    });

    test('a kid\'s own request is still the parent\'s to approve', () async {
      final tablet = await joinDevice(den, clock, member: elsie, name: 'Elsie\'s tablet');
      await den.adjustPoints(elsie, 20, 'Chores');
      final reward = await den.addReward(title: 'Movie night', cost: 10);
      await sync(den, tablet);
      final request = await tablet.requestReward(reward);
      await expectLater(tablet.decideRedemption(request, approve: true), throwsA(isA<PermissionDenied>()));
      await sync(tablet, den);
      await den.decideRedemption(request, approve: true);
      expect(den.points().totals[elsie], 10);
      await tablet.close();
    });
  });

  group('#16: requests don\'t outlive their reward', () {
    test('retiring a reward declines what waits on it; undo brings both back', () async {
      final tablet = await joinDevice(den, clock, member: elsie, name: 'Elsie\'s tablet');
      await den.adjustPoints(elsie, 20, 'Chores');
      final reward = await den.addReward(title: 'Movie night', cost: 10);
      await sync(den, tablet);
      final request = await tablet.requestReward(reward);
      await sync(tablet, den);
      final retired = await den.recording(() => den.updateReward(reward, {'active': false}));
      expect(den.points().pending, isEmpty);
      expect(den.history().first.verb, 'declined');
      await den.undo(retired.changes);
      expect(den.points().pending.single.id, request);
      await tablet.close();
    });

    test('removing a reward (undoing its adding) declines what waits on it', () async {
      final tablet = await joinDevice(den, clock, member: elsie, name: 'Elsie\'s tablet');
      await den.adjustPoints(elsie, 20, 'Chores');
      final added = await den.recording(() => den.addReward(title: 'Free candy', cost: 0));
      await sync(den, tablet);
      await tablet.requestReward(added.value);
      await sync(tablet, den);
      await den.undo(added.changes);
      expect(den.points().pending, isEmpty);
      await tablet.close();
    });
  });

  group('#6: rides', () {
    test('only a parent or an adult drives', () async {
      final soccer = await den.addEvent(
        title: 'Soccer',
        start: at('2026-10-29', '16:00'),
        end: at('2026-10-29', '17:00'),
        assignees: [jimmy],
        rides: const [Ride('to', null)],
      );
      final start = at('2026-10-29', '16:00');
      await expectLater(den.claimRide(soccer, occurrence: start, leg: 'to', driver: jimmy), throwsA(isA<InvalidInput>()));
      await den.claimRide(soccer, occurrence: start, leg: 'to', driver: ann);
      expect(den.event(soccer)!.rides.single.driver, ann);
      expect(canDrive(den.member(elsie)!), isFalse);
      expect(canDrive(den.member(ann)!), isTrue);
    });

    test('one driver in two places at once is a gap, unless both are at the same place', () async {
      await den.addEvent(
        title: 'Soccer',
        start: at('2026-10-29', '16:00'),
        end: at('2026-10-29', '17:00'),
        assignees: [jimmy],
        location: 'Field 2',
        rides: [Ride('to', ann)],
      );
      await den.addEvent(
        title: 'Dentist',
        start: at('2026-10-29', '16:15'),
        end: at('2026-10-29', '17:00'),
        assignees: [elsie],
        location: 'Bright Smiles',
        rides: [Ride('to', ann)],
      );
      await den.addEvent(
        title: 'Piano',
        start: at('2026-10-29', '19:00'),
        end: at('2026-10-29', '20:00'),
        assignees: [elsie],
        rides: [Ride('to', ann)],
      );
      final gaps = den.gaps(at('2026-10-29', '00:00'), at('2026-10-30', '00:00'));
      final busy = gaps.where((g) => g.kind == GapKind.driverBusy).toList();
      expect(busy.single.message, 'Ann is driving two places at once: Soccer and Dentist');
      expect(busy.single.members, [ann]);

      await den.addEvent(
        title: 'Practice',
        start: at('2026-10-30', '16:00'),
        end: at('2026-10-30', '17:00'),
        assignees: [jimmy],
        location: 'Field 2',
        rides: [Ride('to', james)],
      );
      await den.addEvent(
        title: 'Scrimmage',
        start: at('2026-10-30', '16:00'),
        end: at('2026-10-30', '17:00'),
        assignees: [elsie],
        location: 'field 2',
        rides: [Ride('to', james)],
      );
      expect(den.gaps(at('2026-10-30', '00:00'), at('2026-10-31', '00:00')).where((g) => g.kind == GapKind.driverBusy), isEmpty);
    });
  });

  test('#7: a kid can\'t check off a day still to come; a parent can, when it really was done early', () async {
    final tablet = await joinDevice(den, clock, member: elsie, name: 'Elsie\'s tablet');
    final chore = await den.addChore(
      title: 'Make bed',
      owner: OwnerMember(elsie),
      schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-10-01'),
      points: 2,
    );
    await sync(den, tablet);
    await expectLater(tablet.setChoreDone(chore, '2026-11-15', true), throwsA(isA<InvalidInput>()));
    await tablet.setChoreDone(chore, '2026-10-28', true);
    await den.setChoreDoneBy(chore, '2026-10-29', true, elsie);
    expect(den.choresOn('2026-10-29').single.done, isTrue);
    await tablet.close();
  });

  group('#13: search', () {
    setUp(() async {
      await den.addEvent(
        title: 'TEST Soccer',
        start: at('2026-10-29', '16:00'),
        end: at('2026-10-29', '17:00'),
        assignees: [jimmy],
        location: 'Field 2',
      );
      await den.addEvent(
        title: 'TEST Dentist',
        start: at('2026-10-30', '15:00'),
        end: at('2026-10-30', '16:00'),
        assignees: [jimmy],
        notes: 'Bring the insurance card',
      );
      await den.addChore(title: 'Feed the fish', owner: OwnerMember(jimmy), schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-10-01'));
    });

    test('forgives a typo, reads the place and the notes, and words across them', () {
      expect(den.search('socer').map((h) => h.title), contains('TEST Soccer'));
      expect(den.search('Field 2').single.title, 'TEST Soccer');
      expect(den.search('insurance').single.title, 'TEST Dentist');
      expect(den.search('dentist jimmy').first.title, 'TEST Dentist');
      expect(den.search("When is Jimmy's dentist?").first.title, 'TEST Dentist');
      expect(den.search('xyzzy'), isEmpty);
    });

    test('a person brings their events and chores, and removed things stay in History', () async {
      final hits = den.search('Jimmy');
      expect(hits.first.type, RecordType.member);
      expect(hits.map((h) => h.title), containsAll(['TEST Soccer', 'TEST Dentist', 'Feed the fish']));
      final gone = await den.addEvent(title: 'TEST Hike', start: at('2026-10-31', '09:00'), end: at('2026-10-31', '12:00'));
      await den.deleteEvent(gone);
      expect(den.search('hike'), isEmpty);
      expect(den.search('hike', includeHistory: true).single.detail, 'History');
    });

    test('names compare the way people say them', () {
      expect(sameName('Milk ', 'milk'), isTrue);
      expect(sameName('TEST Sports', 'test  sports'), isTrue);
      expect(nearlySame('socer', 'soccer'), isTrue);
      expect(nearlySame('dentsit', 'dentist'), isTrue);
      expect(nearlySame('cat', 'car'), isFalse, reason: 'short words must match exactly');
      expect(searchWords("Jimmy's dentist?"), ['jimmy', 'dentist']);
    });
  });
}
