import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:den_hub/den_hub.dart';
import 'package:den_hub/src/push/web_push_crypto.dart' show VapidKeys, b64url, unb64url;

import 'oidc_keys.dart';
import 'tls.dart';

/// An RSA key pair for tests, as JWK numbers (base64url).
class RsaTestKey {
  /// The key with modulus [n], public exponent [e] and private exponent [d].
  const RsaTestKey({required this.n, required this.e, required this.d});
  final String n;
  final String e;
  final String d;

  BigInt _int(String text) {
    var v = BigInt.zero;
    for (final b in unb64url(text)) {
      v = (v << 8) | BigInt.from(b);
    }
    return v;
  }

  /// The public half, as the hub reads it.
  RsaPublicKey get public => RsaPublicKey.fromJwk(n, e);

  /// The JWK the provider publishes for it under [kid].
  Map<String, Object?> jwk(String kid) => {'kty': 'RSA', 'kid': kid, 'use': 'sig', 'alg': 'RS256', 'n': n, 'e': e};

  /// An RS256 signature over [message].
  List<int> sign(List<int> message) {
    final modulus = _int(n);
    final k = (modulus.bitLength + 7) ~/ 8;
    final em = pkcs1Sha256(message, k);
    var m = BigInt.zero;
    for (final b in em) {
      m = (m << 8) | BigInt.from(b);
    }
    var s = m.modPow(_int(d), modulus);
    final out = List<int>.filled(k, 0);
    for (var i = k - 1; i >= 0; i--) {
      out[i] = (s & BigInt.from(0xff)).toInt();
      s = s >> 8;
    }
    return out;
  }
}

/// A JWT with [header] and [claims], signed RS256 by [key] (or with [signature] as it is).
String signJwt(Map<String, Object?> header, Map<String, Object?> claims, RsaTestKey key, {List<int>? signature}) {
  final input = '${b64url(utf8.encode(jsonEncode(header)))}.${b64url(utf8.encode(jsonEncode(claims)))}';
  return '$input.${b64url(signature ?? key.sign(ascii.encode(input)))}';
}

/// What the person who signed in at the provider is, for one code.
class _Grant {
  _Grant({required this.redirectUri, required this.challenge, required this.nonce, required this.claims});
  final String redirectUri;
  final String challenge;
  final String nonce;
  final Map<String, Object?> claims;
  bool used = false;
}

/// A fake OpenID provider playing Google, or Apple ([apple]), over HTTPS on loopback at
/// `https://other.test:<port>` (support/tls.dart's certificate). It checks what a real one
/// checks at its token endpoint (the client and its secret, Apple's ES256 client secret, the
/// code used once, the redirect, PKCE) and signs ID tokens with RSA keys of its own, which it
/// publishes and rotates as told.
class FakeIdp {
  FakeIdp._(this._server, {required this.apple, required this.clientId, required this.clientSecret, required this.teamId, required this.keyId})
      : issuer = 'https://other.test:${_server.port}';

  /// Starts a provider; [apple] plays Apple.
  static Future<FakeIdp> start({
    bool apple = false,
    String clientId = 'den-client.apps.example',
    String clientSecret = 'den-google-secret',
    String teamId = 'TEAM123456',
    String keyId = 'KEY7654321',
  }) async {
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, serving(otherCert, otherKey));
    final idp = FakeIdp._(server, apple: apple, clientId: clientId, clientSecret: clientSecret, teamId: teamId, keyId: keyId);
    server.listen((r) => unawaited(idp._handle(r)));
    return idp;
  }

  final HttpServer _server;

  /// Whether it plays Apple: form posts, an ES256 client secret, booleans as text.
  final bool apple;

  /// The hub's client id here (Apple: its Services ID).
  final String clientId;

  /// Google's client secret.
  final String clientSecret;

  /// Apple: the team and the key the client secret must name.
  final String teamId;

  /// See [teamId].
  final String keyId;

  /// The key the client secret must be signed with (Apple).
  final VapidKeys appleKey = VapidKeys.fromPrivate(readP8(appleP8));

  /// Its issuer.
  final String issuer;

  /// [issuer] as an address, for [OidcProvider]'s `issuer`.
  Uri get issuerUri => Uri.parse(issuer);

  /// Its origin, where its page posts Apple's form from.
  String get origin => issuer;

  /// The keys its key set publishes, by key id.
  Map<String, RsaTestKey> published = {'k1': keyA};

  /// Which key signs ID tokens now.
  String signingKid = 'k1';

  /// See [signingKid].
  RsaTestKey signingKey = keyA;

  /// What the key set's answer says about caching it.
  String? keysCacheControl = 'public, max-age=3600';

  /// What discovery answers instead, when set.
  Map<String, Object?>? discovery;

  /// How long the token endpoint takes.
  Duration tokenDelay = Duration.zero;

  /// False: the client isn't one that may sign in on a website (Google's Desktop app client).
  bool webClient = true;

  /// The status the token endpoint answers with instead, when set (a provider in trouble).
  int? tokenStatus;

  /// What the token endpoint answers instead, as it is, when set: a page, a redirect, too many
  /// tries.
  ({int status, String body, String type})? tokenRaw;

  /// Changes each ID token's header and claims before it is signed.
  void Function(Map<String, Object?> header, Map<String, Object?> claims)? shape;

  /// Replaces each ID token altogether (forgeries), given what it would have held.
  String Function(Map<String, Object?> header, Map<String, Object?> claims)? forge;

  /// How many times each was asked.
  int discoveryFetches = 0, keyFetches = 0, tokenCalls = 0;

  /// Why the token endpoint refused, each time it did.
  final List<String> refusals = [];

  final Map<String, _Grant> _codes = {};

  /// The person signing in here: checks the authorization request the hub sent the browser to
  /// ([authorize], its `Location`) as a provider would, and returns the code it sends back. The
  /// person is [sub] with [email]; [verified] is `email_verified` ([apple] writes it as text).
  String signIn(Uri authorize, {required String sub, String email = 'alex@example.com', bool verified = true, Map<String, Object?> extra = const {}}) {
    final q = authorize.queryParameters;
    void need(bool ok, String what) {
      if (!ok) throw StateError('the hub\'s authorization request is wrong: $what');
    }

    need(authorize.toString().startsWith('$issuer/authorize'), 'not this provider');
    need(q['response_type'] == 'code', 'response_type');
    need(q['client_id'] == clientId, 'client_id');
    need((q['scope'] ?? '').split(' ').toSet().containsAll({'openid', 'email'}), 'scope');
    need(q['code_challenge_method'] == 'S256' && (q['code_challenge'] ?? '').length == 43, 'PKCE');
    need((q['state'] ?? '').length >= 43 && (q['nonce'] ?? '').length >= 43, 'state and nonce');
    need(apple ? q['response_mode'] == 'form_post' : !q.containsKey('response_mode'), 'response_mode');
    final redirect = q['redirect_uri']!;
    need(redirect.startsWith('https://') && redirect.endsWith('/auth/oidc/${apple ? 'apple' : 'google'}/callback'), 'redirect_uri');
    final code = randomToken(24);
    _codes[code] = _Grant(
      redirectUri: redirect,
      challenge: q['code_challenge']!,
      nonce: q['nonce']!,
      claims: {
        'sub': sub,
        'email': email,
        'email_verified': apple ? '$verified' : verified,
        if (apple) 'is_private_email': 'false',
        ...extra,
      },
    );
    return code;
  }

  Future<void> _handle(HttpRequest r) async {
    final response = r.response;
    Future<void> json(Object body, {int status = 200, Map<String, String> headers = const {}}) async {
      response.statusCode = status;
      response.headers.contentType = ContentType.json;
      headers.forEach(response.headers.set);
      response.write(jsonEncode(body));
      await response.close();
    }

    switch (r.uri.path) {
      case '/.well-known/openid-configuration':
        discoveryFetches++;
        return json(discovery ??
            {
              'issuer': issuer,
              'authorization_endpoint': '$issuer/authorize',
              'token_endpoint': '$issuer/token',
              'jwks_uri': '$issuer/keys',
              'response_types_supported': ['code'],
              'id_token_signing_alg_values_supported': ['RS256'],
              if (!apple) 'code_challenge_methods_supported': ['S256'],
            });
      case '/keys':
        keyFetches++;
        return json({
          'keys': [for (final e in published.entries) e.value.jwk(e.key)],
        }, headers: {'cache-control': ?keysCacheControl});
      case '/token':
        tokenCalls++;
        if (tokenDelay > Duration.zero) await Future<void>.delayed(tokenDelay);
        if (tokenStatus != null) return json({'error': 'server_error'}, status: tokenStatus!);
        final raw = tokenRaw;
        if (raw != null) {
          response.statusCode = raw.status;
          response.headers.contentType = ContentType.parse(raw.type);
          if (raw.status >= 300 && raw.status < 400) response.headers.set('location', 'https://elsewhere.test/');
          response.write(raw.body);
          await response.close();
          return;
        }
        final form = Uri.splitQueryString(await utf8.decoder.bind(r).join());
        final problem = _checkToken(form);
        if (problem != null) {
          refusals.add(problem);
          // As Google and Apple answer: a client (or its secret) they don't know is
          // `invalid_client`, a client that can't sign in on a website `unauthorized_client`, and
          // anything wrong with the code itself `invalid_grant`.
          final client = problem == 'client_id' || problem.startsWith('client_secret');
          if (webClient == false && !client) return json({'error': 'unauthorized_client'}, status: 400);
          return json({'error': client ? 'invalid_client' : 'invalid_grant', 'error_description': problem}, status: client ? 401 : 400);
        }
        final grant = _codes[form['code']]!..used = true;
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final header = <String, Object?>{'alg': 'RS256', 'kid': signingKid, 'typ': 'JWT'};
        final claims = <String, Object?>{
          'iss': issuer,
          'aud': clientId,
          'iat': now,
          'exp': now + 3600,
          'nonce': grant.nonce,
          ...grant.claims,
        };
        shape?.call(header, claims);
        final idToken = forge?.call(header, claims) ?? signJwt(header, claims, signingKey);
        return json({'access_token': randomToken(), 'token_type': 'Bearer', 'expires_in': 3600, 'id_token': idToken});
      default:
        response.statusCode = 404;
        await response.close();
    }
  }

  String? _checkToken(Map<String, String> form) {
    if (form['grant_type'] != 'authorization_code') return 'grant_type';
    if (form['client_id'] != clientId) return 'client_id';
    final secret = form['client_secret'] ?? '';
    final secretProblem = apple ? _appleSecret(secret) : (secret == clientSecret ? null : 'client_secret');
    if (secretProblem != null) return secretProblem;
    final grant = _codes[form['code']];
    if (grant == null) return 'unknown code';
    if (grant.used) return 'code used twice';
    if (form['redirect_uri'] != grant.redirectUri) return 'redirect_uri';
    final verifier = form['code_verifier'] ?? '';
    if (verifier.length < 43 || pkceChallenge(verifier) != grant.challenge) return 'PKCE';
    return null;
  }

  /// Checks Apple's client secret as Apple does: ES256 by the team's key, naming the key, from
  /// the team, for this Services ID, to this issuer, not expired.
  String? _appleSecret(String secret) {
    final parts = secret.split('.');
    if (parts.length != 3) return 'client_secret isn\'t a JWT';
    final header = jsonDecode(utf8.decode(unb64url(parts[0]))) as Map;
    final claims = jsonDecode(utf8.decode(unb64url(parts[1]))) as Map;
    if (header['alg'] != 'ES256' || header['kid'] != keyId) return 'client_secret header';
    if (!appleKey.verify(ascii.encode('${parts[0]}.${parts[1]}'), unb64url(parts[2]))) return 'client_secret signature';
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (claims['iss'] != teamId || claims['sub'] != clientId || claims['aud'] != issuer) return 'client_secret claims';
    final exp = claims['exp'], iat = claims['iat'];
    if (exp is! int || exp <= now || iat is! int || iat > now + 60 || exp - iat > 15777000) return 'client_secret times';
    return null;
  }

  /// Stops it.
  Future<void> stop() => _server.close(force: true);
}

/// A NetGuard client that finds `other.test` (the fake providers) on loopback, which only the
/// tests allow, and trusts only the tests' certificate authority: the hub's own fetching, as it
/// runs, pointed at the fakes.
NetGuard fakeProviderGuard({List<IpNetwork>? allow}) => NetGuard(
      resolve: (host) async => host == 'other.test' ? [InternetAddress.loopbackIPv4] : throw SocketException('no such host $host'),
      allow: allow ?? [IpNetwork.parse('127.0.0.0/8')],
      tls: trustingTestCa(),
    );
