import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

List<String> dates(String rule, DateTime start, {int take = 8, DateTime? from}) => [
      for (final d in RecurrenceRule.parse(rule).expand(start, from: from).take(take))
        d.toIso8601String().substring(0, d.hour == 0 && d.minute == 0 ? 10 : 16),
    ];

void main() {
  test('rules round-trip through their canonical text', () {
    for (final text in [
      'FREQ=DAILY',
      'FREQ=DAILY;INTERVAL=3;COUNT=10',
      'FREQ=WEEKLY;BYDAY=TU,TH',
      'FREQ=WEEKLY;INTERVAL=2;UNTIL=20261231T235959Z;BYDAY=MO',
      'FREQ=MONTHLY;BYDAY=2TU',
      'FREQ=MONTHLY;BYMONTHDAY=-1',
      'FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1',
      'FREQ=YEARLY',
      'FREQ=YEARLY;INTERVAL=2;BYMONTH=11;BYDAY=4TH',
      'FREQ=YEARLY;UNTIL=20300101',
      'FREQ=WEEKLY;UNTIL=20261231T120000;BYDAY=SU;WKST=SU',
    ]) {
      final rule = RecurrenceRule.parse(text);
      expect(rule.toString(), text);
      expect(RecurrenceRule.parse(rule.toString()), rule);
    }
    expect(RecurrenceRule.parse('RRULE:freq=weekly;byday=mo').toString(), 'FREQ=WEEKLY;BYDAY=MO');
  });

  test('unsupported or malformed rules are refused', () {
    for (final text in [
      '',
      'FREQ=HOURLY',
      'BYDAY=MO',
      'FREQ=DAILY;COUNT=3;UNTIL=20260101',
      'FREQ=DAILY;BYHOUR=7',
      'FREQ=WEEKLY;BYDAY=XX',
      'FREQ=MONTHLY;BYMONTHDAY=0',
      'FREQ=DAILY;INTERVAL=0',
      'FREQ=DAILY;FREQ=WEEKLY',
    ]) {
      expect(() => RecurrenceRule.parse(text), throwsFormatException, reason: text);
    }
  });

  test('daily with an interval and a count', () {
    expect(dates('FREQ=DAILY;INTERVAL=3;COUNT=4', DateTime.utc(2026, 2, 26, 7)),
        ['2026-02-26T07:00', '2026-03-01T07:00', '2026-03-04T07:00', '2026-03-07T07:00']);
  });

  test('weekly on several days and every other week', () {
    expect(dates('FREQ=WEEKLY;BYDAY=TU,TH', DateTime.utc(2026, 10, 13), take: 4),
        ['2026-10-13', '2026-10-15', '2026-10-20', '2026-10-22']);
    expect(dates('FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,FR', DateTime.utc(2026, 10, 12), take: 5),
        ['2026-10-12', '2026-10-16', '2026-10-26', '2026-10-30', '2026-11-09']);
    expect(dates('FREQ=WEEKLY;BYDAY=MO', DateTime.utc(2026, 10, 14), take: 2), ['2026-10-19', '2026-10-26'],
        reason: 'a start that doesn\'t match the rule is not an occurrence');
  });

  test('monthly by nth weekday, last day, and missing days', () {
    expect(dates('FREQ=MONTHLY;BYDAY=2TU', DateTime.utc(2026, 1, 1), take: 4),
        ['2026-01-13', '2026-02-10', '2026-03-10', '2026-04-14']);
    expect(dates('FREQ=MONTHLY;BYDAY=-1FR', DateTime.utc(2026, 1, 1), take: 3), ['2026-01-30', '2026-02-27', '2026-03-27']);
    expect(dates('FREQ=MONTHLY;BYMONTHDAY=-1', DateTime.utc(2026, 1, 31), take: 3), ['2026-01-31', '2026-02-28', '2026-03-31']);
    expect(dates('FREQ=MONTHLY;BYMONTHDAY=31', DateTime.utc(2026, 1, 31), take: 4),
        ['2026-01-31', '2026-03-31', '2026-05-31', '2026-07-31']);
    expect(dates('FREQ=MONTHLY', DateTime.utc(2026, 1, 30), take: 3), ['2026-01-30', '2026-03-30', '2026-04-30']);
    expect(dates('FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1', DateTime.utc(2026, 1, 1), take: 3),
        ['2026-01-30', '2026-02-27', '2026-03-31']);
    expect(dates('FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=1,15', DateTime.utc(2026, 1, 1), take: 4),
        ['2026-01-01', '2026-01-15', '2026-03-01', '2026-03-15']);
  });

  test('yearly, leap days, Thanksgiving, and every other year', () {
    expect(dates('FREQ=YEARLY', DateTime.utc(2024, 2, 29), take: 3), ['2024-02-29', '2028-02-29', '2032-02-29']);
    expect(dates('FREQ=YEARLY;BYMONTH=11;BYDAY=4TH', DateTime.utc(2026, 1, 1), take: 3),
        ['2026-11-26', '2027-11-25', '2028-11-23']);
    expect(dates('FREQ=YEARLY;INTERVAL=2', DateTime.utc(2026, 7, 4, 12), take: 3),
        ['2026-07-04T12:00', '2028-07-04T12:00', '2030-07-04T12:00']);
    expect(dates('FREQ=YEARLY;BYDAY=20MO', DateTime.utc(2026, 1, 1), take: 1), ['2026-05-18']);
  });

  test('UNTIL as a date, a floating time, and a UTC instant', () {
    expect(dates('FREQ=DAILY;UNTIL=20261003', DateTime.utc(2026, 10, 1, 9), take: 10),
        ['2026-10-01T09:00', '2026-10-02T09:00', '2026-10-03T09:00']);
    expect(dates('FREQ=DAILY;UNTIL=20261003T080000', DateTime.utc(2026, 10, 1, 9), take: 10),
        ['2026-10-01T09:00', '2026-10-02T09:00']);
    final rule = RecurrenceRule.parse('FREQ=DAILY;UNTIL=20261003T130000Z');
    final inChicago = rule
        .expand(DateTime.utc(2026, 10, 1, 9), toUtc: (w) => w.add(const Duration(hours: 5)).millisecondsSinceEpoch)
        .toList();
    expect(inChicago, hasLength(2), reason: '9 AM in Chicago is 14:00Z, after 13:00Z on the 3rd');
  });

  test('skipping ahead gives the same occurrences as walking from the start', () {
    for (final text in [
      'FREQ=DAILY;INTERVAL=3',
      'FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,SA',
      'FREQ=MONTHLY;BYDAY=-1SU',
      'FREQ=MONTHLY;INTERVAL=5;BYMONTHDAY=31',
      'FREQ=YEARLY;INTERVAL=3;BYMONTH=2;BYMONTHDAY=29',
    ]) {
      final rule = RecurrenceRule.parse(text);
      final start = DateTime.utc(2001, 3, 7, 8, 15);
      final from = DateTime.utc(2026, 4, 2);
      final walked = rule.expand(start).where((d) => !d.isBefore(from)).take(5).toList();
      final skipped = rule.expand(start, from: from).where((d) => !d.isBefore(from)).take(5).toList();
      expect(skipped, walked, reason: text);
    }
  });

  test('rules that can never match end instead of looping', () {
    expect(RecurrenceRule.parse('FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30').expand(DateTime.utc(2026)).take(1), isEmpty);
  });
}
