/// The little of CBOR (RFC 8949) a passkey's answer needs: an attestation object and a COSE key.
///
/// Definite lengths only, integers up to 64 bits, byte and text strings, arrays, maps, and the
/// simple values false, true and null. Anything else (floats, tags, indefinite lengths, nesting
/// past [maxDepth]) is refused with a [FormatException]: no passkey sends it, and a decoder that
/// reads less has less to get wrong.
library;

import 'dart:convert';
import 'dart:typed_data';

/// How deep arrays and maps may nest.
const int maxDepth = 8;

/// One value read from [bytes] at [offset], and where it ended.
({Object? value, int end}) readCbor(List<int> bytes, [int offset = 0]) {
  final reader = _Reader(bytes, offset);
  final value = reader.value(0);
  return (value: value, end: reader.at);
}

/// The single value [bytes] holds, with nothing after it.
Object? decodeCbor(List<int> bytes) {
  final read = readCbor(bytes);
  if (read.end != bytes.length) throw const FormatException('CBOR: bytes after the value');
  return read.value;
}

class _Reader {
  _Reader(this.bytes, this.at);

  final List<int> bytes;
  int at;

  int _byte() {
    if (at >= bytes.length) throw const FormatException('CBOR: ran out of bytes');
    return bytes[at++];
  }

  int _uint(int info) {
    if (info < 24) return info;
    final size = switch (info) { 24 => 1, 25 => 2, 26 => 4, 27 => 8, _ => throw const FormatException('CBOR: no indefinite lengths') };
    var v = 0;
    for (var i = 0; i < size; i++) {
      v = (v << 8) | _byte();
    }
    if (v < 0) throw const FormatException('CBOR: number too large');
    return v;
  }

  Uint8List _take(int length) {
    if (length < 0 || at + length > bytes.length) throw const FormatException('CBOR: ran out of bytes');
    final out = Uint8List.fromList(bytes.sublist(at, at + length));
    at += length;
    return out;
  }

  Object? value(int depth) {
    if (depth > maxDepth) throw const FormatException('CBOR: nested too deep');
    final head = _byte();
    final major = head >> 5, info = head & 0x1f;
    switch (major) {
      case 0:
        return _uint(info);
      case 1:
        return -1 - _uint(info);
      case 2:
        return _take(_uint(info));
      case 3:
        return utf8.decode(_take(_uint(info)));
      case 4:
        final n = _uint(info);
        if (n > bytes.length) throw const FormatException('CBOR: array too long');
        return [for (var i = 0; i < n; i++) value(depth + 1)];
      case 5:
        final n = _uint(info);
        if (n > bytes.length) throw const FormatException('CBOR: map too long');
        final map = <Object?, Object?>{};
        for (var i = 0; i < n; i++) {
          final key = value(depth + 1);
          if (key is! int && key is! String) throw const FormatException('CBOR: map keys are numbers or text');
          if (map.containsKey(key)) throw const FormatException('CBOR: a key twice');
          map[key] = value(depth + 1);
        }
        return map;
      case 7:
        return switch (info) {
          20 => false,
          21 => true,
          22 => null,
          _ => throw const FormatException('CBOR: only false, true and null'),
        };
      default:
        throw const FormatException('CBOR: no tags');
    }
  }
}
