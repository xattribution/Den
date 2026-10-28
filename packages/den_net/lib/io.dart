/// Helpers for platforms with `dart:io`: LAN discovery of hubs over mDNS and serving the sync
/// protocol over WebSockets with shelf.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:multicast_dns/multicast_dns.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'src/relay_protocol.dart';
import 'src/session.dart';
import 'src/sync.dart';

/// The mDNS service type hubs advertise.
const String denServiceType = '_den._tcp';

/// A hub found on the local network.
class DiscoveredHub {
  /// Creates a record of one discovered hub.
  const DiscoveredHub({
    required this.instance,
    required this.host,
    required this.port,
    required this.addresses,
    this.deviceId,
    this.familyId,
    this.txt = const {},
  });

  /// The mDNS service instance name.
  final String instance;

  /// The SRV target host name.
  final String host;

  /// The SRV port (47733 by default).
  final int port;

  /// IPv4 addresses the host name resolved to.
  final List<InternetAddress> addresses;

  /// The hub's device id from the TXT record `id=`; pin it when connecting.
  final String? deviceId;

  /// The family id from the TXT record `f=`.
  final String? familyId;

  /// Every TXT key and value.
  final Map<String, String> txt;

  /// The hub's sync endpoint, `ws://<address>:<port>/ws`.
  Uri get syncUri => Uri(
        scheme: 'ws',
        host: addresses.isEmpty ? host : addresses.first.address,
        port: port,
        path: '/ws',
      );

  @override
  String toString() => 'DiscoveredHub($instance $host:$port id=$deviceId)';
}

/// Parses TXT record text (one `key=value` per line, as package:multicast_dns returns it).
/// Keys are lowercased; a key without `=` maps to an empty string.
Map<String, String> parseServiceTxt(String text) {
  final out = <String, String>{};
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final eq = trimmed.indexOf('=');
    if (eq < 0) {
      out[trimmed.toLowerCase()] = '';
    } else if (eq > 0) {
      out[trimmed.substring(0, eq).toLowerCase()] = trimmed.substring(eq + 1);
    }
  }
  return out;
}

/// Looks for `_den._tcp` hubs on the LAN. Hubs advertise TXT keys `id` (device id), `f` (family
/// id) and `v` (protocol version). Returns what answered within roughly [timeout].
Future<List<DiscoveredHub>> discoverHubs({
  Duration timeout = const Duration(seconds: 3),
  MDnsClient? client,
}) async {
  final mdns = client ?? MDnsClient();
  await mdns.start();
  final found = <String, DiscoveredHub>{};
  try {
    final inner = timeout ~/ 2;
    await for (final ptr in mdns.lookup<PtrResourceRecord>(
      ResourceRecordQuery.serverPointer('$denServiceType.local'),
      timeout: timeout,
    )) {
      final instance = ptr.domainName;
      if (found.containsKey(instance)) continue;
      final srvs = await mdns
          .lookup<SrvResourceRecord>(ResourceRecordQuery.service(instance), timeout: inner)
          .toList();
      if (srvs.isEmpty) continue;
      final srv = srvs.first;
      final txts = await mdns
          .lookup<TxtResourceRecord>(ResourceRecordQuery.text(instance), timeout: inner)
          .toList();
      final txt = txts.isEmpty ? <String, String>{} : parseServiceTxt(txts.map((t) => t.text).join('\n'));
      final addresses = await mdns
          .lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(srv.target), timeout: inner)
          .map((r) => r.address)
          .toList();
      found[instance] = DiscoveredHub(
        instance: instance,
        host: srv.target,
        port: srv.port,
        addresses: addresses,
        deviceId: txt['id'],
        familyId: txt['f'],
        txt: txt,
      );
    }
  } finally {
    mdns.stop();
  }
  return found.values.toList();
}

/// Largest WebSocket message [syncWebSocketHandler] accepts: a session frame of
/// [maxSessionMessageBytes], base64 encoded (text-only channels), with room to spare.
const int maxSyncSocketMessageBytes = 2 * maxSessionMessageBytes + 1024;

/// A shelf handler that upgrades to a WebSocket and serves [node]'s sync protocol on it; mount
/// it at `/ws`. Messages are bounded by [maxMessageBytes] before they are buffered (see
/// [boundedWebSocketHandler]).
Handler syncWebSocketHandler(
  SyncNode node, {
  Duration? pingInterval = const Duration(seconds: 30),
  int maxMessageBytes = maxSyncSocketMessageBytes,
}) =>
    boundedWebSocketHandler(
      (socket) => unawaited(node.serve(socket)),
      maxMessageBytes: maxMessageBytes,
      pingInterval: pingInterval,
    );

/// A shelf handler that upgrades to a WebSocket like `webSocketHandler`, but reads the header of
/// every incoming frame as it arrives and closes the connection (protocol error) as soon as a
/// frame, or the fragments of one message, announce more than [maxMessageBytes] of payload, so
/// an oversized message is refused before any of it is buffered. (dart:io and browser
/// WebSockets, on the client side, have no such hook: they buffer each whole message, and
/// sessions refuse an oversized frame before decrypting it.)
Handler boundedWebSocketHandler(
  void Function(WebSocketChannel socket) onConnection, {
  required int maxMessageBytes,
  Duration? pingInterval,
}) {
  final upgrade = webSocketHandler(
    (WebSocketChannel socket, String? _) => onConnection(socket),
    pingInterval: pingInterval,
  );
  return (Request request) async {
    if (!request.canHijack) return upgrade(request);
    // shelf_web_socket checks and answers the handshake on a copy of the request, whose socket
    // is the real one with its incoming bytes passed through the guard. shelf hands a hijacked
    // socket over later, so the copy waits for the real request's.
    final raw = Completer<StreamChannel<List<int>>>();
    final guarded = Request(
      request.method,
      request.requestedUri,
      protocolVersion: request.protocolVersion,
      headers: request.headersAll,
      handlerPath: request.handlerPath,
      url: request.url,
      context: request.context,
      onHijack: (callback) => unawaited(raw.future.then((channel) {
        final socket = channel.sink;
        if (socket is! Socket) {
          callback(channel);
          return;
        }
        final bounded = _BoundedSocket(socket, maxMessageBytes);
        callback(StreamChannel<List<int>>(bounded, bounded));
      })),
    );
    try {
      return await upgrade(guarded);
    } on HijackException {
      // It was a good handshake: take the socket from the server now, so the server knows it's
      // taken, and pass it on once it lets go of it.
      request.hijack(raw.complete);
    }
  };
}

/// A server's socket whose incoming bytes pass through a [WebSocketFrameGuard]: unchanged up to
/// the first frame over the limit, then an error, and nothing more is read. Everything else is
/// the socket's own.
class _BoundedSocket extends Stream<Uint8List> implements Socket {
  _BoundedSocket(this._socket, int maxMessageBytes) : _guard = WebSocketFrameGuard(maxMessageBytes);

  final Socket _socket;
  final WebSocketFrameGuard _guard;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final out = StreamController<Uint8List>(sync: true);
    StreamSubscription<Uint8List>? input;
    out
      ..onListen = () {
        input = _socket.listen(
          (chunk) {
            final fine = _guard.take(chunk);
            if (fine == chunk.length) {
              out.add(chunk);
              return;
            }
            if (fine > 0) out.add(Uint8List.sublistView(chunk, 0, fine));
            out.addError(const _MessageTooLarge());
            unawaited(input?.cancel());
            unawaited(out.close());
          },
          onError: out.addError,
          onDone: out.close,
        );
      }
      ..onPause = (() => input?.pause())
      ..onResume = (() => input?.resume())
      ..onCancel = (() => input?.cancel());
    return out.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  Encoding get encoding => _socket.encoding;

  @override
  set encoding(Encoding value) => _socket.encoding = value;

  @override
  void add(List<int> data) => _socket.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _socket.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _socket.addStream(stream);

  @override
  Future<void> flush() => _socket.flush();

  @override
  Future<void> close() => _socket.close();

  @override
  Future<void> get done => _socket.done;

  @override
  void write(Object? object) => _socket.write(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) => _socket.writeAll(objects, separator);

  @override
  void writeln([Object? object = '']) => _socket.writeln(object);

  @override
  void writeCharCode(int charCode) => _socket.writeCharCode(charCode);

  @override
  void destroy() => _socket.destroy();

  @override
  bool setOption(SocketOption option, bool enabled) => _socket.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) => _socket.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);

  @override
  int get port => _socket.port;

  @override
  int get remotePort => _socket.remotePort;

  @override
  InternetAddress get address => _socket.address;

  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;
}

class _MessageTooLarge implements Exception {
  const _MessageTooLarge();

  @override
  String toString() => 'WebSocket message too large';
}

/// Follows the frame headers (RFC 6455) in a WebSocket's incoming bytes, chunk by chunk, and
/// says when a data frame, or a message's fragments together, announce more than
/// [maxMessageBytes] of payload, or a control frame more than the 125 bytes it may have. It
/// keeps only the header bytes it is reading, never payload.
class WebSocketFrameGuard {
  /// Creates a guard for one connection's incoming bytes.
  WebSocketFrameGuard(this.maxMessageBytes);

  /// Largest payload of one message.
  final int maxMessageBytes;

  final List<int> _header = [];
  int _headerLength = 2;
  int _payloadLeft = 0;
  int _message = 0;
  bool _over = false;

  /// Reads [chunk]; false once a frame is over the limit, and from then on.
  bool accept(List<int> chunk) => take(chunk) == chunk.length;

  /// Reads [chunk] and returns how many of its bytes come before the first frame over the limit:
  /// all of them while every frame fits, and none once one hasn't.
  int take(List<int> chunk) {
    if (_over) return 0;
    var i = 0;
    var frameStart = 0;
    while (i < chunk.length) {
      if (_payloadLeft > 0) {
        final n = chunk.length - i < _payloadLeft ? chunk.length - i : _payloadLeft;
        _payloadLeft -= n;
        i += n;
        continue;
      }
      if (_header.isEmpty) frameStart = i;
      _header.add(chunk[i++]);
      if (_header.length == 2) {
        final short = _header[1] & 0x7f;
        final masked = (_header[1] & 0x80) != 0;
        _headerLength = 2 + (short == 126 ? 2 : (short == 127 ? 8 : 0)) + (masked ? 4 : 0);
      }
      if (_header.length < 2 || _header.length < _headerLength) continue;
      final length = _payloadLength();
      final opcode = _header[0] & 0x0f;
      final fin = (_header[0] & 0x80) != 0;
      _header.clear();
      _headerLength = 2;
      final over = length == null ||
          (opcode >= 8 ? length > 125 : (opcode != 0 ? 0 : _message) + length > maxMessageBytes);
      if (over) {
        _over = true;
        return frameStart;
      }
      if (opcode < 8) _message = fin ? 0 : (opcode != 0 ? 0 : _message) + length;
      _payloadLeft = length;
    }
    return chunk.length;
  }

  /// The payload length in the header just read, or null when it is absurd (past 2^32).
  int? _payloadLength() {
    final short = _header[1] & 0x7f;
    if (short < 126) return short;
    if (short == 126) return (_header[2] << 8) | _header[3];
    for (var k = 2; k < 6; k++) {
      if (_header[k] != 0) return null;
    }
    return (_header[6] << 24) | (_header[7] << 16) | (_header[8] << 8) | _header[9];
  }
}

/// Serves [node] at `ws://<address>:<port>/ws` (port 0 picks a free one). For hubs that need
/// nothing else on the port, and for tests.
Future<HttpServer> serveSync(
  SyncNode node, {
  Object? address,
  int port = hubPort,
}) {
  final ws = syncWebSocketHandler(node);
  return shelf_io.serve(
    (Request request) {
      if (request.url.path == 'ws') return ws(request);
      if (request.url.path == 'health') return Response.ok('{"ok":true}', headers: {'content-type': 'application/json'});
      return Response.notFound('not found');
    },
    address ?? InternetAddress.anyIPv4,
    port,
  );
}
