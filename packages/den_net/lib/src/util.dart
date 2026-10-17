import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:den_core/den_core.dart';

final Sha256 _sha256 = Sha256();
final Hmac _hmacSha256 = Hmac.sha256();

/// UTF-8 bytes of [text].
Uint8List utf8Bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// [parts] joined into one byte array.
Uint8List concatBytes(Iterable<List<int>> parts) {
  final builder = BytesBuilder(copy: false);
  for (final part in parts) {
    builder.add(part);
  }
  return builder.takeBytes();
}

/// SHA-256 of [data].
Future<Uint8List> sha256(List<int> data) async =>
    Uint8List.fromList((await _sha256.hash(data)).bytes);

/// HMAC-SHA256 of [data] under [key].
Future<Uint8List> hmacSha256(List<int> key, List<int> data) async => Uint8List.fromList(
    (await _hmacSha256.calculateMac(data, secretKey: SecretKey(List<int>.of(key)))).bytes);

/// Compares two byte arrays in time that depends only on their length.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Lowercase hex of [bytes].
String hexEncode(List<int> bytes) {
  final out = StringBuffer();
  for (final b in bytes) {
    out.write((b & 0xff).toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

/// Big-endian 32-bit encoding of [value].
Uint8List u32be(int value) => Uint8List(4)
  ..[0] = (value >> 24) & 0xff
  ..[1] = (value >> 16) & 0xff
  ..[2] = (value >> 8) & 0xff
  ..[3] = value & 0xff;

/// Reads a big-endian 32-bit unsigned integer.
int readU32be(List<int> bytes, int offset) =>
    ((bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]) &
    0xffffffff;

const int _two32 = 0x100000000;

/// Big-endian 64-bit encoding of a non-negative [value] (up to 2^53 on the web).
Uint8List u64be(int value) {
  final hi = value ~/ _two32;
  final lo = value % _two32;
  return Uint8List(8)
    ..setRange(0, 4, u32be(hi))
    ..setRange(4, 8, u32be(lo));
}

/// Reads a big-endian 64-bit unsigned integer (exact up to 2^53).
int readU64be(List<int> bytes, int offset) =>
    readU32be(bytes, offset) * _two32 + readU32be(bytes, offset + 4);

/// Decodes base64url, returning null for anything that isn't.
Uint8List? tryB64d(Object? text) {
  if (text is! String) return null;
  try {
    return b64d(text);
  } on FormatException {
    return null;
  }
}

/// A JSON object from a decoded message, or null.
Map<String, Object?>? asJsonObject(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : null;

/// 32-bit multiply that gives the same result in the VM and in JavaScript.
int _imul32(int a, int b) {
  final aHi = (a >> 16) & 0xffff;
  final aLo = a & 0xffff;
  final bHi = (b >> 16) & 0xffff;
  final bLo = b & 0xffff;
  return (aLo * bLo + ((((aHi * bLo) + (aLo * bHi)) & 0xffff) * 0x10000)) % _two32;
}

/// MurmurHash3's 32-bit finalizer: spreads small integers over 32 bits.
int mix32(int value) {
  var h = value % _two32;
  h = (h ^ (h >> 16)) % _two32;
  h = _imul32(h, 0x85ebca6b);
  h = (h ^ (h >> 13)) % _two32;
  h = _imul32(h, 0xc2b2ae35);
  h = (h ^ (h >> 16)) % _two32;
  return h;
}

/// Serializes calls so each runs after the previous one finished.
class SerialQueue {
  Future<void> _tail = Future<void>.value();

  /// Runs [task] after every task queued before it.
  Future<T> run<T>(Future<T> Function() task) {
    final result = _tail.then((_) => task());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
