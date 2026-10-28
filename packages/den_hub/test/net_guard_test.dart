@Timeout(Duration(seconds: 60))
library;

import 'dart:io';
import 'dart:math';

import 'package:den_hub/den_hub.dart';
import 'package:http/http.dart' as http;

import 'support/test.dart';

/// A server on every IPv4 interface (so 127.0.0.2 reaches it too, as a private address on the
/// hub's network would), recording what it was asked.
class Target {
  Target._(this.server);
  final HttpServer server;
  final List<String> paths = [];
  final List<String?> hosts = [];

  /// Where `/hop` sends the client.
  String? redirectTo;

  static Future<Target> start() async {
    final t = Target._(await HttpServer.bind(InternetAddress.anyIPv4, 0));
    t.server.listen((r) async {
      t.paths.add(r.uri.path);
      t.hosts.add(r.headers.host == null ? null : '${r.headers.host}:${r.headers.port}');
      if (r.uri.path == '/hop' && t.redirectTo != null) {
        r.response
          ..statusCode = 302
          ..headers.set('location', t.redirectTo!);
      } else {
        r.response.write('hello from ${r.uri.path}');
      }
      await r.response.close();
    });
    return t;
  }

  int get port => server.port;
}

/// A resolver answering from [answers], one list per lookup of a name (the last repeats), and
/// counting lookups.
class FakeResolver {
  FakeResolver(this.answers);
  final Map<String, List<List<String>>> answers;
  final Map<String, int> lookups = {};

  Future<List<InternetAddress>> call(String host) async {
    final n = lookups[host] = (lookups[host] ?? 0) + 1;
    final seq = answers[host];
    if (seq == null) throw SocketException('no such host $host');
    final pick = seq[min(n - 1, seq.length - 1)];
    return [for (final a in pick) InternetAddress(a)];
  }
}

void main() {
  group('which addresses are public', () {
    final cases = <String, bool>{
      '8.8.8.8': true,
      '1.1.1.1': true,
      '203.0.114.9': true,
      '2606:4700:4700::1111': true,
      '2a00:1450:4001:80b::200e': true,
      '127.0.0.1': false,
      '127.8.9.10': false,
      '0.0.0.0': false,
      '10.1.2.3': false,
      '172.16.0.1': false,
      '172.31.255.255': false,
      '192.168.1.20': false,
      '169.254.169.254': false,
      '100.64.0.1': false,
      '100.100.100.200': false,
      '192.0.0.192': false,
      '192.0.2.1': false,
      '198.18.0.1': false,
      '224.0.0.251': false,
      '255.255.255.255': false,
      '::': false,
      '::1': false,
      'fe80::1': false,
      'fc00::1': false,
      'fd00:ec2::254': false,
      'ff02::fb': false,
      '::ffff:127.0.0.1': false,
      '::ffff:10.0.0.1': false,
      '::ffff:8.8.8.8': true,
      '64:ff9b::a00:1': false,
      '64:ff9b::808:808': true,
      '2002:c0a8:0101::1': false,
      '2002:0808:0808::1': true,
      '2001::1': false,
      '2001:db8::1': false,
    };
    for (final e in cases.entries) {
      test('${e.key} is ${e.value ? '' : 'not '}public', () {
        expect(isPublicAddress(InternetAddress(e.key)), e.value);
      });
    }
  });

  group('the guarded client', () {
    late Target target;
    setUp(() async => target = await Target.start());
    tearDown(() => target.server.close(force: true));

    // The test server stands in for a public host: only 127.0.0.1 is let through, the way an
    // operator lets a home calendar server in with DEN_FETCH_ALLOW.
    NetGuard guard(FakeResolver resolver) => NetGuard(resolve: resolver.call, allow: [IpNetwork.parse('127.0.0.1')]);

    test('connects to the address it checked, with the name as Host', () async {
      final dns = FakeResolver({
        'calendar.test': [
          ['127.0.0.1'],
        ],
      });
      final client = guard(dns).client();
      addTearDown(client.close);
      final r = await client.get(Uri.parse('http://calendar.test:${target.port}/school.ics'));
      expect(r.statusCode, 200);
      expect(r.body, 'hello from /school.ics');
      expect(target.hosts.single, 'calendar.test:${target.port}');
      expect(dns.lookups['calendar.test'], 1);
    });

    test('refuses a name that resolves to the hub\'s own network, before connecting', () async {
      final dns = FakeResolver({
        'intranet.test': [
          ['127.0.0.2'],
        ],
      });
      final client = guard(dns).client();
      addTearDown(client.close);
      await expectLater(client.get(Uri.parse('http://intranet.test:${target.port}/secret')), throwsA(isA<BlockedAddress>()));
      expect(target.paths, isEmpty, reason: '127.0.0.2 reaches the server, but the guard never connected');
    });

    test('refuses when any answer is private, even if another is allowed', () async {
      final dns = FakeResolver({
        'mixed.test': [
          ['127.0.0.1', '10.0.0.5'],
        ],
      });
      final client = guard(dns).client();
      addTearDown(client.close);
      await expectLater(client.get(Uri.parse('http://mixed.test:${target.port}/')), throwsA(isA<BlockedAddress>()));
      expect(target.paths, isEmpty);
    });

    test('refuses IP literals on the hub\'s network without a lookup', () async {
      final dns = FakeResolver({});
      final client = guard(dns).client();
      addTearDown(client.close);
      for (final url in [
        'http://127.0.0.2:${target.port}/',
        'http://[::1]:${target.port}/',
        'http://169.254.169.254/latest/meta-data/',
        'http://[::ffff:10.0.0.1]/',
      ]) {
        await expectLater(client.get(Uri.parse(url)), throwsA(isA<BlockedAddress>()), reason: url);
      }
      expect(dns.lookups, isEmpty);
      expect(target.paths, isEmpty);
    });

    test('checks every redirect again', () async {
      final dns = FakeResolver({
        'feeds.test': [
          ['127.0.0.1'],
        ],
        'metadata.test': [
          ['169.254.169.254'],
        ],
        'loopback.test': [
          ['127.0.0.2'],
        ],
      });
      final client = guard(dns).client();
      addTearDown(client.close);
      target.redirectTo = 'http://loopback.test:${target.port}/secret';
      await expectLater(client.get(Uri.parse('http://feeds.test:${target.port}/hop')), throwsA(isA<BlockedAddress>()));
      target.redirectTo = 'http://metadata.test/latest/meta-data/';
      await expectLater(client.get(Uri.parse('http://feeds.test:${target.port}/hop')), throwsA(isA<BlockedAddress>()));
      target.redirectTo = 'http://127.0.0.2:${target.port}/secret';
      await expectLater(client.get(Uri.parse('http://feeds.test:${target.port}/hop')), throwsA(isA<BlockedAddress>()));
      expect(target.paths, everyElement('/hop'), reason: 'no redirect reached /secret');
      target.redirectTo = 'http://feeds.test:${target.port}/landed';
      final ok = await client.get(Uri.parse('http://feeds.test:${target.port}/hop'));
      expect(ok.body, 'hello from /landed');
    });

    test('a name that changes its answer (DNS rebinding) is looked up once per connection', () async {
      final dns = FakeResolver({
        'rebind.test': [
          ['127.0.0.1'],
          ['127.0.0.2'],
        ],
      });
      final g = guard(dns);
      final first = g.client();
      final r = await first.get(Uri.parse('http://rebind.test:${target.port}/one'));
      first.close();
      expect(r.body, 'hello from /one');
      expect(dns.lookups['rebind.test'], 1, reason: 'the address checked is the address connected to');
      final second = g.client();
      addTearDown(second.close);
      await expectLater(second.get(Uri.parse('http://rebind.test:${target.port}/two')), throwsA(isA<BlockedAddress>()));
      expect(target.paths, ['/one']);
    });

    test('without an allowance, the hub\'s own machine is refused', () async {
      final client = NetGuard(
        resolve: FakeResolver({
          'calendar.test': [
            ['127.0.0.1'],
          ],
        }).call,
      ).client();
      addTearDown(client.close);
      await expectLater(client.get(Uri.parse('http://calendar.test:${target.port}/')), throwsA(isA<BlockedAddress>()));
      expect(target.paths, isEmpty);
    });

    test('only web addresses', () async {
      final client = guard(FakeResolver({})).client();
      addTearDown(client.close);
      await expectLater(
        client.send(http.Request('GET', Uri.parse('ftp://example.com/feed.ics'))),
        throwsA(anything),
      );
    });
  });
}
