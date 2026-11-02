import 'package:den_app/features/calendar/words/recurrence.dart';
import 'package:den_app/app/format.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

void main() {
  late Formats f;
  setUpAll(() {
    tzdata.initializeTimeZones();
    f = Formats('America/Chicago');
  });

  // Friday, October 16, 2026.
  const start = '2026-10-16';

  Recurrence supported(String raw) {
    final parsed = parseRrule(raw, startDate: start, f: f);
    expect(parsed, isA<SupportedRule>(), reason: raw);
    return (parsed! as SupportedRule).rule;
  }

  String words(String raw) => describeRrule(raw, f, startDate: start)!;

  group('parse and describe', () {
    test('no rule', () {
      expect(parseRrule(null, startDate: start, f: f), isNull);
      expect(parseRrule('', startDate: start, f: f), isNull);
    });

    test('weekly on two days until a date reads like the paper calendar', () {
      expect(words('FREQ=WEEKLY;BYDAY=TU,TH;UNTIL=20261219T055959Z'), 'Every Tuesday and Thursday until Dec 18');
      expect(words('RRULE:FREQ=WEEKLY;BYDAY=TU,TH;UNTIL=20261218'), 'Every Tuesday and Thursday until Dec 18');
    });

    test('weekly variants', () {
      expect(words('FREQ=WEEKLY'), 'Every Friday');
      expect(words('FREQ=WEEKLY;INTERVAL=2;BYDAY=MO'), 'Every 2 weeks on Monday');
      expect(words('FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR'), 'Every weekday');
      expect(words('FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR'), 'Every weekday');
      expect(words('FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=10'), 'Every Monday, Wednesday, and Friday, 10 times');
    });

    test('daily, monthly, yearly', () {
      expect(words('FREQ=DAILY'), 'Every day');
      expect(words('FREQ=DAILY;INTERVAL=3'), 'Every 3 days');
      expect(words('FREQ=MONTHLY'), 'Every month on the 16th');
      expect(words('FREQ=MONTHLY;BYMONTHDAY=1'), 'Every month on the 1st');
      expect(words('FREQ=MONTHLY;BYDAY=3FR'), 'Every month on the third Friday');
      expect(words('FREQ=MONTHLY;BYDAY=FR;BYSETPOS=-1'), 'Every month on the last Friday');
      expect(words('FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'), 'Every 2 months on the 22nd');
      expect(words('FREQ=YEARLY'), 'Every year on October 16');
      expect(words('FREQ=YEARLY;BYMONTH=10;BYMONTHDAY=16'), 'Every year on October 16');
    });

    test('until in another year shows the year', () {
      expect(words('FREQ=WEEKLY;UNTIL=20270115'), 'Every Friday until Jan 15, 2027');
    });

    test('rules the editor cannot express stay custom', () {
      for (final raw in [
        'FREQ=HOURLY',
        'FREQ=MONTHLY;BYDAY=MO,TU;BYSETPOS=1',
        'FREQ=WEEKLY;BYDAY=1MO',
        'FREQ=MONTHLY;BYMONTHDAY=1,15',
        'FREQ=MONTHLY;BYMONTHDAY=-1',
        'FREQ=YEARLY;BYMONTH=3',
        'FREQ=YEARLY;BYDAY=1SU;BYMONTH=10',
        'FREQ=DAILY;BYHOUR=9,17',
        'FREQ=WEEKLY;COUNT=3;UNTIL=20261218',
        'FREQ=DAILY;INTERVAL=2;BYDAY=MO',
        'FREQ=WEEKLY;BYWEEKNO=20',
        'not a rule',
      ]) {
        final parsed = parseRrule(raw, startDate: start, f: f);
        expect(parsed, isA<CustomRule>(), reason: raw);
        expect((parsed! as CustomRule).raw, raw, reason: 'custom rules keep their exact text');
        expect(describeRrule(raw, f, startDate: start), 'Repeats on a custom schedule');
      }
    });
  });

  group('write', () {
    test('every supported rule survives a write and a read', () {
      for (final raw in [
        'FREQ=DAILY',
        'FREQ=DAILY;INTERVAL=3;COUNT=5',
        'FREQ=WEEKLY;BYDAY=TU,TH',
        'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,FR;WKST=SU',
        'FREQ=MONTHLY;BYMONTHDAY=16',
        'FREQ=MONTHLY;BYDAY=3FR',
        'FREQ=MONTHLY;BYDAY=-1FR',
        'FREQ=YEARLY;INTERVAL=2',
        'FREQ=WEEKLY;BYDAY=TU,TH;UNTIL=20261218',
      ]) {
        final rule = supported(raw);
        final written = toRrule(rule, f);
        expect(supported(written), rule, reason: '$raw -> $written');
      }
    });

    test('until is the end of the last day in the family time zone', () {
      final rule = supported('FREQ=WEEKLY;BYDAY=TU,TH').copyWith(until: '2026-12-18');
      // Dec 18, 11:59:59 PM in Chicago (CST, UTC-6) is Dec 19, 5:59:59 AM UTC.
      expect(toRrule(rule, f), 'FREQ=WEEKLY;BYDAY=TU,TH;UNTIL=20261219T055959Z');
    });

    test('weekly days are written Monday first', () {
      const rule = Recurrence(frequency: RepeatFrequency.weekly, weekdays: {0, 6, 1});
      expect(toRrule(rule, f), 'FREQ=WEEKLY;BYDAY=MO,SA,SU');
    });
  });

  group('starting rules', () {
    test('take the start day', () {
      final weekly = Recurrence.starting(RepeatFrequency.weekly, start, f);
      expect(weekly.weekdays, {5});
      final monthly = Recurrence.starting(RepeatFrequency.monthly, start, f);
      expect(monthly.monthDay, 16);
      expect(monthly.ordinal, 3);
    });

    test('the last week of a month offers "last"', () {
      expect(ordinalFor('2026-10-30', f), [5, -1]);
      expect(ordinalFor('2026-10-16', f), [3]);
      expect(ordinalFor('2026-10-25', f), [4, -1]);
    });
  });
}
