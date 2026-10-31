/// Sign-in with Google and Apple: the OpenID Connect side of the hub's accounts
/// (accounts.dart, ARCHITECTURE.md "Accounts").
///
/// The hub is the relying party. It finds each provider's endpoints by discovery, sends the
/// browser there with `state`, a `nonce` and PKCE (S256), exchanges the code at the token
/// endpoint itself (Apple's client secret is an ES256 JWT the hub signs with the `.p8` key),
/// and believes the ID token only when:
///
/// - it is RS256, signed by a key in the provider's published set (fetched through [NetGuard],
///   cached, fetched again when an unknown key id appears, no more than once a
///   [OidcProvider.refetchGap]): `none`, HS256 and every other `alg` are refused before any key is
///   looked at, so a public key can't be used as an HMAC secret;
/// - `iss` is exactly the provider's issuer, `aud` is exactly the hub's client id (one audience,
///   and `azp`, if any, the same), `exp`, `iat` and `nbf` hold within [OidcProvider.skew], and
///   `nonce` is the one this sign-in sent;
/// - the email is there and verified, and isn't one of Apple's Hide My Email relay addresses.
///
/// What it gives back is the provider and the `sub`; the email only so a parent can see which
/// account they bound. Binding is on `sub` alone.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, FileSystemException, Platform;
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:http/http.dart' as http;

import 'push/web_push_crypto.dart' show VapidKeys, b64url, unb64url;

/// The provider ids, in the hub's routes and in `member.account`.
const String googleProvider = 'google';

/// See [googleProvider].
const String appleProvider = 'apple';

/// The domain of Apple's Hide My Email relay addresses, which are refused: a family invites
/// someone by their real address (docs/auth/ACCOUNT_FIRST_REVIEW.md, decision 2).
const String appleRelayDomain = 'privaterelay.appleid.com';

/// What kind of refusal: the account's email (which the person can fix), the provider being
/// unreachable, or anything else (which they can't, and which says nothing more).
enum OidcRefusal {
  /// The token, the code or the answer didn't check out.
  invalid,

  /// The provider couldn't be reached, or answered nonsense.
  unavailable,

  /// The account has no email, or hasn't verified it.
  unverifiedEmail,

  /// Apple's Hide My Email relay address.
  relayEmail,
}

/// A sign-in the hub refused. [reason] is for the log: never a token, a code, a claim's value
/// or an email.
class OidcRefused implements Exception {
  /// A refusal of [kind], for [reason].
  const OidcRefused(this.reason, {this.kind = OidcRefusal.invalid});

  /// Why, in a few words for the log.
  final String reason;

  /// Which kind.
  final OidcRefusal kind;

  @override
  String toString() => 'OidcRefused(${kind.name}: $reason)';
}

/// Who signed in: the provider, their subject (the provider's lasting id for them, which is what
/// binds), and their verified email (shown, never matched).
class OidcIdentity {
  /// An identity.
  const OidcIdentity({required this.provider, required this.sub, required this.email});

  /// [googleProvider] or [appleProvider].
  final String provider;

  /// The `sub` claim.
  final String sub;

  /// The verified email, lowercase.
  final String email;
}

/// A provider's endpoints, from its discovery document.
class OidcEndpoints {
  /// Endpoints.
  const OidcEndpoints({required this.authorization, required this.token, required this.jwks});

  /// Where the browser signs in.
  final Uri authorization;

  /// Where the hub exchanges a code.
  final Uri token;

  /// The provider's signing keys.
  final Uri jwks;
}

/// An RSA public key from a JWK set.
class RsaPublicKey {
  /// The key with modulus [n] and exponent [e].
  RsaPublicKey(this.n, this.e) : length = (n.bitLength + 7) ~/ 8;

  /// From the base64url `n` and `e` of a JWK; throws [FormatException].
  factory RsaPublicKey.fromJwk(String n, String e) => RsaPublicKey(_unsigned(unb64url(n)), _unsigned(unb64url(e)));

  /// The modulus.
  final BigInt n;

  /// The public exponent.
  final BigInt e;

  /// The modulus's length in bytes, which every signature has.
  final int length;
}

/// The DER `DigestInfo` prefix for SHA-256 (RFC 8017, 9.2 note 1).
const List<int> _sha256DigestInfo = [
  0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20, //
];

BigInt _unsigned(List<int> bytes) {
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b);
  }
  return v;
}

Uint8List _fixed(BigInt value, int length) {
  final out = Uint8List(length);
  var v = value;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  return out;
}

/// EMSA-PKCS1-v1_5 of [message] with SHA-256, [k] bytes long (RFC 8017, 9.2).
Uint8List pkcs1Sha256(List<int> message, int k) {
  final hash = const DartSha256().hashSync(message).bytes;
  final t = [..._sha256DigestInfo, ...hash];
  if (k < t.length + 11) throw ArgumentError('the key is too short');
  return Uint8List.fromList([0, 1, ...List.filled(k - t.length - 3, 0xff), 0, ...t]);
}

/// Whether [signature] is [key]'s RSASSA-PKCS1-v1_5 SHA-256 signature over [message] (RS256),
/// checked the way RFC 8017 (8.2.2) prefers: the expected encoding is built in full and compared
/// byte for byte, so nothing is parsed out of what the signature decrypts to.
bool rsaVerifySha256(RsaPublicKey key, List<int> message, List<int> signature) {
  if (signature.length != key.length) return false;
  final s = _unsigned(signature);
  if (s >= key.n) return false;
  final em = _fixed(s.modPow(key.e, key.n), key.length);
  return bytesEqual(em, pkcs1Sha256(message, key.length));
}

/// Whether [a] and [b] are the same bytes, in time that depends only on their length.
bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Whether [a] and [b] are the same text, in time that depends only on their length.
bool textEqual(String a, String b) => bytesEqual(utf8.encode(a), utf8.encode(b));

/// The usable keys of a JWK set (RFC 7517) by key id: RSA, for signing, RS256 if it says, at
/// least 2048 bits, an odd exponent of 3 or more. Anything else in the set is left out; a key id
/// that appears twice is left out altogether, so which key it means is never a guess.
Map<String, RsaPublicKey> parseJwks(Object? json) {
  final keys = json is Map ? json['keys'] : null;
  if (keys is! List) throw const OidcRefused('the key set has no keys', kind: OidcRefusal.unavailable);
  final found = <String, RsaPublicKey>{};
  final twice = <String>{};
  for (final k in keys) {
    if (k is! Map) continue;
    final kid = k['kid'], kty = k['kty'], alg = k['alg'], use = k['use'], n = k['n'], e = k['e'];
    if (kid is! String || kid.isEmpty || kty != 'RSA' || n is! String || e is! String) continue;
    if (alg != null && alg != 'RS256') continue;
    if (use != null && use != 'sig') continue;
    final RsaPublicKey key;
    try {
      key = RsaPublicKey.fromJwk(n, e);
    } on FormatException {
      continue;
    }
    if (key.n.bitLength < 2048 || key.n.bitLength > 8192 || key.e < BigInt.from(3) || key.e.isEven || key.e.bitLength > 32) {
      continue;
    }
    if (found.containsKey(kid) || twice.contains(kid)) {
      found.remove(kid);
      twice.add(kid);
      continue;
    }
    found[kid] = key;
  }
  return found;
}

/// A compact JWS, split and decoded, not yet checked.
class Jwt {
  Jwt._(this.header, this.claims, this.signingInput, this.signature);

  /// Splits [token]; throws [OidcRefused] for anything that isn't three base64url parts with
  /// JSON objects in the first two.
  factory Jwt.parse(String token) {
    if (token.length > 16 * 1024) throw const OidcRefused('the token is too long');
    final parts = token.split('.');
    if (parts.length != 3 || parts.any((p) => p.isEmpty || !_b64url.hasMatch(p))) {
      throw const OidcRefused('the token isn\'t a signed JWT');
    }
    try {
      final header = jsonDecode(utf8.decode(unb64url(parts[0])));
      final claims = jsonDecode(utf8.decode(unb64url(parts[1])));
      if (header is! Map || claims is! Map) throw const FormatException('not objects');
      return Jwt._(header.cast<String, Object?>(), claims.cast<String, Object?>(), ascii.encode('${parts[0]}.${parts[1]}'),
          unb64url(parts[2]));
    } on FormatException {
      throw const OidcRefused('the token isn\'t a signed JWT');
    }
  }

  static final RegExp _b64url = RegExp(r'^[A-Za-z0-9_-]+$');

  /// The JOSE header.
  final Map<String, Object?> header;

  /// The claims.
  final Map<String, Object?> claims;

  /// What the signature covers: the first two parts as sent.
  final Uint8List signingInput;

  /// The signature's bytes.
  final Uint8List signature;
}

/// A new random value for `state`, a `nonce`, a PKCE verifier or a cookie: [bytes] random
/// bytes in base64url (32 bytes make the 43 characters PKCE asks for at least).
String randomToken([int bytes = 32]) => b64url(List.generate(bytes, (_) => _random.nextInt(256)));

final Random _random = Random.secure();

/// The PKCE S256 challenge for [verifier] (RFC 7636, 4.2).
String pkceChallenge(String verifier) => b64url(const DartSha256().hashSync(ascii.encode(verifier)).bytes);

/// The private key of a `.p8` file Apple gives for Sign in with Apple: PKCS #8 PEM holding a
/// P-256 key. Returns its 32 bytes; throws [FormatException] for anything else.
Uint8List readP8(String pem) {
  final body = pem
      .replaceAll(RegExp(r'-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----'), '')
      .replaceAll(RegExp(r'\s'), '');
  if (!pem.contains('-----BEGIN PRIVATE KEY-----') || body.isEmpty) {
    throw const FormatException('It isn\'t a .p8 key (PEM "PRIVATE KEY")');
  }
  final Uint8List der;
  try {
    der = base64.decode(body);
  } on FormatException {
    throw const FormatException('It isn\'t a .p8 key (its base64 doesn\'t read)');
  }
  final info = _Der(der).sequence();
  if (info.integer() != 0) throw const FormatException('It isn\'t a PKCS #8 key');
  final algorithm = info.sequence();
  final kind = algorithm.oid();
  final curve = algorithm.oid();
  if (!bytesEqual(kind, _ecPublicKey) || !bytesEqual(curve, _prime256v1)) {
    throw const FormatException('It isn\'t a P-256 key, which Apple\'s keys are');
  }
  final ec = _Der(info.octets()).sequence();
  if (ec.integer() != 1) throw const FormatException('It isn\'t an EC private key');
  final d = ec.octets();
  if (d.length != 32) throw const FormatException('It isn\'t a P-256 key, which Apple\'s keys are');
  try {
    VapidKeys.fromPrivate(d);
  } on ArgumentError {
    throw const FormatException('It isn\'t a P-256 key, which Apple\'s keys are');
  }
  return d;
}

const List<int> _ecPublicKey = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01];
const List<int> _prime256v1 = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07];

/// Just enough DER to read a PKCS #8 EC key.
class _Der {
  _Der(this._bytes);
  final Uint8List _bytes;
  int _at = 0;

  Uint8List _take(int tag) {
    if (_at + 2 > _bytes.length || _bytes[_at] != tag) throw const FormatException('It isn\'t a .p8 key');
    _at++;
    var length = _bytes[_at++];
    if (length & 0x80 != 0) {
      final n = length & 0x7f;
      if (n == 0 || n > 2 || _at + n > _bytes.length) throw const FormatException('It isn\'t a .p8 key');
      length = 0;
      for (var i = 0; i < n; i++) {
        length = (length << 8) | _bytes[_at++];
      }
    }
    if (_at + length > _bytes.length) throw const FormatException('It isn\'t a .p8 key');
    final out = Uint8List.sublistView(_bytes, _at, _at + length);
    _at += length;
    return out;
  }

  _Der sequence() => _Der(_take(0x30));
  int integer() {
    final v = _take(0x02);
    return v.length == 1 ? v[0] : -1;
  }

  Uint8List oid() => _take(0x06);
  Uint8List octets() => _take(0x04);
}

/// Apple's client secret: a JWT the hub signs with ES256 using the key from Apple ([key], the
/// `.p8`), naming the key ([keyId]), the team ([teamId]) and the Services ID ([servicesId]) it
/// is for, addressed to [audience] (`https://appleid.apple.com`), good for [life] from
/// [nowSeconds] (Apple takes up to six months; the hub makes one per sign-in).
String appleClientSecret({
  required String teamId,
  required String keyId,
  required String servicesId,
  required String audience,
  required List<int> key,
  required int nowSeconds,
  Duration life = const Duration(minutes: 5),
}) {
  final header = b64url(utf8.encode(jsonEncode({'alg': 'ES256', 'kid': keyId, 'typ': 'JWT'})));
  final claims = b64url(utf8.encode(jsonEncode({
    'iss': teamId,
    'iat': nowSeconds,
    'exp': nowSeconds + life.inSeconds,
    'aud': audience,
    'sub': servicesId,
  })));
  final input = '$header.$claims';
  return '$input.${b64url(VapidKeys.fromPrivate(key).sign(ascii.encode(input)))}';
}

/// What signs the hub in at Apple: the team, the key's id and the key's 32 bytes.
class AppleKey {
  /// The key [keyId] of [teamId], whose private half is [privateKey].
  AppleKey({required this.teamId, required this.keyId, required List<int> privateKey})
      : privateKey = Uint8List.fromList(privateKey);

  /// The Apple Developer team id.
  final String teamId;

  /// The key's id.
  final String keyId;

  /// The key's 32 bytes.
  final Uint8List privateKey;
}

/// One provider the hub signs people in with: Google or Apple. It keeps the provider's
/// discovery document and signing keys, fetched through the hub's [NetGuard] client and cached.
class OidcProvider {
  OidcProvider._({
    required this.id,
    required this.name,
    required this.issuer,
    required Set<String> issuers,
    required this.clientId,
    required this.formPost,
    String? clientSecret,
    AppleKey? apple,
  })  : issuers = Set.unmodifiable(issuers),
        _clientSecret = clientSecret,
        _apple = apple;

  /// Google, with the OAuth client the owner made in Google Cloud (`DEN_GOOGLE_CLIENT_ID`,
  /// `DEN_GOOGLE_CLIENT_SECRET`). [issuer] is for tests (a fake provider); Google's own ID
  /// tokens name either of the two issuers Google documents, compared exactly.
  factory OidcProvider.google({required String clientId, required String clientSecret, Uri? issuer}) {
    final iss = issuer == null ? 'https://accounts.google.com' : _issuer(issuer);
    return OidcProvider._(
      id: googleProvider,
      name: 'Google',
      issuer: iss,
      issuers: issuer == null ? const {'https://accounts.google.com', 'accounts.google.com'} : {iss},
      clientId: clientId,
      clientSecret: clientSecret,
      formPost: false,
    );
  }

  /// Apple, with the Services ID (`DEN_APPLE_SERVICES_ID`, the client id) and the key
  /// (`DEN_APPLE_TEAM_ID`, `DEN_APPLE_KEY_ID`, `DEN_APPLE_KEY_FILE`). Apple answers by posting
  /// a form to the hub (`response_mode=form_post`). [issuer] is for tests.
  factory OidcProvider.apple({required String servicesId, required AppleKey key, Uri? issuer}) {
    final iss = issuer == null ? 'https://appleid.apple.com' : _issuer(issuer);
    return OidcProvider._(
      id: appleProvider,
      name: 'Apple',
      issuer: iss,
      issuers: {iss},
      clientId: servicesId,
      apple: key,
      formPost: true,
    );
  }

  static String _issuer(Uri uri) {
    final text = uri.toString();
    return text.endsWith('/') ? text.substring(0, text.length - 1) : text;
  }

  /// [googleProvider] or [appleProvider].
  final String id;

  /// "Google" or "Apple", for people.
  final String name;

  /// The issuer: where discovery is, and what its document must say it is.
  final String issuer;

  /// The `iss` values its ID tokens may carry, compared exactly.
  final Set<String> issuers;

  /// The hub's client id there: what `aud` must be.
  final String clientId;

  /// Whether the provider answers by posting a form (Apple).
  final bool formPost;

  final String? _clientSecret;
  final AppleKey? _apple;

  /// How far the provider's clock and the hub's may disagree.
  static const Duration skew = Duration(seconds: 60);

  /// How old an ID token may be when the hub gets it (it gets it straight from the token
  /// endpoint, so a fresh one).
  static const Duration maxTokenAge = Duration(minutes: 10);

  /// How long a discovery document is kept.
  static const Duration discoveryLife = Duration(hours: 24);

  /// How long a kept document or key set still serves when the provider can't be reached.
  static const Duration staleLife = Duration(days: 2);

  /// How long a key set is kept when the provider doesn't say (`Cache-Control: max-age`, which
  /// counts between 5 minutes and a day).
  static const Duration keysLife = Duration(hours: 1);

  /// Most often an unknown key id makes the hub fetch the key set again: a token naming a key
  /// that doesn't exist can't make the hub hammer the provider.
  static const Duration refetchGap = Duration(seconds: 30);

  /// How long a fetch from the provider may take.
  static const Duration fetchTimeout = Duration(seconds: 10);

  /// Largest answer read from the provider.
  static const int maxAnswer = 256 * 1024;

  OidcEndpoints? _endpoints;
  int _endpointsAt = 0;
  Future<OidcEndpoints>? _discovering;
  OidcRefused? _discoveryFailure;
  int _discoveryFailedAt = 0;

  /// How long a failed discovery is remembered before the hub asks again: sign-ins started
  /// meanwhile fail at once instead of each waiting on, and adding to, a provider in trouble.
  static const Duration discoveryRetry = Duration(seconds: 45);

  Map<String, RsaPublicKey> _keys = const {};
  int _keysAt = 0;
  int _keysFor = keysLife.inMilliseconds;
  int? _refetched;
  Future<void>? _fetchingKeys;

  /// How many times the key set was fetched (tests).
  int keyFetches = 0;

  /// How many times the discovery document was fetched (tests).
  int discoveryFetches = 0;

  /// The provider's endpoints at [now] (UTC milliseconds): kept for [discoveryLife], fetched
  /// through [client] otherwise. A document whose `issuer` isn't exactly [issuer], or whose
  /// endpoints aren't `https`, is refused. Throws [OidcRefused].
  Future<OidcEndpoints> endpoints(http.Client client, int now) async {
    final kept = _endpoints;
    if (kept != null && now - _endpointsAt < discoveryLife.inMilliseconds) return kept;
    final failed = _discoveryFailure;
    final recent = failed != null && now - _discoveryFailedAt < discoveryRetry.inMilliseconds;
    if (recent) {
      if (kept != null && now - _endpointsAt < staleLife.inMilliseconds) return kept;
      throw failed;
    }
    try {
      final found = await (_discovering ??= _discover(client).whenComplete(() => _discovering = null));
      _endpoints = found;
      _endpointsAt = now;
      _discoveryFailure = null;
      return found;
    } on OidcRefused catch (e) {
      _discoveryFailure = e;
      _discoveryFailedAt = now;
      if (kept != null && now - _endpointsAt < staleLife.inMilliseconds) return kept;
      rethrow;
    }
  }

  Future<OidcEndpoints> _discover(http.Client client) async {
    discoveryFetches++;
    final answer = await _getJson(client, Uri.parse('$issuer/.well-known/openid-configuration'));
    final json = answer.json;
    if (json['issuer'] != issuer) throw const OidcRefused('the discovery document names another issuer', kind: OidcRefusal.unavailable);
    Uri endpoint(String name) {
      final value = json[name];
      final uri = value is String ? Uri.tryParse(value) : null;
      if (uri == null || !uri.isScheme('https') || uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasFragment) {
        throw OidcRefused('the discovery document has no https $name', kind: OidcRefusal.unavailable);
      }
      return uri;
    }

    final algs = json['id_token_signing_alg_values_supported'];
    if (algs is List && !algs.contains('RS256')) {
      throw const OidcRefused('the provider doesn\'t sign with RS256', kind: OidcRefusal.unavailable);
    }
    return OidcEndpoints(
      authorization: endpoint('authorization_endpoint'),
      token: endpoint('token_endpoint'),
      jwks: endpoint('jwks_uri'),
    );
  }

  /// Where the browser goes to sign in: the authorization endpoint with the code flow, PKCE
  /// (S256), [state] and [nonce], returning to [redirectUri].
  Uri authorizeUrl(OidcEndpoints endpoints, {required String redirectUri, required String state, required String nonce, required String challenge}) {
    final at = endpoints.authorization;
    return at.replace(queryParameters: {
      ...at.queryParameters,
      'response_type': 'code',
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'scope': 'openid email',
      'state': state,
      'nonce': nonce,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      if (formPost) 'response_mode': 'form_post',
      if (id == googleProvider) 'prompt': 'select_account',
    });
  }

  /// The client secret for the token endpoint: Google's as given, Apple's an ES256 JWT made now.
  String _secret(int now) {
    final apple = _apple;
    if (apple == null) return _clientSecret!;
    return appleClientSecret(
      teamId: apple.teamId,
      keyId: apple.keyId,
      servicesId: clientId,
      audience: issuer,
      key: apple.privateKey,
      nowSeconds: now ~/ 1000,
    );
  }

  /// Exchanges [code] for an ID token at the token endpoint, with the PKCE [verifier] and the
  /// same [redirectUri]; returns the ID token, unchecked ([verify] checks it). Throws
  /// [OidcRefused].
  Future<String> exchange(http.Client client, {required String code, required String verifier, required String redirectUri, required int now}) async {
    final at = await endpoints(client, now);
    final request = http.Request('POST', at.token)
      ..followRedirects = false
      ..headers['accept'] = 'application/json'
      ..bodyFields = {
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': redirectUri,
        'client_id': clientId,
        'client_secret': _secret(now),
        'code_verifier': verifier,
      };
    final answer = await _send(client, request, expectOk: false);
    if (answer.status != 200) {
      final error = answer.json['error'];
      final word = error is String && RegExp(r'^[a-z_]{1,40}$').hasMatch(error) ? error : 'an error';
      throw OidcRefused('the token endpoint answered ${answer.status} ($word)',
          kind: answer.status >= 500 ? OidcRefusal.unavailable : OidcRefusal.invalid);
    }
    final token = answer.json['id_token'];
    if (token is! String || token.isEmpty) throw const OidcRefused('the token endpoint gave no ID token');
    return token;
  }

  /// Checks [idToken] (see the library's comment) for a sign-in that sent [nonce], at [now]
  /// (UTC milliseconds). Throws [OidcRefused].
  Future<OidcIdentity> verify(http.Client client, String idToken, {required String nonce, required int now}) async {
    final jwt = Jwt.parse(idToken);
    final alg = jwt.header['alg'];
    if (alg != 'RS256') throw OidcRefused(alg == 'none' ? 'an unsigned token (alg none)' : 'a token not signed with RS256');
    if (jwt.header.containsKey('crit')) throw const OidcRefused('a token with critical header parameters');
    final kid = jwt.header['kid'];
    if (kid is! String || kid.isEmpty || kid.length > 200) throw const OidcRefused('a token naming no key');
    final key = await _key(client, kid, now);
    if (key == null) throw const OidcRefused('a token signed with a key the provider doesn\'t publish');
    if (!rsaVerifySha256(key, jwt.signingInput, jwt.signature)) throw const OidcRefused('a token whose signature doesn\'t verify');
    return checkClaims(jwt.claims, nonce: nonce, now: now);
  }

  /// Checks a signed token's [claims] for a sign-in that sent [nonce], at [now]. Throws
  /// [OidcRefused].
  OidcIdentity checkClaims(Map<String, Object?> claims, {required String nonce, required int now}) {
    final iss = claims['iss'];
    if (iss is! String || !issuers.contains(iss)) throw const OidcRefused('a token from another issuer');
    final aud = claims['aud'];
    final audiences = aud is String ? [aud] : (aud is List ? aud : const []);
    if (audiences.length != 1 || audiences.single is! String || !textEqual(audiences.single as String, clientId)) {
      throw const OidcRefused('a token for another audience');
    }
    final azp = claims['azp'];
    if (azp != null && (azp is! String || !textEqual(azp, clientId))) throw const OidcRefused('a token for another party');
    final seconds = now / 1000;
    final slack = skew.inSeconds;
    final exp = claims['exp'], iat = claims['iat'], nbf = claims['nbf'];
    if (exp is! num || seconds >= exp + slack) throw const OidcRefused('an expired token');
    if (iat is! num || iat > seconds + slack || seconds - iat > maxTokenAge.inSeconds + slack) {
      throw const OidcRefused('a token issued at the wrong time');
    }
    if (nbf != null && (nbf is! num || seconds < nbf - slack)) throw const OidcRefused('a token not valid yet');
    final sent = claims['nonce'];
    if (sent is! String || !textEqual(sent, nonce)) throw const OidcRefused('a token for another sign-in (nonce)');
    final sub = claims['sub'];
    if (sub is! String || sub.isEmpty || sub.length > 255) throw const OidcRefused('a token naming no one');
    final rawEmail = claims['email'];
    final email = rawEmail is String ? rawEmail.trim().toLowerCase() : '';
    final at = email.lastIndexOf('@');
    if (at <= 0 || at == email.length - 1 || email.length > 320) {
      throw const OidcRefused('an account with no email', kind: OidcRefusal.unverifiedEmail);
    }
    final domain = email.substring(at + 1);
    if (domain == appleRelayDomain || domain.endsWith('.$appleRelayDomain') || _yes(claims['is_private_email'])) {
      throw const OidcRefused('a Hide My Email address', kind: OidcRefusal.relayEmail);
    }
    if (!_yes(claims['email_verified'])) {
      throw const OidcRefused('an account whose email isn\'t verified', kind: OidcRefusal.unverifiedEmail);
    }
    return OidcIdentity(provider: id, sub: sub, email: email);
  }

  /// Apple writes its booleans as `"true"` and `"false"`.
  static bool _yes(Object? v) => v == true || v == 'true';

  /// The key [kid] names: from the kept set while it is fresh, else fetched again. A fresh set
  /// that doesn't have it (the provider rotated its keys) is fetched again too, but no more than
  /// once a [refetchGap]. Null when the provider doesn't publish it.
  Future<RsaPublicKey?> _key(http.Client client, String kid, int now) async {
    final fresh = _keysAt > 0 && now - _keysAt < _keysFor;
    final known = _keys.containsKey(kid);
    if (fresh && known) return _keys[kid];
    final unknown = fresh && !known;
    final last = _refetched;
    if (!unknown || last == null || now - last >= refetchGap.inMilliseconds) {
      if (unknown) _refetched = now;
      try {
        await (_fetchingKeys ??= _fetchKeys(client, now).whenComplete(() => _fetchingKeys = null));
      } on OidcRefused {
        // A set fetched not long ago still serves while the provider can't be reached.
        if (_keysAt == 0 || now - _keysAt >= staleLife.inMilliseconds) rethrow;
      }
    }
    return _keys[kid];
  }

  Future<void> _fetchKeys(http.Client client, int now) async {
    final at = await endpoints(client, now);
    keyFetches++;
    final answer = await _getJson(client, at.jwks);
    final keys = parseJwks(answer.json);
    if (keys.isEmpty) throw const OidcRefused('the provider publishes no usable keys', kind: OidcRefusal.unavailable);
    _keys = Map.unmodifiable(keys);
    _keysAt = now;
    _keysFor = _maxAge(answer.headers['cache-control']) ?? keysLife.inMilliseconds;
  }

  static int? _maxAge(String? cacheControl) {
    final m = RegExp(r'max-age=(\d{1,9})').firstMatch(cacheControl ?? '');
    if (m == null) return null;
    final seconds = int.parse(m[1]!).clamp(300, 86400);
    return seconds * 1000;
  }

  static Future<_Answer> _getJson(http.Client client, Uri url) => _send(
        client,
        http.Request('GET', url)
          ..followRedirects = false
          ..headers['accept'] = 'application/json',
      );

  static Future<_Answer> _send(http.Client client, http.BaseRequest request, {bool expectOk = true}) async {
    final http.StreamedResponse response;
    try {
      response = await client.send(request).timeout(fetchTimeout);
    } on Object catch (e) {
      throw OidcRefused('couldn\'t reach ${request.url.host} (${e.runtimeType})', kind: OidcRefusal.unavailable);
    }
    final bytes = BytesBuilder(copy: false);
    try {
      await for (final chunk in response.stream.timeout(fetchTimeout)) {
        bytes.add(chunk);
        if (bytes.length > maxAnswer) throw const OidcRefused('the provider\'s answer is too long', kind: OidcRefusal.unavailable);
      }
    } on OidcRefused {
      rethrow;
    } on Object {
      throw OidcRefused('${request.url.host} stopped answering', kind: OidcRefusal.unavailable);
    }
    if (expectOk && response.statusCode != 200) {
      throw OidcRefused('${request.url.host} answered ${response.statusCode}', kind: OidcRefusal.unavailable);
    }
    Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes.takeBytes()));
    } on FormatException {
      json = null;
    }
    if (json is! Map) {
      if (!expectOk && response.statusCode != 200) return _Answer(response.statusCode, const {}, response.headers);
      throw OidcRefused('${request.url.host} didn\'t answer with JSON', kind: OidcRefusal.unavailable);
    }
    return _Answer(response.statusCode, json.cast<String, Object?>(), response.headers);
  }
}

class _Answer {
  _Answer(this.status, this.json, this.headers);
  final int status;
  final Map<String, Object?> json;
  final Map<String, String> headers;
}

/// The providers a hub signs people in with (`DEN_GOOGLE_*`, `DEN_APPLE_*`). With none, the
/// hub has no `/auth` routes at all.
class SignInProviders {
  /// [google] and [apple], either or both.
  SignInProviders({this.google, this.apple});

  /// Google, when configured.
  final OidcProvider? google;

  /// Apple, when configured.
  final OidcProvider? apple;

  /// Those configured, Google first.
  List<OidcProvider> get all => [?google, ?apple];

  /// The provider [id] names, when configured.
  OidcProvider? byId(String? id) => switch (id) {
        googleProvider => google,
        appleProvider => apple,
        _ => null,
      };

  /// From the operator's settings (the environment or `den_hub serve` options): Google needs its
  /// client id and secret; Apple its Services ID, team id, key id and the `.p8` key file. Null
  /// when neither is set at all. Throws [FormatException] for a provider set up only in part or a
  /// key file that can't be read, so a typo stops the hub instead of leaving sign-in half on.
  /// [warn] hears about a key file other users on the machine can read.
  static SignInProviders? fromSettings({
    String? googleClientId,
    String? googleClientSecret,
    String? appleServicesId,
    String? appleTeamId,
    String? appleKeyId,
    String? appleKeyFile,
    void Function(String message)? warn,
  }) {
    String? clean(String? v) => v == null || v.trim().isEmpty ? null : v.trim();
    final gId = clean(googleClientId), gSecret = clean(googleClientSecret);
    final aId = clean(appleServicesId), aTeam = clean(appleTeamId), aKey = clean(appleKeyId), aFile = clean(appleKeyFile);
    OidcProvider? google;
    if (gId != null || gSecret != null) {
      if (gId == null || gSecret == null) {
        throw const FormatException('Google sign-in needs both DEN_GOOGLE_CLIENT_ID and DEN_GOOGLE_CLIENT_SECRET');
      }
      google = OidcProvider.google(clientId: gId, clientSecret: gSecret);
    }
    OidcProvider? apple;
    if (aId != null || aTeam != null || aKey != null || aFile != null) {
      if (aId == null || aTeam == null || aKey == null || aFile == null) {
        throw const FormatException(
            'Apple sign-in needs DEN_APPLE_SERVICES_ID, DEN_APPLE_TEAM_ID, DEN_APPLE_KEY_ID and DEN_APPLE_KEY_FILE');
      }
      final file = File(aFile);
      final String pem;
      try {
        pem = file.readAsStringSync();
      } on FileSystemException catch (e) {
        throw FormatException('DEN_APPLE_KEY_FILE: can\'t read $aFile (${e.osError?.message ?? e.message})');
      }
      final Uint8List key;
      try {
        key = readP8(pem);
      } on FormatException catch (e) {
        throw FormatException('DEN_APPLE_KEY_FILE: $aFile: ${e.message}');
      }
      if (!Platform.isWindows && (file.statSync().mode & 0x3f) != 0) {
        warn?.call('$aFile, the key that signs the hub in at Apple, can be read by other users on this machine. '
            'chmod 600 it.');
      }
      apple = OidcProvider.apple(servicesId: aId, key: AppleKey(teamId: aTeam, keyId: aKey, privateKey: key));
    }
    if (google == null && apple == null) return null;
    return SignInProviders(google: google, apple: apple);
  }
}
