@Timeout(Duration(seconds: 120))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:den_hub/den_hub.dart';
import 'package:den_hub/src/push/web_push_crypto.dart' show VapidKeys, b64url, unb64url;
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart' show HMac, KeyParameter, SHA256Digest;

import 'support/fake_idp.dart';
import 'support/oidc_keys.dart';
import 'support/test.dart';

/// The OpenID Connect checks on their own (oidc.dart): what makes an ID token count, the
/// provider's keys, Apple's client secret. Every provider is a local fake; nothing reaches Google
/// or Apple.
void main() {
  group('PKCE', () {
    test('S256 is RFC 7636\'s', () {
      expect(pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'), 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
    });

    test('verifiers, states and nonces are 256 random bits', () {
      final seen = {for (var i = 0; i < 50; i++) randomToken()};
      expect(seen, hasLength(50));
      expect(seen.every((t) => t.length == 43 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(t)), isTrue);
    });
  });

  group('RS256', () {
    test('a signature verifies with its key only, over its message only', () {
      final message = utf8.encode('header.claims');
      final sig = keyA.sign(message);
      expect(rsaVerifySha256(keyA.public, message, sig), isTrue);
      expect(rsaVerifySha256(keyB.public, message, sig), isFalse);
      expect(rsaVerifySha256(keyA.public, utf8.encode('header.claimz'), sig), isFalse);
      expect(rsaVerifySha256(keyA.public, message, sig.sublist(1)), isFalse, reason: 'a signature is as long as the key');
      expect(rsaVerifySha256(keyA.public, message, [0, ...sig]), isFalse);
      final flipped = [...sig]..[100] ^= 1;
      expect(rsaVerifySha256(keyA.public, message, flipped), isFalse);
    });

    test('a key set keeps only RSA signing keys of 2048 bits or more, and drops a key id used twice', () {
      final keys = parseJwks({
        'keys': [
          keyA.jwk('good'),
          {...keyB.jwk('enc'), 'use': 'enc'},
          {...keyB.jwk('ps'), 'alg': 'PS256'},
          {'kty': 'EC', 'kid': 'ec', 'crv': 'P-256', 'x': 'AA', 'y': 'AA'},
          {...keyB.jwk('small'), 'n': b64url(List.filled(128, 0xff))},
          keyA.jwk('twice'),
          keyB.jwk('twice'),
          {'kty': 'RSA', 'n': keyA.n, 'e': keyA.e},
          {...keyB.jwk('no-alg')}..remove('alg'),
        ],
      });
      expect(keys.keys.toSet(), {'good', 'no-alg'});
    });
  });

  group('Apple\'s client secret', () {
    test('reads the .p8 and signs ES256 for the Services ID, from the team, naming the key', () {
      final key = readP8(appleP8);
      final secret = appleClientSecret(
        teamId: 'TEAM123456',
        keyId: 'KEY7654321',
        servicesId: 'family.den.signin',
        audience: 'https://appleid.apple.com',
        key: key,
        nowSeconds: 1800000000,
      );
      final parts = secret.split('.');
      expect(jsonDecode(utf8.decode(unb64url(parts[0]))), {'alg': 'ES256', 'kid': 'KEY7654321', 'typ': 'JWT'});
      expect(jsonDecode(utf8.decode(unb64url(parts[1]))), {
        'iss': 'TEAM123456',
        'iat': 1800000000,
        'exp': 1800000300,
        'aud': 'https://appleid.apple.com',
        'sub': 'family.den.signin',
      });
      final signature = unb64url(parts[2]);
      expect(signature, hasLength(64), reason: 'JWS ES256 is r | s, not DER');
      expect(VapidKeys.fromPrivate(key).verify(ascii.encode('${parts[0]}.${parts[1]}'), signature), isTrue);
      expect(VapidKeys.fromPrivate(readP8(otherP8)).verify(ascii.encode('${parts[0]}.${parts[1]}'), signature), isFalse);
    });

    test('anything but a P-256 PKCS #8 key is refused', () {
      for (final bad in [
        '',
        'not a key',
        '-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----',
        appleP8.replaceAll('PRIVATE KEY', 'PUBLIC KEY'),
        // A PKCS #8 RSA key (openssl genpkey -algorithm RSA, cut short): not EC.
        '-----BEGIN PRIVATE KEY-----\nMIIBVQIBADANBgkqhkiG9w0BAQEFAASCAT8wggE7AgEAAkEA\n-----END PRIVATE KEY-----',
      ]) {
        expect(() => readP8(bad), throwsFormatException, reason: bad);
      }
    });
  });

  group('ID tokens, against a fake provider', () {
    late FakeIdp idp;
    late OidcProvider provider;
    late http.Client client;
    late int now;

    setUp(() async {
      idp = await FakeIdp.start();
      provider = OidcProvider.google(clientId: idp.clientId, clientSecret: idp.clientSecret, issuer: idp.issuerUri);
      client = fakeProviderGuard().client();
      now = DateTime.now().millisecondsSinceEpoch;
    });

    tearDown(() async {
      client.close();
      await idp.stop();
    });

    int s(int ms) => ms ~/ 1000;

    Map<String, Object?> claims({Map<String, Object?> also = const {}}) => {
          'iss': idp.issuer,
          'aud': idp.clientId,
          'sub': '108812345',
          'email': 'Alex@Example.com',
          'email_verified': true,
          'nonce': 'the-nonce',
          'iat': s(now),
          'exp': s(now) + 3600,
          ...also,
        };

    String token({Map<String, Object?> also = const {}, Map<String, Object?>? header, RsaTestKey key = keyA, Set<String> drop = const {}}) =>
        signJwt(header ?? {'alg': 'RS256', 'kid': 'k1'}, claims(also: also)..removeWhere((k, _) => drop.contains(k)), key);

    Future<OidcIdentity> verify(String t, {String nonce = 'the-nonce', int? at}) =>
        provider.verify(client, t, nonce: nonce, now: at ?? now);

    Matcher refused([OidcRefusal kind = OidcRefusal.invalid]) =>
        throwsA(isA<OidcRefused>().having((e) => e.kind, 'kind', kind));

    test('a good token gives the provider, the sub and the email, lowercase', () async {
      final who = await verify(token());
      expect(who.provider, googleProvider);
      expect(who.sub, '108812345');
      expect(who.email, 'alex@example.com');
    });

    test('iss must be exactly the issuer', () async {
      for (final iss in ['${idp.issuer}/', idp.issuer.toUpperCase(), 'https://other.test', '${idp.issuer}.evil', 'accounts.google.com']) {
        await expectLater(verify(token(also: {'iss': iss})), refused(), reason: iss);
      }
      await expectLater(verify(token(drop: {'iss'})), refused());
    });

    test('Google\'s own tokens may name either issuer Google documents, and nothing like them', () {
      final google = OidcProvider.google(clientId: 'c', clientSecret: 's');
      Map<String, Object?> c(String iss) => {
            'iss': iss, 'aud': 'c', 'sub': '1', 'email': 'a@b.c', 'email_verified': true, //
            'nonce': 'n', 'iat': s(now), 'exp': s(now) + 60,
          };
      expect(google.checkClaims(c('https://accounts.google.com'), nonce: 'n', now: now).sub, '1');
      expect(google.checkClaims(c('accounts.google.com'), nonce: 'n', now: now).sub, '1');
      for (final iss in ['https://accounts.google.com/', 'http://accounts.google.com', 'https://accounts.google.com.evil']) {
        expect(() => google.checkClaims(c(iss), nonce: 'n', now: now), throwsA(isA<OidcRefused>()), reason: iss);
      }
    });

    test('aud must be exactly this client, alone; azp, when there, too', () async {
      await expectLater(verify(token(also: {'aud': 'someone-else'})), refused());
      await expectLater(verify(token(also: {'aud': '${idp.clientId}x'})), refused());
      await expectLater(verify(token(also: {'aud': [idp.clientId, 'another-app']})), refused());
      await expectLater(verify(token(also: {'aud': <String>[]})), refused());
      await expectLater(verify(token(drop: {'aud'})), refused());
      expect((await verify(token(also: {'aud': [idp.clientId]}))).sub, '108812345');
      expect((await verify(token(also: {'azp': idp.clientId}))).sub, '108812345');
      await expectLater(verify(token(also: {'azp': 'another-app'})), refused());
    });

    test('exp, iat and nbf hold within a minute of skew', () async {
      expect((await verify(token(also: {'exp': s(now) - 30}))).sub, isNotEmpty, reason: 'within the skew');
      await expectLater(verify(token(also: {'exp': s(now) - 61})), refused());
      await expectLater(verify(token(drop: {'exp'})), refused());
      await expectLater(verify(token(also: {'exp': '${s(now) + 60}'})), refused());
      await expectLater(verify(token(also: {'iat': s(now) + 120})), refused(), reason: 'issued in the future');
      await expectLater(verify(token(also: {'iat': s(now) - 3600})), refused(), reason: 'issued an hour ago');
      await expectLater(verify(token(drop: {'iat'})), refused());
      await expectLater(verify(token(also: {'nbf': s(now) + 120})), refused());
      expect((await verify(token(also: {'nbf': s(now) + 30}))).sub, isNotEmpty);
    });

    test('the nonce must be this sign-in\'s', () async {
      await expectLater(verify(token(), nonce: 'another-sign-in'), refused());
      await expectLater(verify(token(drop: {'nonce'})), refused());
      await expectLater(verify(token(also: {'nonce': 'the-nonc'})), refused());
    });

    test('a forged token is refused: another key, an unknown key id, a tampered body', () async {
      await expectLater(verify(token(key: keyX)), refused(), reason: 'signed by another key under the provider\'s key id');
      await expectLater(verify(token(header: {'alg': 'RS256', 'kid': 'x'}, key: keyX)), refused());
      final good = token().split('.');
      final tampered = '${good[0]}.${b64url(utf8.encode(jsonEncode(claims(also: {'sub': 'someone-else'}))))}.${good[2]}';
      await expectLater(verify(tampered), refused());
      await expectLater(verify('${good[0]}.${good[1]}'), refused(), reason: 'no signature part');
      await expectLater(verify('not a jwt'), refused());
    });

    test('alg none and HS256 with the public key as its secret are refused before any key is used', () async {
      final body = b64url(utf8.encode(jsonEncode(claims())));
      final none = '${b64url(utf8.encode(jsonEncode({'alg': 'none', 'kid': 'k1'})))}.$body.';
      await expectLater(verify(none), refused());
      final noneSigned = '${b64url(utf8.encode(jsonEncode({'alg': 'none', 'kid': 'k1'})))}.$body.${b64url([1])}';
      await expectLater(verify(noneSigned), refused());
      // The classic confusion: HMAC-SHA256 keyed by the bytes of the RSA public key (its JWK,
      // and its modulus), which an attacker has.
      for (final secret in [utf8.encode(jsonEncode(keyA.jwk('k1'))), unb64url(keyA.n)]) {
        final header = b64url(utf8.encode(jsonEncode({'alg': 'HS256', 'kid': 'k1'})));
        final mac = (HMac(SHA256Digest(), 64)..init(KeyParameter(Uint8List.fromList(secret)))).process(ascii.encode('$header.$body'));
        await expectLater(verify('$header.$body.${b64url(mac)}'), refused());
      }
      await expectLater(verify(token(header: {'alg': 'RS512', 'kid': 'k1'})), refused());
      await expectLater(verify(token(header: {'kid': 'k1'})), refused(), reason: 'no alg');
      await expectLater(verify(token(header: {'alg': 'RS256', 'kid': 'k1', 'crit': ['exp']})), refused());
      await expectLater(verify(token(header: {'alg': 'RS256'})), refused(), reason: 'no key id');
      expect(idp.keyFetches, 0, reason: 'none of these got as far as the keys');
    });

    test('an email that isn\'t verified, or none, is refused', () async {
      for (final v in [false, 'false', null, 1, 'yes']) {
        await expectLater(verify(token(also: {'email_verified': v})), refused(OidcRefusal.unverifiedEmail), reason: '$v');
      }
      await expectLater(verify(token(drop: {'email'})), refused(OidcRefusal.unverifiedEmail));
      await expectLater(verify(token(also: {'email': 'not-an-email'})), refused(OidcRefusal.unverifiedEmail));
    });

    test('Apple\'s Hide My Email relay addresses are refused, verified or not', () async {
      final apple = OidcProvider.apple(
        servicesId: idp.clientId,
        key: AppleKey(teamId: idp.teamId, keyId: idp.keyId, privateKey: readP8(appleP8)),
        issuer: idp.issuerUri,
      );
      Future<OidcIdentity> check(Map<String, Object?> also) => apple.verify(client, token(also: also), nonce: 'the-nonce', now: now);
      for (final email in ['x7k2@privaterelay.appleid.com', 'X7K2@PrivateRelay.AppleID.com', 'a@b.privaterelay.appleid.com']) {
        await expectLater(check({'email': email, 'email_verified': 'true'}), refused(OidcRefusal.relayEmail), reason: email);
      }
      await expectLater(check({'email': 'alex@example.com', 'email_verified': 'true', 'is_private_email': 'true'}),
          refused(OidcRefusal.relayEmail));
      final who = await check({'email': 'alex@icloud.com', 'email_verified': 'true', 'is_private_email': 'false'});
      expect((who.provider, who.email), (appleProvider, 'alex@icloud.com'));
    });

    test('keys are fetched once and kept; discovery too', () async {
      for (var i = 0; i < 5; i++) {
        await verify(token());
      }
      expect(idp.keyFetches, 1);
      expect(idp.discoveryFetches, 1);
    });

    test('a rotated key is fetched when a token names it; a made-up key id can\'t make the hub hammer the provider', () async {
      await verify(token());
      expect(idp.keyFetches, 1);
      // The provider rotates: k2 signs now, k1 is still published for a while.
      idp
        ..published = {'k1': keyA, 'k2': keyB}
        ..signingKid = 'k2'
        ..signingKey = keyB;
      final rotated = token(header: {'alg': 'RS256', 'kid': 'k2'}, key: keyB);
      expect((await verify(rotated, at: now + 1000)).sub, '108812345');
      expect(idp.keyFetches, 2);
      // Made-up key ids right after: refused, and no fetch until the gap has passed.
      for (var i = 0; i < 10; i++) {
        await expectLater(verify(token(header: {'alg': 'RS256', 'kid': 'made-up-$i'}, key: keyX), at: now + 2000), refused());
      }
      expect(idp.keyFetches, 2);
      await expectLater(
          verify(token(header: {'alg': 'RS256', 'kid': 'made-up'}, key: keyX), at: now + 1000 + OidcProvider.refetchGap.inMilliseconds),
          refused());
      expect(idp.keyFetches, 3);
      // k1 retired: once the set is fetched again, tokens it signs no longer count.
      idp.published = {'k2': keyB};
      final later = now + const Duration(hours: 2).inMilliseconds;
      await expectLater(provider.verify(client, token(also: {'iat': s(later), 'exp': s(later) + 60}), nonce: 'the-nonce', now: later), refused());
      expect(idp.keyFetches, 4);
    });

    test('the key set is kept as long as its Cache-Control says, within bounds', () async {
      idp.keysCacheControl = 'max-age=300';
      await verify(token());
      final fresh = now + 299 * 1000;
      await provider.verify(client, token(also: {'iat': s(fresh), 'exp': s(fresh) + 60}), nonce: 'the-nonce', now: fresh);
      expect(idp.keyFetches, 1);
      final stale = now + 301 * 1000;
      await provider.verify(client, token(also: {'iat': s(stale), 'exp': s(stale) + 60}), nonce: 'the-nonce', now: stale);
      expect(idp.keyFetches, 2);
      idp.keysCacheControl = 'max-age=1';
      final soon = stale + 2000;
      await provider.verify(client, token(also: {'iat': s(soon), 'exp': s(soon) + 60}), nonce: 'the-nonce', now: soon);
      expect(idp.keyFetches, 2, reason: 'never kept for less than 5 minutes');
    });

    test('a provider that stops answering: kept keys serve a while, unknown ones fail closed', () async {
      await verify(token());
      await idp.stop();
      final later = now + const Duration(hours: 2).inMilliseconds;
      final who = await provider.verify(client, token(also: {'iat': s(later), 'exp': s(later) + 60}), nonce: 'the-nonce', now: later);
      expect(who.sub, '108812345');
      await expectLater(
          provider.verify(client, token(header: {'alg': 'RS256', 'kid': 'k9'}, key: keyX), nonce: 'the-nonce', now: later + 60000),
          refused());
      final muchLater = now + const Duration(days: 3).inMilliseconds;
      await expectLater(
          provider.verify(client, token(also: {'iat': s(muchLater), 'exp': s(muchLater) + 60}), nonce: 'the-nonce', now: muchLater),
          refused(OidcRefusal.unavailable));
    });

    test('discovery that names another issuer, or plain http endpoints, is refused', () async {
      idp.discovery = {
        'issuer': 'https://accounts.google.com',
        'authorization_endpoint': '${idp.issuer}/authorize',
        'token_endpoint': '${idp.issuer}/token',
        'jwks_uri': '${idp.issuer}/keys',
      };
      await expectLater(provider.endpoints(client, now), refused(OidcRefusal.unavailable));
      idp.discovery = {
        'issuer': idp.issuer,
        'authorization_endpoint': '${idp.issuer}/authorize',
        'token_endpoint': '${idp.issuer}/token',
        'jwks_uri': 'http://other.test:${idp.issuerUri.port}/keys',
      };
      await expectLater(provider.endpoints(client, now), refused(OidcRefusal.unavailable));
    });

    test('a discovery that failed is remembered for a while, not asked again at once (finding F7)', () async {
      idp.discovery = {'issuer': 'https://accounts.google.com'};
      await expectLater(provider.endpoints(client, now), refused(OidcRefusal.unavailable));
      for (var i = 0; i < 5; i++) {
        await expectLater(provider.endpoints(client, now + i * 1000), refused(OidcRefusal.unavailable));
      }
      expect(idp.discoveryFetches, 1);
      idp.discovery = null;
      final later = now + OidcProvider.discoveryRetry.inMilliseconds + 1;
      expect((await provider.endpoints(client, later)).token.path, '/token');
      expect(idp.discoveryFetches, 2);
    });

    test('everything goes through NetGuard: a key set on the hub\'s own network is never fetched', () async {
      // The provider's document points its keys at the cloud metadata address.
      idp.discovery = {
        'issuer': idp.issuer,
        'authorization_endpoint': '${idp.issuer}/authorize',
        'token_endpoint': '${idp.issuer}/token',
        'jwks_uri': 'https://169.254.169.254/keys',
      };
      await expectLater(verify(token()), refused(OidcRefusal.unavailable));
      // And a guard that doesn't let the tests' loopback in reaches no provider at all.
      final strict = fakeProviderGuard(allow: const []).client();
      addTearDown(strict.close);
      final another = OidcProvider.google(clientId: idp.clientId, clientSecret: idp.clientSecret, issuer: idp.issuerUri);
      await expectLater(another.endpoints(strict, now), refused(OidcRefusal.unavailable));
      expect(idp.discoveryFetches, 1);
    });

    test('the token endpoint\'s refusal is a refusal', () async {
      await expectLater(provider.exchange(client, code: 'nope', verifier: randomToken(), redirectUri: 'https://den.test/x', now: now),
          refused());
      expect(idp.refusals, ['unknown code']);
    });
  });

  group('checking a client', () {
    late FakeIdp google;
    late FakeIdp apple;
    late http.Client client;
    final now = DateTime.now().millisecondsSinceEpoch;
    const back = 'https://den.test/auth/oidc/google/callback';

    setUp(() async {
      google = await FakeIdp.start();
      apple = await FakeIdp.start(apple: true, clientId: 'family.den.signin');
      client = fakeProviderGuard().client();
    });

    tearDown(() async {
      client.close();
      await google.stop();
      await apple.stop();
    });

    OidcProvider googleWith(String id, String secret) => OidcProvider.google(clientId: id, clientSecret: secret, issuer: google.issuerUri);
    OidcProvider appleWith(String key, {String? team}) => OidcProvider.apple(
          servicesId: apple.clientId,
          key: AppleKey(teamId: team ?? apple.teamId, keyId: apple.keyId, privateKey: readP8(key)),
          issuer: apple.issuerUri,
        );

    test('the token endpoint knows the client and its secret, and nothing else is taken for it', () async {
      expect(await googleWith(google.clientId, google.clientSecret).checkClient(client, redirectUri: back, now: now), ClientCheck.known);
      expect(await googleWith('someone-else', google.clientSecret).checkClient(client, redirectUri: back, now: now), ClientCheck.unknown);
      expect(await googleWith(google.clientId, 'wrong').checkClient(client, redirectUri: back, now: now), ClientCheck.unknown);
      expect(google.refusals, ['unknown code', 'client_id', 'client_secret'], reason: 'a made-up code, never a sign-in');
      google.webClient = false;
      expect(await googleWith(google.clientId, google.clientSecret).checkClient(client, redirectUri: back, now: now), ClientCheck.wrongKind);
    });

    test("Apple's: the Services ID, the team and the key together", () async {
      expect(await appleWith(appleP8).checkClient(client, redirectUri: back, now: now), ClientCheck.known);
      expect(await appleWith(otherP8).checkClient(client, redirectUri: back, now: now), ClientCheck.unknown);
      expect(await appleWith(appleP8, team: 'OTHER12345').checkClient(client, redirectUri: back, now: now), ClientCheck.unknown);
    });

    test('only a 400 invalid_grant confirms the client: a page, a redirect, too many tries or a stray error confirm nothing', () async {
      final p = googleWith(google.clientId, google.clientSecret);
      for (final raw in [
        (status: 302, body: '', type: 'text/html'),
        (status: 200, body: '{"id_token": "x"}', type: 'application/json'),
        (status: 400, body: '<html>Bad request</html>', type: 'text/html'),
        (status: 400, body: '{"error": "redirect_uri_mismatch"}', type: 'application/json'),
        (status: 429, body: '{"error": "rate_limit_exceeded"}', type: 'application/json'),
        (status: 401, body: '{"error": "invalid_grant"}', type: 'application/json'),
      ]) {
        google.tokenRaw = raw;
        expect(await p.checkClient(client, redirectUri: back, now: now), ClientCheck.unconfirmed, reason: '$raw');
      }
      google.tokenRaw = null;
      expect(await p.checkClient(client, redirectUri: back, now: now), ClientCheck.known);
    });

    test('a provider in trouble is a refusal of its own, not an answer about the client', () async {
      google.tokenStatus = 503;
      await expectLater(googleWith(google.clientId, google.clientSecret).checkClient(client, redirectUri: back, now: now),
          throwsA(isA<OidcRefused>().having((e) => e.kind, 'kind', OidcRefusal.unavailable)));
    });
  });
}
