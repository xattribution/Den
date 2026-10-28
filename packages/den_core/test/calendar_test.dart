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
}
