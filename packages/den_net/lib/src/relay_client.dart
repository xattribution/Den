import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:den_core/den_core.dart';
import 'package:http/http.dart' as http;
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'invite.dart';
import 'relay_protocol.dart';
import 'util.dart';

/// Opens a message channel to [uri]; the default is a WebSocket.
typedef ChannelConnector = Future<StreamChannel<dynamic>> Function(Uri uri);

/// Connects a WebSocket and waits until it is open. Works in the VM and in browsers.
Future<StreamChannel<dynamic>> connectWebSocket(Uri uri) async {
  final channel = WebSocketChannel.connect(uri);
  await channel.ready;
  return channel;
}

/// A relay refused a request or broke protocol.
class RelayException implements Exception {
  /// Creates the exception.
  RelayException(this.message, {this.status});

  /// What went wrong.
  final String message;

  /// HTTP status, when there was one.
  final int? status;

  @override
  String toString() => 'RelayException: $message${status == null ? '' : ' ($status)'}';
}

Uri _withScheme(Uri relay, {required bool websocket}) {
  final secure = relay.scheme == 'https' || relay.scheme == 'wss';
  return relay.replace(scheme: websocket ? (secure ? 'wss' : 'ws') : (secure ? 'https' : 'http'));
}

Uri _relayPath(Uri relay, List<String> segments, {required bool websocket, Map<String, String>? query}) {
  final base = _withScheme(relay, websocket: websocket);
  final prefix = base.pathSegments.where((s) => s.isNotEmpty);
  return base.replace(pathSegments: [...prefix, ...segments], queryParameters: query);
}

/// `wss://relay/tunnel/<hubId>`: where a hub keeps its tunnel open.
Uri relayTunnelUri(Uri relay, String hubId) => _relayPath(relay, ['tunnel', hubId], websocket: true);

/// `wss://relay/connect/<hubId>`: where devices reach a hub through its tunnel.
Uri relayConnectUri(Uri relay, String hubId) => _relayPath(relay, ['connect', hubId], websocket: true);

/// `wss://relay/rendezvous/<slot>?role=host|guest`: a one-shot meeting point for pairing.
Uri relayRendezvousUri(Uri relay, String slot, {required bool host}) =>
    _relayPath(relay, ['rendezvous', slot], websocket: true, query: {'role': host ? 'host' : 'guest'});

/// The hub id in a `/connect/<hubId>` URL, or null when [uri] isn't one.
String? hubIdOfConnectUri(Uri uri) {
  final segments = uri.pathSegments;
  if (segments.length < 2 || segments[segments.length - 2] != 'connect') return null;
  final id = segments.last;
  return deviceIdPattern.hasMatch(id) ? id : null;
}

/// State of a hub's relay tunnel.
enum TunnelState {
  /// Opening the socket or authenticating.
  connecting,

  /// Authenticated; clients can connect through the relay.
  online,

  /// Disconnected; waiting to retry.
  offline,

  /// Stopped by [RelayTunnel.stop].
  stopped,
}

/// A tunnel state with the last error, if any.
class TunnelStatus {
  /// Creates a status.
  const TunnelStatus(this.state, [this.lastError]);

  /// The state.
  final TunnelState state;

  /// Why the last attempt failed.
  final String? lastError;

  @override
  String toString() => 'TunnelStatus(${state.name}${lastError == null ? '' : ': $lastError'})';
}

/// The hub side of a relay tunnel: keeps `/tunnel/<hubId>` open, answers the relay's challenge
/// with a signature, and hands each client stream to [onClient] as an ordinary channel, which
/// carries the end-to-end session handshake like a direct WebSocket.
///
/// Client streams are multiplexed over the one socket (see [TunnelOp]).
class RelayTunnel {
  /// Creates a tunnel; call [start].
  RelayTunnel({
    required this.relay,
    required this.keys,
    required this.onClient,
    ChannelConnector? connector,
    this.minBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(minutes: 2),
  }) : _connector = connector ?? connectWebSocket;

  /// The relay's base URL.
  final Uri relay;

  /// The hub's device keys.
  final DeviceKeys keys;

  /// Receives each client stream; typically `SyncNode.serve`.
  final void Function(StreamChannel<dynamic> client) onClient;

  /// First retry delay.
  final Duration minBackoff;

  /// Longest retry delay.
  final Duration maxBackoff;

  final ChannelConnector _connector;
  final Map<int, StreamChannelController<dynamic>> _streams = {};
  final StreamController<TunnelStatus> _statusController = StreamController.broadcast();
  final Random _random = Random();
  TunnelStatus _status = const TunnelStatus(TunnelState.offline);
  StreamChannel<dynamic>? _socket;
  Completer<void>? _wake;
  bool _running = false;
  bool _stopped = false;

  /// The current status.
  TunnelStatus get status => _status;

  /// Status changes.
  Stream<TunnelStatus> get statusChanges => _statusController.stream;

  /// Number of client streams open right now.
  int get openStreams => _streams.length;

  /// Starts connecting and keeps reconnecting with backoff until [stop].
  void start() {
    if (_running || _stopped) return;
    _running = true;
    unawaited(_loop());
  }

  /// Completes once the tunnel is online.
  Future<void> whenOnline() {
    if (_status.state == TunnelState.online) return Future.value();
    return statusChanges.firstWhere((s) => s.state == TunnelState.online || s.state == TunnelState.stopped).then((s) {
      if (s.state == TunnelState.stopped) throw StateError('tunnel stopped');
    });
  }

  /// Closes the tunnel and every client stream.
  Future<void> stop() async {
    _stopped = true;
    if (_wake?.isCompleted == false) _wake!.complete();
    final socket = _socket;
    _socket = null;
    _closeStreams();
    if (socket != null) await socket.sink.close().timeout(const Duration(seconds: 2), onTimeout: () {});
    _setStatus(const TunnelStatus(TunnelState.stopped));
    await _statusController.close();
  }

  Future<void> _loop() async {
    var delay = minBackoff;
    final hubId = await keys.deviceId();
    while (!_stopped) {
      _setStatus(TunnelStatus(TunnelState.connecting, _status.lastError));
      String? error;
      var wasOnline = false;
      try {
        final socket = await _connector(relayTunnelUri(relay, hubId));
        if (_stopped) {
          await socket.sink.close();
          break;
        }
        _socket = socket;
        wasOnline = await _run(socket, hubId);
      } on Object catch (e) {
        error = e is RelayException ? e.message : e.toString();
      }
      _socket = null;
      _closeStreams();
      if (_stopped) break;
      if (wasOnline) delay = minBackoff;
      _setStatus(TunnelStatus(TunnelState.offline, error ?? 'tunnel closed'));
      final jitter = 0.5 + _random.nextDouble() / 2;
      _wake = Completer<void>();
      await Future.any([_wake!.future, Future<void>.delayed(delay * jitter)]);
      _wake = null;
      delay = delay * 2 > maxBackoff ? maxBackoff : delay * 2;
    }
  }

  Future<bool> _run(StreamChannel<dynamic> socket, String hubId) async {
    final queue = StreamQueue<dynamic>(socket.stream);
    final challenge = await _nextJson(queue);
    final nonce = challenge['nonce'];
    if (challenge['t'] != 'challenge' || nonce is! String) throw RelayException('expected a challenge');
    socket.sink.add(jsonEncode({
      't': 'auth',
      'pubkey': keys.pubkey,
      'sig': await keys.sign(tunnelAuthBytes(hubId, nonce)),
    }));
    final ready = await _nextJson(queue);
    if (ready['t'] != 'ready') throw RelayException('relay refused the tunnel');
    _setStatus(const TunnelStatus(TunnelState.online));
    await for (final message in queue.rest) {
      if (message is! List<int>) continue;
      final frame = decodeTunnelFrame(message);
      if (frame == null) continue;
      switch (frame.op) {
        case TunnelOp.open:
          _open(socket, frame.stream);
        case TunnelOp.text:
          final stream = _streams[frame.stream];
          if (stream != null) {
            try {
              stream.local.sink.add(utf8.decode(frame.payload));
            } on FormatException {
              _closeStream(socket, frame.stream, notify: true);
            }
          }
        case TunnelOp.binary:
          _streams[frame.stream]?.local.sink.add(Uint8List.fromList(frame.payload));
        case TunnelOp.close:
          _closeStream(socket, frame.stream, notify: false);
      }
    }
    return true;
  }

  void _open(StreamChannel<dynamic> socket, int id) {
    if (_streams.containsKey(id)) return;
    final controller = StreamChannelController<dynamic>();
    _streams[id] = controller;
    controller.local.stream.listen(
      (message) {
        if (!identical(_socket, socket)) return;
        if (message is String) {
          socket.sink.add(encodeTunnelFrame(TunnelOp.text, id, utf8.encode(message)));
        } else if (message is List<int>) {
          socket.sink.add(encodeTunnelFrame(TunnelOp.binary, id, message));
        }
      },
      onDone: () {
        if (_streams.remove(id) != null && identical(_socket, socket)) {
          socket.sink.add(encodeTunnelFrame(TunnelOp.close, id));
        }
      },
    );
    onClient(controller.foreign);
  }

  void _closeStream(StreamChannel<dynamic> socket, int id, {required bool notify}) {
    final controller = _streams.remove(id);
    if (controller == null) return;
    unawaited(controller.local.sink.close());
    if (notify && identical(_socket, socket)) socket.sink.add(encodeTunnelFrame(TunnelOp.close, id));
  }

  void _closeStreams() {
    final open = _streams.values.toList();
    _streams.clear();
    for (final controller in open) {
      unawaited(controller.local.sink.close());
    }
  }

  void _setStatus(TunnelStatus status) {
    _status = status;
    if (!_statusController.isClosed) _statusController.add(status);
  }
}

Future<Map<String, Object?>> _nextJson(StreamQueue<dynamic> queue) async {
  final Object? raw;
  try {
    raw = await queue.next.timeout(const Duration(seconds: 15));
  } on StateError {
    throw RelayException('relay closed the connection');
  } on TimeoutException {
    throw RelayException('relay did not answer');
  }
  if (raw is! String) throw RelayException('unexpected relay message');
  try {
    final decoded = asJsonObject(jsonDecode(raw));
    if (decoded == null) throw RelayException('unexpected relay message');
    return decoded;
  } on FormatException {
    throw RelayException('unexpected relay message');
  }
}

/// Meets the other side of a pairing at a relay rendezvous slot and returns the piped channel.
///
/// The host (the inviting device) waits up to [timeout] (default 15 minutes, the relay's slot
/// lifetime) for a guest; a guest fails at once when no host is waiting. The relay sends
/// `{"t":"paired"}` to both, then forwards messages unchanged, so the session handshake runs
/// end to end over the returned channel.
Future<StreamChannel<dynamic>> rendezvous(
  Uri relay,
  String slot, {
  required bool host,
  ChannelConnector? connector,
  Duration? timeout,
}) async {
  final StreamChannel<dynamic> socket;
  try {
    socket = await (connector ?? connectWebSocket)(relayRendezvousUri(relay, slot, host: host));
  } on Object {
    throw RelayException(host ? 'rendezvous slot unavailable' : 'nobody is waiting at the rendezvous');
  }
  final queue = StreamQueue<dynamic>(socket.stream);
  try {
    final first = await queue.next.timeout(timeout ?? (host ? const Duration(minutes: 15) : const Duration(seconds: 30)));
    final message = first is String ? asJsonObject(jsonDecode(first)) : null;
    if (message?['t'] != 'paired') throw RelayException('unexpected rendezvous message');
  } on Object catch (e) {
    unawaited(queue.cancel(immediate: true)?.then((_) {}, onError: (Object _) {}));
    unawaited(socket.sink.close().then((_) {}, onError: (Object _) {}));
    if (e is RelayException) rethrow;
    if (e is TimeoutException) throw RelayException('nobody arrived at the rendezvous');
    throw RelayException('rendezvous closed');
  }
  return StreamChannel<dynamic>.withCloseGuarantee(queue.rest, socket.sink);
}

/// Opens a channel to the device that showed [invite]: each hub URL in turn, then the relay
/// tunnel to the inviting device, then the invite's relay rendezvous slot (where an inviting
/// phone with no hub waits as host).
Future<StreamChannel<dynamic>> openInviteChannel(
  Invite invite, {
  ChannelConnector? connector,
  Duration attemptTimeout = const Duration(seconds: 10),
}) async {
  final connect = connector ?? connectWebSocket;
  Object? lastError;
  for (final hub in invite.hubs) {
    try {
      return await connect(hub).timeout(attemptTimeout);
    } on Object catch (e) {
      lastError = e;
    }
  }
  final relay = invite.relay;
  if (relay != null) {
    try {
      return await connect(relayConnectUri(relay, invite.inviterDevice)).timeout(attemptTimeout);
    } on Object catch (e) {
      lastError = e;
    }
    return rendezvous(relay, await invite.rendezvousSlot(), host: false, connector: connector);
  }
  throw RelayException('the inviting device is unreachable${lastError == null ? '' : ': $lastError'}');
}

/// One stored mailbox blob.
class MailboxEntry {
  /// Creates an entry.
  const MailboxEntry(this.cursor, this.blob);

  /// Position in the mailbox; read with `after` set to the last cursor seen.
  final int cursor;

  /// The sealed blob.
  final Uint8List blob;
}

/// A page of mailbox entries.
class MailboxPage {
  /// Creates a page.
  const MailboxPage(this.entries, this.next, this.more);

  /// Entries after the requested cursor, oldest first.
  final List<MailboxEntry> entries;

  /// Cursor to pass as `after` next time.
  final int next;

  /// Whether more entries are waiting.
  final bool more;
}

/// HTTP client for a relay's mailboxes: `POST /mailbox/<id>` and `GET /mailbox/<id>?after=`.
class RelayMailbox {
  /// Creates a client for the relay at [relay] (http, https, ws or wss).
  RelayMailbox(Uri relay, {http.Client? client})
      : _base = _withScheme(relay, websocket: false),
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  final Uri _base;
  final http.Client _client;
  final bool _ownsClient;

  Uri _uri(String id, [Map<String, String>? query]) {
    if (!relayKeyPattern.hasMatch(id)) throw ArgumentError('bad mailbox id');
    return _relayPath(_base, ['mailbox', id], websocket: false, query: query);
  }

  /// Appends [blob] (at most [maxRelayMessageBytes]) and returns its cursor.
  Future<int> append(String mailboxId, List<int> blob) async {
    if (blob.length > maxRelayMessageBytes) throw ArgumentError('blob too large');
    final response = await _client.post(
      _uri(mailboxId),
      headers: {'content-type': 'application/octet-stream'},
      body: blob,
    );
    if (response.statusCode != 200) throw RelayException('mailbox append failed', status: response.statusCode);
    final cursor = asJsonObject(jsonDecode(response.body))?['cursor'];
    if (cursor is! int) throw RelayException('bad mailbox response');
    return cursor;
  }

  /// Reads entries after [after].
  Future<MailboxPage> read(String mailboxId, {int after = 0, int? limit}) async {
    final response = await _client.get(_uri(mailboxId, {
      'after': '$after',
      if (limit != null) 'limit': '$limit',
    }));
    if (response.statusCode != 200) throw RelayException('mailbox read failed', status: response.statusCode);
    final json = asJsonObject(jsonDecode(response.body));
    final items = json?['items'];
    final next = json?['next'];
    if (items is! List || next is! int) throw RelayException('bad mailbox response');
    final entries = <MailboxEntry>[];
    for (final item in items) {
      final map = asJsonObject(item);
      final cursor = map?['c'];
      final blob = tryB64d(map?['b']);
      if (cursor is! int || blob == null) throw RelayException('bad mailbox response');
      entries.add(MailboxEntry(cursor, blob));
    }
    return MailboxPage(entries, next, json?['more'] == true);
  }

  /// Releases the HTTP client if this object created it.
  void close() {
    if (_ownsClient) _client.close();
  }
}
