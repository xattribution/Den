@Timeout(Duration(minutes: 5))
library;

import 'package:den_core/demo.dart';
import 'package:den_core/src/time.dart' show dateIn;
import 'package:test/test.dart';

/// The demo family builds at any moment the real clock may show: around midnight where the
/// family lives, and on the nights clocks change, in the US and elsewhere. It once refused to
/// build in the first twenty minutes of every day: the kids' check-offs for today were clocked
/// twenty minutes before "now", which was still yesterday, so today hadn't come yet.
void main() {
  // Instants (UTC) and the zone the demo family lives in.
  final cases = <(String, String, DateTime)>[
    // Local midnight, and a few minutes either side, on an ordinary night in Chicago (CDT).
    ('Chicago, 11:59 PM', demoTimeZone, DateTime.utc(2026, 10, 21, 4, 59)),
    ('Chicago, midnight', demoTimeZone, DateTime.utc(2026, 10, 21, 5)),
    ('Chicago, 12:05 AM', demoTimeZone, DateTime.utc(2026, 10, 21, 5, 5)),
    ('Chicago, 12:19 AM', demoTimeZone, DateTime.utc(2026, 10, 21, 5, 19)),
    // US clocks go back: 2026-11-01 2:00 AM CDT becomes 1:00 AM CST (07:00 UTC).
    ('US fall back, midnight', demoTimeZone, DateTime.utc(2026, 11, 1, 5)),
    ('US fall back, 12:05 AM', demoTimeZone, DateTime.utc(2026, 11, 1, 5, 5)),
    ('US fall back, first 1:30 AM', demoTimeZone, DateTime.utc(2026, 11, 1, 6, 30)),
    ('US fall back, second 1:30 AM', demoTimeZone, DateTime.utc(2026, 11, 1, 7, 30)),
    ('US fall back, noon', demoTimeZone, DateTime.utc(2026, 11, 1, 18)),
    ('US fall back, next midnight', demoTimeZone, DateTime.utc(2026, 11, 2, 6, 5)),
    // US clocks go forward: 2026-03-08 2:00 AM CST becomes 3:00 AM CDT (08:00 UTC).
    ('US spring forward, midnight', demoTimeZone, DateTime.utc(2026, 3, 8, 6, 1)),
    ('US spring forward, 1:59 AM', demoTimeZone, DateTime.utc(2026, 3, 8, 7, 59)),
    ('US spring forward, 3:00 AM', demoTimeZone, DateTime.utc(2026, 3, 8, 8)),
    ('US spring forward, next midnight', demoTimeZone, DateTime.utc(2026, 3, 9, 5, 10)),
    // Elsewhere: Europe changes at 01:00 UTC on other Sundays; Sydney's clocks go back in April.
    ('London, midnight', 'Europe/London', DateTime.utc(2026, 10, 25)),
    ('London, clocks go back', 'Europe/London', DateTime.utc(2026, 10, 25, 1, 10)),
    ('London, clocks go forward', 'Europe/London', DateTime.utc(2026, 3, 29, 1, 5)),
    ('Sydney, midnight on the day clocks go back', 'Australia/Sydney', DateTime.utc(2026, 4, 4, 13, 10)),
    ('Kolkata, 12:10 AM', 'Asia/Kolkata', DateTime.utc(2026, 10, 20, 18, 40)),
  ];

  for (final (name, zone, now) in cases) {
    test('builds at $name ($zone, ${now.toIso8601String()})', () async {
      final den = await createDemoFamily(now: now, zone: zone);
      final today = dateIn(zone, now.millisecondsSinceEpoch);
      expect(den.family!.timezone, zone);
      expect(den.todayDate(), today);
      expect(den.history().first.when.millis, lessThanOrEqualTo(now.millisecondsSinceEpoch), reason: 'nothing from the future');
      final done = den.choresOn(today).where((c) => c.done).map((c) => c.chore.title).toSet();
      expect(done, containsAll(['Make bed', 'Feed the cat']), reason: "the kids' check-offs this morning");
      await den.close();
    });
  }
}
