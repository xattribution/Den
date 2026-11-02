@Timeout(Duration(seconds: 120))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_hub/src/edge.dart' show WrongGuesses;
import 'package:den_net/den_net.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

import 'support/fixture.dart';
import 'support/host_fixture.dart';

class _Log implements RoutableLog {
  _Log(this.name, {this.familyId, Set<String>? hostnames, this.holds = const {}})
      : hubDevice = 'HUB$name',
        hostnames = hostnames ?? {};
  final String name;
  @override
  final String? familyId;
  @override
  final String hubDevice;
  @override
  final Set<String> hostnames;
  final Set<String> holds;
  @override
  String toString() => name;
}

Request _request(Map<String, String> headers, {String peer = '203.0.113.9'}) =>
    Request('GET', Uri.parse('http://127.0.0.1/x'), headers: headers, context: {
      'shelf.io.connection_info': _Info(InternetAddress(peer)),
    });

class _Info implements HttpConnectionInfo {
  _Info(this.remoteAddress);
  @override
  final InternetAddress remoteAddress;
  @override
  int get localPort => 47733;
  @override
  int get remotePort => 50000;
}

void main() {
  group('choosing a family (the router alone)', () {
    final a = _Log('a', familyId: 'FA', hostnames: {'den-a.test'}, holds: {'ta'});
    final b = _Log('b', familyId: 'FB', hostnames: {'den-b.test'}, holds: {'tb', 'both'});
    final c = _Log('c', hostnames: {'den-c.test'}, holds: {'both'});
    final two = TenantRouter(() => [a, b]);
    final one = TenantRouter(() => [a], single: () => true);
    final left = TenantRouter(() => [a]);

    test('by address: its family; with one family, that one at any address; with several, none at a stranger\'s', () {
      expect(two.forHostname('den-a.test'), a);
      expect(two.forHostname('den-b.test'), b);
      expect(two.forHostname('127.0.0.1'), isNull, reason: 'fail closed, never the first one');
      expect(two.forHostname(null), isNull);
      expect(one.forHostname('127.0.0.1'), a, reason: 'a hub with one family answers as it always did');
      expect(one.forHostname(null), a);
      expect(left.forHostname('den-b.test'), isNull,
          reason: "a host for several families with only one attached now (the others opening): never that one's");
      expect(left.forHostname(null), isNull);
      expect(TenantRouter<_Log>(() => [], single: () => true).forHostname('x'), isNull, reason: 'none attached yet');
      final clash = TenantRouter(() => [a, _Log('a2', hostnames: {'den-a.test'})]);
      expect(clash.forHostname('den-a.test'), isNull, reason: 'two families at one address: neither');
    });

    test('by the family in a hello, preferring the address\'s replica when two hold it', () {
      expect(two.forFamily('FB', hostname: 'den-a.test'), b, reason: 'the hello decides, not the address');
      expect(two.forFamily('FZ'), isNull);
      final replicas = TenantRouter(() => [a, _Log('a2', familyId: 'FA', hostnames: {'den-x.test'})]);
      expect(replicas.forFamily('FA', hostname: 'den-a.test'), a);
      expect(replicas.forFamily('FA', hostname: 'den-x.test')!.toString(), 'a2');
      expect(replicas.forFamily('FA'), isNull, reason: 'two replicas and no address to tell: neither');
      expect(replicas.forFamily('FA', hostname: 'elsewhere.test'), isNull);
    });

    test('by hub device; a credential by address first, then by who holds it', () {
      expect(two.forHub('HUBb'), b);
      expect(two.forHub('HUBz'), isNull);
      bool holds(_Log l, String t) => l.holds.contains(t);
      expect(two.forCredential('den-b.test', (l) => holds(l, 'ta')), b, reason: "a family's own address decides, so a's token there is b's to refuse");
      expect(two.forCredential('127.0.0.1', (l) => holds(l, 'ta')), a);
      expect(two.forCredential('127.0.0.1', (l) => holds(l, 'nope')), isNull);
      final three = TenantRouter(() => [a, b, c]);
      expect(three.forCredential('127.0.0.1', (l) => holds(l, 'both')), isNull, reason: 'held twice: neither');
      expect(one.forCredential('127.0.0.1', (l) => holds(l, 'nope')), a);
      expect(left.forCredential('den-b.test', (l) => holds(l, 'nope')), isNull);
      expect(left.forCredential('127.0.0.1', (l) => holds(l, 'ta')), a, reason: 'whose token it is');
    });

    test('a book: whoever keeps it, wherever asked; else the address\'s family', () {
      bool holds(_Log l, String t) => l.holds.contains(t);
      expect(two.forBook('den-a.test', (l) => holds(l, 'tb')), b);
      expect(two.forBook('den-a.test', (l) => holds(l, 'nope')), a);
      expect(two.forBook('127.0.0.1', (l) => holds(l, 'nope')), isNull);
      expect(two.forBook('den-a.test', (l) => holds(l, 'nope'), fallback: false), isNull);
      final three = TenantRouter(() => [a, b, c]);
      expect(three.forBook('127.0.0.1', (l) => holds(l, 'both')), isNull);
    });

    test('the address a request came to: Host, or a trusted proxy\'s X-Forwarded-Host', () {
      final proxy = [IpNetwork.parse('127.0.0.1')];
      expect(requestHostname(_request({'host': 'Den-A.Test:443'}), proxy), 'den-a.test');
      expect(requestHostname(_request({'host': 'den-a.test.'}), proxy), 'den-a.test');
      expect(requestHostname(_request({'host': '[::1]:47733'}), proxy), '::1');
      expect(requestHostname(_request({'host': '192.168.1.5:47733'}), proxy), '192.168.1.5');
      expect(requestHostname(_request({}), proxy), isNull);
      final forwarded = {'host': '127.0.0.1:47733', 'x-forwarded-host': 'den-b.test', 'x-forwarded-for': '198.51.100.7'};
      expect(requestHostname(_request(forwarded, peer: '127.0.0.1'), proxy), 'den-b.test');
      expect(requestHostname(_request(forwarded), proxy), '127.0.0.1', reason: 'only a trusted proxy names the address');
    });
  });

  group('a host with two families', () {
    late HostFixture f;
    late Directory web;

    setUp(() async {
      web = await Directory.systemTemp.createTemp('den-web');
      File('${web.path}/index.html').writeAsStringSync('<!doctype html><title>Den</title>');
      f = await HostFixture.start(
        configure: (c) => HostConfig(
          port: 0,
          host: InternetAddress.loopbackIPv4,
          log: c.log,
          webDir: web.path,
          // No DNS at all: whatever reaches another family here does it in this process.
          resolver: (name) async => throw SocketException('no DNS for $name here'),
        ),
        hub: (name, c) => HubConfig(mdns: false, publicUrl: c.publicUrl, log: c.log, public: false),
      );
    });

    tearDown(() async {
      await f.stop();
      await web.delete(recursive: true);
    });

    test('each address answers as its own family; an address that is neither gets neither', () async {
      for (final name in ['den-a.test', 'den-b.test']) {
        final status = await f.call('GET', '/api/v1/hub/status', hostname: name);
        expect(status.body['device'], f[name].hubDen.deviceId, reason: name);
        final health = await f.call('GET', '/health', hostname: name);
        expect(health.body['device'], f[name].hubDen.deviceId);
      }
      final nowhere = await f.call('GET', '/api/v1/hub/status');
      expect(nowhere.status, 404);
      expect(nowhere.error['code'], 'no_family');
      final health = await f.call('GET', '/health');
      expect(health.status, 200);
      expect(health.body, {'ok': true, 'api': 1, 'ready': true}, reason: 'the host says only that it serves');
      expect((await f.call('GET', '/oauth/authorize/status')).error['code'], 'no_family');
    });

    test('the web app is the same at every address, with its own address in the CSP', () async {
      for (final name in ['den-a.test', 'den-b.test', null]) {
        final r = await f.open('/', hostname: name);
        expect(r.statusCode, 200);
        expect(await r.stream.bytesToString(), contains('<title>Den</title>'));
        if (name != null) expect(r.headers['content-security-policy'], contains('wss://$name'));
        expect(r.headers['strict-transport-security'], name == null ? isNull : isNotNull);
      }
    });

    test('a sync connection goes to the family its hello names, at whatever address', () async {
      final a = f['den-a.test'];
      final b = f['den-b.test'];
      final node = SyncNode(a.phone);
      // At b's address, as a phone holding both families would (one origin, several logs).
      final ws = await WebSocket.connect('${f.base.replace(scheme: 'ws', path: '/ws')}', headers: {'host': 'den-b.test'});
      final peer = await node.connect(IOWebSocketChannel(ws), expectDevice: a.hubDen.deviceId);
      await peer.live;
      expect(a.hub.node.peers.map((p) => p.deviceId), contains(a.phone.deviceId));
      expect(b.hub.node.peers, isEmpty, reason: "b's hub never sees a's phone");
      await node.close();
    });

    test('a hello naming no family goes to the address\'s family; one naming a family not here is closed', () async {
      final b = f['den-b.test'];
      final stranger = await DeviceKeys.generate();
      Future<Session> hello(String? family, String hostname) async {
        final ws = await WebSocket.connect('${f.base.replace(scheme: 'ws', path: '/ws')}', headers: {'host': hostname});
        return Session.connect(IOWebSocketChannel(ws), keys: stranger, familyId: family, timeout: const Duration(seconds: 5));
      }

      final joiner = await hello(null, 'den-b.test');
      expect(joiner.peerDevice, b.hubDen.deviceId);
      expect(joiner.peerFamily, b.phone.familyId);
      await joiner.close();
      await expectLater(hello('NOSUCHFAMILY0000', 'den-b.test'), throwsA(isA<SessionException>()));
      await expectLater(hello(null, '127.0.0.1'), throwsA(isA<SessionException>()), reason: 'two families, a stranger\'s address');
    });

    test('a signed request goes to the hub it names once its signature checks out there; else to its address\'s family', () async {
      final a = f['den-a.test'];
      Future<ApiResult> feeds({String? hostname, bool sendHub = true}) =>
          f.signed(a.phone, 'GET', '/api/v1/feeds', hub: a.hubDen.deviceId, hostname: hostname, sendHub: sendHub);
      expect((await feeds(hostname: 'den-b.test')).status, 200, reason: 'X-Den-Hub decides');
      expect((await feeds()).status, 200);
      expect((await feeds(hostname: 'den-a.test', sendHub: false)).status, 200, reason: 'an older app at its own address');
      expect((await feeds(sendHub: false)).status, 401, reason: "an older app at an address that is no family's: nobody's, by address");
      expect((await feeds(hostname: 'den-b.test', sendHub: false)).status, 401, reason: "b's address is b's: a's device isn't one of b's");
    });

    test("a family's hub reads another family's shared calendar here in this process: no DNS, proxy or peer list", () async {
      final a = f['den-a.test'];
      final b = f['den-b.test'];
      final made = await f.signed(a.phone, 'POST', '/api/v1/feeds',
          hub: a.hubDen.deviceId, body: {'feed': 'shared', 'label': 'For the other family'});
      expect(made.status, 201, reason: made.text);
      final url = made.body['url']! as String;
      final feeds = b.hub.context.feedFetch;
      final feed = await feeds.get(Uri.parse(url));
      expect(feed.statusCode, 200);
      expect(feed.body, contains('@${a.phone.familyId}.den'));
      final watch = await feeds.send(http.Request('GET', Uri.parse(url.replaceFirst('shared.ics', 'watch'))));
      expect(watch.statusCode, 200);
      expect(await watch.stream.transform(utf8.decoder).firstWhere((s) => s.contains('hello')), contains('etag'));
      // Its own address, another port, or http: NetGuard, as ever (which finds no DNS here).
      await expectLater(a.hub.context.feedFetch.get(Uri.parse(url)), throwsA(isA<SocketException>()));
      await expectLater(feeds.get(Uri.parse(url.replaceFirst('den-a.test', 'den-a.test:8443'))), throwsA(isA<SocketException>()));
      await expectLater(feeds.get(Uri.parse(url.replaceFirst('https:', 'http:'))), throwsA(isA<SocketException>()));
      // A secret that isn't a's, at a's address: refused like any stranger's.
      expect((await feeds.get(Uri.parse('https://den-a.test/ics/denfeed_guess/shared.ics'))).statusCode, 401);
      // Only the feed service reads in-process: whatever else a hub fetches goes through NetGuard.
      await expectLater(b.hub.context.fetch.get(Uri.parse(url)), throwsA(isA<SocketException>()));
    });

    test('made-up signature headers reach nothing an address doesn\'t, and say nothing about which hubs are here', () async {
      final b = f['den-b.test'];
      Map<String, String> fake(String hub) => {DeviceRequest.device: 'NOBODY', DeviceRequest.signature: 'x', DeviceRequest.hubHeader: hub};
      final plain = await f.call('GET', '/api/v1/hub/status');
      final known = await f.call('GET', '/api/v1/hub/status', headers: fake(b.hubDen.deviceId));
      final unknown = await f.call('GET', '/api/v1/hub/status', headers: fake('NOSUCHHUB0000000'));
      expect(plain.error['code'], 'no_family');
      expect([known.status, known.text], [unknown.status, unknown.text], reason: 'a hub that is here and one that isn\'t look the same');
      expect(known.status, isNot(200));
      final atA = await f.call('GET', '/api/v1/push', hostname: 'den-a.test', headers: fake(b.hubDen.deviceId));
      expect(atA.status, 401, reason: "by address: a's, which refuses it");
    });

    test("one family's bad calendar links never use up another's in-process reads, and nothing else is read in-process", () async {
      final a = f['den-a.test'];
      final b = f['den-b.test'];
      final made = await f.signed(b.phone, 'POST', '/api/v1/feeds',
          hub: b.hubDen.deviceId, body: {'feed': 'shared', 'label': 'For the other family'});
      final url = made.body['url']! as String;
      var limited = false;
      for (var i = 0; i < 45 && !limited; i++) {
        final r = await a.hub.context.feedFetch.get(Uri.parse('https://den-b.test/ics/denfeed_guess$i/shared.ics'));
        limited = r.statusCode == 429;
      }
      expect(limited, isTrue, reason: "a's hub spent its own failed tries");
      final c = await HostFixture.addFamily(f.host, 'den-c.test');
      addTearDown(() async {
        await f.host.remove(c.hub);
        await c.hubDen.close();
        await c.phone.close();
      });
      expect((await c.hub.context.feedFetch.get(Uri.parse(url))).statusCode, 200, reason: "c's reads are c's own");
      // Anything but reading a calendar link goes out through NetGuard (which finds no DNS here).
      for (final other in ['https://den-b.test/api/v1/hub/status', 'https://den-b.test/api/v1/host', 'https://den-b.test/.well-known/oauth-authorization-server']) {
        await expectLater(a.hub.context.feedFetch.get(Uri.parse(other)), throwsA(isA<SocketException>()), reason: other);
      }
      await expectLater(a.hub.context.feedFetch.post(Uri.parse(url)), throwsA(isA<SocketException>()), reason: 'only GET');
    });

    test('families come and go while the host runs; two can never share a hub, a family or an address', () async {
      final c = await HostFixture.addFamily(f.host, 'den-c.test');
      expect((await f.call('GET', '/api/v1/hub/status', hostname: 'den-c.test')).status, 200);
      expect(f.host.tenants, hasLength(3));
      await f.host.remove(c.hub);
      expect((await f.call('GET', '/api/v1/hub/status', hostname: 'den-c.test')).error['code'], 'no_family');
      await c.hubDen.close();
      await c.phone.close();
      expect((await f.call('GET', '/api/v1/hub/status', hostname: 'den-c.test')).error['code'], 'no_family',
          reason: "never another family's answer, with one family fewer");

      final a = f['den-a.test'];
      await expectLater(f.host.add(a.hubDen, HubConfig(mdns: false, publicUrl: Uri.parse('https://den-z.test'))), throwsStateError);
      final other = await createDemoFamily();
      final otherHub = await HubFixture.approvedHub(other);
      await expectLater(f.host.add(otherHub, HubConfig(mdns: false, publicUrl: Uri.parse('https://den-a.test'))), throwsStateError);
      final sameFamily = await HubFixture.approvedHub(a.phone, name: 'Second hub');
      await expectLater(f.host.add(sameFamily, HubConfig(mdns: false, publicUrl: Uri.parse('https://den-y.test'))), throwsStateError);
      expect(f.host.tenants, hasLength(2));
      await other.close();
      await otherHub.close();
      await sameFamily.close();
    });
  });

  group('a host whose families aren\'t all open', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('den-host-open'));
    tearDown(() => dir.delete(recursive: true));

    HubLog quiet() => HubLog(level: LogLevel.error, sink: (_) {});

    test("a configured address whose family isn't attached answers 503, never another family's; /health fails only while starting", () async {
      final host = await DenHost.start(
          HostConfig(port: 0, host: InternetAddress.loopbackIPv4, log: quiet(), expected: const ['den-a.test', 'den-b.test']));
      final a = await HostFixture.addFamily(host, 'den-a.test');
      addTearDown(() async {
        await host.stop();
        await a.hubDen.close();
        await a.phone.close();
      });
      Future<ApiResult> at(String method, String path, String? name) =>
          apiCall(host.localUrl, method, path, headers: {'host': ?name});
      for (final (method, path) in [
        ('GET', '/api/v1/hub/status'),
        ('GET', '/ics/denfeed_abcdef/shared.ics'),
        ('GET', '/ics/denfeed_abcdef/watch'),
        ('POST', '/api/v1/link'),
        ('GET', '/health'),
      ]) {
        final r = await at(method, path, 'den-b.test');
        expect(r.status, 503, reason: '$method $path: ${r.text}');
        expect(r.headers['retry-after'], isNotNull);
      }
      final health = await at('GET', '/health', null);
      expect(health.status, 503, reason: 'starting: every family has its first try first');
      expect(health.body['waiting'], 1);
      // A hello naming no family at b's address is closed, never a's.
      final ws = await WebSocket.connect('${host.localUrl.replace(scheme: 'ws', path: '/ws')}', headers: {'host': 'den-b.test'});
      await expectLater(
          Session.connect(IOWebSocketChannel(ws), keys: await DeviceKeys.generate(), familyId: null, timeout: const Duration(seconds: 5)),
          throwsA(isA<SessionException>()));
      expect((await at('GET', '/api/v1/hub/status', 'den-a.test')).status, 200, reason: 'a is open');
      // Every family has had its try: the host is up (a is served), and says one isn't open.
      await host.openConfigured();
      final up = await at('GET', '/health', null);
      expect(up.status, 200, reason: "one family that won't open doesn't hold up the others' --wait");
      expect(up.body['waiting'], 1);
      expect(up.body['ready'], isFalse);
      expect((await at('GET', '/api/v1/hub/status', 'den-b.test')).status, 503, reason: "b's address still waits for b");

      final b = await HostFixture.addFamily(host, 'den-b.test');
      addTearDown(() async {
        await b.hubDen.close();
        await b.phone.close();
      });
      expect((await at('GET', '/api/v1/hub/status', 'den-b.test')).status, 200);
      expect((await at('GET', '/health', null)).status, 200);
    });

    test('a host for one family answers 503 everywhere until that family is attached', () async {
      final host = await DenHost.start(HostConfig(port: 0, host: InternetAddress.loopbackIPv4, log: quiet(), single: true));
      addTearDown(host.stop);
      for (final name in ['den-a.test', null]) {
        expect((await apiCall(host.localUrl, 'GET', '/health', headers: {'host': ?name})).status, 503);
      }
      final a = await HostFixture.addFamily(host, 'den-a.test');
      addTearDown(() async {
        await a.hubDen.close();
        await a.phone.close();
      });
      expect((await apiCall(host.localUrl, 'GET', '/health')).status, 200);
      expect((await apiCall(host.localUrl, 'GET', '/api/v1/hub/status', headers: {'host': 'elsewhere.test'})).status, 200);
    });

    test("a family in host.json that doesn't open is tried again until it does", () async {
      var tries = 0;
      final phone = await createDemoFamily();
      final hubDen = await HubFixture.approvedHub(phone);
      addTearDown(() async {
        await hubDen.close();
        await phone.close();
      });
      Future<HostedTenant> open(HostedLog log) async {
        tries++;
        if (tries < 3) throw StateError('Another den_hub is using it');
        return (den: hubDen, config: HubConfig(mdns: false, publicUrl: log.publicUrl, log: quiet()), close: () async {});
      }

      HostState(dir.path).put(HostedLog(id: 'smith', publicUrl: Uri.parse('https://den-b.test'), added: 1));
      final host = await DenHost.start(HostConfig(
          port: 0, host: InternetAddress.loopbackIPv4, log: quiet(), dataDir: dir.path, openLog: open,
          retryInterval: const Duration(milliseconds: 100)));
      addTearDown(host.stop);
      expect((await apiCall(host.localUrl, 'GET', '/health')).status, 503, reason: 'starting');
      final missing = await host.openConfigured();
      expect(missing.map((l) => l.id), ['smith']);
      expect((await apiCall(host.localUrl, 'GET', '/api/v1/hub/status', headers: {'host': 'den-b.test'})).status, 503);
      // Up, saying how many aren't open; the host's own command line hears which, and why.
      expect((await apiCall(host.localUrl, 'GET', '/health')).body['waiting'], 1);
      final listed = await _admin(host, dir.path, 'GET', '/api/v1/host');
      expect(listed.statusCode, 200);
      final waiting = (jsonDecode(listed.body) as Map)['waiting'] as List;
      expect(waiting.single, containsPair('id', 'smith'));
      expect(waiting.single, containsPair('error', 'Another den_hub is using it'));
      await eventually(() => host.tenants.isNotEmpty);
      expect(tries, 3);
      expect((await apiCall(host.localUrl, 'GET', '/api/v1/hub/status', headers: {'host': 'den-b.test'})).status, 200);
      expect(host.unavailable, isEmpty);
    });
  });

  test('wrong-guess ceilings grow with the families, while each client keeps its own count', () {
    var families = 1;
    final guesses = WrongGuesses(perClient: 2, ceiling: 3, window: const Duration(minutes: 10), scale: () => families);
    for (final c in ['a', 'b', 'c']) {
      guesses.add(c, 1000);
    }
    expect(guesses.wait('d', 1001)?.all, isTrue, reason: 'one family: 3 for everyone');
    families = 2;
    expect(guesses.wait('d', 1001), isNull, reason: 'two families: 6 for everyone');
    guesses
      ..add('d', 1002)
      ..add('d', 1003);
    expect(guesses.wait('d', 1004)?.all, isFalse, reason: "and still 2 for one client");
  });

  test('a host with one family answers at any address, as a hub always has', () async {
    final f = await HubFixture.start(configure: (c) => HubConfig(
          port: 0,
          host: InternetAddress.loopbackIPv4,
          mdns: false,
          log: c.log,
          publicUrl: Uri.parse('https://den-a.test'),
          public: false,
        ));
    addTearDown(f.stop);
    for (final name in ['den-a.test', 'elsewhere.test', '127.0.0.1']) {
      final status = await f.call('GET', '/api/v1/hub/status', headers: {'host': name});
      expect(status.body['device'], f.hubDen.deviceId, reason: name);
    }
  });

  test("anonymous sign-ins naming another family's calendar link as their app never read it in-process", () async {
    final proxy = [IpNetwork.parse('127.0.0.1')];
    final f = await HostFixture.start(
      configure: (c) => HostConfig(
        port: 0,
        host: InternetAddress.loopbackIPv4,
        log: c.log,
        trustedProxies: proxy,
        resolver: (name) async => throw SocketException('no DNS for $name here'),
      ),
      hub: (name, c) => HubConfig(mdns: false, publicUrl: c.publicUrl, log: c.log, public: false, trustedProxies: proxy),
    );
    addTearDown(f.stop);
    final a = f['den-a.test'];
    final b = f['den-b.test'];
    final made = await f.signed(b.phone, 'POST', '/api/v1/feeds', hub: b.hubDen.deviceId, body: {'feed': 'shared', 'label': 'For a'});
    final url = made.body['url']! as String;
    // Strangers start sign-ins at a's address with "apps" whose metadata is at b's calendar
    // links: a's hub looks them up through NetGuard, which finds no DNS here, so none of them
    // is read in-process or spends a's in-process tries.
    for (var ip = 1; ip <= 4; ip++) {
      for (var i = 0; i < 10; i++) {
        final query = {
          'response_type': 'code',
          'client_id': 'https://den-b.test/ics/denfeed_cimd$ip$i/x.ics',
          'redirect_uri': 'http://127.0.0.1:9/cb',
          'code_challenge': 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
          'code_challenge_method': 'S256',
          'state': 's',
        };
        await http.get(f.base.resolve('/oauth/authorize').replace(queryParameters: query),
            headers: {'host': 'den-a.test', 'x-forwarded-for': '198.51.100.$ip'});
      }
    }
    expect((await a.hub.context.feedFetch.get(Uri.parse(url))).statusCode, 200, reason: "a's calendar reads are untouched");
    await expectLater(a.hub.context.fetch.get(Uri.parse(url)), throwsA(isA<SocketException>()), reason: 'metadata documents go through NetGuard');
  });

  group("the host's own command line", () {
    late Directory dir;
    late DenHost host;
    late HostedFamily first;
    final opened = <String, Den>{};
    final deleted = <String>[];
    HubLog quiet() => HubLog(level: LogLevel.error, sink: (_) {});

    Future<HostedTenant> fresh(HostedLog log) async {
      final den = opened[log.id] ??= await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
      return (den: den, config: HubConfig(mdns: false, publicUrl: log.publicUrl, log: quiet()), close: () async {});
    }

    Future<DenHost> startHost() => DenHost.start(HostConfig(
          port: 0,
          host: InternetAddress.loopbackIPv4,
          log: quiet(),
          dataDir: dir.path,
          single: true,
          expected: const ['den-a.test'],
          openLog: fresh,
          createLog: fresh,
          deleteLog: (log) async {
            deleted.add(log.id);
            await opened.remove(log.id)?.close();
          },
        ));

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('den-host-cli');
      opened.clear();
      deleted.clear();
      host = await startHost();
      first = await HostFixture.addFamily(host, 'den-a.test');
      await host.openConfigured();
    });

    tearDown(() async {
      await host.stop();
      await first.hubDen.close();
      await first.phone.close();
      for (final den in opened.values) {
        await den.close();
      }
      await dir.delete(recursive: true);
    });

    Future<int> statusAt(String name) async => (await apiCall(host.localUrl, 'GET', '/api/v1/hub/status', headers: {'host': name})).status;

    test('a host that had another family never answers as one family again: not when it is taken off, deleted, or the host restarts', () async {
      expect(host.single, isTrue);
      expect((await apiCall(host.localUrl, 'GET', '/api/v1/hub/status', headers: {'host': 'elsewhere.test'})).status, 200);
      final added = await _admin(host, dir.path, 'POST', '/api/v1/host/families', body: {'public_url': 'https://den-b.test'});
      expect(added.statusCode, 201, reason: added.body);
      final id = (jsonDecode(added.body) as Map)['id'] as String;
      expect(host.single, isFalse);
      expect((await _admin(host, dir.path, 'DELETE', '/api/v1/host/families/den-b.test')).statusCode, 200);
      expect(host.single, isFalse, reason: 'taken off, its address is still never the first family\'s');
      for (final (method, path) in [('GET', '/api/v1/hub/status'), ('GET', '/ics/denfeed_abcdef/shared.ics'), ('POST', '/api/v1/link')]) {
        final r = await apiCall(host.localUrl, method, path, headers: {'host': 'den-b.test'});
        expect(r.status, 404, reason: '$method $path: ${r.text}');
        expect(r.error['code'], 'no_family');
      }
      final ws = await WebSocket.connect('${host.localUrl.replace(scheme: 'ws', path: '/ws')}', headers: {'host': 'den-b.test'});
      await expectLater(
          Session.connect(IOWebSocketChannel(ws), keys: await DeviceKeys.generate(), familyId: null, timeout: const Duration(seconds: 5)),
          throwsA(isA<SessionException>()),
          reason: "a joiner's hello at b's old address is never the first family's");
      final gone = await _admin(host, dir.path, 'DELETE', '/api/v1/host/families/den-b.test?delete_data=1');
      expect(gone.statusCode, 200, reason: gone.body);
      expect(deleted, [id]);
      expect(HostState(dir.path).all, isEmpty);
      expect(await statusAt('den-b.test'), 404, reason: 'deleted, still never the first family\'s');
      await host.stop();
      host = await startHost();
      await host.add(first.hubDen, HubConfig(mdns: false, publicUrl: Uri.parse('https://den-a.test'), log: quiet()));
      expect(host.single, isFalse, reason: 'host.json remembers');
      expect(await statusAt('den-b.test'), 404);
      expect(await statusAt('den-a.test'), 200);
    });

    test("deleting a family's data happens in the running host, by its id while it is on the host, and frees its address", () async {
      final added = await _admin(host, dir.path, 'POST', '/api/v1/host/families', body: {'public_url': 'https://den-c.test'});
      final id = (jsonDecode(added.body) as Map)['id'] as String;
      final byAddress = await _admin(host, dir.path, 'DELETE', '/api/v1/host/families/den-c.test?delete_data=1');
      expect(byAddress.statusCode, 409, reason: 'a mistyped name never deletes a family in use');
      expect(await statusAt('den-c.test'), 200, reason: 'still served');
      final byId = await _admin(host, dir.path, 'DELETE', '/api/v1/host/families/$id?delete_data=1');
      expect(byId.statusCode, 200, reason: byId.body);
      expect(deleted, [id]);
      expect(HostState(dir.path).all, isEmpty, reason: 'the record is gone from host.json');
      final again = await _admin(host, dir.path, 'POST', '/api/v1/host/families', body: {'public_url': 'https://den-c.test'});
      expect(again.statusCode, 201, reason: 'a new family at the freed address: ${again.body}');
      expect((jsonDecode(again.body) as Map)['id'], isNot(id));
    });

    test('only from this machine, with no proxy in between; a request shelf could not read is a 400, not a 500', () async {
      expect((await _admin(host, dir.path, 'GET', '/api/v1/host')).statusCode, 200);
      for (final header in ['x-forwarded-for', 'forwarded', 'x-real-ip', 'x-forwarded-host', 'x-forwarded-proto', 'x-forwarded-server', 'x-forwarded-port', 'via', 'cf-connecting-ip', 'true-client-ip']) {
        final r = await _admin(host, dir.path, 'GET', '/api/v1/host', headers: {header: header == 'x-forwarded-proto' ? 'https' : '1.2.3.4'});
        // Through a proxy it is from outside, where the gate answers nothing (404); else 403.
        expect(r.statusCode, isIn([403, 404]), reason: header);
      }
      final bad = await http.get(host.localUrl.resolve('/health'), headers: {'x-forwarded-proto': '1.2.3.4'});
      expect(bad.statusCode, 400);
      expect((await http.get(host.localUrl.resolve('/health'))).statusCode, 200, reason: 'and the host serves on');
    });
  });
}

/// A request to [host]'s command-line endpoints, with the secret it left in [dataDir].
Future<http.Response> _admin(DenHost host, String dataDir, String method, String path,
    {Object? body, Map<String, String> headers = const {}}) async {
  final secret = File('$dataDir/$hostStateDir/$hostCliFile').readAsStringSync().trim();
  final request = http.Request(method, host.localUrl.resolve(path))
    ..headers[DenHost.secretHeader] = secret
    ..headers.addAll(headers);
  if (body != null) {
    request.headers['content-type'] = 'application/json';
    request.body = jsonEncode(body);
  }
  return http.Response.fromStream(await request.send());
}
