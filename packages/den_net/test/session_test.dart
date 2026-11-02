import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'support/channels.dart';

Future<({Session client, Session server})> establish(
  StreamChannel<dynamic> clientEnd,
  StreamChannel<dynamic> serverEnd,
  DeviceKeys clientKeys,
  DeviceKeys serverKeys, {
  String? family = 'fam',
  String? serverFamily = 'fam',
  String? expectDevice,
  String? expectPubkey,
}) async {
  final server = Session.accept(serverEnd, keys: serverKeys, familyId: serverFamily);
  final client = Session.connect(
    clientEnd,
    keys: clientKeys,
    familyId: family,
    expectDevice: expectDevice,
    expectPubkey: expectPubkey,
  );
  return (client: await client, server: await server);
}

Map<String, Object?> decodeJson(Object? m) =>
    Map<String, Object?>.from(jsonDecode(m is String ? m : utf8.decode(m! as List<int>)) as Map);

String encodeJson(Map<String, Object?> m) => jsonEncode(m);

void main() {
  late DeviceKeys alice;
  late DeviceKeys hub;
  late DeviceKeys mallory;

  setUpAll(() async {
    alice = await DeviceKeys.generate();
    hub = await DeviceKeys.generate();
    mallory = await DeviceKeys.generate();
  });

  group('handshake', () {
    test('both sides learn each other\'s verified identity and the same transcript', () async {
      final tap = Tap<dynamic>();
      final s = await establish(tap.client, tap.server, alice, hub);
      expect(s.client.peerDevice, await hub.deviceId());
      expect(s.client.peerPubkey, hub.pubkey);
      expect(s.server.peerDevice, await alice.deviceId());
      expect(s.server.peerPubkey, alice.pubkey);
      expect(s.server.peerFamily, 'fam');
      expect(s.client.isClient, isTrue);
      expect(s.server.isClient, isFalse);
      expect(s.client.transcriptHash, s.server.transcriptHash);
      expect(s.client.matchingWords, hasLength(3));
      expect(s.client.matchingWords, s.server.matchingWords);
      for (final w in s.client.matchingWords) {
        expect(wordList, contains(w));
      }

      final fromClient = s.server.messages.first;
      await s.client.send({'t': 'hi', 'n': 1});
      expect(await fromClient, {'t': 'hi', 'n': 1});
      final fromServer = s.client.messages.take(2).toList();
      await s.server.send({'t': 'a'});
      await s.server.send({'t': 'b'});
      expect(await fromServer, [
        {'t': 'a'},
        {'t': 'b'},
      ]);
      await s.client.close();
      await s.server.done;
      expect(s.server.isClosed, isTrue);
      expect(s.server.error, isNull);
    });

    test('works over text-only and bytes-only channels', () async {
      final text = pipe<String>();
      final t = await establish(text.a, text.b, alice, hub);
      final gotText = t.server.messages.first;
      await t.client.send({'x': 'over text'});
      expect(await gotText, {'x': 'over text'});

      final bytes = pipe<List<int>>();
      final b = await establish(bytes.a, bytes.b, alice, hub);
      final gotBytes = b.client.messages.first;
      await b.server.send({'x': 'over bytes'});
      expect(await gotBytes, {'x': 'over bytes'});
    });

    test('ephemeral keys differ per session, so transcripts and words differ', () async {
      final one = pipe<dynamic>();
      final two = pipe<dynamic>();
      final a = await establish(one.a, one.b, alice, hub);
      final b = await establish(two.a, two.b, alice, hub);
      expect(a.client.transcriptHash, isNot(b.client.transcriptHash));
    });

    test('a pinned client accepts the expected server', () async {
      final p = pipe<dynamic>();
      final s = await establish(p.a, p.b, alice, hub, expectDevice: await hub.deviceId(), expectPubkey: hub.pubkey);
      expect(s.client.pinned, isTrue);
    });

    test('a pinned client rejects any other server', () async {
      final p = pipe<dynamic>();
      final server = Session.accept(p.b, keys: mallory, familyId: 'fam');
      unawaited(server.then((_) {}, onError: (Object _) {}));
      await expectLater(
        Session.connect(p.a, keys: alice, familyId: 'fam', expectDevice: await hub.deviceId()),
        throwsA(isA<SessionException>().having((e) => e.message, 'message', contains('unexpected server'))),
      );
    });

    test('a server in another family is rejected', () async {
      final p = pipe<dynamic>();
      unawaited(Session.accept(p.b, keys: hub, familyId: 'other').then((_) {}, onError: (Object _) {}));
      await expectLater(
        Session.connect(p.a, keys: alice, familyId: 'fam'),
        throwsA(isA<SessionException>()),
      );
    });

    test('the server can refuse a client before revealing anything else', () async {
      final p = pipe<dynamic>();
      final server = Session.accept(p.b, keys: hub, familyId: 'fam', admit: (hello) => hello.family == 'nope');
      final client = Session.connect(p.a, keys: alice, familyId: 'fam', timeout: const Duration(seconds: 5));
      await expectLater(server, throwsA(isA<SessionException>().having((e) => e.message, 'message', 'client refused')));
      await expectLater(
        client,
        throwsA(isA<SessionException>().having((e) => e.message, 'message', contains('closed during handshake'))),
      );
    });

    test('a silent server times out', () async {
      final p = pipe<dynamic>();
      p.b.stream.listen((_) {});
      await expectLater(
        Session.connect(p.a, keys: alice, timeout: const Duration(milliseconds: 200)),
        throwsA(isA<SessionException>().having((e) => e.message, 'message', contains('timed out'))),
      );
    });
  });

  group('wrong signatures and identities', () {
    test('a server hello signed by another key is rejected', () async {
      final forged = await mallory.sign([1, 2, 3]);
      final tap = Tap<dynamic>(toClient: (i, m) {
        if (i != 0) return [m];
        final hello = decodeJson(m)..['sig'] = forged;
        return [encodeJson(hello)];
      });
      unawaited(Session.accept(tap.server, keys: hub, familyId: 'fam').then((_) {}, onError: (Object _) {}));
      await expectLater(
        Session.connect(tap.client, keys: alice, familyId: 'fam'),
        throwsA(isA<SessionException>().having((e) => e.message, 'message', 'bad server signature')),
      );
    });

    test('a client auth signed by another key is rejected', () async {
      final tap = Tap<dynamic>(toServer: (i, m) {
        if (i != 1) return [m];
        return [encodeJson({'t': 'auth', 'sig': b64e(List.filled(64, 7))})];
      });
      final server = Session.accept(tap.server, keys: hub, familyId: 'fam');
      unawaited(Session.connect(tap.client, keys: alice, familyId: 'fam').then((_) {}, onError: (Object _) {}));
      await expectLater(
        server,
        throwsA(isA<SessionException>().having((e) => e.message, 'message', 'bad client signature')),
      );
    });

    test('a hello whose device id does not match its key is rejected', () async {
      final otherId = await mallory.deviceId();
      final tap = Tap<dynamic>(toClient: (i, m) {
        if (i != 0) return [m];
        return [encodeJson(decodeJson(m)..['device'] = otherId)];
      });
      unawaited(Session.accept(tap.server, keys: hub, familyId: 'fam').then((_) {}, onError: (Object _) {}));
      await expectLater(
        Session.connect(tap.client, keys: alice, familyId: 'fam'),
        throwsA(isA<SessionException>().having((e) => e.message, 'message', contains('does not match'))),
      );
    });

    test('a client claiming another device\'s key cannot complete the handshake', () async {
      // Mallory presents Alice's public key and id but holds only her own private key.
      final p = pipe<dynamic>();
      final server = Session.accept(p.b, keys: hub, familyId: 'fam');
      final impostorHello = {
        't': 'hello',
        'v': 1,
        'family': 'fam',
        'device': await alice.deviceId(),
        'pubkey': alice.pubkey,
        'eph': b64e(List.filled(32, 9)),
      };
      final replies = StreamIterator(p.a.stream);
      p.a.sink.add(jsonEncode(impostorHello));
      expect(await replies.moveNext(), isTrue);
      p.a.sink.add(jsonEncode({'t': 'auth', 'sig': await mallory.sign([0])}));
      await expectLater(server, throwsA(isA<SessionException>()));
    });

    test('a relay that swaps the ephemeral keys breaks the signatures', () async {
      final relayEph = b64e(List.generate(32, (i) => i + 1));
      final tap = Tap<dynamic>(
        toServer: (i, m) => i == 0 ? [encodeJson(decodeJson(m)..['eph'] = relayEph)] : [m],
        toClient: (i, m) => i == 0 ? [encodeJson(decodeJson(m)..['eph'] = relayEph)] : [m],
      );
      unawaited(Session.accept(tap.server, keys: hub, familyId: 'fam').then((_) {}, onError: (Object _) {}));
      await expectLater(
        Session.connect(tap.client, keys: alice, familyId: 'fam'),
        throwsA(isA<SessionException>().having((e) => e.message, 'message', 'bad server signature')),
      );
    });
  });

  group('frames', () {
    Future<void> expectServerRejects(Tamper toServer, String reason) async {
      final tap = Tap<dynamic>(toServer: toServer);
      final s = await establish(tap.client, tap.server, alice, hub);
      final errors = <Object>[];
      final received = <Map<String, Object?>>[];
      s.server.messages.listen(received.add, onError: errors.add);
      for (var i = 1; i <= 3; i++) {
        await s.client.send({'n': i});
      }
      await s.server.done.timeout(const Duration(seconds: 5));
      expect(s.server.isClosed, isTrue);
      expect(s.server.error?.message, contains(reason));
      expect(errors.single, isA<SessionException>());
      expect(received.length, lessThan(3));
    }

    // Client messages: 0 hello, 1 auth, 2.. frames.
    test('a tampered frame closes the session', () async {
      await expectServerRejects((i, m) {
        if (i != 3) return [m];
        final bytes = Uint8List.fromList(m! as List<int>);
        bytes[bytes.length - 20] ^= 0x01;
        return [bytes];
      }, 'authentication');
    });

    test('a tampered counter closes the session', () async {
      await expectServerRejects((i, m) {
        if (i != 2) return [m];
        final bytes = Uint8List.fromList(m! as List<int>);
        bytes[7] ^= 0x02;
        return [bytes];
      }, 'out of order');
    });

    test('a replayed frame closes the session', () async {
      await expectServerRejects((i, m) => i == 2 ? [m, m] : [m], 'replayed');
    });

    test('reordered frames close the session', () async {
      Object? held;
      await expectServerRejects((i, m) {
        if (i == 2) {
          held = m;
          return [];
        }
        if (i == 3) return [m, held];
        return [m];
      }, 'out of order');
    });

    test('a dropped frame closes the session at the next one', () async {
      await expectServerRejects((i, m) => i == 2 ? [] : [m], 'out of order');
    });

    test('a frame from the other direction is rejected', () async {
      // Reflect the server's first frame back at it: wrong direction byte in the nonce.
      final reflect = StreamController<Object?>();
      final tap = Tap<dynamic>(toClient: (i, m) {
        if (i == 1) reflect.add(m);
        return [m];
      });
      final s = await establish(tap.client, tap.server, alice, hub);
      final errors = <Object>[];
      s.server.messages.listen((_) {}, onError: errors.add);
      await s.server.send({'n': 1});
      final frame = await reflect.stream.first;
      tap.client.sink.add(frame);
      await s.server.done.timeout(const Duration(seconds: 5));
      expect(s.server.error?.message, contains('authentication'));
    });

    test('messages over the size limit are refused on send', () async {
      final p = pipe<dynamic>();
      final s = await establish(p.a, p.b, alice, hub);
      await expectLater(
        s.client.send({'big': 'x' * (maxSessionMessageBytes + 1)}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('relay in the middle', () {
    test('a relay running its own sessions shows different words on each side', () async {
      // The relay terminates the client's session with its own identity and opens its own
      // session to the real server, forwarding plaintext. Unpinned (spoken-code) handshakes both
      // succeed, but the transcripts differ, so the matching words do too.
      final left = pipe<dynamic>();
      final right = pipe<dynamic>();
      final relayAsServer = Session.accept(left.b, keys: mallory, familyId: null);
      final clientFuture = Session.connect(left.a, keys: alice, familyId: null);
      final serverFuture = Session.accept(right.b, keys: hub, familyId: 'fam');
      final relayAsClient = Session.connect(right.a, keys: mallory, familyId: null);
      final client = await clientFuture;
      final server = await serverFuture;
      final m1 = await relayAsServer;
      final m2 = await relayAsClient;
      m1.messages.listen(m2.send);
      m2.messages.listen(m1.send);

      final got = server.messages.first;
      await client.send({'t': 'pair'});
      expect(await got, {'t': 'pair'});
      expect(client.matchingWords, isNot(server.matchingWords));
      expect(client.peerDevice, isNot(await hub.deviceId()));
    });

    test('a pinned client cannot be fooled by a relay with its own identity', () async {
      final left = pipe<dynamic>();
      unawaited(Session.accept(left.b, keys: mallory, familyId: 'fam').then((_) {}, onError: (Object _) {}));
      await expectLater(
        Session.connect(left.a, keys: alice, familyId: 'fam', expectPubkey: hub.pubkey),
        throwsA(isA<SessionException>()),
      );
    });
  });

  group('peeking at the hello (a host holding several logs)', () {
    test('says which family the client names, and the session starts as if nobody had looked', () async {
      final link = pipe<dynamic>();
      final client = Session.connect(link.a, keys: alice, familyId: 'fam-b');
      final peeked = await peekHello(link.b);
      expect(peeked, isNotNull);
      expect(peeked!.family, 'fam-b');
      final server = await Session.accept(peeked.channel, keys: hub, familyId: 'fam-b');
      final c = await client;
      expect(c.transcriptHash, server.transcriptHash);
      expect(server.peerFamily, 'fam-b');
      final got = server.messages.first;
      await c.send({'t': 'ping'});
      expect(await got, {'t': 'ping'});
      final back = c.messages.first;
      await server.send({'t': 'pong'});
      expect(await back, {'t': 'pong'});
    });

    test('a hello that names no family peeks as null, and bytes channels keep their kind', () async {
      final link = pipe<List<int>>();
      final client = Session.connect(link.a, keys: alice, familyId: null);
      final peeked = await peekHello(link.b);
      expect(peeked!.family, isNull);
      expect(peeked.channel, isA<StreamChannel<List<int>>>());
      final server = await Session.accept(peeked.channel, keys: hub, familyId: 'fam');
      expect((await client).peerFamily, 'fam');
      expect(server.peerFamily, isNull);
    });

    test('anything but a hello closes the channel, and so does silence', () async {
      for (final first in <Object>[
        'not json',
        encodeJson({'t': 'auth', 'sig': 'x'}),
        encodeJson({'t': 'hello', 'family': 7}),
        '[1, 2]',
        'x' * (maxHandshakeBytes + 1),
      ]) {
        final link = pipe<dynamic>();
        final closed = link.a.stream.toList();
        link.a.sink.add(first);
        expect(await peekHello(link.b), isNull, reason: '$first'.length > 40 ? 'a long one' : '$first');
        await closed.timeout(const Duration(seconds: 5));
      }
      final quiet = pipe<dynamic>();
      final closed = quiet.a.stream.toList();
      expect(await peekHello(quiet.b, timeout: const Duration(milliseconds: 50)), isNull);
      await closed.timeout(const Duration(seconds: 5));
    });
  });
}
