import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:den_core/den_core.dart' show b64e;
import 'package:den_net/io.dart' show boundedWebSocketHandler;
import 'package:den_net/relay_protocol.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'config.dart';
import 'mailbox_store.dart';
import 'rate_limit.dart';
import 'rendezvous.dart';
import 'tunnels.dart';

/// The relay's version, reported by `/health`.
const String relayVersion = '1.0.0';

/// Den's relay: hub tunnels, sealed mailboxes and pairing rendezvous over HTTP and WebSockets.
///
/// It keeps no accounts, sees only ciphertext and never logs content, mailbox ids, slots or
/// hub ids.
class RelayServer {
  RelayServer._(this.config, this.mailboxes)
      : tunnels = TunnelRegistry(config),
        slots = RendezvousSlots(config),
        _ipLimiter = RateLimiter(config.ipRate, config.currentMillis),
        _writeLimiter = RateLimiter(config.mailboxWriteRate, config.currentMillis),
        _readLimiter = RateLimiter(config.mailboxReadRate, config.currentMillis);

  /// Settings.
  final RelayConfig config;

  /// Persistent mailboxes.
  final MailboxStore mailboxes;

  /// Hub tunnels.
  final TunnelRegistry tunnels;

  /// Pairing slots.
  final RendezvousSlots slots;

  final RateLimiter _ipLimiter;
  final RateLimiter _writeLimiter;
  final RateLimiter _readLimiter;
  HttpServer? _http;
  Timer? _sweeper;

  /// Opens the mailbox store and returns a relay whose [handler] can be served.
  static Future<RelayServer> create(RelayConfig config) async {
    final store = MailboxStore(config);
    await store.open();
    final server = RelayServer._(config, store);
    await store.sweep();
    server._sweeper = Timer.periodic(config.sweepInterval, (_) {
      unawaited(store.sweep().then((_) {}, onError: (Object _) {}));
      server._ipLimiter.prune();
      server._writeLimiter.prune();
      server._readLimiter.prune();
    });
    return server;
  }

  /// Creates a relay and serves it on [port] (0 picks a free one).
  static Future<RelayServer> start(RelayConfig config, {Object? address, int port = relayPort}) async {
    final server = await create(config);
    server._http = await shelf_io.serve(server.handler, address ?? InternetAddress.anyIPv4, port);
    server._http!.idleTimeout = const Duration(seconds: 120);
    return server;
  }

  /// The port being served, after [start].
  int get port => _http!.port;

  /// Stops serving and closes every tunnel and slot.
  Future<void> close() async {
    _sweeper?.cancel();
    tunnels.closeAll();
    slots.closeAll();
    await _http?.close(force: true);
  }

  /// The shelf handler for every route.
  Handler get handler => (Request request) async {
        try {
          return await _route(request);
        } on HijackException {
          rethrow;
        } on Object catch (e) {
          stderr.writeln('den_relay: internal error (${e.runtimeType})');
          return _json(500, {'error': 'internal'});
        }
      };

  Future<Response> _route(Request request) async {
    final segments = request.url.pathSegments;
    if (segments.length == 1 && segments[0] == 'health' && request.method == 'GET') {
      return _json(200, {'ok': true, 'version': relayVersion});
    }
    final client = clientKeyOf(_clientAddress(request));
    final wait = _ipLimiter.take(client);
    if (wait != null) return _tooMany(wait);
    if (segments.length != 2) return _json(404, {'error': 'not found'});
    final kind = segments[0];
    final key = segments[1];
    switch (kind) {
      case 'tunnel' when request.method == 'GET':
        if (!deviceIdPattern.hasMatch(key)) return _json(400, {'error': 'bad hub id'});
        if (!tunnels.canOpen(key, client: client)) return _json(503, {'error': 'relay full'});
        // A hub's tunnel frames carry a 5-byte header around each client message.
        return _upgrade(request, (ws) => unawaited(tunnels.serveHub(ws, key, client: client)), extra: 5);
      case 'connect' when request.method == 'GET':
        if (!deviceIdPattern.hasMatch(key)) return _json(400, {'error': 'bad hub id'});
        if (!tunnels.has(key)) return _json(404, {'error': 'hub not connected'});
        if (!tunnels.canConnect(key, client: client)) return _json(503, {'error': 'hub full'});
        return _upgrade(request, (ws) => tunnels.serveClient(ws, key, from: client));
      case 'rendezvous' when request.method == 'GET':
        if (!relayKeyPattern.hasMatch(key)) return _json(400, {'error': 'bad slot'});
        final role = request.url.queryParameters['role'];
        if (role == 'host') {
          if (slots.hasHost(key)) return _json(409, {'error': 'slot taken'});
          if (!slots.canHost(key, client: client)) return _json(503, {'error': 'relay full'});
          return _upgrade(request, (ws) => slots.host(ws, key, client: client));
        }
        if (role == 'guest') {
          if (!slots.hasHost(key)) return _json(404, {'error': 'nobody waiting'});
          return _upgrade(request, (ws) => slots.guest(ws, key));
        }
        return _json(400, {'error': 'role must be host or guest'});
      case 'mailbox':
        if (!relayKeyPattern.hasMatch(key)) return _json(400, {'error': 'bad mailbox id'});
        if (request.method == 'POST') return _append(request, key, client);
        if (request.method == 'GET') return _read(request, key);
        return _json(405, {'error': 'method not allowed'});
    }
    return _json(404, {'error': 'not found'});
  }

  Future<Response> _append(Request request, String id, String client) async {
    final wait = _writeLimiter.take(id);
    if (wait != null) return _tooMany(wait);
    final declared = request.contentLength;
    if (declared != null && declared > config.maxBlobBytes) return _json(413, {'error': 'blob too large'});
    final body = BytesBuilder(copy: false);
    await for (final chunk in request.read()) {
      body.add(chunk);
      if (body.length > config.maxBlobBytes) return _json(413, {'error': 'blob too large'});
    }
    if (body.isEmpty) return _json(400, {'error': 'empty blob'});
    try {
      final cursor = await mailboxes.append(id, body.takeBytes(), client: client);
      return _json(200, {'cursor': cursor});
    } on StoreFull catch (e) {
      return _json(507, {'error': 'full', 'cap': e.reason});
    }
  }

  Future<Response> _read(Request request, String id) async {
    final wait = _readLimiter.take(id);
    if (wait != null) return _tooMany(wait);
    final after = int.tryParse(request.url.queryParameters['after'] ?? '0');
    final limitParam = request.url.queryParameters['limit'];
    final limit = limitParam == null ? null : int.tryParse(limitParam);
    if (after == null || after < 0 || (limitParam != null && (limit == null || limit < 1))) {
      return _json(400, {'error': 'bad cursor'});
    }
    final slice = await mailboxes.read(id, after: after, limit: limit);
    return _json(200, {
      'items': [
        for (final b in slice.blobs) {'c': b.cursor, 'b': b64e(b.bytes)},
      ],
      'next': slice.next,
      'more': slice.more,
    });
  }

  /// Upgrades to a WebSocket whose messages are bounded by [RelayConfig.maxMessageBytes] (plus
  /// [extra]) before they are buffered: a frame announcing more closes the connection.
  Future<Response> _upgrade(Request request, void Function(WebSocketChannel socket) onSocket, {int extra = 0}) async {
    final handler = boundedWebSocketHandler(
      onSocket,
      maxMessageBytes: config.maxMessageBytes + extra,
      pingInterval: config.pingInterval,
    );
    return await handler(request);
  }

  String _clientAddress(Request request) {
    if (config.trustProxy) {
      final forwarded = request.headers['x-forwarded-for'];
      if (forwarded != null) {
        final parts = forwarded.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
        if (parts.isNotEmpty) return parts.last;
      }
    }
    final info = request.context['shelf.io.connection_info'];
    if (info is HttpConnectionInfo) return info.remoteAddress.address;
    return 'unknown';
  }
}

Response _json(int status, Map<String, Object?> body) => Response(
      status,
      body: jsonEncode(body),
      headers: {'content-type': 'application/json', 'cache-control': 'no-store'},
    );

Response _tooMany(int seconds) => Response(
      429,
      body: jsonEncode({'error': 'rate limited'}),
      headers: {'content-type': 'application/json', 'retry-after': '$seconds'},
    );
