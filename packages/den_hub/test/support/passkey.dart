import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:pointycastle/export.dart';

/// base64url without padding, as WebAuthn's JSON writes bytes.
String b64u(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List unb64u(String text) => base64Url.decode(base64Url.normalize(text));

Uint8List sha(List<int> bytes) => Uint8List.fromList(const DartSha256().hashSync(bytes).bytes);

/// The CBOR (RFC 8949) a passkey sends: maps, numbers, bytes and text.
List<int> cbor(Object? value) {
  List<int> head(int major, int n) {
    if (n < 24) return [(major << 5) | n];
    if (n < 0x100) return [(major << 5) | 24, n];
    if (n < 0x10000) return [(major << 5) | 25, n >> 8, n & 0xff];
    return [(major << 5) | 26, (n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff];
  }

  return switch (value) {
    final int n when n >= 0 => head(0, n),
    final int n => head(1, -1 - n),
    final Uint8List b => [...head(2, b.length), ...b],
    final String s => [...head(3, utf8.encode(s).length), ...utf8.encode(s)],
    final List<Object?> l => [...head(4, l.length), for (final v in l) ...cbor(v)],
    final Map<Object?, Object?> m => [...head(5, m.length), for (final e in m.entries) ...[...cbor(e.key), ...cbor(e.value)]],
    true => [0xf5],
    false => [0xf4],
    null => [0xf6],
    _ => throw ArgumentError('no CBOR for $value'),
  };
}

final ECDomainParameters _p256 = ECCurve_prime256v1();

Uint8List _fixed(BigInt v, int length) {
  final out = Uint8List(length);
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  return out;
}

BigInt _unsigned(List<int> bytes) => bytes.fold(BigInt.zero, (v, b) => (v << 8) | BigInt.from(b));

List<int> _derInt(BigInt v) {
  var bytes = _fixed(v, 32).toList();
  while (bytes.length > 1 && bytes[0] == 0 && bytes[1] & 0x80 == 0) {
    bytes = bytes.sublist(1);
  }
  if (bytes[0] & 0x80 != 0) bytes = [0, ...bytes];
  return [0x02, bytes.length, ...bytes];
}

/// A phone's passkey for one address, as iCloud Keychain or Google Password Manager would make
/// it: a P-256 key, Face ID always passes unless told otherwise.
class FakePasskey {
  FakePasskey._(this.id, this._private, this.x, this.y);

  /// A new one.
  factory FakePasskey.make() {
    final random = Random.secure();
    final id = Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
    BigInt d;
    do {
      d = _unsigned(List.generate(32, (_) => random.nextInt(256)));
    } while (d == BigInt.zero || d >= _p256.n);
    final q = (_p256.G * d)!;
    return FakePasskey._(
      id,
      ECPrivateKey(d, _p256),
      _fixed(q.x!.toBigInteger()!, 32),
      _fixed(q.y!.toBigInteger()!, 32),
    );
  }

  /// The credential id.
  final Uint8List id;
  final ECPrivateKey _private;
  final Uint8List x;
  final Uint8List y;

  /// The credential id as the browser reports it.
  String get credentialId => b64u(id);

  /// The user handle the hub gave it.
  String? userHandle;

  List<int> _sign(List<int> message) {
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))..init(true, PrivateKeyParameter<ECPrivateKey>(_private));
    final s = signer.generateSignature(Uint8List.fromList(message)) as ECSignature;
    final body = [..._derInt(s.r), ..._derInt(s.s)];
    return [0x30, body.length, ...body];
  }

  static int _flags({required bool uv, bool attested = false}) => 0x01 | (uv ? 0x04 : 0) | 0x08 | 0x10 | (attested ? 0x40 : 0);

  List<int> _clientData(String type, String challenge, String origin) =>
      utf8.encode(jsonEncode({'type': type, 'challenge': challenge, 'origin': origin, 'crossOrigin': false}));

  /// `navigator.credentials.create`'s answer for [options] (the hub's `options`) at [origin],
  /// as `PublicKeyCredential.toJSON()` writes it.
  Map<String, Object?> register(
    Map<String, Object?> options, {
    required String origin,
    bool uv = true,
    String? rpId,
    String type = 'webauthn.create',
    String? challenge,
    Map<Object?, Object?>? cose,
  }) {
    final rp = rpId ?? ((options['rp']! as Map)['id']! as String);
    userHandle = (options['user']! as Map)['id'] as String?;
    final key = cose ?? {1: 2, 3: -7, -1: 1, -2: x, -3: y};
    final authData = [
      ...sha(utf8.encode(rp)),
      _flags(uv: uv, attested: true),
      0, 0, 0, 0, //
      ...List.filled(16, 0),
      id.length >> 8, id.length & 0xff,
      ...id,
      ...cbor(key),
    ];
    final attestation = cbor({'fmt': 'none', 'attStmt': <Object?, Object?>{}, 'authData': Uint8List.fromList(authData)});
    return {
      'id': credentialId,
      'rawId': credentialId,
      'type': 'public-key',
      'response': {
        'clientDataJSON': b64u(_clientData(type, challenge ?? options['challenge']! as String, origin)),
        'attestationObject': b64u(attestation),
        'transports': ['internal', 'hybrid'],
      },
      'authenticatorAttachment': 'platform',
      'clientExtensionResults': <String, Object?>{},
    };
  }

  /// `navigator.credentials.get`'s answer for [options] (the hub's `options`) at [origin].
  Map<String, Object?> assert_(
    Map<String, Object?> options, {
    required String origin,
    bool uv = true,
    String? rpId,
    String type = 'webauthn.get',
    String? challenge,
    bool tamper = false,
    int count = 0,
  }) {
    final rp = rpId ?? options['rpId']! as String;
    final authData = [...sha(utf8.encode(rp)), _flags(uv: uv), (count >> 24) & 0xff, (count >> 16) & 0xff, (count >> 8) & 0xff, count & 0xff];
    final clientData = _clientData(type, challenge ?? options['challenge']! as String, origin);
    final signature = _sign([...authData, ...sha(clientData)]);
    return {
      'id': credentialId,
      'rawId': credentialId,
      'type': 'public-key',
      'response': {
        'clientDataJSON': b64u(clientData),
        'authenticatorData': b64u(tamper ? [...authData.sublist(0, 33), 9, 9, 9, 9] : authData),
        'signature': b64u(signature),
        'userHandle': userHandle,
      },
      'authenticatorAttachment': 'platform',
      'clientExtensionResults': <String, Object?>{},
    };
  }
}
