@Timeout(Duration(seconds: 180))
library;

import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_hub/src/edge.dart' show Limits;

import 'support/browser.dart';
import 'support/fake_idp.dart';
import 'support/fixture.dart';
import 'support/host_fixture.dart';
import 'support/oidc_keys.dart';
import 'support/sign_in.dart';
import 'support/test.dart';

/// Signing in to the hub with Google and Apple, sessions, and binding a parent's account
/// (accounts.dart): phase 1 of docs/auth/ACCOUNT_FIRST_REVIEW.md. The providers are local fakes
/// over HTTPS, reached through the hub's own NetGuard; nothing reaches Google or Apple.
void main() {
  final public = Uri.parse('https://den.test');

  HubConfig configFor(HubConfig base, {FakeIdp? google, FakeIdp? apple, Uri? url, List<IpNetwork> proxies = const []}) => HubConfig(
        port: 0,
        host: InternetAddress.loopbackIPv4,
        mdns: false,
        log: base.log,
        publicUrl: url ?? public,
        trustedProxies: proxies,
        fetchClient: fakeProviderGuard().client(),
        signInIssuers: issuersOf(google: google, apple: apple),
      );

  /// A hub over the demo family whose host signs in with [google] and [apple], as a parent of
  /// its own family turned them on in the app.
  Future<HubFixture> started({FakeIdp? google, FakeIdp? apple, Uri? url, List<IpNetwork> proxies = const [], String appleKey = appleP8}) async {
    final f = await HubFixture.start(configure: (base) => configFor(base, google: google, apple: apple, url: url, proxies: proxies));
    await turnOnSignIn(f.hub.host, google: google, apple: apple, appleKey: appleKey);
    return f;
  }

  Future<Answer> signed(HubFixture f, Den den, String method, String path, {Object? body}) =>
      signedCall(f.base, den, method, path, hub: f.hubDen.deviceId, body: body);

  /// Binds [sub]'s account at [idp] to whoever acts on [phone], as the app does: asks the hub for
  /// a binding, signs in through its start link, reads the result back and writes it itself.
  Future<AccountRef> bind(HubFixture f, Den phone, FakeIdp idp, String sub, {String email = 'alex@example.com'}) async {
    final started = await signed(f, phone, 'POST', '/api/v1/account/bindings', body: {'provider': idp.apple ? 'apple' : 'google'});
    expect(started.status, 201, reason: started.body);
    final json = started.json! as Map;
    final page = await Browser(f.base).signIn(idp, sub: sub, email: email, start: json['start_url'] as String);
    expect(page.status, 200, reason: page.body);
    final polled = await signed(f, phone, 'GET', '/api/v1/account/bindings/${json['id']}');
    expect((polled.json! as Map)['state'], 'done', reason: polled.body);
    final account = AccountRef.fromJson((polled.json! as Map)['account'])!;
    await phone.setAccount(phone.actor!.id, account);
    await f.toHub();
    return account;
  }

  group('with no provider configured', () {
    test('/auth, /api/v1/me and bindings don\'t exist, and nothing else changes', () async {
      final f = await HubFixture.start(configure: (base) => configFor(base));
      addTearDown(f.stop);
      final b = Browser(f.base);
      for (final path in ['/auth/oidc/google/start', '/auth/oidc/apple/callback', '/auth/oidc/google/callback?code=x&state=y', '/auth/x']) {
        final a = await b.go('GET', path);
        expect(a.status, 404, reason: path);
        expect(a.setCookies, isEmpty);
      }
      expect((await b.go('POST', '/auth/logout', headers: {'origin': 'https://den.test'})).status, 404);
      expect((await b.go('POST', '/auth/oidc/apple/callback', form: 'code=x&state=y')).status, 404);
      expect((await b.go('GET', '/api/v1/me')).status, 404);
      expect((await signed(f, f.phone, 'POST', '/api/v1/account/bindings', body: {'provider': 'google'})).status, 404);
      expect((await signed(f, f.phone, 'GET', '/api/v1/account/providers')).status, 404);
      expect(f.hub.accounts.enabled, isFalse);
      expect((await b.go('GET', '/health')).status, 200);
    });

    test('a provider without an https public URL to come back to stays off', () async {
      final google = await FakeIdp.start();
      addTearDown(google.stop);
      final f = await started(google: google, url: Uri.parse('http://den.local:47733'));
      addTearDown(f.stop);
      expect(f.hub.accounts.enabled, isFalse);
      expect((await Browser(f.base).go('GET', '/auth/oidc/google/start')).status, 404);
    });
  });

  group('Google', () {
    late FakeIdp google;
    late HubFixture f;
    late String alex;

    setUp(() async {
      google = await FakeIdp.start();
      f = await started(google: google);
      alex = f.id('Alex');
    });

    tearDown(() async {
      await f.stop();
      await google.stop();
    });

    test('a parent binds their account from their phone, signs in, and /api/v1/me says who', () async {
      final account = await bind(f, f.phone, google, '108812345');
      expect(account.provider, 'google');
      expect(account.hash, accountHash(f.phone.familyId!, 'google', '108812345'));
      expect(account.proof!.hub, f.hubDen.deviceId, reason: 'the hub vouches for the sign-in; the phone writes it');
      expect(account.proof!.key, f.hubDen.keys.pubkey);
      expect(f.hubDen.member(alex)!.account, account);

      final b = Browser(f.base);
      final page = await b.signIn(google, sub: '108812345');
      expect(page.status, 200, reason: page.body);
      expect(page.body, contains('as Alex'));
      final me = await b.go('GET', '/api/v1/me');
      expect(me.status, 200, reason: me.body);
      final json = me.json! as Map;
      expect(json['member'], {'id': alex, 'name': 'Alex', 'role': 'parent'});
      expect(json['provider'], 'google');
      expect((json['family'] as Map)['id'], f.phone.familyId);
      expect(json['expires_ms'] as int, (json['signed_in_ms'] as int) + HubAccounts.sessionLifetime.inMilliseconds);
      // Nothing else about devices changed.
      expect(f.hubDen.devices.map((d) => d.id).toSet(), f.phone.devices.map((d) => d.id).toSet());
    });

    test('the cookies are __Host- cookies: Secure, HttpOnly, SameSite=Lax, Path=/, no Domain, short-lived', () async {
      await bind(f, f.phone, google, '108812345');
      final b = Browser(f.base);
      final started = await b.go('GET', '/auth/oidc/google/start');
      final flow = started.cookieLine(HubAccounts.flowCookie)!;
      final at = Uri.parse(started.location!);
      final code = google.signIn(at, sub: '108812345');
      final back = await b.go('GET', '/auth/oidc/google/callback?code=$code&state=${at.queryParameters['state']}');
      final session = back.cookieLine(HubAccounts.sessionCookie)!;
      for (final (line, life) in [(flow, 600), (session, 43200)]) {
        final attributes = line.split(';').skip(1).map((a) => a.trim()).toSet();
        expect(line, startsWith('__Host-'));
        expect(attributes, {'Path=/', 'Secure', 'HttpOnly', 'SameSite=Lax', 'Max-Age=$life'}, reason: line);
        expect(line.toLowerCase(), isNot(contains('domain')));
      }
      expect(back.cookieLine(HubAccounts.flowCookie), contains('Max-Age=0'), reason: 'signing in clears the sign-in cookie');
      expect(back.header('cache-control'), 'no-store');
    });

    test('each sign-in is a new session, and ends the one the browser had', () async {
      await bind(f, f.phone, google, '108812345');
      final b = Browser(f.base);
      await b.signIn(google, sub: '108812345');
      final first = b.cookies[HubAccounts.sessionCookie]!;
      await b.signIn(google, sub: '108812345');
      final second = b.cookies[HubAccounts.sessionCookie]!;
      expect(second, isNot(first));
      expect((await b.go('GET', '/api/v1/me')).status, 200);
      final stale = Browser(f.base)..cookies[HubAccounts.sessionCookie] = first;
      expect((await stale.go('GET', '/api/v1/me')).status, 401);
      expect(f.hub.accounts.sessionCount, 1);
    });

    test('an account bound to nobody gets the generic answer, and nothing is made', () async {
      final changes = f.hubDen.changesSince(const {}).length;
      final b = Browser(f.base);
      final page = await b.signIn(google, sub: 'nobody-here', email: 'stranger@example.com');
      expect(page.status, 403);
      expect(page.body, contains('isn&#39;t set up for this family'));
      expect(page.cookieLine(HubAccounts.sessionCookie), isNull);
      expect(b.cookies, isEmpty);
      expect(f.hub.accounts.sessionCount, 0);
      expect(f.hub.accounts.flowCount, 0);
      expect(f.hubDen.changesSince(const {}).length, changes);
      expect((await b.go('GET', '/api/v1/me')).status, 401);
    });

    test('no binding and no family answer alike: status, body, headers and timing class', () async {
      await bind(f, f.phone, google, '108812345');
      // A hub that isn't in a family yet, signing in with the same provider.
      final lonelyDen = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
      final lonely = await DenHub.start(lonelyDen, configFor(HubConfig(log: f.hub.config.log), google: google));
      await turnOnSignIn(lonely.host, google: google);
      addTearDown(() async {
        await lonely.stop();
        await lonelyDen.close();
      });
      expect(lonely.ready, isFalse);
      google.tokenDelay = const Duration(milliseconds: 250);
      final calls = google.tokenCalls;
      final noBinding = await Browser(f.base).signIn(google, sub: 'someone-else');
      final noFamily = await Browser(lonely.localUrl).signIn(google, sub: '108812345');
      expect(google.tokenCalls, calls + 2, reason: 'both exchanged the code and checked the token');
      expect(noBinding.status, 403);
      expect(noFamily.status, noBinding.status);
      expect(noFamily.body, noBinding.body);
      Map<String, List<String>> headers(Answer a) => {...a.headers}..remove('date');
      expect(headers(noFamily), headers(noBinding));
      for (final a in [noBinding, noFamily]) {
        expect(a.elapsed, greaterThanOrEqualTo(google.tokenDelay), reason: 'both waited on the provider');
      }
      expect(lonely.accounts.sessionCount, 0);
      expect(lonelyDen.changesSince(const {}), isEmpty);
    });

    test('binding is by sub, never by email', () async {
      await bind(f, f.phone, google, '108812345', email: 'alex@example.com');
      final sameEmail = await Browser(f.base).signIn(google, sub: '999999', email: 'alex@example.com');
      expect(sameEmail.status, 403, reason: 'another account with Alex\'s address is someone else');
      final newEmail = Browser(f.base);
      final page = await newEmail.signIn(google, sub: '108812345', email: 'alex.new@example.org');
      expect(page.status, 200, reason: 'the same account with a new address is still Alex');
      expect(((await newEmail.go('GET', '/api/v1/me')).json! as Map)['member'], containsPair('id', alex));
    });

    test('state: a sign-in comes back once, to the browser that began it', () async {
      await bind(f, f.phone, google, '108812345');
      final a = Browser(f.base);
      final started = await a.go('GET', '/auth/oidc/google/start');
      final at = Uri.parse(started.location!);
      final flow = a.cookies[HubAccounts.flowCookie]!;
      final code = google.signIn(at, sub: '108812345');
      final callback = '/auth/oidc/google/callback?code=$code&state=${at.queryParameters['state']}';
      // Another browser handed the link (login CSRF): refused, and the sign-in is used up.
      final other = Browser(f.base);
      expect((await other.go('GET', callback)).status, 400);
      expect((await a.go('GET', callback)).status, 400);
      // A fresh one, replayed with its cookie after it worked: refused, and never sent on.
      final fresh = await a.go('GET', '/auth/oidc/google/start');
      final at2 = Uri.parse(fresh.location!);
      final again = '/auth/oidc/google/callback?code=${google.signIn(at2, sub: '108812345')}&state=${at2.queryParameters['state']}';
      final flow2 = a.cookies[HubAccounts.flowCookie]!;
      expect((await a.go('GET', again)).status, 200);
      final calls = google.tokenCalls;
      final replay = Browser(f.base)..cookies[HubAccounts.flowCookie] = flow2;
      expect((await replay.go('GET', again)).status, 400);
      expect(google.tokenCalls, calls);
      expect((await Browser(f.base).go('GET', '/auth/oidc/google/callback?code=x&state=made-up')).status, 400);
      expect(flow, isNot(flow2));
    });

    test('PKCE: the provider gets the challenge, the hub alone sends the verifier', () async {
      await bind(f, f.phone, google, '108812345');
      final b = Browser(f.base);
      // Someone swaps the challenge on the way to the provider: the code is theirs, not the hub's.
      final page = await b.signIn(google, sub: '108812345',
          authorize: (u) => u.replace(queryParameters: {...u.queryParameters, 'code_challenge': pkceChallenge(randomToken())}));
      expect(page.status, 400);
      expect(google.refusals, contains('PKCE'));
      expect(b.cookies.containsKey(HubAccounts.sessionCookie), isFalse);
    });

    test('the token must be this sign-in\'s and the provider\'s own', () async {
      await bind(f, f.phone, google, '108812345');
      final cases = <String, void Function(Map<String, Object?> header, Map<String, Object?> claims)>{
        'another nonce': (h, c) => c['nonce'] = randomToken(),
        'another issuer': (h, c) => c['iss'] = '${google.issuer}/',
        'another audience': (h, c) => c['aud'] = 'someone-elses-app',
        'two audiences': (h, c) => c['aud'] = [google.clientId, 'another'],
        'expired': (h, c) => c['exp'] = (c['iat']! as int) - 3600,
        'unverified email': (h, c) => c['email_verified'] = false,
      };
      for (final e in cases.entries) {
        google.shape = e.value;
        final b = Browser(f.base);
        final page = await b.signIn(google, sub: '108812345');
        expect(page.status, inInclusiveRange(400, 403), reason: e.key);
        expect(b.cookies.containsKey(HubAccounts.sessionCookie), isFalse, reason: e.key);
      }
      google.shape = null;
      final forgeries = <String, String Function(Map<String, Object?>, Map<String, Object?>)>{
        'signed by another key': (h, c) => signJwt(h, c, keyX),
        'alg none': (h, c) => signJwt({...h, 'alg': 'none'}, c, keyA, signature: const []),
        'HS256': (h, c) => signJwt({...h, 'alg': 'HS256'}, c, keyA, signature: List.filled(32, 7)),
      };
      for (final e in forgeries.entries) {
        google.forge = e.value;
        final b = Browser(f.base);
        final page = await b.signIn(google, sub: '108812345');
        expect(page.status, 400, reason: e.key);
        expect(b.cookies.containsKey(HubAccounts.sessionCookie), isFalse, reason: e.key);
      }
      expect(f.hub.accounts.sessionCount, 0);
    });

    test('a callback naming another issuer (RFC 9207), or a cancelled sign-in, signs nobody in', () async {
      await bind(f, f.phone, google, '108812345');
      final wrong = await Browser(f.base).signIn(google, sub: '108812345', back: (q) => {...q, 'iss': 'https://evil.test'});
      expect(wrong.status, 400);
      final cancelled = await Browser(f.base).signIn(google, sub: '108812345', back: (q) => {'state': q['state']!, 'error': 'access_denied'});
      expect(cancelled.status, 400);
      expect(cancelled.body, contains('cancelled'));
      expect(f.hub.accounts.sessionCount, 0);
    });

    test('signing out takes Den\'s own Origin; anything else is refused and the session stays', () async {
      await bind(f, f.phone, google, '108812345');
      final b = Browser(f.base);
      await b.signIn(google, sub: '108812345');
      for (final origin in [null, 'https://evil.test', 'null', 'http://den.test', 'https://den.test:8443']) {
        final out = await b.go('POST', '/auth/logout', headers: {'origin': ?origin});
        expect(out.status, 403, reason: '$origin');
        expect((await b.go('GET', '/api/v1/me')).status, 200, reason: '$origin');
      }
      final out = await b.go('POST', '/auth/logout', headers: {'origin': 'https://den.test'});
      expect(out.status, 200);
      expect(out.cookieLine(HubAccounts.sessionCookie), contains('Max-Age=0'));
      expect(f.hub.accounts.sessionCount, 0);
      expect((await b.go('GET', '/api/v1/me')).status, 401);
    });

    test('a session ends once its member no longer has the account', () async {
      await bind(f, f.phone, google, '108812345');
      final b = Browser(f.base);
      await b.signIn(google, sub: '108812345');
      expect((await b.go('GET', '/api/v1/me')).status, 200);
      await f.phone.setAccount(alex, null);
      await f.toHub();
      expect((await b.go('GET', '/api/v1/me')).status, 401);
      expect(f.hub.accounts.sessionCount, 0);
    });

    test('turning Google off or changing its client ends its sessions, its sign-ins on their way and its bindings', () async {
      await bind(f, f.phone, google, '108812345');
      final b = Browser(f.base);
      await b.signIn(google, sub: '108812345');
      expect((await b.go('GET', '/api/v1/me')).status, 200);
      // A sign-in on its way, and a binding waiting.
      final waiting = Browser(f.base);
      final started = await waiting.go('GET', '/auth/oidc/google/start');
      final at = Uri.parse(started.location!);
      final binding = (await signed(f, f.phone, 'POST', '/api/v1/account/bindings', body: {'provider': 'google'})).json! as Map;

      // Changed (the same client set again counts: whatever was set up before is over).
      await turnOnSignIn(f.hub.host, google: google);
      expect((await b.go('GET', '/api/v1/me')).status, 401, reason: 'the session ended');
      expect(f.hub.accounts.sessionCount, 0);
      final code = google.signIn(at, sub: '108812345');
      expect((await waiting.go('GET', '/auth/oidc/google/callback?code=$code&state=${at.queryParameters['state']}')).status, 400);
      expect(waiting.cookies[HubAccounts.sessionCookie], isNull);
      final polled = await signed(f, f.phone, 'GET', '/api/v1/account/bindings/${binding['id']}');
      expect((polled.json! as Map)['state'], 'failed');
      expect((await Browser(f.base).go('GET', binding['start_url'] as String)).body, contains('expired'));

      // Signed in again, then turned off and on: over again.
      await b.signIn(google, sub: '108812345');
      expect((await b.go('GET', '/api/v1/me')).status, 200);
      await f.hub.host.signIn.turnOff(googleProvider);
      await turnOnSignIn(f.hub.host, google: google);
      expect((await b.go('GET', '/api/v1/me')).status, 401);
    });

    test('a cookie sent twice counts for nothing', () async {
      await bind(f, f.phone, google, '108812345');
      final b = Browser(f.base);
      await b.signIn(google, sub: '108812345');
      final token = b.cookies[HubAccounts.sessionCookie]!;
      final twice = await Browser(f.base).go('GET', '/api/v1/me',
          headers: {'cookie': '${HubAccounts.sessionCookie}=$token; ${HubAccounts.sessionCookie}=$token'});
      expect(twice.status, 401);
    });

    group('binding', () {
      Future<Map<String, Object?>> startBinding(Den den) async {
        final a = await signed(f, den, 'POST', '/api/v1/account/bindings', body: {'provider': 'google'});
        expect(a.status, 201, reason: a.body);
        return (a.json! as Map).cast<String, Object?>();
      }

      Future<Answer> poll(Den den, Map<String, Object?> b) => signed(f, den, 'GET', '/api/v1/account/bindings/${b['id']}');

      test('the providers list and the start link are for a parent\'s own phone', () async {
        final list = await signed(f, f.phone, 'GET', '/api/v1/account/providers');
        expect(list.json, {
          'providers': [
            {'id': 'google', 'name': 'Google'},
          ],
        });
        final b = await startBinding(f.phone);
        expect(b['start_url'] as String, startsWith('https://den.test/auth/oidc/google/start?bind='));
        expect(Uri.parse(b['start_url'] as String).queryParameters['bind'], isNot(b['id']), reason: 'the link can\'t read the result');
        expect((await signed(f, f.phone, 'POST', '/api/v1/account/bindings', body: {'provider': 'apple'})).status, 400);
      });

      test('the result is read once, by the phone that asked', () async {
        final b = await startBinding(f.phone);
        expect(((await poll(f.phone, b)).json! as Map)['state'], 'waiting');
        await Browser(f.base).signIn(google, sub: '108812345', start: b['start_url'] as String);
        // Priya, a parent on her own phone, can't read Alex's.
        final priyaPhone = await _personalDevice(f, f.id('Priya'), 'Priya phone');
        expect((await poll(priyaPhone, b)).status, 404);
        final done = await poll(f.phone, b);
        expect((done.json! as Map)['state'], 'done');
        expect((done.json! as Map)['email'], 'alex@example.com');
        expect((await poll(f.phone, b)).status, 404, reason: 'once');
        await priyaPhone.close();
      });

      test('a session cookie can neither start one nor read one', () async {
        await bind(f, f.phone, google, '108812345');
        final b = Browser(f.base);
        await b.signIn(google, sub: '108812345');
        final binding = await startBinding(f.phone);
        expect((await b.go('POST', '/api/v1/account/bindings', headers: {'origin': 'https://den.test'})).status, 401);
        expect((await b.go('GET', '/api/v1/account/bindings/${binding['id']}')).status, 401);
      });

      test('a start link used twice binds nothing, whoever used it first', () async {
        final b = await startBinding(f.phone);
        final start = b['start_url'] as String;
        final ticket = Uri.parse(start).queryParameters['bind']!;
        final mine = Browser(f.base);
        final first = await mine.confirm(start);
        expect(first.status, 302);
        // Someone else who saw the link opens it too: the page no longer offers it.
        expect((await Browser(f.base).go('GET', start)).status, 400);
        // And posting its ticket anyway spoils it for both.
        final theirs = await Browser(f.base)
            .go('POST', '/auth/oidc/google/start', form: 'bind=$ticket', headers: {'origin': 'https://den.test'});
        expect(theirs.status, 400);
        final at = Uri.parse(first.location!);
        await mine.go('GET', '/auth/oidc/google/callback?code=${google.signIn(at, sub: '108812345')}&state=${at.queryParameters['state']}');
        final polled = (await poll(f.phone, b)).json! as Map;
        expect(polled['state'], 'failed');
        expect(polled['message'], contains('used twice'));
        expect(polled.containsKey('account'), isFalse);
      });

      test('the start link only asks: opening it (a preview, a scanner) starts nothing', () async {
        final b = await startBinding(f.phone);
        final start = b['start_url'] as String;
        for (var i = 0; i < 3; i++) {
          final page = await Browser(f.base).go('GET', start);
          expect(page.status, 200);
          expect(page.setCookies, isEmpty);
          expect(page.body, contains('sign in as Alex in Carter family&#39;s Den'));
          expect(page.body, contains('Continue only if you are Alex'));
          expect(page.body, isNot(contains('<script')));
          expect(page.body, contains('<form method="post" action="/auth/oidc/google/start">'));
          final policy = page.header('content-security-policy')!;
          expect(policy, contains("default-src 'none'"));
          expect(policy, contains("form-action 'self'"));
          expect(policy, isNot(contains('script-src')));
        }
        expect(f.hub.accounts.flowCount, 0);
        expect(google.discoveryFetches, 0, reason: 'nothing was started');
        // Then the parent presses Continue and it works.
        final page = await Browser(f.base).signIn(google, sub: '108812345', start: start);
        expect(page.status, 200, reason: page.body);
        expect(((await poll(f.phone, b)).json! as Map)['state'], 'done');
      });

      test('Continue takes the hub\'s own Origin', () async {
        final b = await startBinding(f.phone);
        final ticket = Uri.parse(b['start_url'] as String).queryParameters['bind']!;
        for (final origin in [null, 'https://evil.test', 'null']) {
          final a = await Browser(f.base)
              .go('POST', '/auth/oidc/google/start', form: 'bind=$ticket', headers: {'origin': ?origin});
          expect(a.status, 403, reason: '$origin');
        }
        expect(f.hub.accounts.flowCount, 0);
        expect(((await poll(f.phone, b)).json! as Map)['state'], 'waiting', reason: 'nothing spoiled it');
      });

      test('names on the page are escaped', () async {
        await f.phone.updateMember(f.id('Alex'), {'name': '<b>Alex</b>'});
        await f.toHub();
        final b = await startBinding(f.phone);
        final page = await Browser(f.base).go('GET', b['start_url'] as String);
        expect(page.body, isNot(contains('<b>Alex</b>')));
        expect(page.body, contains('&lt;b&gt;Alex&lt;&#47;b&gt;'));
      });

      test('a binding\'s callback replayed finishes nothing more', () async {
        final b = await startBinding(f.phone);
        final browser = Browser(f.base);
        final started = await browser.confirm(b['start_url'] as String);
        final at = Uri.parse(started.location!);
        final flow = browser.cookies[HubAccounts.flowCookie]!;
        final callback = '/auth/oidc/google/callback?code=${google.signIn(at, sub: '108812345')}&state=${at.queryParameters['state']}';
        expect((await browser.go('GET', callback)).status, 200);
        final replay = Browser(f.base)..cookies[HubAccounts.flowCookie] = flow;
        expect((await replay.go('GET', callback)).status, 400);
        final polled = (await poll(f.phone, b)).json! as Map;
        expect(polled['state'], 'done');
        expect((await poll(f.phone, b)).status, 404);
      });

      test('kids\' phones, shared screens and other hubs can\'t start one', () async {
        final kid = await _personalDevice(f, f.id('Maya'), 'Maya phone');
        expect((await signed(f, kid, 'POST', '/api/v1/account/bindings', body: {'provider': 'google'})).status, 403);
        final display = await _device(f, 'Kitchen', DeviceMode.shared);
        display.actAs(alex);
        expect((await signed(f, display, 'POST', '/api/v1/account/bindings', body: {'provider': 'google'})).status, 403);
        final ownHub = await _device(f, 'Alex laptop (hub)', DeviceMode.hub, member: alex);
        ownHub.actAs(alex);
        expect((await signed(f, ownHub, 'POST', '/api/v1/account/bindings', body: {'provider': 'google'})).status, 403);
        for (final d in [kid, display, ownHub]) {
          await d.close();
        }
      });

      test('an account someone else in the family has can\'t be bound again', () async {
        await bind(f, f.phone, google, '108812345');
        final priyaPhone = await _personalDevice(f, f.id('Priya'), 'Priya phone');
        final a = await signed(f, priyaPhone, 'POST', '/api/v1/account/bindings', body: {'provider': 'google'});
        final b = (a.json! as Map).cast<String, Object?>();
        final page = await Browser(f.base).signIn(google, sub: '108812345', start: b['start_url'] as String);
        expect(page.status, 409);
        final polled = (await signed(f, priyaPhone, 'GET', '/api/v1/account/bindings/${b['id']}')).json! as Map;
        expect(polled['state'], 'failed');
        await priyaPhone.close();
      });

      test('the hub itself can\'t write member.account, nor can a connection through it', () async {
        final account = AccountRef('google', accountHash(f.phone.familyId!, 'google', '108812345'));
        f.hubDen.actAs(alex);
        await expectLater(f.hubDen.setAccount(alex, account), throwsA(isA<PermissionDenied>()));
        f.hubDen.actAs(null);
        final token = await f.token(scopes: {Scope.read, Scope.admin}, member: alex);
        final save = await f.call('POST', '/api/v1/actions/family.save_member', token: token, body: {
          'member': alex,
          'account': account.toJson(),
        });
        expect(save.status, 400, reason: save.text);
        expect(f.hubDen.member(alex)!.account, isNull);
        // And the hash isn't something connections read.
        await bind(f, f.phone, google, '108812345');
        final members = await f.call('GET', '/api/v1/members', token: token);
        expect(members.text, isNot(contains(account.hash)));
      });
    });

    test('/auth is budgeted per client, through a trusted proxy by the real client', () async {
      await f.stop();
      f = await started(google: google, proxies: [IpNetwork.parse('127.0.0.1/32')]);
      final b = Browser(f.base);
      final headers = {'x-forwarded-for': '203.0.113.7'};
      // What cloudflared sends: whatever the client claimed first, the real client last. Making
      // up the front of the chain buys nothing.
      for (var i = 0; i < Limits.auth.burst; i++) {
        final spoofed = {'x-forwarded-for': '198.51.100.$i, 192.0.2.$i, 203.0.113.7'};
        expect((await b.go('GET', '/auth/oidc/google/start', headers: spoofed)).status, 302, reason: '$i');
      }
      final limited = await b.go('GET', '/auth/oidc/google/start', headers: headers);
      expect(limited.status, 429);
      expect(int.parse(limited.header('retry-after')!), greaterThan(0));
      expect((await b.go('GET', '/auth/oidc/google/callback?state=x&code=y', headers: headers)).status, 429);
      expect((await b.go('POST', '/auth/logout', headers: {...headers, 'origin': 'https://den.test'})).status, 429);
      // Someone else behind the same proxy isn't held back.
      expect((await Browser(f.base).go('GET', '/auth/oidc/google/start', headers: {'x-forwarded-for': '203.0.113.8'})).status, 302);
    });
  });

  group('Apple', () {
    late FakeIdp apple;
    late HubFixture f;

    setUp(() async {
      apple = await FakeIdp.start(apple: true, clientId: 'family.den.signin');
      f = await started(apple: apple);
    });

    tearDown(() async {
      await f.stop();
      await apple.stop();
    });

    test('binds and signs in through Apple\'s form post, with the ES256 client secret', () async {
      final account = await bind(f, f.phone, apple, '001234.abcdef0123456789.0042', email: 'alex@icloud.com');
      expect(account.provider, 'apple');
      final b = Browser(f.base);
      final page = await b.signIn(apple, sub: '001234.abcdef0123456789.0042', email: 'alex@icloud.com');
      expect(page.status, 200, reason: page.body);
      expect(((await b.go('GET', '/api/v1/me')).json! as Map)['provider'], 'apple');
      expect(apple.refusals, isEmpty, reason: 'Apple took every client secret');
    });

    test('a Hide My Email address is refused and never matched', () async {
      await bind(f, f.phone, apple, '001234.abc', email: 'alex@icloud.com');
      final b = Browser(f.base);
      final page = await b.signIn(apple, sub: '001234.abc', email: 'k2x9@privaterelay.appleid.com');
      expect(page.status, 403);
      expect(page.body, contains('Share My Email'));
      expect(b.cookies.containsKey(HubAccounts.sessionCookie), isFalse);
      final binding = await signed(f, f.phone, 'POST', '/api/v1/account/bindings', body: {'provider': 'apple'});
      final json = binding.json! as Map;
      await Browser(f.base).signIn(apple, sub: '001234.xyz', email: 'z@privaterelay.appleid.com', start: json['start_url'] as String);
      final polled = (await signed(f, f.phone, 'GET', '/api/v1/account/bindings/${json['id']}')).json! as Map;
      expect(polled['state'], 'failed');
      expect(polled['message'], contains('Hide My Email'));
    });

    test('Apple\'s email_verified as "false" is refused', () async {
      await bind(f, f.phone, apple, '001234.abc', email: 'alex@icloud.com');
      final page = await Browser(f.base).signIn(apple, sub: '001234.abc', email: 'alex@icloud.com', verified: false);
      expect(page.status, 403);
      expect(f.hub.accounts.sessionCount, 0);
    });

    test('the form must come from Apple, once; the browser still finishes it with its cookie', () async {
      await bind(f, f.phone, apple, '001234.abc', email: 'alex@icloud.com');
      final b = Browser(f.base);
      final started = await b.go('GET', '/auth/oidc/apple/start');
      final at = Uri.parse(started.location!);
      final state = at.queryParameters['state']!;
      final code = apple.signIn(at, sub: '001234.abc', email: 'alex@icloud.com');
      final form = 'code=$code&state=$state';
      final forged = await b.go('POST', '/auth/oidc/apple/callback', form: form, headers: {'origin': 'https://evil.test'}, crossSitePost: true);
      expect(forged.status, 400);
      final posted = await b.go('POST', '/auth/oidc/apple/callback', form: form, headers: {'origin': apple.origin}, crossSitePost: true);
      expect(posted.status, 303);
      expect(posted.location, 'https://den.test/auth/oidc/apple/callback?state=${Uri.encodeQueryComponent(state)}');
      // A second post for the same sign-in (a replay, or someone else's code) spoils it.
      final again = await b.go('POST', '/auth/oidc/apple/callback', form: form, headers: {'origin': apple.origin}, crossSitePost: true);
      expect(again.status, 400);
      expect((await b.go('GET', posted.location!)).status, 400);
      expect(f.hub.accounts.sessionCount, 0);
      // Without its cookie the GET finishes nothing either.
      final c = Browser(f.base);
      final s2 = await c.go('GET', '/auth/oidc/apple/start');
      final at2 = Uri.parse(s2.location!);
      final p2 = await c.go('POST', '/auth/oidc/apple/callback',
          form: 'code=${apple.signIn(at2, sub: '001234.abc', email: 'alex@icloud.com')}&state=${at2.queryParameters['state']}',
          headers: {'origin': apple.origin},
          crossSitePost: true);
      expect((await Browser(f.base).go('GET', p2.location!)).status, 400);
    });

    test('a client secret signed with another key is refused by Apple, and nobody signs in', () async {
      await f.stop();
      f = await started(apple: apple, appleKey: otherP8);
      final page = await Browser(f.base).signIn(apple, sub: '001234.abc', email: 'alex@icloud.com');
      expect(page.status, 400);
      expect(apple.refusals, ['client_secret signature']);
    });
  });

  group('one host, two families', () {
    late FakeIdp google;
    late HostFixture host;

    setUp(() async {
      google = await FakeIdp.start();
      host = await HostFixture.start(
        configure: (c) => HostConfig(
            port: c.port, host: c.host, log: c.log, fetchClient: fakeProviderGuard().client(), signInIssuers: issuersOf(google: google)),
        hub: (name, base) => HubConfig(mdns: false, publicUrl: Uri.parse('https://$name'), log: base.log),
      );
      await turnOnSignIn(host.host, google: google);
    });

    tearDown(() async {
      await host.stop();
      await google.stop();
    });

    Future<Answer> signedAt(String name, Den den, String method, String path, {Object? body}) =>
        signedCall(host.base, den, method, path, hub: host[name].hubDen.deviceId, body: body, hostname: name);

    Future<AccountRef> bindAt(String name, String sub) async {
      final family = host[name];
      final started = await signedAt(name, family.phone, 'POST', '/api/v1/account/bindings', body: {'provider': 'google'});
      expect(started.status, 201, reason: started.body);
      final json = started.json! as Map;
      expect(json['start_url'] as String, startsWith('https://$name/'));
      final page = await Browser(host.base, hostname: name).signIn(google, sub: sub, start: json['start_url'] as String);
      expect(page.status, 200, reason: page.body);
      final polled = await signedAt(name, family.phone, 'GET', '/api/v1/account/bindings/${json['id']}');
      final account = AccountRef.fromJson((polled.json! as Map)['account'])!;
      await family.phone.setAccount(family.phone.actor!.id, account);
      await family.toHub();
      return account;
    }

    test('a session at one family\'s address reads nothing at another\'s', () async {
      final a = await bindAt('den-a.test', 'same-person');
      final at = Browser(host.base, hostname: 'den-a.test');
      expect((await at.signIn(google, sub: 'same-person')).status, 200);
      final me = await at.go('GET', '/api/v1/me');
      expect(((me.json! as Map)['family'] as Map)['id'], host['den-a.test'].phone.familyId);
      // The same cookie at the other family's address.
      final elsewhere = Browser(host.base, hostname: 'den-b.test')..cookies.addAll(at.cookies);
      expect((await elsewhere.go('GET', '/api/v1/me')).status, 401);
      // The same person, bound in A, is nobody in B.
      final inB = await Browser(host.base, hostname: 'den-b.test').signIn(google, sub: 'same-person');
      expect(inB.status, 403);
      // B's parent can't copy A's binding in: A's hub vouched for A's family and member only. And
      // the hash itself is keyed by the family, so it wouldn't match in B anyway.
      final b = host['den-b.test'];
      await expectLater(b.phone.setAccount(b.phone.actor!.id, a), throwsA(isA<PermissionDenied>()));
      expect((await Browser(host.base, hostname: 'den-b.test').signIn(google, sub: 'same-person')).status, 403);
      expect(accountHash(b.phone.familyId!, 'google', 'same-person'), isNot(a.hash));
    });

    test('a binding started in one family can\'t be opened or read in another', () async {
      final a = host['den-a.test'], b = host['den-b.test'];
      final started = await signedAt('den-a.test', a.phone, 'POST', '/api/v1/account/bindings', body: {'provider': 'google'});
      final json = started.json! as Map;
      final link = Uri.parse(json['start_url'] as String);
      // Its link at B's address: B never made it.
      final atB = await Browser(host.base, hostname: 'den-b.test').go('GET', '${link.path}?${link.query}');
      expect(atB.status, 400);
      // B's parent asking B's hub for A's binding: not there.
      expect((await signedAt('den-b.test', b.phone, 'GET', '/api/v1/account/bindings/${json['id']}')).status, 404);
      // A's phone asking at B's address goes to A's hub (X-Den-Hub), which still has it.
      final polled = await signedCall(host.base, a.phone, 'GET', '/api/v1/account/bindings/${json['id']}',
          hub: a.hubDen.deviceId, hostname: 'den-b.test');
      expect((polled.json! as Map)['state'], 'waiting');
      expect(a.hub.accounts.sessionCount + b.hub.accounts.sessionCount, 0);
    });

    test('an address with no family gets the host\'s answer, before any sign-in', () async {
      final none = await Browser(host.base, hostname: 'den-c.test').go('GET', '/auth/oidc/google/start');
      expect(none.status, 404);
      expect(none.setCookies, isEmpty);
      expect(google.discoveryFetches, 0);
    });
  });
}

/// A personal device of [member], approved by the fixture's phone, holding what it holds.
Future<Den> _personalDevice(HubFixture f, String member, String name) => _device(f, name, DeviceMode.personal, member: member);

Future<Den> _device(HubFixture f, String name, DeviceMode mode, {String? member}) async {
  final d = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
  await d.requestJoin(
    familyId: f.phone.familyId!,
    founderPubkey: f.phone.founderPubkey!,
    deviceName: name,
    kind: mode == DeviceMode.shared ? DeviceKind.display : DeviceKind.phone,
    mode: mode,
    memberId: member,
  );
  await f.phone.ingest(d.changesSince(const {}));
  await f.phone.approveDevice(d.deviceId, member: member, mode: mode);
  await d.ingest(f.phone.changesSince(const {}));
  await f.toHub();
  return d;
}
