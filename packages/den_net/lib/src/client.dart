import 'dart:async';
import 'dart:math';

import 'relay_client.dart';
import 'session.dart';
import 'sync.dart';

/// What a [SyncClient] is doing.
enum SyncState {
  /// Opening a connection and running the handshake.
  connecting,

  /// Connected; exchanging what each side lacks (or waiting for a parent's approval).
  syncing,

  /// Caught up; live changes flow both ways.
  live,

  /// Disconnected; retrying after a backoff.
  offline,

  /// Stopped.
  stopped,
}

/// A client's state, the endpoint in use and the last error.
class SyncStatus {
  /// Creates a status.
  const SyncStatus(this.state, {this.endpoint, this.device, this.lastError, this.awaitingApproval = false});

  /// The state.
  final SyncState state;

  /// The endpoint connected or being tried.
  final Uri? endpoint;

  /// The device at [endpoint], once connected.
  final String? device;

  /// Why the last connection failed or ended.
  final String? lastError;

  /// The server reported this device isn't approved yet.
  final bool awaitingApproval;

  @override
  String toString() =>
      'SyncStatus(${state.name}${endpoint == null ? '' : ' $endpoint'}${lastError == null ? '' : ': $lastError'})';
}

/// Keeps one device synced with its hub: connects to the first reachable endpoint (direct
/// `ws(s)://host:47733/ws` URLs or relay tunnels `wss://relay/connect/<hubDeviceId>`), syncs,
/// stays live, and reconnects with exponential backoff and jitter.
///
/// A `/connect/<hubDeviceId>` endpoint pins the server to that device id. An endpoint whose
/// server this family doesn't trust (a hub that was removed, or one it never approved) goes to
/// the back of the line, and the next one is tried at once, so a dead hub still answering at a
/// saved address doesn't keep a device from the hub that replaced it.
class SyncClient {
  /// Creates a client; call [start].
  SyncClient({
    required this.node,
    required List<Uri> endpoints,
    this.expectDevice,
    this.expectPubkey,
    ChannelConnector? connector,
    this.minBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(minutes: 2),
    this.connectTimeout = const Duration(seconds: 15),
  })  : endpoints = List.unmodifiable(endpoints),
        _connector = connector ?? connectWebSocket;

  /// The node whose den is synced.
  final SyncNode node;

  /// Endpoints in preference order.
  final List<Uri> endpoints;

  /// Required server device id for every endpoint, if known.
  final String? expectDevice;

  /// Required server key for every endpoint, if known.
  final String? expectPubkey;

  /// First retry delay.
  final Duration minBackoff;

  /// Longest retry delay.
  final Duration maxBackoff;

  /// How long opening one endpoint may take.
  final Duration connectTimeout;

  final ChannelConnector _connector;
  final StreamController<SyncStatus> _controller = StreamController.broadcast();
  final Random _random = Random();
  SyncStatus _status = const SyncStatus(SyncState.offline);
  SyncPeer? _peer;
  Completer<void>? _wake;
  bool _running = false;
  bool _stopped = false;

  /// Endpoints whose server was refused, tried after the others.
  final Set<Uri> _refused = {};

  /// Close reasons that mean "not this server", not "not now".
  static const _refusals = {'removed', 'unknown-peer'};

  /// The current status.
  SyncStatus get status => _status;

  /// Status changes.
  Stream<SyncStatus> get statusChanges => _controller.stream;

  /// The live peer, while connected.
  SyncPeer? get peer => _peer;

  /// Starts the connect loop.
  void start() {
    if (_running || _stopped) return;
    _running = true;
    unawaited(_loop());
  }

  /// Retries at once instead of waiting out the backoff (after a network change, say).
  void retryNow() {
    if (_wake?.isCompleted == false) _wake!.complete();
  }

  /// Completes the next time the client is live.
  Future<void> whenLive() {
    if (_status.state == SyncState.live) return Future.value();
    return statusChanges.firstWhere((s) => s.state == SyncState.live || s.state == SyncState.stopped).then((s) {
      if (s.state == SyncState.stopped) throw StateError('client stopped');
    });
  }

  /// Disconnects and stops retrying.
  Future<void> stop() async {
    _stopped = true;
    retryNow();
    await _peer?.close();
    _set(SyncStatus(SyncState.stopped, lastError: _status.lastError));
    await _controller.close();
  }

  Future<void> _loop() async {
    var delay = minBackoff;
    while (!_stopped) {
      String? error;
      SyncPeer? peer;
      Uri? used;
      for (final endpoint in [...endpoints.where((e) => !_refused.contains(e)), ...endpoints.where(_refused.contains)]) {
        if (_stopped) break;
        _set(SyncStatus(SyncState.connecting, endpoint: endpoint, lastError: _status.lastError));
        try {
          final channel = await _connector(endpoint).timeout(connectTimeout);
          if (_stopped) {
            await channel.sink.close();
            break;
          }
          peer = await node.connect(
            channel,
            expectDevice: expectDevice ?? hubIdOfConnectUri(endpoint),
            expectPubkey: expectPubkey,
          );
          used = endpoint;
          break;
        } on Object catch (e) {
          error = _describe(e);
        }
      }
      if (peer != null) {
        _peer = peer;
        var wentLive = false;
        final device = peer.deviceId;
        _set(SyncStatus(SyncState.syncing, endpoint: used, device: device));
        final approvalWatch = Timer.periodic(const Duration(milliseconds: 500), (_) {
          if (peer!.awaitingApproval && !_status.awaitingApproval && _status.state == SyncState.syncing) {
            _set(SyncStatus(SyncState.syncing, endpoint: used, device: device, awaitingApproval: true));
          }
        });
        unawaited(peer.live.then((_) {
          wentLive = true;
          if (identical(_peer, peer) && !_stopped) _set(SyncStatus(SyncState.live, endpoint: used, device: device));
        }, onError: (Object _) {}));
        await peer.closed;
        approvalWatch.cancel();
        _peer = null;
        error = peer.closeReason ?? 'disconnected';
        if (wentLive) delay = minBackoff;
        if (_refusals.contains(error)) {
          // Another endpoint may reach the right hub: try it now rather than after the backoff
          // (once per refusal, so endpoints that can't be reached don't make this spin).
          if (_refused.add(used!) && !_stopped && endpoints.any((e) => !_refused.contains(e))) {
            _set(SyncStatus(SyncState.offline, endpoint: used, device: device, lastError: error));
            continue;
          }
        } else if (wentLive) {
          _refused.remove(used);
        }
      }
      if (_stopped) break;
      _set(SyncStatus(SyncState.offline, endpoint: used, lastError: error ?? 'no endpoint reachable'));
      final wake = _wake = Completer<void>();
      await Future.any([wake.future, Future<void>.delayed(delay * (0.5 + _random.nextDouble() / 2))]);
      _wake = null;
      delay = delay * 2 > maxBackoff ? maxBackoff : delay * 2;
    }
  }

  void _set(SyncStatus status) {
    _status = status;
    if (!_controller.isClosed) _controller.add(status);
  }
}

String _describe(Object error) {
  if (error is SessionException) return error.message;
  if (error is RelayException) return error.message;
  if (error is TimeoutException) return 'timed out';
  final text = error.toString();
  return text.length > 200 ? text.substring(0, 200) : text;
}
