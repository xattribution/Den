import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import 'hlc.dart';
import 'ids.dart';

/// One signed edit to one record. See ARCHITECTURE.md, "The model".
class Change {
  const Change({
    required this.id,
    required this.space,
    required this.hlc,
    required this.type,
    required this.rid,
    required this.fields,
    required this.device,
    required this.actor,
    required this.sig,
  });

  /// `"<deviceId>:<counter>"`.
  final String id;
  final String space;
  final Hlc hlc;
  final String type;
  final String rid;
  final Map<String, Object?> fields;
  final String device;
  final String? actor;
  final String sig;

  int get counter => int.parse(id.substring(id.lastIndexOf(':') + 1));

  bool get isDelete => fields['_deleted'] == true;

  /// The bytes the author signs: canonical JSON of everything except the signature.
  Uint8List get signedBytes => utf8.encode(canonicalJson(
        [id, space, hlc.toString(), type, rid, fields, device, actor],
      ));

  Map<String, Object?> toJson() => {
        'id': id,
        'space': space,
        'hlc': hlc.toString(),
        'type': type,
        'rid': rid,
        'fields': fields,
        'device': device,
        'actor': actor,
        'sig': sig,
      };

  static Change fromJson(Map<String, Object?> json) => Change(
        id: json['id']! as String,
        space: json['space']! as String,
        hlc: Hlc.parse(json['hlc']! as String),
        type: json['type']! as String,
        rid: json['rid']! as String,
        fields: Map<String, Object?>.from(json['fields']! as Map),
        device: json['device']! as String,
        actor: json['actor'] as String?,
        sig: json['sig']! as String,
      );

  @override
  String toString() => 'Change($id $type/$rid ${fields.keys.join(',')})';
}

/// JSON with object keys sorted recursively and no whitespace.
String canonicalJson(Object? value) => jsonEncode(_sorted(value));

Object? _sorted(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return {for (final k in keys) k: _sorted(value[k])};
  }
  if (value is List) return value.map(_sorted).toList();
  return value;
}

final Ed25519 _ed25519 = Ed25519();
final X25519 _x25519 = X25519();

/// A device's long-term keys: Ed25519 for signing changes and handshakes, X25519 for sealing
/// space keys to it.
class DeviceKeys {
  DeviceKeys._(this.signing, this.signingPublic, this.agreement, this.agreementPublic);

  final SimpleKeyPair signing;
  final SimplePublicKey signingPublic;
  final SimpleKeyPair agreement;
  final SimplePublicKey agreementPublic;

  static Future<DeviceKeys> generate() async {
    final signing = await _ed25519.newKeyPair();
    final agreement = await _x25519.newKeyPair();
    return DeviceKeys._(
      signing,
      await signing.extractPublicKey(),
      agreement,
      await agreement.extractPublicKey(),
    );
  }

  /// Restores keys from [toJson] output.
  static Future<DeviceKeys> fromJson(Map<String, Object?> json) async {
    final signing = await _ed25519.newKeyPairFromSeed(_b64d(json['signingSeed']! as String));
    final agreement = await _x25519.newKeyPairFromSeed(_b64d(json['agreementSeed']! as String));
    return DeviceKeys._(
      signing,
      await signing.extractPublicKey(),
      agreement,
      await agreement.extractPublicKey(),
    );
  }

  Future<Map<String, Object?>> toJson() async => {
        'signingSeed': _b64e(await signing.extractPrivateKeyBytes()),
        'agreementSeed': _b64e(await agreement.extractPrivateKeyBytes()),
      };

  /// base64url of the Ed25519 public key; stored as `device.pubkey`.
  String get pubkey => _b64e(signingPublic.bytes);

  /// base64url of the X25519 public key; stored as `device.xpub`.
  String get xpub => _b64e(agreementPublic.bytes);

  /// The device id: base32 of the first 10 bytes of SHA-256 of the Ed25519 public key.
  Future<String> deviceId() => deviceIdFor(signingPublic.bytes);

  Future<String> sign(List<int> bytes) async =>
      _b64e((await _ed25519.sign(bytes, keyPair: signing)).bytes);
}

Future<String> deviceIdFor(List<int> ed25519PublicKey) async {
  final digest = await Sha256().hash(ed25519PublicKey);
  return base32(digest.bytes.sublist(0, 10));
}

/// [deviceIdFor] from a base64url public key, synchronously; null when the key isn't base64url.
String? deviceIdOf(String pubkey) {
  try {
    return base32(const DartSha256().hashSync(_b64d(pubkey)).bytes.sublist(0, 10));
  } on FormatException {
    return null;
  }
}

/// The family id a founder's key and the family's creation time commit to: base32 of the first
/// 10 bytes of SHA-256 over the founder's Ed25519 public key bytes followed by the creation time
/// in UTC milliseconds as a decimal string.
String familyIdFor(String founderPubkey, int createdMillis) => base32(const DartSha256()
    .hashSync([..._b64d(founderPubkey), ...utf8.encode('$createdMillis')])
    .bytes
    .sublist(0, 10));

/// Lowercase hex SHA-256 of a string's UTF-8 bytes; how bearer tokens are stored.
String sha256Hex(String value) => const DartSha256()
    .hashSync(utf8.encode(value))
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

/// Verifies [signature] (base64url) by [pubkey] (base64url Ed25519) over [bytes].
Future<bool> verifySignature(List<int> bytes, String signature, String pubkey) async {
  try {
    return await _ed25519.verify(
      bytes,
      signature: Signature(
        _b64d(signature),
        publicKey: SimplePublicKey(_b64d(pubkey), type: KeyPairType.ed25519),
      ),
    );
  } on Object {
    return false;
  }
}

String _b64e(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List _b64d(String text) => base64Url.decode(base64Url.normalize(text));

/// base64url without padding, as used for keys and signatures throughout Den.
String b64e(List<int> bytes) => _b64e(bytes);

/// Decodes base64url with or without padding.
Uint8List b64d(String text) => _b64d(text);
