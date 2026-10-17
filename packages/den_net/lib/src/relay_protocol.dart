import 'dart:typed_data';

import 'package:den_core/den_core.dart';

import 'util.dart';

/// The relay's default port.
const int relayPort = 47734;

/// The hub's default port.
const int hubPort = 47733;

/// Largest WebSocket message the relay forwards, and largest mailbox blob it stores.
const int maxRelayMessageBytes = 1024 * 1024;

/// Mailbox ids and rendezvous slots: 64 lowercase hex characters.
final RegExp relayKeyPattern = RegExp(r'^[0-9a-f]{64}$');

/// Device ids: 16 lowercase base32 characters.
final RegExp deviceIdPattern = RegExp(r'^[a-z2-7]{16}$');

/// WebSocket close codes the relay uses.
abstract final class RelayClose {
  /// Tunnel authentication failed.
  static const int unauthorized = 4401;

  /// No hub tunnel or rendezvous host to connect to.
  static const int notFound = 4404;

  /// The rendezvous slot expired before the other side arrived.
  static const int expired = 4408;

  /// The slot or tunnel was taken over by a newer connection.
  static const int replaced = 4409;

  /// A message was larger than [maxRelayMessageBytes].
  static const int tooLarge = 4413;

  /// A cap on tunnels, streams or slots was reached.
  static const int full = 4503;
}

/// Operations in the tunnel's multiplexing frames.
///
/// After authentication every message on a hub's `/tunnel/<hubId>` socket is binary:
/// `op (1 byte) | stream id (u32 big-endian) | payload`. The relay sends [open] when a client
/// connects to `/connect/<hubId>`, [text] and [binary] carry each client WebSocket message
/// unchanged in either direction, and [close] ends one stream from either side.
abstract final class TunnelOp {
  /// A client connected; payload is empty.
  static const int open = 1;

  /// A text message; payload is its UTF-8 bytes.
  static const int text = 2;

  /// A binary message; payload is its bytes.
  static const int binary = 3;

  /// The stream ended; payload is empty.
  static const int close = 4;
}

/// One decoded tunnel frame.
class TunnelFrame {
  /// Creates a frame.
  const TunnelFrame(this.op, this.stream, this.payload);

  /// One of [TunnelOp].
  final int op;

  /// Stream id assigned by the relay.
  final int stream;

  /// Message bytes.
  final Uint8List payload;
}

/// Encodes a tunnel frame.
Uint8List encodeTunnelFrame(int op, int stream, [List<int> payload = const []]) =>
    concatBytes([
      [op],
      u32be(stream),
      payload,
    ]);

/// Decodes a tunnel frame; null when malformed.
TunnelFrame? decodeTunnelFrame(List<int> bytes) {
  if (bytes.length < 5) return null;
  final op = bytes[0];
  if (op < TunnelOp.open || op > TunnelOp.close) return null;
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  return TunnelFrame(op, readU32be(data, 1), Uint8List.sublistView(data, 5));
}

/// What a hub signs to prove it holds the key for [hubId]: a label, the hub id and the relay's
/// base64url challenge nonce.
Uint8List tunnelAuthBytes(String hubId, String nonce) => utf8Bytes('den/relay-tunnel/v1|$hubId|$nonce');

/// Checks a hub's tunnel authentication: [hubId] must be the device id of [pubkey]
/// (base32 of the first 10 bytes of SHA-256 of it) and [sig] its signature over the challenge.
Future<bool> verifyTunnelAuth({
  required String hubId,
  required String nonce,
  required String pubkey,
  required String sig,
}) async {
  final key = tryB64d(pubkey);
  if (key == null || key.length != 32) return false;
  if (await deviceIdFor(key) != hubId) return false;
  return verifySignature(tunnelAuthBytes(hubId, nonce), sig, pubkey);
}

/// The control message the relay sends both rendezvous sides once they are paired.
const String rendezvousPairedMessage = '{"t":"paired"}';
