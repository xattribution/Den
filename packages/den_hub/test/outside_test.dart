@Timeout(Duration(seconds: 120))
library;

import 'dart:io';

import 'package:den_net/den_net.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/fixture.dart';
import 'support/server_fixture.dart';

/// Inside and outside (server/outside.dart): from outside the home a family's address loads the
/// app for anyone and only the family's devices get its data; anything else is an empty 404. A
/// working setup link lets a browser into a fresh hub with a door pass; on the home network a
/// fresh hub is anyone's to claim.
void main() {
  /// What a request through a Cloudflare tunnel carries.
  const tunnel = {'cf-connecting-ip': '203.0.113.9', 'x-forwarded-for': '203.0.113.9'};

  Future<http.Response> get(Uri base, String path, {Map<String, String> headers = const {}}) async {
    final request = http.Request('GET', base.resolve(path))
      ..followRedirects = false
      ..headers.addAll(headers);
    return http.Response.fromStream(await request.send());
  }

  group('a family hub', () {
    late HubFixture f;
    setUp(() async => f = await HubFixture.start());
    tearDown(() => f.stop());

    Future<List<String>> invite() async {
      final sync = f.base.replace(scheme: 'ws', path: '/ws');
      final made = SyncNode(f.phone).createHubInvite(f.hubDen.deviceId, hubs: [sync], validFor: const Duration(days: 3));
      final grant = (await InviteGrant.sign(made, keys: f.phone.keys, context: 'invite')).toJson();
      final r = await f.call('POST', '/api/v1/invites', body: grant);
      expect(r.status, 201, reason: r.text);
      return (r.body['words']! as List).cast<String>();
    }

    test("the outside loads the app at a family's address, and nothing else without the family", () async {
      // The app's files (none in this test hub, so its 404 says so in words) and the hub's status.
      expect((await get(f.base, '/', headers: tunnel)).body, isNotEmpty);
      expect((await get(f.base, '/api/v1/hub/status', headers: tunnel)).statusCode, 200);
      for (final path in ['/health', '/api/v1/hub/first-boot', '/api/v1/today']) {
        final r = await get(f.base, path, headers: tunnel);
        expect(r.statusCode, 404, reason: path);
        expect(r.body, isEmpty, reason: path);
      }
      // Inside, the same address answers as always.
      expect((await get(f.base, '/health')).statusCode, isNot(404));
    });

    test('the outside still reaches what devices and joiners need', () async {
      final words = await invite();
      final redeemed = await f.call('POST', '/api/v1/invites/redeem', body: {'code': words.join(' ')}, headers: tunnel);
      expect(redeemed.status, 200, reason: redeemed.text);
      // A made-up token or signature is the family's to refuse, not the door's to hide.
      final token = await f.call('GET', '/api/v1/today', token: 'nope', headers: tunnel);
      expect(token.status, 401);
    });

    test('a working invite link gives a door pass that loads the app; a wrong one gets nothing', () async {
      final words = await invite();
      final link = '/join/${words.join('-')}';
      final r = await get(f.base, link, headers: tunnel);
      expect(r.statusCode, 302, reason: r.body);
      expect(r.headers['location'], '/#$link');
      final cookie = r.headers['set-cookie']!;
      expect(cookie, startsWith('__Host-den_pass='));
      expect(cookie, contains('Secure'));
      expect(cookie, contains('HttpOnly'));
      final pass = cookie.split(';').first;

      final status = await get(f.base, '/api/v1/hub/status', headers: {...tunnel, 'cookie': pass});
      expect(status.statusCode, 200);

      // A wrong link at a family's address opens the app, which says it has run out; no pass.
      final wrong = await get(f.base, '/join/maple-river-canoe-tiger', headers: tunnel);
      expect(wrong.statusCode, 302);
      expect(wrong.headers['set-cookie'], isNull);
    });

    test("a device of the family renews its browser's pass with a signed request; nobody else gets one", () async {
      final url = f.base.resolve('/api/v1/door/pass');
      final headers = await DeviceRequest.sign(keys: f.phone.keys, method: 'POST', url: url, body: const [], hub: f.hubDen.deviceId);
      final signed = await http.post(url, headers: {...headers, ...tunnel});
      expect(signed.statusCode, 200, reason: signed.body);
      expect(signed.headers['set-cookie'], startsWith('__Host-den_pass='));
      expect(signed.headers['set-cookie'], contains('Max-Age=${const Duration(days: 90).inSeconds}'));
      final anon = await http.post(url, headers: tunnel);
      expect(anon.statusCode, 404);
      expect(anon.headers['set-cookie'], isNull);
    });

    test('Tailscale Serve on this machine forwarding a tailnet address is inside; forwarding a public one is outside', () async {
      final tailnet = await get(f.base, '/health', headers: {'x-forwarded-for': '100.101.102.103'});
      expect(tailnet.statusCode, isNot(404));
      // A client can put a home address first; the proxy's own hop, the right-most, is what counts.
      final spoofed = await get(f.base, '/health', headers: {'x-forwarded-for': '192.168.1.5, 8.8.8.8'});
      expect(spoofed.statusCode, 404);
    });

    test('the invite link is in the path, which the door can read', () async {
      final words = await invite();
      final made = DenLink(kind: DenLinkKind.family, words: words.join(' ')).link(Uri.parse('https://den.example.com'));
      expect(made.toString(), 'https://den.example.com/join/${words.join('-')}');
      expect(DenLink.parse(made.toString())!.words, words.join(' '));
    });
  });

  group('a fresh server', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('den_outside_'));
    tearDown(() => tmp.delete(recursive: true));

    Future<ServerFixture> fresh() async {
      final dir = '${tmp.path}/new';
      return ServerFixture.start(dir, await openDataDir(dir));
    }

    test('on the home network it is open to claim with no code; from outside, only its setup link opens it', () async {
      final s = await fresh();
      addTearDown(s.stop);
      final home = await apiCall(s.base, 'GET', '/api/v1/hub/status');
      expect(home.body['open'], isTrue);
      final console = await apiCall(s.base, 'GET', '/api/v1/hub/first-boot');
      expect(console.status, 200, reason: console.text);
      expect(console.body['setup_link'], contains('/setup/${s.own.setupCode}/${s.own.den.deviceId}'));
      expect(console.body['setup_link'], isNot(contains('#')));

      final outside = await apiCall(s.base, 'GET', '/api/v1/hub/first-boot', headers: tunnel);
      expect(outside.status, 404);

      final link = await get(s.base, '/setup/${s.own.setupCode}/${s.own.den.deviceId}', headers: tunnel);
      expect(link.statusCode, 302);
      expect(link.headers['location'], '/#/setup/${s.own.setupCode}/${s.own.den.deviceId}');
      expect(link.headers['set-cookie'], startsWith('__Host-den_pass='));
      final pass = link.headers['set-cookie']!.split(';').first;
      final status = await get(s.base, '/api/v1/hub/status', headers: {...tunnel, 'cookie': pass});
      expect(status.statusCode, 200);
      expect(status.body, isNot(contains('"open"')), reason: 'from outside it still needs its code');

      final wrong = await get(s.base, '/setup/AAAA-AAAA/${s.own.den.deviceId}', headers: tunnel);
      expect(wrong.statusCode, 404);
    });
  });
}
