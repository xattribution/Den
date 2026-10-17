import 'dart:math';
import 'dart:typed_data';

final Random _random = Random.secure();

const String _base32 = 'abcdefghijklmnopqrstuvwxyz234567';

/// Lowercase RFC 4648 base32 without padding.
String base32(List<int> bytes) {
  final out = StringBuffer();
  var buffer = 0;
  var bits = 0;
  for (final byte in bytes) {
    buffer = (buffer << 8) | (byte & 0xff);
    bits += 8;
    while (bits >= 5) {
      out.write(_base32[(buffer >> (bits - 5)) & 31]);
      bits -= 5;
    }
  }
  if (bits > 0) out.write(_base32[(buffer << (5 - bits)) & 31]);
  return out.toString();
}

Uint8List randomBytes(int length) =>
    Uint8List.fromList(List<int>.generate(length, (_) => _random.nextInt(256)));

/// A 16-character random record id (80 bits).
String newId() => base32(randomBytes(10));
