import 'package:den_core/den_core.dart';
import 'package:den_core/src/time.dart';
import 'package:test/test.dart';

import 'support.dart';

const hour = 3600000;
const day = 24 * hour;

String wall(String zone, int utc) => wallTime(zone, utc).toIso8601String().substring(0, 16);

void main() {
  late TestClock clock;
  late Den den;
  late String leo;
  const ny = 'America/New_York';

  setUp(() async {
    clock = TestClock.at(DateTime.utc(2026, 1, 5, 14));
    den = await foundFamily(clock, timezone: ny);
    leo = await den.addMember(name: 'Leo', role: Role.kid);
  });

  group('time zones', () {
    test('a weekly 7:00 AM event stays at 7:00 AM across both DST changes in New York', () async {
      final start = wallToUtc(ny, DateTime.utc(2026, 2, 2, 7));
      await den.addEvent(title: 'Swim team', start: start, end: start + hour, rrule: 'FREQ=WEEKLY;BYDAY=MO');
      final occ = den.occurrences(start, wallToUtc(ny, DateTime.utc(2026, 12, 1)));
      expect(occ.length, greaterThan(40));
      for (final o in occ) {
        expect(wallTime(ny, o.start).hour, 7);
        expect(wallTime(ny, o.start).minute, 0);
        expect(o.end - o.start, hour);
      }
      final march2 = occ.firstWhere((o) => wall(ny, o.start) == '2026-03-02T07:00');
      final march9 = occ.firstWhere((o) => wall(ny, o.start) == '2026-03-09T07:00');
      expect(DateTime.fromMillisecondsSinceEpoch(march2.start, isUtc: true).hour, 12);
      expect(DateTime.fromMillisecondsSinceEpoch(march9.start, isUtc: true).hour, 11);
      final oct26 = occ.firstWhere((o) => wall(ny, o.start) == '2026-10-26T07:00');
      final nov2 = occ.firstWhere((o) => wall(ny, o.start) == '2026-11-02T07:00');
      expect(DateTime.fromMillisecondsSinceEpoch(oct26.start, isUtc: true).hour, 11);
      expect(DateTime.fromMillisecondsSinceEpoch(nov2.start, isUtc: true).hour, 12);
      expect(nov2.start - oct26.start, 7 * day + hour);
    });

    test('an event repeats in its own zone, not the family\'s', () async {
      const london = 'Europe/London';
      final start = wallToUtc(london, DateTime.utc(2026, 3, 23, 7));
      await den.addEvent(title: 'Call with Gran', start: start, end: start + hour, tz: london, rrule: 'FREQ=WEEKLY');
      final occ = den.occurrences(start, start + 40 * 7 * day);
      expect(occ.map((o) => wall(london, o.start)).take(3), ['2026-03-23T07:00', '2026-03-30T07:00', '2026-04-06T07:00']);
      expect(DateTime.fromMillisecondsSinceEpoch(occ[0].start, isUtc: true).hour, 7);
      expect(DateTime.fromMillisecondsSinceEpoch(occ[1].start, isUtc: true).hour, 6);
      final late = occ.firstWhere((o) => wall(london, o.start) == '2026-10-26T07:00');
      expect(DateTime.fromMillisecondsSinceEpoch(late.start, isUtc: true).hour, 7);
      for (final o in occ) {
        expect(wallTime(london, o.start).hour, 7);
      }
    });

    test('all-day events cover local days and appear on each day they span', () async {
      final first = dayStartIn(ny, '2026-01-09');
      await den.addEvent(title: 'Ski trip', start: first, end: dayStartIn(ny, '2026-01-12'), allDay: true, countdown: true);
      expect(den.today(date: '2026-01-08').events, isEmpty);
      for (final d in ['2026-01-09', '2026-01-10', '2026-01-11']) {
        expect(den.today(date: d).events.single.title, 'Ski trip');
      }
      expect(den.today(date: '2026-01-12').events, isEmpty);
      final week = den.week('2026-01-04');
      expect(week.everyone['2026-01-10']!.single.allDay, isTrue);
      expect(week.everyone['2026-01-08'], isEmpty);
    });
  });

  group('repeating across DST changes', () {
    test('a weekly all-day event stays on its own day when the clocks change', () async {
      final first = dayStartIn(ny, '2026-03-01');
      await den.addEvent(title: 'Family day', start: first, end: dayStartIn(ny, '2026-03-02'), allDay: true, rrule: 'FREQ=WEEKLY');
      for (final d in ['2026-03-01', '2026-03-08', '2026-03-15', '2026-11-01', '2026-11-08']) {
        expect(den.today(date: d).events.map((o) => o.title), ['Family day'], reason: d);
        expect(den.today(date: addDays(d, 1)).events, isEmpty, reason: 'the day after $d');
        expect(den.today(date: addDays(d, -1)).events, isEmpty, reason: 'the day before $d');
      }
      final occ = den.occurrences(first, dayStartIn(ny, '2026-11-30'));
      for (final o in occ) {
        expect(o.end, dayStartIn(ny, addDays(dateIn(ny, o.start), 1)), reason: wall(ny, o.start));
      }
      final march8 = occ.firstWhere((o) => dateIn(ny, o.start) == '2026-03-08');
      expect(march8.end - march8.start, 23 * hour, reason: 'the day the clocks spring forward is short');
      final nov1 = occ.firstWhere((o) => dateIn(ny, o.start) == '2026-11-01');
      expect(nov1.end - nov1.start, 25 * hour);
    });

    test('a timed event keeps its wall-clock end across the night the clocks change', () async {
      final start = wallToUtc(ny, DateTime.utc(2026, 3, 6, 1));
      await den.addEvent(title: 'Night shift', start: start, end: wallToUtc(ny, DateTime.utc(2026, 3, 6, 3, 30)), rrule: 'FREQ=DAILY;COUNT=5');
      final occ = den.occurrences(start, start + 6 * day);
      expect(occ, hasLength(5));
      for (final o in occ) {
        expect(wall(ny, o.start).substring(11), '01:00');
        expect(wall(ny, o.end).substring(11), '03:30', reason: wall(ny, o.start));
      }
    });

    test('an occurrence the week after the clocks change is addressed by its own wall-clock start', () async {
      final start = wallToUtc(ny, DateTime.utc(2026, 10, 27, 17));
      final id = await den.addEvent(title: 'Soccer practice', start: start, end: start + hour, rrule: 'FREQ=WEEKLY');
      List<Occurrence> threeWeeks() => den.occurrences(start, start + 15 * day);
      final occ = threeWeeks();
      expect(occ.map((o) => wall(ny, o.start)), ['2026-10-27T17:00', '2026-11-03T17:00', '2026-11-10T17:00']);
      expect(occ[1].seriesStart - occ[0].seriesStart, 7 * day + hour, reason: 'the clocks fell back on Nov 1');
      await den.updateEvent(id, {'location': 'Field 9', 'start': occ[0].start + hour}, scope: EditScope.one, occurrence: occ[0].seriesStart);
      await expectLater(
        den.deleteEvent(id, scope: EditScope.one, occurrence: occ[0].seriesStart + 7 * day),
        throwsA(isA<InvalidInput>()),
        reason: 'seven times 24 hours later is 4 PM, not an occurrence',
      );
      await den.deleteEvent(id, scope: EditScope.one, occurrence: occ[1].seriesStart);
      final after = threeWeeks();
      expect(after.map((o) => o.seriesStart), [occ[0].seriesStart, occ[2].seriesStart]);
      expect(after.first.location, 'Field 9');
      expect(wall(ny, after.first.start), '2026-10-27T18:00');
    });

    test('splitting a series after the change keeps each day whole', () async {
      final first = dayStartIn(ny, '2026-03-01');
      final id = await den.addEvent(title: 'Garden', start: first, end: dayStartIn(ny, '2026-03-02'), allDay: true, rrule: 'FREQ=WEEKLY');
      final march8 = dayStartIn(ny, '2026-03-08');
      await den.updateEvent(id, {'title': 'Garden (spring)'}, scope: EditScope.following, occurrence: march8);
      expect(den.today(date: '2026-03-08').events.map((o) => o.title), ['Garden (spring)']);
      expect(den.today(date: '2026-03-09').events, isEmpty);
      final split = den.events.firstWhere((e) => e.title == 'Garden (spring)');
      expect(split.end, dayStartIn(ny, '2026-03-09'));
    });
  });

  group('exceptions and edit scopes', () {
    late String id;
    late int first;

    setUp(() async {
      first = wallToUtc(ny, DateTime.utc(2026, 1, 6, 17));
      id = await den.addEvent(
        title: 'Soccer',
        start: first,
        end: first + 90 * 60000,
        rrule: 'FREQ=WEEKLY;BYDAY=TU,TH',
        assignees: [leo],
        rides: const [Ride('to', null), Ride('from', null)],
      );
    });

    List<Occurrence> month() => den.occurrences(first, first + 31 * day);

    test('one occurrence changed, moved and moved again by its series start', () async {
      final third = month()[2];
      expect(third.seriesStart, third.start);
      await den.updateEvent(id, {'title': 'Soccer (away game)', 'location': 'Hill Park'},
          scope: EditScope.one, occurrence: third.seriesStart);
      var edited = month()[2];
      expect(edited.title, 'Soccer (away game)');
      expect(edited.location, 'Hill Park');
      expect(edited.exceptionId, isNotNull);
      expect(month()[1].title, 'Soccer');

      final moved = third.seriesStart + 2 * hour;
      await den.updateEvent(id, {'start': moved, 'end': moved + hour}, scope: EditScope.one, occurrence: third.seriesStart);
      edited = month().firstWhere((o) => o.exceptionId != null);
      expect(edited.start, moved);
      expect(edited.seriesStart, third.seriesStart, reason: 'the series start still addresses it');
      expect(edited.title, 'Soccer (away game)', reason: 'earlier overrides stay');

      await den.updateEvent(id, {'notes': 'Bring orange slices'}, scope: EditScope.one, occurrence: edited.seriesStart);
      final again = month().firstWhere((o) => o.exceptionId != null);
      expect(again.start, moved);
      expect(again.notes, 'Bring orange slices');
      await expectLater(
        den.updateEvent(id, {'notes': 'x'}, scope: EditScope.one, occurrence: moved),
        throwsA(isA<InvalidInput>()),
        reason: 'the moved start is not a series start',
      );
      expect(month().where((o) => o.exceptionId != null), hasLength(1));
    });

    test('an occurrence moved into a window shows there; one moved out doesn\'t', () async {
      final third = month()[2];
      final nextWeek = third.seriesStart + 6 * day;
      await den.updateEvent(id, {'start': nextWeek, 'end': nextWeek + hour}, scope: EditScope.one, occurrence: third.seriesStart);
      expect(den.occurrences(third.seriesStart - hour, third.seriesStart + hour), isEmpty);
      final there = den.occurrences(nextWeek - hour, nextWeek + hour);
      expect(there.single.seriesStart, third.seriesStart);
    });

    test('an occurrence carries its own category after a change', () async {
      final sports = await den.addCategory(name: 'Sports', icon: 'sports');
      final school = await den.addCategory(name: 'School', icon: 'school');
      await den.updateEvent(id, {'category': sports});
      final third = month()[2];
      await den.updateEvent(id, {'category': school}, scope: EditScope.one, occurrence: third.seriesStart);
      final occ = month();
      expect(occ[1].category, sports);
      expect(occ[2].category, school);
    });

    test('canceling one occurrence and claiming a ride for one', () async {
      final occ = month();
      await den.deleteEvent(id, scope: EditScope.one, occurrence: occ[1].seriesStart);
      expect(month().map((o) => o.seriesStart), isNot(contains(occ[1].seriesStart)));
      await den.claimRide(id, occurrence: occ[0].seriesStart, leg: 'from', driver: den.actor!.id);
      final after = month();
      expect(after[0].rides.firstWhere((r) => r.leg == 'from').driver, den.actor!.id);
      expect(after[1].rides.every((r) => r.driver == null), isTrue);
      final gaps = den.gaps(occ[0].seriesStart, occ[0].seriesStart + day);
      expect(gaps.map((g) => g.message), ['Nobody is driving Leo to Soccer']);
    });

    test('this and following splits the series', () async {
      final occ = month();
      final cut = occ[4];
      await den.updateEvent(id, {'title': 'Soccer (spring)', 'location': 'Field 2'},
          scope: EditScope.following, occurrence: cut.seriesStart);
      final after = month();
      expect(after.length, occ.length);
      expect(after.take(4).map((o) => o.title), everyElement('Soccer'));
      expect(after.skip(4).map((o) => o.title), everyElement('Soccer (spring)'));
      expect(after.skip(4).map((o) => o.location), everyElement('Field 2'));
      expect(after.map((o) => o.start), occ.map((o) => o.start));
      expect(den.events, hasLength(2));
      expect(den.event(id)!.rrule, contains('UNTIL='));
    });

    test('this and following on a counted series splits the count', () async {
      final counted = await den.addEvent(title: 'Piano', start: first, end: first + hour, rrule: 'FREQ=DAILY;COUNT=10');
      final occ = den.occurrences(first, first + 30 * day).where((o) => o.event.id == counted).toList();
      expect(occ, hasLength(10));
      await den.updateEvent(counted, {'title': 'Piano with Ms. Lee'}, scope: EditScope.following, occurrence: occ[6].seriesStart);
      final after = den.occurrences(first, first + 30 * day).where((o) => o.title.startsWith('Piano')).toList();
      expect(after, hasLength(10));
      expect(after.where((o) => o.title == 'Piano with Ms. Lee'), hasLength(4));
      expect(den.event(counted)!.rrule, 'FREQ=DAILY;COUNT=6');
    });

    test('changing the time of all shifts the whole series by the wall-clock delta, across DST', () async {
      final occ = den.occurrences(first, first + 120 * day);
      final march = occ.firstWhere((o) => wall(ny, o.start) == '2026-03-10T17:00');
      await den.updateEvent(id, {'title': 'Soccer (late)'}, scope: EditScope.one, occurrence: occ[1].seriesStart);
      final newStart = march.seriesStart + 30 * 60000;
      await den.updateEvent(id, {'start': newStart, 'end': newStart + 90 * 60000}, occurrence: march.seriesStart);
      final after = den.occurrences(first, first + 120 * day);
      for (final o in after) {
        expect(wall(ny, o.start).substring(11), '17:30');
      }
      expect(wall(ny, den.event(id)!.start), '2026-01-06T17:30');
      final kept = after.firstWhere((o) => o.exceptionId != null);
      expect(kept.title, 'Soccer (late)', reason: 'exceptions follow the shifted series');
      expect(wall(ny, kept.seriesStart), wall(ny, occ[1].seriesStart).replaceFirst('17:00', '17:30'));
    });

    test('delete this and following, and delete all', () async {
      final occ = month();
      await den.deleteEvent(id, scope: EditScope.following, occurrence: occ[3].seriesStart);
      expect(month().map((o) => o.seriesStart), occ.take(3).map((o) => o.seriesStart));
      await den.deleteEvent(id);
      expect(month(), isEmpty);
      expect(den.history().first.verb, 'removed');
    });

    test('scopes on a single event behave like all', () async {
      final single = await den.addEvent(title: 'Dentist', start: first, end: first + hour);
      await den.updateEvent(single, {'title': 'Dentist (Zoe)'}, scope: EditScope.one, occurrence: first);
      expect(den.event(single)!.title, 'Dentist (Zoe)');
      await den.claimRide(single, occurrence: first, leg: 'to', driver: den.actor!.id);
      expect(den.event(single)!.rides.single.driver, den.actor!.id);
    });
  });

  test('yearly and every-other-week rules survive the round trip through an event', () async {
    final birthday = wallToUtc(ny, DateTime.utc(2026, 7, 22));
    final id = await den.addEvent(
      title: 'Leo\'s birthday',
      start: birthday,
      end: dayStartIn(ny, '2026-07-23'),
      allDay: true,
      rrule: 'rrule:freq=yearly',
    );
    expect(den.event(id)!.rrule, 'FREQ=YEARLY');
    final years = den.occurrences(birthday, birthday + 3 * 365 * day);
    expect(years.map((o) => dateIn(ny, o.start)), ['2026-07-22', '2027-07-22', '2028-07-22']);
    final start = wallToUtc(ny, DateTime.utc(2026, 1, 12, 18));
    final club = await den.addEvent(title: 'Book club', start: start, end: start + hour, rrule: 'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO');
    expect(den.event(club)!.rrule, 'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO');
    final meetings = den.occurrences(start, start + 60 * day).where((o) => o.event.id == club);
    expect(meetings.map((o) => dateIn(ny, o.start)), ['2026-01-12', '2026-01-26', '2026-02-09', '2026-02-23', '2026-03-09']);
    expect(meetings.map((o) => wall(ny, o.start).substring(11)), everyElement('18:00'));
  });

  group('rides, one leg at a time', () {
    late String dana;
    late String priya;
    late String alex;
    late int first;
    late String soccer;

    setUp(() async {
      dana = den.actor!.id;
      priya = await den.addMember(name: 'Priya', role: Role.parent);
      alex = await den.addMember(name: 'Alex', role: Role.adult);
      first = wallToUtc(ny, DateTime.utc(2026, 1, 6, 17));
      soccer = await den.addEvent(
        title: 'Soccer',
        start: first,
        end: first + 90 * 60000,
        rrule: 'FREQ=WEEKLY;BYDAY=TU',
        assignees: [leo],
        rides: const [Ride('to', null), Ride('from', null)],
      );
    });

    Map<String, String?> legs(List<Ride> rides) => {for (final r in rides) r.leg: r.driver};

    /// Each Soccer occurrence's rides over four weeks, whichever event (after a split) it's in.
    List<Map<String, String?>> weeks() => [
          for (final o in den.occurrences(first - day, first + 27 * day))
            if (o.title.startsWith('Soccer')) legs(o.rides),
        ];
    List<int> starts() => [
          for (final o in den.occurrences(first - day, first + 27 * day))
            if (o.title.startsWith('Soccer')) o.seriesStart,
        ];

    /// The changes [body] writes, in order.
    Future<List<Change>> written(Future<void> Function() body) async {
      final r = await den.recording(body);
      final byId = {for (final c in den.changesSince({})) c.id: c};
      return [for (final id in r.changes) byId[id]!];
    }

    Set<String> keysOf(Change c) => {for (final k in c.fields.keys) if (!k.startsWith('_')) k};

    test('an event with rides is made in a change older versions read, then its drivers in one of their own', () async {
      final made = await written(() => den.addEvent(title: 'Piano', start: first, end: first + hour, rides: [Ride('from', priya)]));
      expect(made, hasLength(2));
      expect(keysOf(made.first), isNot(contains('drivers')));
      expect(made.first.fields['rides'], [{'leg': 'from', 'driver': priya}]);
      expect(keysOf(made.last), {'drivers'});
      expect(made.last.fields['drivers'], {'from': priya});
      final plain = await written(() => den.addEvent(title: 'Recital', start: first, end: first + hour));
      expect(plain, hasLength(1), reason: 'an event without rides needs no drivers');
    });

    test('a claim writes its leg alone, after the whole list older versions read', () async {
      final once = await den.addEvent(title: 'Dentist', start: first, end: first + hour, rides: const [Ride('to', null), Ride('from', null)]);
      final made = await written(() => den.claimRide(once, occurrence: first, leg: 'from', driver: priya));
      expect(made.map(keysOf), [{'rides'}, {'drivers.from'}]);
      expect(made.first.fields['rides'], [{'leg': 'to', 'driver': null}, {'leg': 'from', 'driver': priya}]);
      expect(made.last.fields['drivers.from'], priya);
      expect(den.event(once)!.readsDrivers, isTrue);
      await den.claimRide(once, occurrence: first, leg: 'to', driver: dana);
      expect(legs(den.event(once)!.rides), {'to': dana, 'from': priya});
      expect(await written(() => den.claimRide(once, occurrence: first, leg: 'to', driver: dana)), isEmpty, reason: 'it already is');
      // A leg it didn't have comes with the whole map, which says which legs there are.
      final single = await den.addEvent(title: 'Field trip', start: first, end: first + hour, rides: const [Ride('to', null)]);
      final added = await written(() => den.claimRide(single, occurrence: first, leg: 'from', driver: alex));
      expect(added.last.fields['drivers'], {'to': null, 'from': alex});
      expect(legs(den.event(single)!.rides), {'to': null, 'from': alex});
    });

    test('one occurrence takes a driver per leg; the others, and its other leg, follow the series', () async {
      final at = starts();
      final made = await written(() => den.claimRide(soccer, occurrence: at[1], leg: 'to', driver: dana));
      expect(made.map(keysOf), [
        {'event', 'occurrence', 'patch.rides'},
        {'patch.drivers.to'},
      ]);
      await den.claimRide(soccer, occurrence: at[1], leg: 'from', driver: priya);
      await den.claimRide(soccer, occurrence: at[2], leg: 'to', driver: priya);
      expect(weeks().take(3), [
        {'to': null, 'from': null},
        {'to': dana, 'from': priya},
        {'to': priya, 'from': null},
      ]);
      // Alex picks up every week: the third week's drive home follows, the second keeps Priya.
      await den.updateEvent(soccer, {'rides': [const Ride('to', null), Ride('from', alex)]});
      expect(weeks().take(3), [
        {'to': null, 'from': alex},
        {'to': dana, 'from': priya},
        {'to': priya, 'from': alex},
      ]);
      // Priya can't that week after all: nobody that day, though Alex has the others.
      final released = await written(() => den.claimRide(soccer, occurrence: at[1], leg: 'from', driver: null));
      expect(released.last.fields, containsPair('patch.drivers.from', ''));
      expect(weeks().take(3), [
        {'to': null, 'from': alex},
        {'to': dana, 'from': null},
        {'to': priya, 'from': alex},
      ]);
      final gaps = den.gaps(at[1], at[1] + day).where((g) => g.kind == GapKind.noDriver);
      expect(gaps.map((g) => g.leg), ['from']);
    });

    test('an occurrence can have a leg the series hasn\'t, or go without one it has', () async {
      final piano = await den.addEvent(title: 'Piano', start: first, end: first + hour, rrule: 'FREQ=WEEKLY', rides: const [Ride('to', null)]);
      List<Map<String, String?>> piano3() => [
            for (final o in den.occurrences(first, first + 21 * day))
              if (o.event.id == piano) legs(o.rides),
          ];
      final at = [for (final o in den.occurrences(first, first + 21 * day)) if (o.event.id == piano) o.seriesStart];
      await den.claimRide(piano, occurrence: at[1], leg: 'from', driver: priya);
      expect(piano3(), [{'to': null}, {'to': null, 'from': priya}, {'to': null}]);
      // No drive there the third week, only a pickup: per-leg drivers can't leave a leg out, so
      // that occurrence gets its whole list, as older versions write it.
      final edited = await written(() => den.updateEvent(piano, {'rides': [const Ride('from', null)]}, scope: EditScope.one, occurrence: at[2]));
      expect(keysOf(edited.single).where((k) => k.startsWith('patch.')), ['patch.rides']);
      await den.claimRide(piano, occurrence: at[2], leg: 'from', driver: dana);
      expect(piano3()[2], {'from': dana}, reason: 'it keeps going without a drive there');
      // A leg added for one day on the event's page, the way the app adds one.
      await den.updateEvent(piano, {'rides': [const Ride('to', null), const Ride('from', null)]}, scope: EditScope.one, occurrence: at[0]);
      expect(piano3()[0], {'to': null, 'from': null});
    });

    test('drivers go along when the series moves, splits or changes who can see it', () async {
      var at = starts();
      await den.claimRide(soccer, occurrence: at[1], leg: 'to', driver: dana);
      await den.updateEvent(soccer, {'rides': [Ride('to', priya), const Ride('from', null)]});
      final want = [
        {'to': priya, 'from': null},
        {'to': dana, 'from': null},
        {'to': priya, 'from': null},
        {'to': priya, 'from': null},
      ];
      expect(weeks(), want);
      final later = first + 30 * 60000;
      await den.updateEvent(soccer, {'start': later, 'end': later + 90 * 60000});
      expect(weeks(), want, reason: 'a new time for all of it');
      await den.updateEvent(soccer, {'audience': Audience.parents});
      expect(weeks(), want, reason: 'parents only');
      at = starts();
      await den.updateEvent(soccer, {'title': 'Soccer (spring)'}, scope: EditScope.following, occurrence: at[1]);
      expect(weeks(), want, reason: 'this and following');
      final spring = den.events.firstWhere((e) => e.title == 'Soccer (spring)');
      expect(spring.readsDrivers, isTrue);
      await den.updateEvent(spring.id, {'rides': [Ride('to', priya), Ride('from', alex)]}, scope: EditScope.following, occurrence: starts()[2]);
      expect(weeks(), [
        {'to': priya, 'from': null},
        {'to': dana, 'from': null},
        {'to': priya, 'from': alex},
        {'to': priya, 'from': alex},
      ]);
    });

    test('only a parent or an adult is named a driver, however the rides are written', () async {
      final at = starts();
      for (final write in <Future<void> Function()>[
        () => den.claimRide(soccer, occurrence: at[0], leg: 'to', driver: leo),
        () => den.updateEvent(soccer, {'rides': [Ride('to', leo)]}),
        () => den.updateEvent(soccer, {'rides': [Ride('to', leo)]}, scope: EditScope.one, occurrence: at[0]),
        () => den.addEvent(title: 'Carpool', start: first, end: first + hour, rides: [Ride('to', leo)]),
        () => den.updateEvent(soccer, {'rides': [Ride('to', 'nobody-here')]}),
      ]) {
        await expectLater(write(), throwsA(isA<InvalidInput>()));
      }
      await expectLater(den.updateEvent(soccer, {'drivers': {'to': dana}}), throwsA(isA<InvalidInput>()),
          reason: 'drivers change through rides or a claim');
      expect(checkFields(RecordType.event, {'drivers': {'to': null, 'from': dana}}, creating: false), isNull);
      expect(checkFields(RecordType.event, {'drivers.from': dana}, creating: false), isNull);
      expect(checkFields(RecordType.event, {'drivers.to': ''}, creating: false), isNotNull, reason: 'null is nobody');
      expect(checkFields(RecordType.event, {'drivers.back': null}, creating: false), isNotNull);
      expect(checkFields(RecordType.event, {'drivers': {'home': null}}, creating: false), isNotNull);
      expect(checkFields(RecordType.eventException, {'patch.drivers.to': ''}, creating: false), isNull);
      expect(checkFields(RecordType.eventException, {'patch.drivers.to': null}, creating: false), isNull);
      expect(checkFields(RecordType.eventException, {'patch.drivers.back': dana}, creating: false), isNotNull);
      expect(checkFields(RecordType.eventException, {'patch.drivers': {'to': dana}}, creating: false), isNotNull);
    });

    test('History shows a claim once, and undo takes back one leg and leaves the other', () async {
      final at = starts();
      final once = await den.addEvent(title: 'Dentist', start: first, end: first + hour, rides: const [Ride('to', null), Ride('from', null)]);
      final mine = await den.recording(() => den.claimRide(once, occurrence: first, leg: 'to', driver: dana));
      expect(mine.changes, hasLength(2));
      await den.claimRide(once, occurrence: first, leg: 'from', driver: priya);
      await den.claimRide(soccer, occurrence: at[0], leg: 'to', driver: dana);
      final history = den.history(limit: 5);
      const made = 'title notes location category start end allDay tz rrule assignees reminders source rides countdown';
      expect([for (final h in history) '${h.type} ${h.verb}: ${h.diffs.map((d) => d.field).where((f) => !f.startsWith('event')).join(' ')}'], [
        'eventException added: occurrence patch.rides',
        'event changed: rides',
        'event changed: rides',
        'event added: $made',
        'event added: $made',
      ]);
      expect(den.historyOf(mine.changes), hasLength(1));
      final undone = await den.undo(mine.changes);
      expect(undone.skipped, isEmpty, reason: 'Priya\'s later list says nothing of the drive there');
      expect(legs(den.event(once)!.rides), {'to': null, 'from': priya});
    });

    test('undoing one day\'s claims, first to last, leaves it following the series again', () async {
      final at = starts();
      await den.updateEvent(soccer, {'notes': 'Away game'}, scope: EditScope.one, occurrence: at[1]);
      final there = await den.recording(() => den.claimRide(soccer, occurrence: at[1], leg: 'to', driver: dana));
      final home = await den.recording(() => den.claimRide(soccer, occurrence: at[1], leg: 'from', driver: priya));
      expect(weeks()[1], {'to': dana, 'from': priya});
      expect((await den.undo(there.changes)).skipped, isEmpty);
      expect(weeks()[1], {'to': null, 'from': priya});
      expect((await den.undo(home.changes)).skipped, isEmpty);
      expect(weeks()[1], {'to': null, 'from': null}, reason: 'not the list written with the first claim');
      await den.updateEvent(soccer, {'rides': [Ride('to', alex), const Ride('from', null)]});
      expect(weeks()[1], {'to': alex, 'from': null}, reason: 'it follows the series');
    });
  });

  group('older versions', () {
    late String dana;
    late String priya;
    late Den phone;
    late int first;
    var counter = 1000;

    setUp(() async {
      dana = den.actor!.id;
      priya = await den.addMember(name: 'Priya', role: Role.parent);
      phone = await joinDevice(den, clock, member: dana, name: 'Old phone', kind: DeviceKind.phone);
      first = wallToUtc(ny, DateTime.utc(2026, 1, 6, 17));
    });

    Map<String, String?> legs(List<Ride> rides) => {for (final r in rides) r.leg: r.driver};

    /// What a version that knows only `rides` writes from [phone]: [fields] on one record.
    Future<void> older(String type, String rid, Map<String, Object?> fields) async {
      clock.advance(const Duration(seconds: 1));
      await den.ingest([await forge(phone.keys, counter: counter++, millis: clock.now, type: type, rid: rid, fields: fields, actor: dana)]);
    }

    test('an event with only a rides list reads as before; a claim takes over the whole list', () async {
      await older(RecordType.event, 'swim', {
        'title': 'Swim',
        'start': first,
        'end': first + hour,
        'rides': [
          {'leg': 'to', 'driver': priya},
          {'leg': 'from', 'driver': null},
        ],
      });
      expect(legs(den.event('swim')!.rides), {'to': priya, 'from': null});
      expect(den.event('swim')!.readsDrivers, isFalse);
      expect(den.occurrences(first, first + hour).single.rides.map((r) => r.leg), ['to', 'from']);
      clock.advance(const Duration(seconds: 1));
      final r = await den.recording(() => den.claimRide('swim', occurrence: first, leg: 'from', driver: dana));
      final drivers = den.changesSince({}).firstWhere((c) => c.id == r.changes.last);
      expect(drivers.fields['drivers'], {'to': priya, 'from': dana}, reason: 'the whole map, so the leg nobody touched comes along');
      expect(legs(den.event('swim')!.rides), {'to': priya, 'from': dana});
      expect(den.event('swim')!.readsDrivers, isTrue);
    });

    test('rides an older version writes after the drivers stand, until a newer claim', () async {
      final swim = await den.addEvent(title: 'Swim', start: first, end: first + hour, rides: const [Ride('to', null), Ride('from', null)]);
      await den.claimRide(swim, occurrence: first, leg: 'from', driver: priya);
      // The phone hasn't updated: it takes the drive there with the list it has, which says Priya
      // picks up (the list Den wrote alongside the drivers).
      await older(RecordType.event, swim, {
        'rides': [
          {'leg': 'to', 'driver': dana},
          {'leg': 'from', 'driver': priya},
        ],
      });
      expect(legs(den.event(swim)!.rides), {'to': dana, 'from': priya});
      expect(den.event(swim)!.readsDrivers, isFalse);
      clock.advance(const Duration(seconds: 1));
      await den.claimRide(swim, occurrence: first, leg: 'from', driver: dana);
      expect(legs(den.event(swim)!.rides), {'to': dana, 'from': dana}, reason: 'the older phone\'s drive there is kept');
      expect(den.event(swim)!.readsDrivers, isTrue);
    });

    test('an occurrence with only an older version\'s list reads it whole; a claim takes it over', () async {
      final soccer = await den.addEvent(
        title: 'Soccer',
        start: first,
        end: first + hour,
        rrule: 'FREQ=WEEKLY',
        rides: const [Ride('to', null), Ride('from', null)],
      );
      List<Map<String, String?>> weeks() => [
            for (final o in den.occurrences(first, first + 21 * day))
              if (o.event.id == soccer) legs(o.rides),
          ];
      final second = first + 7 * day;
      await older(RecordType.eventException, '$soccer@$second', {
        'event': soccer,
        'occurrence': second,
        'patch.rides': [
          {'leg': 'to', 'driver': priya},
          {'leg': 'from', 'driver': null},
        ],
      });
      expect(weeks()[1], {'to': priya, 'from': null});
      clock.advance(const Duration(seconds: 1));
      await den.claimRide(soccer, occurrence: second, leg: 'from', driver: dana);
      expect(weeks()[1], {'to': priya, 'from': dana});
      // Every week gets a drive there now; the older phone's Priya stays on hers.
      await den.updateEvent(soccer, {'rides': [Ride('to', dana), const Ride('from', null)]});
      expect(weeks(), [
        {'to': dana, 'from': null},
        {'to': priya, 'from': dana},
        {'to': dana, 'from': null},
      ]);
      // And the older phone's next word on that day stands whole again.
      await older(RecordType.eventException, '$soccer@$second', {
        'patch.rides': [
          {'leg': 'to', 'driver': dana},
        ],
      });
      expect(weeks()[1], {'to': dana});
    });

    test('undoing a claim that took over an older version\'s list puts that list back', () async {
      final swim = await den.addEvent(title: 'Swim', start: first, end: first + hour, rides: const [Ride('to', null), Ride('from', null)]);
      await den.claimRide(swim, occurrence: first, leg: 'from', driver: priya);
      await older(RecordType.event, swim, {
        'rides': [
          {'leg': 'to', 'driver': dana},
          {'leg': 'from', 'driver': priya},
        ],
      });
      clock.advance(const Duration(seconds: 1));
      final took = await den.recording(() => den.claimRide(swim, occurrence: first, leg: 'from', driver: dana));
      expect(legs(den.event(swim)!.rides), {'to': dana, 'from': dana});
      expect((await den.undo(took.changes)).skipped, isEmpty);
      expect(legs(den.event(swim)!.rides), {'to': dana, 'from': priya});
      expect(den.event(swim)!.readsDrivers, isFalse, reason: 'the older phone\'s list, not the drivers from before it');

      final soccer = await den.addEvent(
        title: 'Soccer',
        start: first,
        end: first + hour,
        rrule: 'FREQ=WEEKLY',
        rides: const [Ride('to', null), Ride('from', null)],
      );
      final second = first + 7 * day;
      await older(RecordType.eventException, '$soccer@$second', {
        'event': soccer,
        'occurrence': second,
        'patch.rides': [
          {'leg': 'to', 'driver': priya},
          {'leg': 'from', 'driver': null},
        ],
      });
      clock.advance(const Duration(seconds: 1));
      final claimed = await den.recording(() => den.claimRide(soccer, occurrence: second, leg: 'from', driver: dana));
      Map<String, String?> day2() => legs(den.occurrences(second, second + 1).single.rides);
      expect(day2(), {'to': priya, 'from': dana});
      expect((await den.undo(claimed.changes)).skipped, isEmpty);
      expect(day2(), {'to': priya, 'from': null});
    });

    test('what Den writes for a ride, an older version can take in: the list comes in its own change', () async {
      final soccer = await den.addEvent(
        title: 'Soccer',
        start: first,
        end: first + hour,
        rrule: 'FREQ=WEEKLY',
        rides: const [Ride('to', null), Ride('from', null)],
      );
      final once = await den.addEvent(title: 'Dentist', start: first, end: first + hour, rides: const [Ride('to', null)]);
      final r = await den.recording(() async {
        await den.claimRide(soccer, occurrence: first, leg: 'to', driver: dana);
        await den.claimRide(once, occurrence: first, leg: 'to', driver: priya);
        await den.updateEvent(soccer, {'rides': [Ride('to', priya)]});
        await den.updateEvent(soccer, {'start': first + hour, 'end': first + 2 * hour});
      });
      final made = [for (final c in den.changesSince({})) if (r.changes.contains(c.id)) c];
      bool isNew(String k) => k == 'drivers' || k.startsWith('drivers.') || k.startsWith('patch.drivers.');
      for (final c in made) {
        final keys = c.fields.keys.where((k) => !k.startsWith('_'));
        final patch = c.fields['patch'];
        expect(keys.every(isNew) || !keys.any(isNew), isTrue, reason: 'one or the other: ${c.fields}');
        if (patch is Map) expect(patch.keys.where((k) => '$k'.startsWith('drivers.')), isEmpty);
      }
      expect(made.where((c) => c.fields.keys.any(isNew)), isNotEmpty);
    });
  });
}
