import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:den_relay/den_relay.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

late Directory tmp;

Future<RelayServer> startRelay(RelayConfig config) =>
    RelayServer.start(config.copyWith(dataDir: tmp.path), address: InternetAddress.loopbackIPv4, port: 0);

Uri httpBase(RelayServer relay) => Uri.parse('http://127.0.0.1:${relay.port}');
Uri wsUri(RelayServer relay, String path) => Uri.parse('ws://127.0.0.1:${relay.port}$path');
String mailbox(int n) => n.toRadixString(16).padLeft(64, 'a');

void main() {
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('den_relay_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('health', () async {
    final relay = await startRelay(const RelayConfig());
    addTearDown(relay.close);
    final response = await http.get(httpBase(relay).replace(path: '/health'));
    expect(response.statusCode, 200);
    expect(jsonDecode(response.body), {'ok': true, 'version': relayVersion});
    expect((await http.get(httpBase(relay).replace(path: '/nothing/here'))).statusCode, 404);
  });

  group('tunnel', () {
    late RelayServer relay;
    late DeviceKeys hubKeys;
    late DeviceKeys forger;
    late String hubId;

    setUp(() async {
      relay = await startRelay(const RelayConfig());
      hubKeys = await DeviceKeys.generate();
      forger = await DeviceKeys.generate();
      hubId = await hubKeys.deviceId();
    });

    tearDown(() => relay.close());

    Future<int?> tryAuth(String pubkey, Future<String> Function(String nonce) sign) async {
      final ws = WebSocketChannel.connect(wsUri(relay, '/tunnel/$hubId'));
      await ws.ready;
      final queue = StreamQueue<dynamic>(ws.stream);
      final challenge = jsonDecode(await queue.next as String) as Map;
      expect(challenge['t'], 'challenge');
      ws.sink.add(jsonEncode({'t': 'auth', 'pubkey': pubkey, 'sig': await sign(challenge['nonce'] as String)}));
      final rest = await queue.rest.toList().timeout(const Duration(seconds: 5));
      if (rest.isNotEmpty && rest.first == '{"t":"ready"}') return null;
      return ws.closeCode;
    }

    test('rejects a hub that cannot sign for the id', () async {
      // The forger's own key hashes to another id.
      expect(
        await tryAuth(forger.pubkey, (nonce) => forger.sign(tunnelAuthBytes(hubId, nonce))),
        RelayClose.unauthorized,
      );
      // The real key with the forger's signature.
      expect(
        await tryAuth(hubKeys.pubkey, (nonce) => forger.sign(tunnelAuthBytes(hubId, nonce))),
        RelayClose.unauthorized,
      );
      // A signature over a different challenge.
      expect(
        await tryAuth(hubKeys.pubkey, (_) => hubKeys.sign(tunnelAuthBytes(hubId, 'old-nonce'))),
        RelayClose.unauthorized,
      );
      expect(relay.tunnels.has(hubId), isFalse);
      final refused = await http.get(httpBase(relay).replace(path: '/connect/$hubId'));
      expect(refused.statusCode, 404);
    });

    test('pipes clients to the hub with the session handshake end to end', () async {
      final tunnel = RelayTunnel(
        relay: httpBase(relay),
        keys: hubKeys,
        onClient: (channel) async {
          final session = await Session.accept(channel, keys: hubKeys, familyId: 'fam');
          session.messages.listen((m) => session.send({'echo': m, 'from': 'hub'}));
        },
      );
      tunnel.start();
      addTearDown(tunnel.stop);
      await tunnel.whenOnline();
      expect(relay.tunnels.has(hubId), isTrue);

      Future<void> oneClient(int n) async {
        final device = await DeviceKeys.generate();
        final channel = await connectWebSocket(relayConnectUri(httpBase(relay), hubId));
        final session = await Session.connect(channel, keys: device, familyId: 'fam', expectDevice: hubId);
        expect(session.peerDevice, hubId);
        final replies = StreamQueue(session.messages);
        for (var i = 0; i < 3; i++) {
          await session.send({'n': n, 'i': i, 'pad': 'x' * (n * 1000)});
          final reply = await replies.next;
          expect(reply['from'], 'hub');
          expect((reply['echo'] as Map)['i'], i);
        }
        await session.close();
      }

      await Future.wait([for (var n = 0; n < 5; n++) oneClient(n)]);
      await eventuallyTrue(() => tunnel.openStreams == 0);
    });

    test('a client cannot reach a hub with no tunnel', () async {
      await expectLater(connectWebSocket(relayConnectUri(httpBase(relay), hubId)), throwsA(anything));
    });

    test('a newer authenticated tunnel replaces the old one', () async {
      final first = RelayTunnel(relay: httpBase(relay), keys: hubKeys, onClient: (_) {});
      first.start();
      await first.whenOnline();
      final second = RelayTunnel(relay: httpBase(relay), keys: hubKeys, onClient: (_) {}, minBackoff: const Duration(minutes: 5));
      second.start();
      await second.whenOnline();
      await eventuallyTrue(() => first.status.state != TunnelState.online);
      expect(relay.tunnels.count, 1);
      await first.stop();
      await second.stop();
    });
  });

  group('mailbox', () {
    test('append, read with cursors and pages, and survive a restart', () async {
      var relay = await startRelay(const RelayConfig(readPageEntries: 2));
      final client = RelayMailbox(httpBase(relay));
      final id = mailbox(1);
      final cursors = <int>[];
      for (var i = 0; i < 3; i++) {
        cursors.add(await client.append(id, utf8.encode('blob $i')));
      }
      expect(cursors[1], greaterThan(cursors[0]));
      expect(cursors[2], greaterThan(cursors[1]));

      final page1 = await client.read(id);
      expect(page1.entries.map((e) => utf8.decode(e.blob)), ['blob 0', 'blob 1']);
      expect(page1.more, isTrue);
      final page2 = await client.read(id, after: page1.next);
      expect(page2.entries.map((e) => utf8.decode(e.blob)), ['blob 2']);
      expect(page2.more, isFalse);
      expect((await client.read(id, after: page2.next)).entries, isEmpty);
      expect((await client.read(id, after: cursors[0], limit: 1)).entries.single.cursor, cursors[1]);
      expect((await client.read(mailbox(2))).entries, isEmpty);
      client.close();
      await relay.close();

      relay = await startRelay(const RelayConfig());
      addTearDown(relay.close);
      final again = RelayMailbox(httpBase(relay));
      final all = await again.read(id);
      expect(all.entries.map((e) => e.cursor), cursors);
      final next = await again.append(id, [42]);
      expect(next, greaterThan(cursors.last));
      again.close();
    });

    test('blobs expire after the TTL and sweeps remove them', () async {
      var now = DateTime.utc(2026, 10, 1).millisecondsSinceEpoch;
      final relay = await startRelay(RelayConfig(now: () => now));
      addTearDown(relay.close);
      final client = RelayMailbox(httpBase(relay));
      addTearDown(client.close);
      final old = mailbox(3);
      final mixed = mailbox(4);
      final oldCursor = await client.append(old, [1]);
      await client.append(mixed, [2]);
      now += const Duration(days: 20).inMilliseconds;
      await client.append(mixed, [3]);
      now += const Duration(days: 11).inMilliseconds;

      expect((await client.read(old)).entries, isEmpty, reason: 'expired blobs are hidden before the sweep');
      expect(await relay.mailboxes.sweep(), 2);
      expect(relay.mailboxes.mailboxCount, 1);
      expect((await client.read(mixed)).entries.map((e) => e.blob), [
        [3],
      ]);
      // Cursors keep increasing even for a mailbox that expired completely.
      expect(await client.append(old, [4]), greaterThan(oldCursor));
    });

    test('caps: blob size, entries and bytes per mailbox, number of mailboxes', () async {
      final relay = await startRelay(const RelayConfig(
        maxBlobBytes: 100,
        maxMailboxEntries: 2,
        maxMailboxBytes: 150,
        maxMailboxes: 2,
      ));
      addTearDown(relay.close);
      final client = RelayMailbox(httpBase(relay));
      addTearDown(client.close);
      Future<int> post(String id, int size) async =>
          (await http.post(httpBase(relay).replace(path: '/mailbox/$id'), body: List.filled(size, 1))).statusCode;

      expect(await post(mailbox(1), 101), 413);
      expect(await post(mailbox(1), 0), 400);
      expect(await post(mailbox(1), 100), 200);
      expect(await post(mailbox(1), 60), 507, reason: 'byte cap');
      expect(await post(mailbox(1), 10), 200);
      expect(await post(mailbox(1), 10), 507, reason: 'entry cap');
      expect(await post(mailbox(2), 10), 200);
      expect(await post(mailbox(3), 10), 507, reason: 'mailbox cap');
      expect(await post('not-a-mailbox-id', 10), 400);
      expect((await http.get(httpBase(relay).replace(path: '/mailbox/${mailbox(1)}', query: 'after=-1'))).statusCode, 400);
    });
  });

  group('rate limits', () {
    test('per client address', () async {
      final relay = await startRelay(const RelayConfig(ipRate: RateSpec(capacity: 3, perSecond: 0.01)));
      addTearDown(relay.close);
      final uri = httpBase(relay).replace(path: '/mailbox/${mailbox(1)}');
      for (var i = 0; i < 3; i++) {
        expect((await http.get(uri)).statusCode, 200);
      }
      final limited = await http.get(uri);
      expect(limited.statusCode, 429);
      expect(int.parse(limited.headers['retry-after']!), greaterThan(0));
      // The health check stays reachable for container orchestration.
      expect((await http.get(httpBase(relay).replace(path: '/health'))).statusCode, 200);
    });

    test('X-Forwarded-For is honored only with --trust-proxy', () async {
      const config = RelayConfig(ipRate: RateSpec(capacity: 1, perSecond: 0.01));
      final plain = await startRelay(config);
      final uri = httpBase(plain).replace(path: '/mailbox/${mailbox(1)}');
      expect((await http.get(uri, headers: {'x-forwarded-for': '10.0.0.1'})).statusCode, 200);
      expect((await http.get(uri, headers: {'x-forwarded-for': '10.0.0.2'})).statusCode, 429);
      await plain.close();

      final proxied = await startRelay(config.copyWith(trustProxy: true));
      addTearDown(proxied.close);
      final uri2 = httpBase(proxied).replace(path: '/mailbox/${mailbox(1)}');
      expect((await http.get(uri2, headers: {'x-forwarded-for': 'spoofed, 10.0.0.1'})).statusCode, 200);
      expect((await http.get(uri2, headers: {'x-forwarded-for': 'spoofed, 10.0.0.2'})).statusCode, 200);
      expect((await http.get(uri2, headers: {'x-forwarded-for': 'other, 10.0.0.1'})).statusCode, 429);
    });

    test('per mailbox', () async {
      final relay = await startRelay(const RelayConfig(mailboxWriteRate: RateSpec(capacity: 2, perSecond: 0.01)));
      addTearDown(relay.close);
      final client = RelayMailbox(httpBase(relay));
      addTearDown(client.close);
      await client.append(mailbox(1), [1]);
      await client.append(mailbox(1), [2]);
      await expectLater(
        client.append(mailbox(1), [3]),
        throwsA(isA<RelayException>().having((e) => e.status, 'status', 429)),
      );
      expect(await client.append(mailbox(2), [1]), greaterThan(0), reason: 'other mailboxes are unaffected');
    });

    test('unit: token bucket refills', () {
      var now = 0;
      final bucket = TokenBucket(const RateSpec(capacity: 2, perSecond: 1), now);
      expect(bucket.take(now), isTrue);
      expect(bucket.take(now), isTrue);
      expect(bucket.take(now), isFalse);
      expect(bucket.retryAfterSeconds(now), 1);
      now += 1000;
      expect(bucket.take(now), isTrue);
      expect(bucket.take(now), isFalse);
      now += 10000;
      expect(bucket.isFull(now), isTrue);
    });
  });

  group('per-client shares', () {
    test('clients are IPv4 addresses, or the /64 an IPv6 address is in', () {
      expect(clientKeyOf('203.0.113.7'), '203.0.113.7');
      expect(clientKeyOf('2001:db8:1:2::1'), '2001:db8:1:2::/64');
      expect(clientKeyOf('2001:db8:1:2:ffff:ffff:ffff:ffff'), '2001:db8:1:2::/64');
      expect(clientKeyOf('2001:db8:1:3::1'), '2001:db8:1:3::/64');
      expect(clientKeyOf('::ffff:203.0.113.7'), '203.0.113.7');
      expect(clientKeyOf('unknown'), 'unknown');
    });

    test('the rate limit counts a whole IPv6 /64 as one client', () async {
      final relay = await startRelay(const RelayConfig(trustProxy: true, ipRate: RateSpec(capacity: 1, perSecond: 0.01)));
      addTearDown(relay.close);
      final uri = httpBase(relay).replace(path: '/mailbox/${mailbox(1)}');
      Future<int> from(String address) async => (await http.get(uri, headers: {'x-forwarded-for': address})).statusCode;
      expect(await from('2001:db8:5:6::1'), 200);
      expect(await from('2001:db8:5:6::2'), 429, reason: 'the same /64');
      expect(await from('2001:db8:5:7::1'), 200);
    });

    test('one client can fill only its share of mailbox bytes and mailboxes', () async {
      final relay = await startRelay(const RelayConfig(trustProxy: true, maxClientBytes: 150, maxClientMailboxes: 2));
      addTearDown(relay.close);
      Future<http.Response> post(String address, String id, int size) => http.post(
            httpBase(relay).replace(path: '/mailbox/$id'),
            headers: {'x-forwarded-for': address},
            body: List.filled(size, 1),
          );
      expect((await post('2001:db8:1:2::1', mailbox(1), 100)).statusCode, 200);
      final over = await post('2001:db8:1:2::99', mailbox(1), 60);
      expect(over.statusCode, 507);
      expect(jsonDecode(over.body), containsPair('cap', 'client'));
      expect((await post('2001:db8:1:3::1', mailbox(1), 60)).statusCode, 200, reason: 'another client still can');
      expect((await post('2001:db8:1:2::1', mailbox(2), 10)).statusCode, 200);
      expect((await post('2001:db8:1:2::1', mailbox(3), 10)).statusCode, 507, reason: 'two mailboxes each');
      expect((await post('2001:db8:1:3::1', mailbox(3), 10)).statusCode, 200);
      expect(relay.mailboxes.bytesOf('2001:db8:1:2::/64'), 110);
      expect(relay.mailboxes.mailboxesOf('2001:db8:1:2::/64'), 2);
    });

    test('expired blobs give a client its share back', () async {
      var now = DateTime.utc(2026, 10, 1).millisecondsSinceEpoch;
      final relay = await startRelay(RelayConfig(now: () => now, maxClientBytes: 100, maxClientMailboxes: 1));
      addTearDown(relay.close);
      final client = RelayMailbox(httpBase(relay));
      addTearDown(client.close);
      await client.append(mailbox(1), List.filled(100, 1));
      await expectLater(client.append(mailbox(2), [1]), throwsA(isA<RelayException>().having((e) => e.status, 'status', 507)));
      now += const Duration(days: 31).inMilliseconds;
      await relay.mailboxes.sweep();
      expect(relay.mailboxes.bytesOf('127.0.0.1'), 0);
      expect(await client.append(mailbox(2), List.filled(100, 1)), greaterThan(0));
    });

    test('one client can hold only its share of tunnels, a tunnel\'s streams, and rendezvous slots', () async {
      final relay = await startRelay(const RelayConfig(maxTunnelsPerClient: 1, maxStreamsPerClient: 2, maxSlotsPerClient: 1));
      addTearDown(relay.close);
      final hubKeys = await DeviceKeys.generate();
      final hubId = await hubKeys.deviceId();
      final tunnel = RelayTunnel(relay: httpBase(relay), keys: hubKeys, onClient: (_) {});
      tunnel.start();
      addTearDown(tunnel.stop);
      await tunnel.whenOnline();
      final other = await (await DeviceKeys.generate()).deviceId();
      expect((await http.get(httpBase(relay).replace(path: '/tunnel/$other'))).statusCode, 503);

      final streams = [
        for (var i = 0; i < 2; i++) await connectWebSocket(relayConnectUri(httpBase(relay), hubId)),
      ];
      await eventuallyTrue(() => tunnel.openStreams == 2);
      expect((await http.get(httpBase(relay).replace(path: '/connect/$hubId'))).statusCode, 503);
      await streams.first.sink.close();
      await eventuallyTrue(() => relay.tunnels.canConnect(hubId, client: '127.0.0.1'));
      for (final s in streams.skip(1)) {
        await s.sink.close();
      }

      final waiting = rendezvous(httpBase(relay), 'ab' * 32, host: true, timeout: const Duration(seconds: 5));
      unawaited(waiting.then((_) {}, onError: (Object _) {}));
      await eventuallyTrue(() => relay.slots.hasHost('ab' * 32));
      final second = await http.get(httpBase(relay).replace(path: '/rendezvous/${'cd' * 32}', query: 'role=host'));
      expect(second.statusCode, 503);
    });
  });

  group('rendezvous', () {
    test('pairs a host and a guest and pipes a session between them', () async {
      final relay = await startRelay(const RelayConfig());
      addTearDown(relay.close);
      final hostKeys = await DeviceKeys.generate();
      final guestKeys = await DeviceKeys.generate();
      final slot = await codeRendezvousSlot('zoo zone zero zebra');

      final hostChannel = rendezvous(httpBase(relay), slot, host: true);
      await eventuallyTrue(() => relay.slots.hasHost(slot));
      final guestChannel = await rendezvous(httpBase(relay), slot, host: false);
      final serverSession = Session.accept(await hostChannel, keys: hostKeys);
      final client = await Session.connect(guestChannel, keys: guestKeys);
      final server = await serverSession;
      expect(client.matchingWords, server.matchingWords);
      final got = server.messages.first;
      await client.send({'t': 'pair'});
      expect(await got, {'t': 'pair'});
      expect(relay.slots.hasHost(slot), isFalse, reason: 'slots are one-shot');
    });

    test('a guest with no host is refused; a second host is refused', () async {
      final relay = await startRelay(const RelayConfig());
      addTearDown(relay.close);
      final slot = 'ab' * 32;
      await expectLater(rendezvous(httpBase(relay), slot, host: false), throwsA(isA<RelayException>()));
      final waiting = rendezvous(httpBase(relay), slot, host: true, timeout: const Duration(seconds: 5));
      unawaited(waiting.then((_) {}, onError: (Object _) {}));
      await eventuallyTrue(() => relay.slots.hasHost(slot));
      final second = await http.get(httpBase(relay).replace(path: '/rendezvous/$slot', query: 'role=host'));
      expect(second.statusCode, 409);
    });

    test('a message over the limit closes the connection before the relay buffers it', () async {
      final relay = await startRelay(const RelayConfig(maxMessageBytes: 1000));
      addTearDown(relay.close);
      final slot = 'ef' * 32;
      final host = await connectWebSocket(relayRendezvousUri(httpBase(relay), slot, host: true));
      await eventuallyTrue(() => relay.slots.hasHost(slot));
      var closed = false;
      final ended = host.stream.drain<void>().then((_) => closed = true, onError: (Object _) => closed = true);
      host.sink.add(List.filled(5000, 1));
      await ended.timeout(const Duration(seconds: 5), onTimeout: () => false);
      expect(closed, isTrue, reason: 'the relay closed the connection');
    });

    test('a waiting host is closed when the slot expires', () async {
      final relay = await startRelay(const RelayConfig(slotTtl: Duration(milliseconds: 300)));
      addTearDown(relay.close);
      final slot = 'cd' * 32;
      await expectLater(
        rendezvous(httpBase(relay), slot, host: true, timeout: const Duration(seconds: 5)),
        throwsA(isA<RelayException>()),
      );
      expect(relay.slots.hasHost(slot), isFalse);
    });
  });
}

Future<void> eventuallyTrue(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
