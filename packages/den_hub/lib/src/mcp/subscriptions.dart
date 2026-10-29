import 'dart:async';
import 'dart:convert';

import 'package:den_core/den_core.dart' show hashToken;
import 'package:shelf/shelf.dart';

import '../access.dart';
import '../context.dart';
import '../feed.dart';
import '../http_util.dart';
import 'server.dart';

/// `subscriptions/listen` over Streamable HTTP (2026-07-28): a server-sent event stream that
/// stays open and tells the client when a Den resource it subscribed to has changed.
///
/// Of the filter, only `resourceSubscriptions` is honored, for resources the caller may read
/// (at most [maxResources]); Den's lists of tools, prompts and resources don't change while the
/// hub runs, so the acknowledgment leaves those out. After each batch of changes on the hub,
/// each subscribed resource is read again as the caller, and a changed one gets
/// `notifications/resources/updated`. The stream pings every [ping], ends when the token stops
/// working, and ends with a final result when the hub stops.
class McpListen {
  /// Subscriptions for [server], told about changes by [feed].
  McpListen(this.hub, this.server, this.feed, {this.ping = const Duration(seconds: 20)});

  /// Shared hub context.
  final HubContext hub;

  /// Reads the resources.
  final McpServer server;

  /// What changed on the hub.
  final ChangeFeed feed;

  /// Keep-alive interval.
  final Duration ping;

  /// Most resources one subscription follows.
  static const int maxResources = 20;

  /// Most subscriptions open at once.
  static const int maxStreams = 50;

  final Set<_Listener> _open = {};

  /// Number of open subscriptions.
  int get openStreams => _open.length;

  /// Opens subscription [id] for [access] (holding [token], checked again on every ping) with the
  /// filter in [params].
  Response open(Request request, Access access, String token, Object? id, Map<String, Object?> params, Map<String, String> headers) {
    if (_open.length >= maxStreams) {
      return jsonResponse(McpServer.errorResponse(id, RpcError.internal, 'Too many open subscriptions; try again later'),
          status: 503, headers: headers);
    }
    final filter = params['notifications'];
    final asked = filter is Map ? filter['resourceSubscriptions'] : null;
    final uris = <String>{
      if (asked is List)
        for (final u in asked)
          if (u is String && server.canRead(access, u)) u,
    }.take(maxResources).toList();
    final controller = StreamController<List<int>>();
    final listener = _Listener(this, access, token, id, uris, controller);
    _open.add(listener);
    controller.onCancel = listener.close;
    listener.start();
    return Response.ok(
      controller.stream,
      headers: {
        ...headers,
        'content-type': 'text/event-stream; charset=utf-8',
        'cache-control': 'no-cache',
        'x-accel-buffering': 'no',
      },
      context: {'shelf.io.buffer_output': false},
    );
  }

  /// Ends every subscription with a final result.
  Future<void> shutdown() async {
    for (final l in List.of(_open)) {
      await l.finish();
    }
  }
}

class _Listener {
  _Listener(this.listen, this.access, this.token, this.id, this.uris, this.controller);

  final McpListen listen;
  final Access access;
  final String token;
  final Object? id;
  final List<String> uris;
  final StreamController<List<int>> controller;
  final Map<String, String> _seen = {};
  StreamSubscription<ChangeBatch>? _batches;
  Timer? _ping;
  bool _closed = false;
  bool _checking = false;
  bool _again = false;

  HubContext get hub => listen.hub;

  void _write(String text) {
    if (_closed || controller.isClosed) return;
    controller.add(utf8.encode(text));
  }

  void _send(Map<String, Object?> message) => _write('data: ${jsonEncode(message)}\n\n');

  void start() {
    _send(McpServer.acknowledgement(id, {if (uris.isNotEmpty) 'resourceSubscriptions': uris}));
    _batches = listen.feed.batches.listen((_) => _changed());
    _ping = Timer.periodic(listen.ping, (_) {
      if (_valid()) _write(':\n\n');
    });
    _checking = true;
    unawaited(_baseline());
  }

  Future<void> _baseline() async {
    for (final u in uris) {
      _seen[u] = await _fingerprint(u);
    }
    _done();
  }

  void _done() {
    _checking = false;
    if (_again && !_closed) {
      _again = false;
      unawaited(_check());
    }
  }

  void _changed() {
    if (_closed || uris.isEmpty || !_valid()) return;
    if (_checking) {
      _again = true;
      return;
    }
    unawaited(_check());
  }

  Future<void> _check() async {
    _checking = true;
    try {
      for (final u in uris) {
        if (_closed) return;
        final now = await _fingerprint(u);
        if (now == _seen[u]) continue;
        _seen[u] = now;
        _send({
          'jsonrpc': '2.0',
          'method': 'notifications/resources/updated',
          'params': {
            '_meta': {McpMeta.subscriptionId: id},
            'uri': u,
          },
        });
      }
    } finally {
      _done();
    }
  }

  Future<String> _fingerprint(String uri) async {
    try {
      return hashToken(jsonEncode(await listen.server.readResource(access, uri)));
    } on Object {
      return '';
    }
  }

  /// Whether the token still works; closes the stream when it doesn't.
  bool _valid() {
    final current = hub.access(token);
    if (current != null && current.connection.id == access.connection.id) return true;
    unawaited(close());
    if (!controller.isClosed) unawaited(controller.close());
    return false;
  }

  /// Sends the final result and closes.
  Future<void> finish() async {
    _send({
      'jsonrpc': '2.0',
      'id': id,
      'result': {
        'resultType': 'complete',
        '_meta': {McpMeta.subscriptionId: id, McpMeta.serverInfo: McpServer.serverInfo},
      },
    });
    await close();
    if (!controller.isClosed) unawaited(controller.close());
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    listen._open.remove(this);
    _ping?.cancel();
    await _batches?.cancel();
  }
}
