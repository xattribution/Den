import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:cryptography/cryptography.dart';
import 'package:den_core/den_core.dart';
import 'package:stream_channel/stream_channel.dart';

import 'util.dart';
import 'words.dart' as words;

/// How a channel carries a session.
enum FrameEncoding {
  /// Every message is a string: handshake JSON, then base64url frames. For text-only channels.
  text,

  /// Every message is bytes: UTF-8 handshake JSON, then raw frames.
  bytes,

  /// Handshake JSON as text messages, frames as binary messages. What WebSockets use.
  mixed,
}

/// A handshake or framing failure. The session is closed when one is raised.
class SessionException implements Exception {
  /// Creates an exception with a reason that never includes secret material.
  SessionException(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => 'SessionException: $message';
}

/// The identity a client presented in its hello, verified to match its public key.
class ClientHello {
  /// Creates a hello view.
  const ClientHello({required this.device, required this.pubkey, required this.family});

  /// Device id: base32 of the first 10 bytes of SHA-256 of [pubkey].
  final String device;

  /// base64url Ed25519 public key.
  final String pubkey;

  /// The family the client believes it belongs to, or null for a spoken-code joiner.
  final String? family;
}

/// Protocol version carried in every hello.
const int sessionProtocolVersion = 1;

/// Largest handshake message accepted, in bytes.
const int maxHandshakeBytes = 16 * 1024;

/// Largest message, in plaintext bytes, a session sends or accepts.
const int maxSessionMessageBytes = 1024 * 1024;

const int _dirClientToServer = 0x01;
const int _dirServerToClient = 0x02;
const int _tagLength = 16;

final X25519 _x25519 = X25519();
final AesGcm _aes = AesGcm.with256bits();
final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

/// An authenticated, encrypted connection between two devices. See ARCHITECTURE.md, "Sessions".
///
/// The handshake: the client sends `hello {v, family, device, pubkey, eph}` with a fresh X25519
/// key; the server answers `hello {v, family, device, pubkey, eph, sig}` signing the transcript
/// hash (SHA-256 of both hellos); the client sends `auth {sig}` over the same hash. Both derive
/// `k_c2s` and `k_s2c` with HKDF-SHA256 from the X25519 shared secret, salted with the transcript
/// hash. Every later message is an AES-256-GCM frame: an 8-byte big-endian counter, then
/// ciphertext and tag; the nonce is the direction byte, three zero bytes and the counter.
/// Counters start at 1 and must go up by exactly one; a replayed, reordered, dropped or tampered
/// frame closes the session.
class Session {
  Session._({
    required _Wire wire,
    required this.isClient,
    required this.localDevice,
    required this.peerDevice,
    required this.peerPubkey,
    required this.peerFamily,
    required this.transcriptHash,
    required this.matchingWords,
    required this.pinned,
    required SecretKey sendKey,
    required SecretKey receiveKey,
  })  : _wire = wire,
        _sendKey = sendKey,
        _receiveKey = receiveKey,
        _sendDirection = isClient ? _dirClientToServer : _dirServerToClient,
        _receiveDirection = isClient ? _dirServerToClient : _dirClientToServer {
    _subscription = wire.queue.rest.asyncMap(_open).listen(
      (message) {
        if (message != null && !_messages.isClosed) _messages.add(message);
      },
      onError: (Object error, StackTrace stack) {
        _fail(error is SessionException ? error : SessionException('bad frame'));
      },
      onDone: () => _shutDown(closeSink: true),
      cancelOnError: true,
    );
  }

  final _Wire _wire;
  final SecretKey _sendKey;
  final SecretKey _receiveKey;
  final int _sendDirection;
  final int _receiveDirection;
  late final StreamSubscription<Map<String, Object?>?> _subscription;
  final StreamController<Map<String, Object?>> _messages = StreamController();
  final Completer<void> _done = Completer();
  Future<void> _sendChain = Future<void>.value();
  int _sendCounter = 0;
  int _receiveCounter = 0;
  bool _closed = false;
  SessionException? _error;

  /// Whether this side opened the connection.
  final bool isClient;

  /// This device's id.
  final String localDevice;

  /// The other device's id, verified to match [peerPubkey] and its handshake signature.
  final String peerDevice;

  /// The other device's base64url Ed25519 public key.
  final String peerPubkey;

  /// The family the other side named in its hello.
  final String? peerFamily;

  /// SHA-256 of both hellos; both sides hold the same value only when no one is in the middle.
  final Uint8List transcriptHash;

  /// Three words derived from [transcriptHash] for people to compare across screens.
  final List<String> matchingWords;

  /// Whether the client required a specific server identity (from a QR code, a relay tunnel id
  /// or a known hub) and got it.
  final bool pinned;

  /// Decrypted messages, in order. Closes when the session ends; a protocol violation arrives
  /// as a [SessionException] error first.
  Stream<Map<String, Object?>> get messages => _messages.stream;

  /// Completes when the session has ended for any reason.
  Future<void> get done => _done.future;

  /// The violation that ended the session, if one did.
  SessionException? get error => _error;

  /// Whether the session has ended.
  bool get isClosed => _closed;

  /// Opens a session as the client.
  ///
  /// [familyId] is the family this device belongs to or is joining (null for a spoken-code
  /// joiner, who learns it during pairing). [expectDevice] and [expectPubkey] pin the server's
  /// identity; the handshake fails if the server presents anything else.
  static Future<Session> connect(
    StreamChannel<dynamic> channel, {
    required DeviceKeys keys,
    String? familyId,
    String? expectDevice,
    String? expectPubkey,
    FrameEncoding? encoding,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final wire = _Wire(channel, encoding ?? _detectEncoding(channel));
    try {
      final deviceId = await keys.deviceId();
      final eph = await _x25519.newKeyPair();
      final ephPublic = await eph.extractPublicKey();
      final hello = <String, Object?>{
        't': 'hello',
        'v': sessionProtocolVersion,
        'family': familyId,
        'device': deviceId,
        'pubkey': keys.pubkey,
        'eph': b64e(ephPublic.bytes),
      };
      wire.sendJson(hello);

      final reply = await wire.nextJson(timeout);
      final server = await _Hello.parse(reply, withSignature: true);
      if (server.device == deviceId) throw SessionException('peer is this device');
      if (expectDevice != null && server.device != expectDevice) {
        throw SessionException('unexpected server device');
      }
      if (expectPubkey != null && server.pubkey != expectPubkey) {
        throw SessionException('unexpected server key');
      }
      if (familyId != null && server.family != familyId) {
        throw SessionException('server is in another family');
      }
      final transcript = await _transcriptHash(hello, Map.of(reply)..remove('sig'));
      final serverSigned = concatBytes([_serverLabel, transcript]);
      if (!await verifySignature(serverSigned, server.sig!, server.pubkey)) {
        throw SessionException('bad server signature');
      }
      final sig = await keys.sign(concatBytes([_clientLabel, transcript]));
      wire.sendJson({'t': 'auth', 'sig': sig});

      final derived = await _deriveKeys(eph, server.eph, transcript);
      return Session._(
        wire: wire,
        isClient: true,
        localDevice: deviceId,
        peerDevice: server.device,
        peerPubkey: server.pubkey,
        peerFamily: server.family,
        transcriptHash: transcript,
        matchingWords: await words.matchingWords(transcript),
        pinned: expectDevice != null || expectPubkey != null,
        sendKey: derived.c2s,
        receiveKey: derived.s2c,
      );
    } catch (error) {
      wire.abort();
      if (error is SessionException) rethrow;
      if (error is TimeoutException) throw SessionException('handshake timed out');
      throw SessionException('handshake failed');
    }
  }

  /// Accepts a session as the server.
  ///
  /// [admit] sees the client's verified identity before this side reveals anything beyond its
  /// own hello; returning false ends the handshake.
  static Future<Session> accept(
    StreamChannel<dynamic> channel, {
    required DeviceKeys keys,
    String? familyId,
    FutureOr<bool> Function(ClientHello hello)? admit,
    FrameEncoding? encoding,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final wire = _Wire(channel, encoding ?? _detectEncoding(channel));
    try {
      final deviceId = await keys.deviceId();
      final helloJson = await wire.nextJson(timeout);
      final client = await _Hello.parse(helloJson, withSignature: false);
      if (client.device == deviceId) throw SessionException('peer is this device');
      if (admit != null &&
          !await admit(ClientHello(device: client.device, pubkey: client.pubkey, family: client.family))) {
        throw SessionException('client refused');
      }
      final eph = await _x25519.newKeyPair();
      final ephPublic = await eph.extractPublicKey();
      final reply = <String, Object?>{
        't': 'hello',
        'v': sessionProtocolVersion,
        'family': familyId,
        'device': deviceId,
        'pubkey': keys.pubkey,
        'eph': b64e(ephPublic.bytes),
      };
      final transcript = await _transcriptHash(helloJson, reply);
      reply['sig'] = await keys.sign(concatBytes([_serverLabel, transcript]));
      wire.sendJson(reply);

      final auth = await wire.nextJson(timeout);
      final sig = auth['sig'];
      if (auth['t'] != 'auth' || sig is! String) throw SessionException('expected auth');
      if (!await verifySignature(concatBytes([_clientLabel, transcript]), sig, client.pubkey)) {
        throw SessionException('bad client signature');
      }
      final derived = await _deriveKeys(eph, client.eph, transcript);
      return Session._(
        wire: wire,
        isClient: false,
        localDevice: deviceId,
        peerDevice: client.device,
        peerPubkey: client.pubkey,
        peerFamily: client.family,
        transcriptHash: transcript,
        matchingWords: await words.matchingWords(transcript),
        pinned: false,
        sendKey: derived.s2c,
        receiveKey: derived.c2s,
      );
    } catch (error) {
      wire.abort();
      if (error is SessionException) rethrow;
      if (error is TimeoutException) throw SessionException('handshake timed out');
      throw SessionException('handshake failed');
    }
  }

  /// Encrypts and sends one JSON message. Messages go out in the order [send] is called.
  Future<void> send(Map<String, Object?> message) {
    if (_closed) return Future.error(StateError('session closed'));
    final plain = utf8Bytes(jsonEncode(message));
    if (plain.length > maxSessionMessageBytes) {
      return Future.error(ArgumentError('message larger than $maxSessionMessageBytes bytes'));
    }
    final counter = ++_sendCounter;
    final sent = _sendChain.then((_) async {
      final box = await _aes.encrypt(plain, secretKey: _sendKey, nonce: _nonce(_sendDirection, counter));
      if (_closed) return;
      _wire.sendFrame(concatBytes([u64be(counter), box.cipherText, box.mac.bytes]));
    });
    _sendChain = sent.catchError((Object _) {});
    return sent;
  }

  /// Ends the session after queued messages are sent.
  Future<void> close() => _shutDown(closeSink: true, flush: true);

  Future<Map<String, Object?>?> _open(Object? raw) async {
    if (_closed) return null;
    final frame = _wire.decodeFrame(raw);
    if (frame == null || frame.length < 8 + _tagLength) throw SessionException('malformed frame');
    final counter = readU64be(frame, 0);
    if (counter != _receiveCounter + 1) throw SessionException('frame out of order or replayed');
    _receiveCounter = counter;
    final List<int> plain;
    try {
      plain = await _aes.decrypt(
        SecretBox(
          frame.sublist(8, frame.length - _tagLength),
          nonce: _nonce(_receiveDirection, counter),
          mac: Mac(frame.sublist(frame.length - _tagLength)),
        ),
        secretKey: _receiveKey,
      );
    } on SecretBoxAuthenticationError {
      throw SessionException('frame failed authentication');
    }
    if (plain.length > maxSessionMessageBytes) throw SessionException('frame too large');
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(plain));
    } on FormatException {
      throw SessionException('frame is not JSON');
    }
    final message = asJsonObject(decoded);
    if (message == null) throw SessionException('frame is not a JSON object');
    return message;
  }

  void _fail(SessionException error) {
    if (_closed) return;
    _error = error;
    if (!_messages.isClosed) _messages.addError(error);
    unawaited(_shutDown(closeSink: true));
  }

  Future<void> _shutDown({required bool closeSink, bool flush = false}) async {
    if (_closed) return;
    if (flush) await _sendChain;
    _closed = true;
    if (closeSink) {
      try {
        await _wire.channel.sink.close().timeout(const Duration(seconds: 2), onTimeout: () {});
      } on Object {
        // The transport may already be gone.
      }
      unawaited(_subscription.cancel());
    }
    if (!_messages.isClosed) unawaited(_messages.close());
    if (!_done.isCompleted) _done.complete();
  }
}

final Uint8List _serverLabel = utf8Bytes('den/session/v1/server');
final Uint8List _clientLabel = utf8Bytes('den/session/v1/client');

List<int> _nonce(int direction, int counter) =>
    concatBytes([
      [direction, 0, 0, 0],
      u64be(counter),
    ]);

FrameEncoding _detectEncoding(StreamChannel<dynamic> channel) {
  if (channel is StreamChannel<String>) return FrameEncoding.text;
  if (channel is StreamChannel<List<int>>) return FrameEncoding.bytes;
  return FrameEncoding.mixed;
}

Future<Uint8List> _transcriptHash(Map<String, Object?> clientHello, Map<String, Object?> serverHello) {
  final c = utf8Bytes(canonicalJson(clientHello));
  final s = utf8Bytes(canonicalJson(serverHello));
  return sha256(concatBytes([
    utf8Bytes('den/session/v1'),
    [0],
    u32be(c.length),
    c,
    u32be(s.length),
    s,
  ]));
}

Future<({SecretKey c2s, SecretKey s2c})> _deriveKeys(
  SimpleKeyPair eph,
  List<int> peerEph,
  List<int> transcript,
) async {
  final shared = await _x25519.sharedSecretKey(
    keyPair: eph,
    remotePublicKey: SimplePublicKey(peerEph, type: KeyPairType.x25519),
  );
  final sharedBytes = await shared.extractBytes();
  if (sharedBytes.every((b) => b == 0)) throw SessionException('weak ephemeral key');
  final c2s = await _hkdf.deriveKey(
    secretKey: SecretKey(sharedBytes),
    nonce: transcript,
    info: utf8Bytes('den/session/v1 c2s'),
  );
  final s2c = await _hkdf.deriveKey(
    secretKey: SecretKey(sharedBytes),
    nonce: transcript,
    info: utf8Bytes('den/session/v1 s2c'),
  );
  return (c2s: SecretKey(await c2s.extractBytes()), s2c: SecretKey(await s2c.extractBytes()));
}

class _Hello {
  _Hello(this.device, this.pubkey, this.eph, this.family, this.sig);

  final String device;
  final String pubkey;
  final Uint8List eph;
  final String? family;
  final String? sig;

  static Future<_Hello> parse(Map<String, Object?> json, {required bool withSignature}) async {
    if (json['t'] != 'hello') throw SessionException('expected hello');
    if (json['v'] != sessionProtocolVersion) throw SessionException('unsupported protocol version');
    final device = json['device'];
    final pubkey = json['pubkey'];
    final family = json['family'];
    final eph = tryB64d(json['eph']);
    final pubkeyBytes = tryB64d(pubkey);
    if (device is! String || pubkey is! String || pubkeyBytes == null || pubkeyBytes.length != 32) {
      throw SessionException('bad identity in hello');
    }
    if (eph == null || eph.length != 32) throw SessionException('bad ephemeral key in hello');
    if (family != null && family is! String) throw SessionException('bad family in hello');
    final sig = json['sig'];
    if (withSignature && sig is! String) throw SessionException('hello is not signed');
    if (await deviceIdFor(pubkeyBytes) != device) {
      throw SessionException('device id does not match key');
    }
    return _Hello(device, pubkey, eph, family as String?, sig as String?);
  }
}

class _Wire {
  _Wire(this.channel, this.encoding) : queue = StreamQueue<dynamic>(channel.stream);

  final StreamChannel<dynamic> channel;
  final FrameEncoding encoding;
  final StreamQueue<dynamic> queue;

  void sendJson(Map<String, Object?> message) {
    final text = jsonEncode(message);
    channel.sink.add(encoding == FrameEncoding.bytes ? utf8Bytes(text) : text);
  }

  Future<Map<String, Object?>> nextJson(Duration timeout) async {
    final hasNext = await queue.hasNext.timeout(timeout);
    if (!hasNext) throw SessionException('connection closed during handshake');
    final raw = await queue.next;
    final String text;
    if (raw is String) {
      text = raw;
    } else if (raw is List<int>) {
      if (raw.length > maxHandshakeBytes) throw SessionException('handshake message too large');
      try {
        text = utf8.decode(raw);
      } on FormatException {
        throw SessionException('handshake message is not UTF-8');
      }
    } else {
      throw SessionException('unexpected handshake message');
    }
    if (text.length > maxHandshakeBytes) throw SessionException('handshake message too large');
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw SessionException('handshake message is not JSON');
    }
    final message = asJsonObject(decoded);
    if (message == null) throw SessionException('handshake message is not an object');
    return message;
  }

  void sendFrame(Uint8List frame) => channel.sink.add(encoding == FrameEncoding.text ? b64e(frame) : frame);

  Uint8List? decodeFrame(Object? raw) {
    if (raw is String) return raw.length > maxSessionMessageBytes * 2 ? null : tryB64d(raw);
    if (raw is Uint8List) return raw;
    if (raw is List<int>) return Uint8List.fromList(raw);
    return null;
  }

  void abort() {
    unawaited(queue.cancel(immediate: true)?.then((_) {}, onError: (Object _) {}));
    try {
      unawaited(channel.sink.close().then((_) {}, onError: (Object _) {}));
    } on Object {
      // Already closed.
    }
  }
}
