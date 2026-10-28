/// Helpers for platforms with `dart:io`: LAN discovery of hubs over mDNS and serving the sync
/// protocol over WebSockets with shelf.
library;

import 'dart:async';
import 'dart:io';

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
    // shelf_web_socket checks and answers the handshake on a copy of the request whose socket
    // comes through the guard. shelf hands a hijacked socket over later, so the copy waits for
    // the real request's socket.
    final raw = Completer<StreamChannel<List<int>>>();
    final guarded = Request(
      request.method,
      request.requestedUri,
      protocolVersion: request.protocolVersion,
      headers: request.headersAll,
      handlerPath: request.handlerPath,
      url: request.url,
      context: request.context,
      onHijack: (callback) => unawaited(raw.future.then(
            (channel) => callback(channel.changeStream((bytes) => _limitFrames(bytes, maxMessageBytes))),
          )),
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

/// [input] (a WebSocket's raw incoming bytes) passed through unchanged until a frame is over
/// the limit; then an error, and nothing more is read.
Stream<List<int>> _limitFrames(Stream<List<int>> input, int maxMessageBytes) {
  final guard = WebSocketFrameGuard(maxMessageBytes);
  final out = StreamController<List<int>>(sync: true);
  StreamSubscription<List<int>>? subscription;
  out
    ..onListen = () {
      subscription = input.listen(
        (chunk) {
          if (guard.accept(chunk)) {
            out.add(chunk);
            return;
          }
          out.addError(const _MessageTooLarge());
          unawaited(subscription?.cancel());
          unawaited(out.close());
        },
        onError: out.addError,
        onDone: out.close,
      );
    }
    ..onPause = (() => subscription?.pause())
    ..onResume = (() => subscription?.resume())
    ..onCancel = (() => subscription?.cancel());
  return out.stream;
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
  bool accept(List<int> chunk) {
    if (_over) return false;
    var i = 0;
    while (i < chunk.length) {
      if (_payloadLeft > 0) {
        final n = chunk.length - i < _payloadLeft ? chunk.length - i : _payloadLeft;
        _payloadLeft -= n;
        i += n;
        continue;
      }
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
      if (length == null) return _overLimit();
      if (opcode >= 8) {
        if (length > 125) return _overLimit();
      } else {
        if (opcode != 0) _message = 0;
        _message += length;
        if (_message > maxMessageBytes) return _overLimit();
        if (fin) _message = 0;
      }
      _payloadLeft = length;
    }
    return true;
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

  bool _overLimit() {
    _over = true;
    return false;
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
