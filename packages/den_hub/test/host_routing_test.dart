@Timeout(Duration(seconds: 120))
library;

import 'dart:async';
import 'dart:io';

import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';
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
    final one = TenantRouter(() => [a]);

    test('by address: its family; with one family, that one at any address; with several, none at a stranger\'s', () {
      expect(two.forHostname('den-a.test'), a);
      expect(two.forHostname('den-b.test'), b);
      expect(two.forHostname('127.0.0.1'), isNull, reason: 'fail closed, never the first one');
      expect(two.forHostname(null), isNull);
      expect(one.forHostname('127.0.0.1'), a, reason: 'a hub with one family answers as it always did');
      expect(one.forHostname(null), a);
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
        configure: (c) => HostConfig(port: 0, host: InternetAddress.loopbackIPv4, log: c.log, webDir: web.path),
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

    test('a signed request goes to the hub it names; without the name, to its address\'s family or the one that knows the device', () async {
      final a = f['den-a.test'];
      Future<ApiResult> feeds({String? hostname, bool sendHub = true}) =>
          f.signed(a.phone, 'GET', '/api/v1/feeds', hub: a.hubDen.deviceId, hostname: hostname, sendHub: sendHub);
      expect((await feeds(hostname: 'den-b.test')).status, 200, reason: 'X-Den-Hub decides');
      expect((await feeds()).status, 200);
      expect((await feeds(hostname: 'den-a.test', sendHub: false)).status, 200, reason: 'an older app at its own address');
      expect((await feeds(sendHub: false)).status, 200, reason: 'an older app at an address that is no family\'s: the one family that knows it');
      expect((await feeds(hostname: 'den-b.test', sendHub: false)).status, 401, reason: "b's address is b's: a's device isn't one of b's");
    });

    test('families come and go while the host runs; two can never share a hub, a family or an address', () async {
      final c = await HostFixture.addFamily(f.host, 'den-c.test');
      expect((await f.call('GET', '/api/v1/hub/status', hostname: 'den-c.test')).status, 200);
      expect(f.host.tenants, hasLength(3));
      await f.host.remove(c.hub);
      expect((await f.call('GET', '/api/v1/hub/status', hostname: 'den-c.test')).error['code'], 'no_family');
      await c.hubDen.close();
      await c.phone.close();

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
}
