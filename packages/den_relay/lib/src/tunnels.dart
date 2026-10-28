import 'dart:async';
import 'dart:convert';

import 'package:async/async.dart';
import 'package:den_core/den_core.dart' show b64e, randomBytes;
import 'package:den_net/relay_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'config.dart';

class _Tunnel {
  _Tunnel(this.hubId, this.socket, this.owner);

  final String hubId;
  final WebSocketChannel socket;

  /// The client (see `clientKeyOf`) the hub connected from.
  final String owner;
  final Map<int, WebSocketChannel> clients = {};

  /// Stream id -> the client it came from.
  final Map<int, String> from = {};

  int streamsFrom(String client) => clients.keys.where((id) => from[id] == client).length;
  int _nextStream = 1;
  bool closed = false;

  int nextStream() {
    final id = _nextStream;
    _nextStream = _nextStream >= 0xfffffffe ? 1 : _nextStream + 1;
    return id;
  }

  void send(int op, int stream, [List<int> payload = const []]) {
    if (!closed) socket.sink.add(encodeTunnelFrame(op, stream, payload));
  }

  void close(int code) {
    if (closed) return;
    closed = true;
    unawaited(socket.sink.close(code));
    final open = clients.values.toList();
    clients.clear();
    for (final client in open) {
      unawaited(client.sink.close(RelayClose.notFound));
    }
  }
}

/// Hub tunnels: each hub keeps one authenticated WebSocket at `/tunnel/<hubId>`; every client
/// at `/connect/<hubId>` becomes a stream multiplexed over it (see [TunnelOp]).
class TunnelRegistry {
  /// Creates an empty registry.
  TunnelRegistry(this.config);

  /// Limits.
  final RelayConfig config;

  final Map<String, _Tunnel> _tunnels = {};

  /// Hubs with an open tunnel.
  int get count => _tunnels.length;

  /// Whether [hubId] has an open tunnel.
  bool has(String hubId) => _tunnels.containsKey(hubId);

  /// Whether a new tunnel for [hubId] from [client] would fit under the caps: the relay's, and
  /// the client's share. A hub replacing its own tunnel always fits.
  bool canOpen(String hubId, {String client = ''}) {
    if (_tunnels.containsKey(hubId)) return true;
    if (_tunnels.length >= config.maxTunnels) return false;
    return _tunnels.values.where((t) => t.owner == client).length < config.maxTunnelsPerClient;
  }

  /// Whether [client] may open another stream through [hubId]'s tunnel: under the tunnel's cap
  /// and the client's share of it, so nobody can take a family's every slot.
  bool canConnect(String hubId, {String client = ''}) {
    final tunnel = _tunnels[hubId];
    if (tunnel == null || tunnel.closed) return false;
    return tunnel.clients.length < config.maxStreamsPerTunnel &&
        tunnel.streamsFrom(client) < config.maxStreamsPerClient;
  }

  /// Runs the challenge, then forwards frames until the hub disconnects.
  ///
  /// The relay sends `{"t":"challenge","nonce":<32 random bytes, base64url>}`; the hub answers
  /// `{"t":"auth","pubkey","sig"}` where `sig` signs [tunnelAuthBytes] and `pubkey` hashes to
  /// [hubId]. A forged or late answer closes the socket with [RelayClose.unauthorized]. A newer
  /// authenticated tunnel for the same hub replaces the older one.
  Future<void> serveHub(WebSocketChannel socket, String hubId, {String client = ''}) async {
    final nonce = b64e(randomBytes(32));
    socket.sink.add(jsonEncode({'t': 'challenge', 'nonce': nonce}));
    final queue = StreamQueue<dynamic>(socket.stream);
    var authed = false;
    try {
      final answer = await queue.next.timeout(config.authTimeout);
      if (answer is String && answer.length < 4096) {
        final json = jsonDecode(answer);
        if (json is Map && json['t'] == 'auth' && json['pubkey'] is String && json['sig'] is String) {
          authed = await verifyTunnelAuth(
            hubId: hubId,
            nonce: nonce,
            pubkey: json['pubkey'] as String,
            sig: json['sig'] as String,
          );
        }
      }
    } on Object {
      authed = false;
    }
    if (!authed) {
      await queue.cancel(immediate: true);
      await socket.sink.close(RelayClose.unauthorized);
      return;
    }
    if (!canOpen(hubId, client: client)) {
      await queue.cancel(immediate: true);
      await socket.sink.close(RelayClose.full);
      return;
    }
    _tunnels.remove(hubId)?.close(RelayClose.replaced);
    final tunnel = _Tunnel(hubId, socket, client);
    _tunnels[hubId] = tunnel;
    socket.sink.add(jsonEncode({'t': 'ready'}));
    try {
      await for (final message in queue.rest) {
        if (message is! List<int>) continue;
        if (message.length > config.maxMessageBytes + 5) {
          tunnel.close(RelayClose.tooLarge);
          break;
        }
        final frame = decodeTunnelFrame(message);
        if (frame == null) continue;
        final client = tunnel.clients[frame.stream];
        if (client == null) continue;
        switch (frame.op) {
          case TunnelOp.text:
            try {
              client.sink.add(utf8.decode(frame.payload));
            } on FormatException {
              tunnel.clients.remove(frame.stream);
              unawaited(client.sink.close());
            }
          case TunnelOp.binary:
            client.sink.add(frame.payload);
          case TunnelOp.close:
            tunnel.clients.remove(frame.stream);
            unawaited(client.sink.close());
        }
      }
    } on Object {
      // The hub's socket failed; treated like a disconnect.
    } finally {
      if (identical(_tunnels[hubId], tunnel)) _tunnels.remove(hubId);
      tunnel.close(RelayClose.notFound);
    }
  }

  /// Pipes one client socket through [hubId]'s tunnel until either side closes. [from] is the
  /// client it came from (see `clientKeyOf`).
  void serveClient(WebSocketChannel client, String hubId, {String from = ''}) {
    final tunnel = _tunnels[hubId];
    if (tunnel == null || tunnel.closed) {
      unawaited(client.sink.close(RelayClose.notFound));
      return;
    }
    if (!canConnect(hubId, client: from)) {
      unawaited(client.sink.close(RelayClose.full));
      return;
    }
    final id = tunnel.nextStream();
    tunnel.clients[id] = client;
    tunnel.from[id] = from;
    tunnel.send(TunnelOp.open, id);
    client.stream.listen(
      (message) {
        if (!identical(tunnel.clients[id], client)) return;
        final List<int> bytes;
        final int op;
        if (message is String) {
          bytes = utf8.encode(message);
          op = TunnelOp.text;
        } else if (message is List<int>) {
          bytes = message;
          op = TunnelOp.binary;
        } else {
          return;
        }
        if (bytes.length > config.maxMessageBytes) {
          tunnel.clients.remove(id);
          tunnel.send(TunnelOp.close, id);
          unawaited(client.sink.close(RelayClose.tooLarge));
          return;
        }
        tunnel.send(op, id, bytes);
      },
      onDone: () {
        tunnel.from.remove(id);
        if (identical(tunnel.clients.remove(id), client)) tunnel.send(TunnelOp.close, id);
      },
      onError: (Object _) {},
      cancelOnError: true,
    );
  }

  /// Closes every tunnel.
  void closeAll() {
    for (final t in _tunnels.values.toList()) {
      t.close(RelayClose.notFound);
    }
    _tunnels.clear();
  }
}
