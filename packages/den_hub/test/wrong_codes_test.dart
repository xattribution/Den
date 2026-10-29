@Timeout(Duration(seconds: 90))
library;

import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_hub/src/edge.dart';

import 'support/fixture.dart';
import 'support/test.dart';

/// Wrong invite words and recovery codes count per client, under a ceiling for everyone that
/// one client can't reach: one address guessing can't keep the family from joining or getting
/// back in.
void main() {
  test('each client has its own wrong guesses, under a ceiling for everyone', () {
    final w = WrongGuesses(perClient: 3, ceiling: 8, window: const Duration(minutes: 10));
    const minute = 60000;
    for (var i = 0; i < 3; i++) {
      expect(w.wait('203.0.113.7', i), isNull);
      w.add('203.0.113.7', i);
    }
    expect(w.wait('203.0.113.7', 3), (seconds: 600, all: false));
    expect(w.wait('198.51.100.9', 3), isNull, reason: 'another address isn\'t held up');
    for (var i = 0; i < 3; i++) {
      w.add('198.51.100.9', 3);
    }
    w.add('2001:db8::/64', 4);
    expect(w.wait('2001:db8::/64', 5), isNull);
    w.add('2001:db8::/64', 5);
    expect(w.wait('192.0.2.1', 6)?.all, isTrue, reason: 'eight wrong guesses in all');
    expect(w.wait('192.0.2.1', 10 * minute + 1), isNull, reason: 'the oldest ones stop counting');
    expect(w.wait('203.0.113.7', 10 * minute + 3), isNull);
  });

  group('over HTTP', () {
    late HubFixture f;
    setUpAll(() async => f = await HubFixture.start(
        configure: (c) => HubConfig(
              port: 0,
              host: InternetAddress.loopbackIPv4,
              mdns: false,
              log: c.log,
              trustedProxies: [IpNetwork.parse('127.0.0.1')],
            )));
    tearDownAll(() => f.stop());

    Future<ApiResult> from(String address, String path, Map<String, Object?> body) =>
        f.call('POST', path, body: body, headers: {'x-forwarded-for': address});

    test('an address that guessed wrong too often waits; the family\'s own doesn\'t', () async {
      for (var i = 0; i < 10; i++) {
        expect((await from('203.0.113.7', '/api/v1/invites/redeem', {'code': 'maple river canoe tiger'})).status, 404);
      }
      final held = await from('203.0.113.7', '/api/v1/invites/redeem', {'code': 'maple river canoe tiger'});
      expect(held.status, 429);
      expect(held.error['message'], contains('from here'));
      expect((await from('198.51.100.9', '/api/v1/invites/redeem', {'code': 'maple river canoe tiger'})).status, 404,
          reason: 'another address still gets an answer');
    });

    test('the same for recovery codes', () async {
      await f.phone.setServerRecoveryKey((await f.hub.recovery.serverKey()).publicKey);
      await f.toHub();
      final pubkey = (await DeviceKeys.generate()).pubkey;
      for (var i = 0; i < HubRecovery.maxWrong; i++) {
        final r = await from('203.0.113.8', '/api/v1/recovery/redeem', {'code': 'maple river canoe tiger', 'pubkey': pubkey});
        expect(r.status, 404);
      }
      expect((await from('203.0.113.8', '/api/v1/recovery/redeem', {'code': 'maple river canoe tiger', 'pubkey': pubkey})).status, 429);
      final other = await from('198.51.100.10', '/api/v1/recovery/redeem', {'code': 'maple river canoe tiger', 'pubkey': pubkey});
      expect(other.status, 404, reason: 'another address still gets an answer');
    });
  });
}
