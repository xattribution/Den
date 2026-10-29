@Timeout(Duration(seconds: 120))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';
import 'package:http/http.dart' as http;

import 'support/fixture.dart';
import 'support/test.dart';
import 'support/tls.dart';

/// Shared calendars between families (P5a): a family's link for another family holds its
/// Everyone events only, answers conditional GETs, and has a watch stream; the other family's hub
/// copies it in, hears changes in seconds, never echoes or relays, and lets go when it stops.
void main() {
  final hubs = <HubFixture>[];
  tearDown(() async {
    for (final f in hubs.reversed) {
      await f.stop();
    }
    hubs.clear();
  });

  /// A new family named [name], founded by Alex's phone.
  Future<Den> family(String name) async {
    final phone = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    await phone.createFamily(
      familyName: name,
      timezone: 'America/Chicago',
      yourName: 'Alex',
      deviceName: "Alex's phone",
      deviceKind: DeviceKind.phone,
    );
    return phone;
  }

  /// A hub for a new family named [name]. Every hub here is on this machine, which it may fetch
  /// from only because the test allows it (DEN_FETCH_ALLOW), as for a calendar server at home.
  Future<HubFixture> hubFor(String name) async {
    final f = await HubFixture.start(
      phone: await family(name),
      configure: (c) => HubConfig(
        port: 0,
        host: InternetAddress.loopbackIPv4,
        mdns: false,
        log: HubLog(level: LogLevel.error, sink: (line) => stderr.writeln('[$name] $line')),
        fetchAllow: [IpNetwork.parse('127.0.0.1')],
      ),
    );
    hubs.add(f);
    return f;
  }

  /// Calls [f]'s hub as Alex's phone, signing with its key.
  Future<ApiResult> signed(HubFixture f, String method, String path, {Object? body}) async {
    final bytes = body == null ? <int>[] : utf8.encode(jsonEncode(body));
    final headers = await DeviceRequest.sign(
      keys: f.phone.keys,
      method: method,
      url: f.base.resolve(path),
      body: bytes,
      hub: f.hubDen.deviceId,
      actorId: f.phone.actor?.id,
    );
    return f.call(method, path, body: body, headers: headers);
  }

  /// A calendar link of [feed] from Alex's phone: its address and id.
  Future<({String url, String id})> link(HubFixture f, {String feed = 'shared', String label = 'The other family'}) async {
    final made = await signed(f, 'POST', '/api/v1/feeds', body: {'feed': feed, 'label': label});
    expect(made.status, 201, reason: made.text);
    return (url: made.body['url']! as String, id: made.body['id']! as String);
  }

  int day(Den phone, int days, [int hour = 10]) => phone.dayStart(phone.todayDate()) + days * 86400000 + hour * 3600000;

  /// Adds an event on [f]'s phone and brings the hub up to date.
  Future<String> add(HubFixture f, String title, {int days = 3, Audience audience = Audience.everyone, EventSource? source}) async {
    final id = await f.phone.addEvent(
      title: title,
      start: day(f.phone, days),
      end: day(f.phone, days, 11),
      audience: audience,
      source: source,
    );
    await f.toHub();
    return id;
  }

  /// What [f]'s hub copied in from feeds.
  List<Event> imported(HubFixture f) => f.hubDen.events.where((e) => e.source.kind == 'ics').toList();
  Set<String> titles(Iterable<Event> events) => {for (final e in events) e.title};

  /// Subscribes [f]'s family to [url] and fetches it.
  Future<String> subscribe(HubFixture f, String url) async {
    final id = await f.phone.addSubscription(url: url);
    await f.toHub();
    await f.hub.feeds.syncAll();
    return id;
  }

  group('the shared feed', () {
    test('holds Everyone events with their full details, never Parents-only or Just-me ones, read as the family', () async {
      final a = await hubFor('Kotvas');
      final sports = await a.phone.addCategory(name: 'Sports', icon: 'sports');
      final soccer = await a.phone.addEvent(
        title: 'Soccer at the park',
        start: day(a.phone, 2, 17),
        end: day(a.phone, 2, 18),
        tz: 'America/Chicago',
        rrule: 'FREQ=WEEKLY;COUNT=4',
        location: 'Field 9, Oak Park',
        notes: 'Bring water; shin guards too',
        category: sports,
      );
      final first = a.phone.occurrences(day(a.phone, 0), day(a.phone, 30)).firstWhere((o) => o.event.id == soccer);
      await a.phone.updateEvent(soccer, {'location': 'Field 2'}, scope: EditScope.one, occurrence: first.seriesStart);
      await a.toHub();
      await add(a, 'Anniversary dinner', audience: Audience.parents);
      await add(a, 'Dentist (just me)', audience: Audience.justMe);
      // A school's calendar the family brought in is theirs to share; what another family shared
      // with them (a shared feed's UID, or an older calendar link's) is not.
      await add(a, 'Book fair', source: const EventSource('ics', 'fair@oakgrove.example', 'Oak Grove School'));
      await add(a, 'Smith bake sale', source: const EventSource('ics', 'k3j4@abcdefghijklmnop.den', 'Smith family'));
      await add(a, 'From an old link', source: const EventSource('ics', 'q7x2@den', 'Lee family'));

      final shared = await link(a);
      expect(shared.url, endsWith('/shared.ics'));
      final listed = await signed(a, 'GET', '/api/v1/feeds');
      expect((listed.body['feeds']! as List).single, containsPair('feed', 'shared'));
      final r = await http.get(Uri.parse(shared.url));
      expect(r.statusCode, 200);
      expect(r.headers['content-type'], 'text/calendar; charset=utf-8');
      expect(r.headers['etag'], startsWith('W/"'));
      final text = r.body;
      expect(text, contains('X-WR-CALNAME:Kotvas'));
      expect(text, contains('SUMMARY:Soccer at the park'));
      expect(text, contains('LOCATION:Field 9\\, Oak Park'));
      expect(text, contains('DESCRIPTION:Bring water\\; shin guards too'));
      expect(text, contains('CATEGORIES:Sports'));
      expect(text, contains('RRULE:FREQ=WEEKLY;COUNT=4'));
      expect(text, contains('RECURRENCE-ID'));
      expect(text, contains('LOCATION:Field 2'));
      expect(text, contains('SUMMARY:Book fair'));
      for (final hidden in ['Anniversary dinner', 'Dentist', 'Smith bake sale', 'From an old link']) {
        expect(text, isNot(contains(hidden)), reason: hidden);
      }
      final uids = RegExp(r'^UID:(.*)$', multiLine: true).allMatches(text.replaceAll('\r\n', '\n')).map((m) => m.group(1)!).toSet();
      expect(uids, hasLength(2));
      expect(uids, everyElement(endsWith('@${a.phone.familyId}.den')));
      final parsed = parseIcs(text, defaultZone: 'America/Chicago');
      expect(parsed.events.map((e) => e.summary).toSet(), {'Soccer at the park', 'Book fair'});

      // Alex made it, and Alex's own family link holds Parents-only and Just-me things (with the
      // UIDs subscribed calendars already know), but the shared one reads as the family.
      final own = await http.get(Uri.parse((await link(a, feed: 'family', label: "Alex's iPhone")).url));
      expect(own.body, contains('Anniversary dinner'));
      expect(own.body, contains('Dentist (just me)'));
      expect(RegExp(r'^UID:.*@den\r$', multiLine: true).allMatches(own.body), isNotEmpty);
      expect(own.body, isNot(contains('.den\r\n')));

      // The link opens its own file and its watch, nothing else.
      final secret = Uri.parse(shared.url).pathSegments[1];
      expect((await a.call('GET', '/ics/$secret/family.ics')).status, 404);
      expect((await a.call('GET', '/api/v1/today', token: secret)).status, 401);
    });

    test('answers with an ETag, and 304 while the Everyone events stay the same', () async {
      final a = await hubFor('Kotvas');
      await add(a, 'Kotvas picnic');
      final path = Uri.parse((await link(a)).url).path;
      final first = await a.call('GET', path);
      final etag = first.headers['etag']!;
      expect(etag, startsWith('W/"'));

      final again = await a.call('GET', path, headers: {'if-none-match': etag});
      expect(again.status, 304);
      expect(again.text, isEmpty);
      expect(again.headers['etag'], etag);
      expect((await a.call('GET', path, headers: {'if-none-match': etag.substring(2)})).status, 304, reason: 'compared weakly');
      expect((await a.call('GET', path, headers: {'if-none-match': '"other", $etag'})).status, 304);
      expect((await a.call('GET', path, headers: {'if-none-match': '"other"'})).status, 200);

      // The file says when it was written (DTSTAMP), which isn't a change.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      final later = await a.call('GET', path);
      expect(later.headers['etag'], etag);

      await add(a, 'Anniversary dinner', audience: Audience.parents);
      expect((await a.call('GET', path, headers: {'if-none-match': etag})).status, 304, reason: 'a Parents-only event isn\'t in it');
      await add(a, 'Kotvas bonfire');
      final changed = await a.call('GET', path, headers: {'if-none-match': etag});
      expect(changed.status, 200);
      expect(changed.text, contains('Kotvas bonfire'));
      expect(changed.headers['etag'], isNot(etag));

      // The older feeds answer conditional GETs the same way.
      final family = Uri.parse((await link(a, feed: 'family', label: "Alex's iPhone")).url).path;
      final f1 = await a.call('GET', family);
      expect((await a.call('GET', family, headers: {'if-none-match': f1.headers['etag']!})).status, 304);
    });
  });

  group('no loops', () {
    test('A → B → A never echoes, A → B → C never relays, and a family\'s own share brings nothing', () async {
      final a = await hubFor('Kotvas');
      final b = await hubFor('Smith family');
      final c = await hubFor('The Riveras');
      await add(a, 'Kotvas picnic');
      await add(b, 'Smith bake sale');
      await add(c, 'Rivera recital');
      final fromA = (await link(a)).url;
      final fromB = (await link(b)).url;

      await subscribe(b, fromA);
      expect(titles(imported(b)), {'Kotvas picnic'});
      final copy = imported(b).single;
      expect(copy.source.ref, endsWith('@${a.phone.familyId}.den'));
      expect(copy.source.label, 'Kotvas');
      expect(copy.space, Space.family);

      // A → B → A: B's share holds B's own events, not the copy of A's.
      await subscribe(a, fromB);
      expect(titles(imported(a)), {'Smith bake sale'});
      expect(a.hubDen.events.where((e) => e.title == 'Kotvas picnic'), hasLength(1));
      await b.hub.feeds.syncAll();
      await a.hub.feeds.syncAll();
      expect(titles(imported(b)), {'Kotvas picnic'});
      expect(titles(imported(a)), {'Smith bake sale'});

      // A → B → C: C gets B's events and nothing B copied in.
      await subscribe(c, fromB);
      expect(titles(imported(c)), {'Smith bake sale'});
      final bText = (await http.get(Uri.parse(fromB))).body;
      expect(bText, isNot(contains('Kotvas')));

      // A subscribing to its own share: its own UIDs are left out.
      final self = await subscribe(a, fromA);
      expect(titles(imported(a)), {'Smith bake sale'});
      expect(a.hubDen.subscription(self)!.status, "This is your own family's calendar, so Den leaves it out.");
    });
  });

  group('the watch stream', () {
    test('says changed only when Everyone events change, and revoked when the link is turned off', () async {
      final a = await hubFor('Kotvas');
      await add(a, 'Kotvas picnic');
      final shared = await link(a);
      final watchUrl = shareWatchUri(shared.url)!;
      expect(watchUrl.path, endsWith('/watch'));

      final events = <(String, Map<String, Object?>)>[];
      var closed = false;
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final response = await (await client.getUrl(watchUrl)).close();
      expect(response.statusCode, 200);
      expect(response.headers.contentType?.mimeType, 'text/event-stream');
      expect(response.headers.value('cache-control'), contains('no-transform'));
      String? name;
      final data = StringBuffer();
      response.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (line.isEmpty) {
          if (name != null) events.add((name!, (jsonDecode(data.toString()) as Map).cast<String, Object?>()));
          name = null;
          data.clear();
        } else if (line.startsWith('event: ')) {
          name = line.substring(7);
        } else if (line.startsWith('data: ')) {
          data.write(line.substring(6));
        }
      }, onDone: () => closed = true);

      await eventually(() => events.isNotEmpty);
      final feed = await http.get(Uri.parse(shared.url));
      expect(events.single.$1, 'hello');
      expect(events.single.$2, {'etag': feed.headers['etag']});

      // Nothing an Everyone subscriber would see: no word.
      await add(a, 'Anniversary dinner', audience: Audience.parents);
      await add(a, 'Smith bake sale', source: const EventSource('ics', 'k3j4@abcdefghijklmnop.den', 'Smith family'));
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(events.map((e) => e.$1), ['hello']);

      final watch = Stopwatch()..start();
      await add(a, 'Kotvas bonfire');
      await eventually(() => events.length > 1, timeout: const Duration(seconds: 5));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      final now = await http.get(Uri.parse(shared.url));
      expect(events.last.$1, 'changed');
      expect(events.last.$2, {'etag': now.headers['etag']});

      expect((await signed(a, 'DELETE', '/api/v1/feeds/${shared.id}')).status, 200);
      await eventually(() => closed, timeout: const Duration(seconds: 5));
      expect(events.last.$1, 'revoked');
      expect((await http.get(watchUrl)).statusCode, 401);

      // A link for a phone's calendar has no watch stream.
      final family = Uri.parse((await link(a, feed: 'family', label: "Alex's iPhone")).url);
      expect((await http.get(family.replace(path: family.path.replaceFirst('family.ics', 'watch')))).statusCode, 404);
    });

    test('another family\'s hub hears a change within a couple of seconds and copies it in', () async {
      final a = await hubFor('Kotvas');
      final b = await hubFor('Smith family');
      final picnic = await add(a, 'Kotvas picnic');
      final sub = await subscribe(b, (await link(a)).url);
      expect(titles(imported(b)), {'Kotvas picnic'});
      await eventually(() => b.hub.feeds.watching.contains(sub));

      final watch = Stopwatch()..start();
      await add(a, 'Kotvas bonfire');
      await eventually(() => titles(imported(b)).contains('Kotvas bonfire'), timeout: const Duration(seconds: 10));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)), reason: 'the watch stream, not the ${sharePoll.inMinutes}-minute poll');

      watch.reset();
      await a.phone.updateEvent(picnic, {'location': 'Lakeside shelter', 'notes': 'Bring a blanket'});
      await a.toHub();
      bool moved() => imported(b).any((e) => e.title == 'Kotvas picnic' && e.location == 'Lakeside shelter' && e.notes == 'Bring a blanket');
      await eventually(moved, timeout: const Duration(seconds: 10));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));

      await a.phone.deleteEvent(picnic);
      await a.toHub();
      await eventually(() => titles(imported(b)).length == 1, timeout: const Duration(seconds: 10));
      expect(titles(imported(b)), {'Kotvas bonfire'});
      await b.toPhone();
      expect(b.phone.events.where((e) => e.source.kind == 'ics').map((e) => e.title), ['Kotvas bonfire']);
    });
  });

  group('stopping', () {
    test('turning the link off removes the copies at once and tells the other family\'s parents', () async {
      final a = await hubFor('Kotvas');
      final b = await hubFor('Smith family');
      await add(a, 'Kotvas picnic');
      await add(a, 'Kotvas bonfire', days: 5);
      await add(b, 'Smith bake sale');
      final shared = await link(a);
      final sub = await subscribe(b, shared.url);
      expect(titles(imported(b)), {'Kotvas picnic', 'Kotvas bonfire'});
      await eventually(() => b.hub.feeds.watching.contains(sub));

      expect((await signed(a, 'DELETE', '/api/v1/feeds/${shared.id}')).status, 200);
      await eventually(() => imported(b).isEmpty, timeout: const Duration(seconds: 5));
      expect(b.hubDen.subscription(sub)!.status, 'The Kotvas family stopped sharing their calendar');
      expect(b.hub.feeds.watching, isEmpty);
      expect(titles(b.hubDen.events), {'Smith bake sale'}, reason: 'the family\'s own events stay');
      await b.toPhone();
      expect(b.phone.subscription(sub)!.status, 'The Kotvas family stopped sharing their calendar');

      // Fetching again changes nothing and says the same.
      await b.hub.feeds.syncAll();
      expect(imported(b), isEmpty);
      expect(b.hubDen.subscription(sub)!.status, 'The Kotvas family stopped sharing their calendar');
    });

    test('a share that answers 401 loses every copy, even ones a cut-short fetch left; other feeds keep theirs', () async {
      final b = await hubFor('Smith family');
      const family = 'abcdefghijklmnop';
      final share = await _FakeShare.start(name: 'Carter family', family: family, at: day(b.phone, 3));
      addTearDown(share.close);
      final school = await _FakeShare.start(name: 'Oak Grove School', family: null, at: day(b.phone, 4));
      addTearDown(school.close);
      final sub = await subscribe(b, share.url);
      final other = await subscribe(b, school.url);
      expect(titles(imported(b)), {'Carter picnic', 'Oak Grove School picnic'});
      // A copy a fetch wrote before it could note it down.
      await b.hubDen.addEvent(
        title: 'Carter stray',
        start: day(b.phone, 6),
        end: day(b.phone, 6, 11),
        source: const EventSource('ics', 'stray@$family.den', 'Carter family'),
      );

      share.status = 401;
      school.status = 401;
      await b.hub.feeds.syncAll();
      expect(titles(imported(b)), {'Oak Grove School picnic'});
      expect(b.hubDen.subscription(sub)!.status, 'The Carter family stopped sharing their calendar');
      expect(b.hubDen.subscription(other)!.status, "That link doesn't work anymore: the server answered 401");
    });

    test('says who stopped in words that fit the family\'s name', () {
      expect(familyPhrase('Kotvas'), 'The Kotvas family');
      expect(familyPhrase('Carter family'), 'The Carter family');
      expect(familyPhrase('The Riveras'), 'The Riveras');
      expect(familyPhrase(null), 'The other family');
    });
  });

  group('recognizing a Den share', () {
    test('by its address', () {
      expect(shareWatchUri('https://den-smith.example.com/ics/denfeed_q3Jx/shared.ics').toString(),
          'https://den-smith.example.com/ics/denfeed_q3Jx/watch');
      expect(shareWatchUri('webcal://den-smith.example.com/ics/denfeed_q3Jx/shared.ics?x=1').toString(),
          'https://den-smith.example.com/ics/denfeed_q3Jx/watch');
      expect(shareWatchUri('https://den-smith.example.com/ics/denfeed_q3Jx/family.ics'), isNull);
      expect(shareWatchUri('https://school.example.org/shared.ics'), isNull);
      expect(shareWatchUri('https://school.example.org/ics/nope/shared.ics'), isNull);
      expect(isDenUid('k3j4@abcdefghijklmnop.den'), isTrue);
      expect(isDenUid('q7x2@den'), isTrue);
      expect(isDenUid('fair@oakgrove.example'), isFalse);
      expect(isDenUid('x@golden'), isFalse);
    });
  });

  group('NetGuard and the families on one server', () {
    late HttpServer hubsTls;
    late HttpServer otherTls;
    late HttpServer plain;
    late _Resolver dns;
    String? redirectTo;
    final paths = <String>[];

    Future<HttpServer> serve(HttpServer server) async {
      server.listen((r) async {
        paths.add('${r.headers.host}${r.uri.path}');
        if (r.uri.path == '/hop' && redirectTo != null) {
          r.response
            ..statusCode = 302
            ..headers.set('location', redirectTo!);
        } else {
          r.response.write('hello from ${r.uri.path}');
        }
        await r.response.close();
      });
      return server;
    }

    setUp(() async {
      paths.clear();
      redirectTo = null;
      hubsTls = await serve(await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, serving(hubsCert, hubsKey)));
      otherTls = await serve(await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, serving(otherCert, otherKey)));
      plain = await serve(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
      dns = _Resolver({
        'den-a.test': ['127.0.0.1'],
        'den-b.test': ['127.0.0.1'],
        'den-c.test': ['127.0.0.1'],
        'other.test': ['127.0.0.1'],
        'metadata.test': ['169.254.169.254'],
        'private.test': ['10.0.0.5'],
        'cgnat.test': ['100.64.1.1'],
        'mixed.test': ['127.0.0.1', '10.0.0.5'],
      });
    });
    tearDown(() async {
      await hubsTls.close(force: true);
      await otherTls.close(force: true);
      await plain.close(force: true);
    });

    http.Client guard(List<String> listed) {
      final client = NetGuard(
        resolve: dns.call,
        hubs: [for (final h in listed) Uri.parse(h)],
        tls: trustingTestCa(),
      ).client();
      addTearDown(client.close);
      return client;
    }

    test('lets the hub\'s own address and its listed peers reach this machine, over https and their port only', () async {
      final p = hubsTls.port;
      final client = guard(['https://den-a.test:$p', 'https://den-b.test:$p']);
      expect((await client.get(Uri.parse('https://den-a.test:$p/ics/x/shared.ics'))).body, 'hello from /ics/x/shared.ics');
      expect((await client.get(Uri.parse('https://DEN-B.test:$p/watch'))).body, 'hello from /watch');

      for (final url in [
        'https://other.test:${otherTls.port}/', // not listed
        'http://den-a.test:${plain.port}/', // listed name, but http
        'https://den-a.test:${otherTls.port}/', // listed name, another port
        'https://127.0.0.1:$p/', // an address is never a hub
        'https://[::1]:$p/',
        'http://10.0.0.5/',
        'http://169.254.169.254/latest/meta-data/',
      ]) {
        await expectLater(client.get(Uri.parse(url)), throwsA(isA<BlockedAddress>()), reason: url);
      }
      expect(paths, ['den-a.test/ics/x/shared.ics', 'den-b.test/watch'], reason: 'nothing else was reached');
    });

    test('a listed name that leads anywhere private but loopback is refused', () async {
      final client = guard([for (final n in ['metadata', 'private', 'cgnat', 'mixed']) 'https://$n.test']);
      for (final n in ['metadata', 'private', 'cgnat', 'mixed']) {
        await expectLater(client.get(Uri.parse('https://$n.test/')), throwsA(isA<BlockedAddress>()), reason: n);
      }
    });

    test('the certificate is still checked for the name', () async {
      final p = hubsTls.port;
      // den-c.test is listed and leads to this machine, but what answers there holds den-a's and
      // den-b's certificate, not den-c's.
      final client = guard(['https://den-c.test:$p']);
      await expectLater(client.get(Uri.parse('https://den-c.test:$p/')), throwsA(isA<HandshakeException>()));
      expect(paths, isEmpty);
    });

    test('redirects are checked again', () async {
      final p = hubsTls.port;
      final client = guard(['https://den-a.test:$p', 'https://den-b.test:$p']);
      for (final to in [
        'http://127.0.0.1:${plain.port}/secret',
        'http://den-a.test:${plain.port}/secret',
        'https://den-a.test:${otherTls.port}/secret',
        'https://other.test:${otherTls.port}/secret',
        'https://metadata.test/secret',
      ]) {
        redirectTo = to;
        await expectLater(client.get(Uri.parse('https://den-a.test:$p/hop')), throwsA(isA<BlockedAddress>()), reason: to);
      }
      expect(paths, everyElement('den-a.test/hop'), reason: 'no redirect reached /secret');
      redirectTo = 'https://den-b.test:$p/landed';
      expect((await client.get(Uri.parse('https://den-a.test:$p/hop'))).body, 'hello from /landed');
    });

    test('the hub lets its DEN_PUBLIC_URL and DEN_PEER_HUBS through, and nothing else', () async {
      final p = hubsTls.port;
      final f = await HubFixture.start(
        configure: (c) => HubConfig(
          port: 0,
          host: InternetAddress.loopbackIPv4,
          mdns: false,
          log: HubLog.silent(),
          resolver: dns.call,
          publicUrl: Uri.parse('https://den-a.test:$p'),
          peerHubs: parsePeerHubs('den-b.test:$p'),
        ),
      );
      hubs.add(f);
      final fetch = f.hub.context.fetch;
      // The hub trusts the system's certificates, not the test's, so its own and its peer's
      // address get as far as TLS, and every other one is refused before connecting.
      await expectLater(fetch.get(Uri.parse('https://den-a.test:$p/')), throwsA(isA<HandshakeException>()));
      await expectLater(fetch.get(Uri.parse('https://den-b.test:$p/')), throwsA(isA<HandshakeException>()));
      await expectLater(fetch.get(Uri.parse('https://other.test:${otherTls.port}/')), throwsA(isA<BlockedAddress>()));
      await expectLater(fetch.get(Uri.parse('https://den-c.test:$p/')), throwsA(isA<BlockedAddress>()));
      await expectLater(fetch.get(Uri.parse('http://den-b.test:${plain.port}/')), throwsA(isA<BlockedAddress>()));
      expect(paths, isEmpty);
    });

    test('DEN_PEER_HUBS takes names and https addresses, nothing else', () {
      expect(parsePeerHubs(' den-smith.example.com, https://den-jones.example.com:8443/x  DEN-Lee.example.com ').map((u) => '$u'), [
        'https://den-smith.example.com',
        'https://den-jones.example.com:8443',
        'https://den-lee.example.com',
      ]);
      expect(parsePeerHubs(''), isEmpty);
      for (final bad in ['http://den.example.com', '10.0.0.1', 'https://10.0.0.1', '[::1]', 'localhost', 'me@den.example.com', 'den_x.example.com']) {
        expect(() => parsePeerHubs(bad), throwsFormatException, reason: bad);
      }
    });
  });
}

/// A resolver answering from a table.
class _Resolver {
  _Resolver(this.answers);
  final Map<String, List<String>> answers;

  Future<List<InternetAddress>> call(String host) async {
    final a = answers[host.toLowerCase()];
    if (a == null) throw SocketException('no such host $host');
    return [for (final x in a) InternetAddress(x)];
  }
}

/// A calendar served at a Den share's address (or, without [family], a school's), with one
/// event, that can start answering [status] instead.
class _FakeShare {
  _FakeShare._(this.server, this.path);
  final HttpServer server;
  final String path;
  int status = 200;
  late String body;

  static Future<_FakeShare> start({required String name, required String? family, required int at}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final s = _FakeShare._(server, family == null ? '/calendar.ics' : '/ics/denfeed_${Random().nextInt(1 << 30)}/shared.ics');
    final stamp = DateTime.fromMillisecondsSinceEpoch(at, isUtc: true);
    String two(int n) => '$n'.padLeft(2, '0');
    final start = '${stamp.year}${two(stamp.month)}${two(stamp.day)}T${two(stamp.hour)}${two(stamp.minute)}00Z';
    final first = name.split(' ').first;
    s.body = [
      'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//test//EN', 'X-WR-CALNAME:$name', //
      'BEGIN:VEVENT', 'UID:picnic@${family == null ? 'school.example' : '$family.den'}', 'DTSTAMP:20261029T000000Z',
      'DTSTART:$start', 'DURATION:PT1H', 'SUMMARY:${family == null ? name : first} picnic', 'END:VEVENT',
      'END:VCALENDAR', '',
    ].join('\r\n');
    server.listen((r) async {
      if (r.uri.path != s.path) {
        r.response.statusCode = 404;
      } else if (s.status != 200) {
        r.response.statusCode = s.status;
      } else {
        r.response
          ..headers.contentType = ContentType('text', 'calendar', charset: 'utf-8')
          ..write(s.body);
      }
      await r.response.close();
    });
    return s;
  }

  String get url => 'http://127.0.0.1:${server.port}$path';

  Future<void> close() => server.close(force: true);
}
