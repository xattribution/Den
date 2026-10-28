@Timeout(Duration(seconds: 90))
library;

import 'dart:async';
import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'support/test.dart';

import 'support/fixture.dart';

int utc(int y, int mo, int d, [int h = 0, int mi = 0]) => DateTime.utc(y, mo, d, h, mi).millisecondsSinceEpoch;

/// Serves one ICS document with an ETag, counting requests and conditional hits.
class FeedServer {
  FeedServer._(this.server);
  final HttpServer server;
  String body = '';
  int requests = 0;
  int notModified = 0;
  int status = 200;

  /// Never answers, like a calendar server that hangs.
  bool hang = false;

  static Future<FeedServer> start() async {
    final s = FeedServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    s.server.listen((request) async {
      s.requests++;
      if (s.hang) return;
      final etag = '"${s.body.hashCode}"';
      if (s.status != 200) {
        request.response.statusCode = s.status;
      } else if (request.headers.value('if-none-match') == etag) {
        s.notModified++;
        request.response.statusCode = 304;
      } else {
        request.response.headers
          ..set('etag', etag)
          ..contentType = ContentType('text', 'calendar', charset: 'utf-8');
        request.response.write(s.body);
      }
      await request.response.close();
    });
    return s;
  }

  String get url => 'http://127.0.0.1:${server.port}/school.ics';
}

/// [ics] with four events Den can't place (a cut-short date, letters in a date, month 13, a
/// RECURRENCE-ID that isn't a date) and one whose EXDATE and DURATION are partly broken.
String withBroken(String ics) => ics.replaceFirst('END:VCALENDAR', [
      'BEGIN:VEVENT', 'UID:short@school', 'DTSTART;VALUE=DATE:2026', 'SUMMARY:Short date', 'END:VEVENT',
      'BEGIN:VEVENT', 'UID:letters@school', 'DTSTART;VALUE=DATE:2026AB01', 'SUMMARY:Letters', 'END:VEVENT',
      'BEGIN:VEVENT', 'UID:month@school', 'DTSTART:20261345T100000', 'SUMMARY:Month 13', 'END:VEVENT',
      'BEGIN:VEVENT', 'UID:band@school', 'RECURRENCE-ID;VALUE=DATE:20', 'DTSTART:20261103T120000Z', 'SUMMARY:Broken override',
      'END:VEVENT',
      'BEGIN:VEVENT', 'UID:exdate@school', 'DTSTART:20261101T100000Z', 'RRULE:FREQ=DAILY;COUNT=3',
      'EXDATE:2026,20261102T100000Z', 'DURATION:P99999999W', 'SUMMARY:Bad exdate', 'END:VEVENT',
      'END:VCALENDAR',
    ].join('\n'));

void main() {
  final fixture = File('test/fixtures/school.ics').readAsStringSync();

  group('parser', () {
    test('unfolds, unescapes, reads zones, dates, durations, exceptions and cancellations', () {
      final cal = parseIcs(fixture, defaultZone: 'America/Chicago');
      expect(cal.name, 'Oak Grove School');
      final fair = cal.events.firstWhere((e) => e.uid == 'fair@school');
      expect(fair.summary, 'Book fair, evening');
      expect(fair.description, 'Bring a tote bag.\nCash only.');
      expect(fair.endUtc - fair.start!.utc, 2 * 3600000);
      final picture = cal.events.firstWhere((e) => e.uid == 'picture@school');
      expect(picture.allDay, isTrue);
      expect(picture.start!.utc, utc(2026, 10, 21, 5));
      final occ = expandCalendar(cal, utc(2026, 10, 1), utc(2026, 12, 31)).where((o) => o.uid == 'band@school').toList();
      expect(occ.map((o) => o.start), [utc(2026, 10, 20, 11), utc(2026, 11, 3, 12), utc(2026, 11, 10, 12, 30), utc(2026, 11, 24, 12)]);
      expect(occ[2].title, 'Band practice (late start)');
      expect(parseIcsDuration('-PT15M'), const Duration(minutes: -15));
      expect(parseIcsDuration('P1W2DT3H'), const Duration(days: 9, hours: 3));
      expect(zoneForTzid('Eastern Standard Time'), 'America/New_York');
      expect(zoneForTzid('/mozilla.org/20050126_1/Europe/Paris'), 'Europe/Paris');
      expect(() => parseIcs('hello', defaultZone: 'UTC'), throwsA(isA<IcsFormatException>()));
    });

    test('a malformed date skips that event, never the whole calendar', () {
      final cal = parseIcs(withBroken(fixture), defaultZone: 'America/Chicago');
      expect(cal.skipped, 4);
      expect(cal.events.map((e) => e.uid).toSet(), containsAll(['band@school', 'fair@school', 'exdate@school']));
      expect(cal.events.map((e) => e.uid), isNot(contains('short@school')));
      final exdate = cal.events.firstWhere((e) => e.uid == 'exdate@school');
      expect(exdate.exdates.map((x) => x.utc), [utc(2026, 11, 2, 10)], reason: 'the readable EXDATE still counts');
      expect(exdate.duration, isNull, reason: 'a duration of millions of weeks is ignored');
      expect(parseIcsDuration('P99999999W'), isNull);
    });
  });

  group('feeds', () {
    late HubFixture f;
    late FeedServer feed;
    late String subId;
    setUp(() async {
      f = await HubFixture.start();
      feed = await FeedServer.start();
      feed.body = fixture;
      subId = await f.phone.addSubscription(url: feed.url, exclude: ['board'], assignee: f.id('Maya'));
      await f.toHub();
    });
    tearDown(() async {
      await feed.server.close(force: true);
      await f.stop();
    });

    List<Event> imported() => f.hubDen.events.where((e) => e.source.kind == 'ics').toList();

    test('imports series with DST, exceptions, all-day and cancellations, then follows changes', () async {
      await f.hub.feeds.syncAll();
      final events = imported();
      expect(events.map((e) => e.title).toSet(), {'Band practice', 'Picture day', 'Book fair, evening'});
      final band = events.firstWhere((e) => e.title == 'Band practice');
      expect(band.tz, 'America/New_York');
      expect(band.rrule, contains('FREQ=WEEKLY'));
      expect(band.assignees, [f.id('Maya')]);
      expect(band.source.ref, 'band@school');
      expect(band.source.label, 'Oak Grove School');
      final window = f.hubDen.occurrences(utc(2026, 10, 1), utc(2026, 12, 31)).where((o) => o.event.id == band.id).toList();
      expect(window.map((o) => o.start), [utc(2026, 10, 20, 11), utc(2026, 11, 3, 12), utc(2026, 11, 10, 12, 30), utc(2026, 11, 24, 12)]);
      expect(window[2].title, 'Band practice (late start)');
      expect(f.hubDen.subscription(subId)!.status, matches(RegExp(r'^3 events, updated \d{1,2}:\d\d [AP]M$')));
      final token = await f.token(scopes: {Scope.admin});
      final patch = await f.call('PATCH', '/api/v1/events/${band.id}', token: token, body: {'title': 'Mine'});
      expect(patch.status, 409);

      final changes = f.hubDen.changesSince(const {}).length;
      await f.hub.feeds.syncAll();
      expect(feed.notModified, 1, reason: 'a conditional GET');
      expect(f.hubDen.changesSince(const {}).length, changes, reason: 'nothing changed, nothing written');

      feed.body = fixture
          .replaceFirst(RegExp(r'BEGIN:VEVENT\r?\nUID:fair@school[\s\S]*?END:VEVENT\r?\n'), '')
          .replaceFirst(RegExp(r'EXDATE;TZID=America/New_York:20261027T070000\r?\n'), '')
          .replaceFirst('SUMMARY:Picture day', 'SUMMARY:Picture day (retakes)');
      await f.hub.feeds.syncAll();
      expect(imported().map((e) => e.title).toSet(), {'Band practice', 'Picture day (retakes)'});
      final again = f.hubDen.occurrences(utc(2026, 10, 1), utc(2026, 12, 31)).where((o) => o.event.id == band.id);
      expect(again.map((o) => o.start), contains(utc(2026, 10, 27, 11)), reason: 'the EXDATE went away');
      expect(f.hubDen.subscription(subId)!.status, startsWith('2 events'));
      await f.toPhone();
      expect(f.phone.history(type: 'event').first.via, 'Oak Grove School');
    });

    test('a sync that starts over finds what it wrote by UID: no copies, and old copies go', () async {
      await f.hub.feeds.syncAll();
      final first = {for (final e in imported()) e.source.ref: e.id};
      expect(first.keys.toSet(), {'band@school', 'picture@school', 'fair@school'});
      final band = imported().firstWhere((e) => e.source.ref == 'band@school');
      // A copy an interrupted sync of an older hub left behind.
      await f.hubDen.addEvent(
        title: band.title,
        start: band.start,
        end: band.end,
        tz: band.tz,
        rrule: band.rrule,
        assignees: band.assignees,
        source: const EventSource('ics', 'band@school', 'Oak Grove School'),
      );
      expect(imported(), hasLength(4));
      // The hub stopped before it saved which UID became which event.
      f.hub.context.state.read('feeds').remove(subId);
      await f.hub.feeds.syncAll();
      final again = {for (final e in imported()) e.source.ref: e.id};
      expect(imported(), hasLength(3), reason: 'no event was added twice, and the old copy is gone');
      expect(again, first, reason: 'the same events were kept and updated');
      expect(f.hubDen.subscription(subId)!.status, startsWith('3 events'));
    });

    test('a malformed event is skipped and reported; the rest of the feed still comes in', () async {
      feed.body = withBroken(fixture);
      await f.hub.feeds.syncAll();
      expect(imported().map((e) => e.title).toSet(), {'Band practice', 'Picture day', 'Book fair, evening', 'Bad exdate'});
      expect(f.hubDen.subscription(subId)!.status, matches(RegExp(r"^4 events \(4 Den couldn't read\), updated ")));
    });

    test('stopping doesn\'t wait for a calendar server that never answers', () async {
      feed.hang = true;
      unawaited(f.hub.feeds.syncAll());
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final watch = Stopwatch()..start();
      await f.hub.feeds.stop();
      expect(watch.elapsed, lessThan(FeedService.stopWait + const Duration(seconds: 2)));
    });

    test('a broken link is reported in words, and removing the feed removes its events', () async {
      await f.hub.feeds.syncAll();
      expect(imported(), isNotEmpty);
      feed.status = 404;
      await f.phone.updateSubscription(subId, {'label': 'School'});
      await f.toHub();
      await f.hub.feeds.syncAll(onlyChanged: true);
      expect(f.hubDen.subscription(subId)!.status, 'That link doesn\'t work anymore: the server answered 404');
      await f.phone.removeSubscription(subId);
      await f.toHub();
      await f.hub.feeds.syncAll();
      expect(imported(), isEmpty);
    });
  });

  test('the family feed round-trips through the parser', () async {
    final f = await HubFixture.start();
    addTearDown(f.stop);
    final soccer = f.phone.events.firstWhere((e) => e.title == 'Soccer practice');
    final upcoming = f.phone
        .occurrences(f.phone.dayStart(f.phone.todayDate()), f.phone.dayStart(f.phone.todayDate()) + 21 * 86400000)
        .where((o) => o.event.id == soccer.id)
        .toList();
    final next = upcoming[0];
    await f.phone.updateEvent(soccer.id, {'location': 'Field 9', 'start': next.start + 3600000}, scope: EditScope.one, occurrence: next.seriesStart);
    // The following occurrence as Den expands it (in wall-clock time, so across a DST change
    // it isn't exactly a week of UTC milliseconds later).
    final later = upcoming[1].seriesStart;
    await f.phone.deleteEvent(soccer.id, scope: EditScope.one, occurrence: later);
    await f.toHub();
    final token = await f.token();
    final r = await f.call('GET', '/ics/$token/family.ics');
    expect(r.status, 200);
    expect(r.headers['content-type'], 'text/calendar; charset=utf-8');
    expect(r.text, contains('BEGIN:VTIMEZONE'));
    final cal = parseIcs(r.text, defaultZone: 'America/Chicago');
    final from = f.phone.dayStart(f.phone.todayDate()) - 7 * 86400000;
    final to = from + 60 * 86400000;
    final parsed = {for (final o in expandCalendar(cal, from, to)) '${o.start} ${o.end} ${o.title}'};
    final expected = {for (final o in f.hubDen.occurrences(from, to)) '${o.start} ${o.end} ${o.title}'};
    expect(parsed, expected);
    final leo = await f.token(member: f.id('Leo'), label: 'Leo calendar');
    final mine = await f.call('GET', '/ics/$leo/${f.id('Leo')}.ics');
    expect(mine.text, contains('Soccer practice'));
    expect(mine.text, isNot(contains('Anniversary dinner')));
    expect((await f.call('GET', '/ics/nope/family.ics')).status, 401);
  });
}
