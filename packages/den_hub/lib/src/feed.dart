import 'dart:async';
import 'dart:convert';

import 'package:den_core/den_core.dart';
import 'package:shelf/shelf.dart';

import 'access.dart';
import 'config.dart';
import 'context.dart';
import 'times.dart';

/// One record a batch touched.
class ChangedRecord {
  /// Creates the record reference.
  const ChangedRecord(this.type, this.id, this.space);

  /// Record type.
  final String type;

  /// Record id.
  final String id;

  /// Its space.
  final String space;
}

/// Changes newly stored on the hub (local writes, API and MCP writes, synced changes), gathered
/// for up to 250 ms.
class ChangeBatch {
  /// Creates a batch of [changes], in HLC order.
  ChangeBatch(this.changes, this.at);

  /// The changes, oldest first.
  final List<Change> changes;

  /// When the batch was applied (UTC ms).
  final int at;
}

/// Watches the hub's [Den] for newly stored changes and hands them out in batches.
class ChangeFeed {
  /// Starts watching [den]; changes already stored are not announced.
  ChangeFeed(this.den, {this.coalesce = const Duration(milliseconds: 250)}) {
    for (final c in den.changesSince(const {})) {
      _mark(c);
    }
    _advance();
    _subscription = den.onChange.listen((types) {
      if (types.any(RecordType.all.contains)) _schedule();
    });
  }

  /// The hub's engine.
  final Den den;

  /// How long changes are gathered into one batch.
  final Duration coalesce;

  final StreamController<ChangeBatch> _batches = StreamController.broadcast();
  final Map<String, int> _contiguous = {};
  final Map<String, Set<int>> _above = {};
  late final StreamSubscription<Set<String>> _subscription;
  Timer? _timer;

  /// Batches as they are applied.
  Stream<ChangeBatch> get batches => _batches.stream;

  void _mark(Change c) => (_above[c.device] ??= {}).add(c.counter);

  bool _seen(Change c) => c.counter <= (_contiguous[c.device] ?? 0) || (_above[c.device]?.contains(c.counter) ?? false);

  void _advance() {
    for (final e in _above.entries) {
      var n = _contiguous[e.key] ?? 0;
      while (e.value.remove(n + 1)) {
        n++;
      }
      _contiguous[e.key] = n;
    }
  }

  void _schedule() {
    if (_timer != null || _batches.isClosed) return;
    _timer = Timer(coalesce, _flush);
  }

  void _flush() {
    _timer = null;
    if (_batches.isClosed) return;
    final fresh = [
      for (final c in den.changesSince(_contiguous))
        if (!_seen(c)) c,
    ];
    for (final c in fresh) {
      _mark(c);
    }
    _advance();
    if (fresh.isEmpty) return;
    fresh.sort((a, b) => a.hlc.compareTo(b.hlc));
    _batches.add(ChangeBatch(fresh, DateTime.now().toUtc().millisecondsSinceEpoch));
  }

  /// Stops watching.
  Future<void> close() async {
    _timer?.cancel();
    await _subscription.cancel();
    await _batches.close();
  }
}

/// `GET /api/v1/stream`: server-sent events for one token.
class EventStream {
  /// Creates the stream endpoint.
  EventStream(this.hub, this.feed, {this.ping = const Duration(seconds: 20)});

  /// Shared hub context.
  final HubContext hub;

  /// Where batches come from.
  final ChangeFeed feed;

  /// Keep-alive interval.
  final Duration ping;

  final Set<_Subscriber> _subscribers = {};

  /// Opens a stream for [access] and [token].
  Response open(Access access, String token) {
    final controller = StreamController<List<int>>();
    final sub = _Subscriber(this, access, token, controller);
    _subscribers.add(sub);
    controller.onCancel = sub.close;
    sub.start();
    return Response.ok(
      controller.stream,
      headers: {
        'content-type': 'text/event-stream; charset=utf-8',
        'cache-control': 'no-cache',
        'x-accel-buffering': 'no',
      },
      context: {'shelf.io.buffer_output': false},
    );
  }

  /// Number of open streams.
  int get openStreams => _subscribers.length;

  /// Says goodbye to every stream and closes them.
  Future<void> shutdown() async {
    for (final s in List.of(_subscribers)) {
      s.goodbye('shutdown');
    }
  }
}

class _Subscriber {
  _Subscriber(this.stream, this.access, this.token, this.controller);

  final EventStream stream;
  final Access access;
  final String token;
  final StreamController<List<int>> controller;
  StreamSubscription<ChangeBatch>? _batches;
  Timer? _ping;
  bool _closed = false;

  HubContext get hub => stream.hub;

  void _send(String text) {
    if (_closed || controller.isClosed) return;
    controller.add(utf8.encode(text));
  }

  void _event(String name, Map<String, Object?> data, {String? id}) =>
      _send('event: $name\n${id == null ? '' : 'id: $id\n'}data: ${jsonEncode(data)}\n\n');

  Map<String, Object?> _time(int millis) {
    final zone = hub.zone;
    return {'time': isoIn(zone, millis), 'time_ms': millis};
  }

  void start() {
    _send('retry: 5000\n\n');
    _event('hello', {'hub': hub.den.deviceId, 'version': hubVersion, ..._time(hub.now())});
    _batches = stream.feed.batches.listen(_onBatch);
    _ping = Timer.periodic(stream.ping, (_) {
      if (_stillValid()) _send(': ping\n\n');
    });
  }

  /// Checks the token; says goodbye and closes when it no longer works.
  bool _stillValid() {
    final current = hub.den.connectionForToken(token);
    if (current != null && current.id == access.connection.id) return true;
    final record = hub.den.connections.where((c) => c.id == access.connection.id).firstOrNull;
    final expired = record != null &&
        record.status == ConnectionStatus.active &&
        record.expires != null &&
        record.expires! <= hub.now();
    goodbye(expired ? 'token_expired' : 'token_revoked');
    return false;
  }

  void _onBatch(ChangeBatch batch) {
    if (_closed || !_stillValid()) return;
    final readable = readableSpacesFor(hub.den, access.member);
    final visible = [
      for (final c in batch.changes)
        if (readable.contains(c.space) && RecordType.all.contains(c.type)) c,
    ];
    if (visible.isEmpty) return;
    final seen = <String>{};
    final records = <Map<String, Object?>>[];
    for (final c in visible.reversed) {
      if (seen.add('${c.space}|${c.type}|${c.rid}')) records.add({'type': c.type, 'id': c.rid, 'space': c.space});
    }
    final newest = visible.last;
    final types = <String>[];
    for (final c in visible) {
      if (!types.contains(c.type)) types.add(c.type);
    }
    _event(
      'changed',
      {
        'types': types,
        'records': records.take(100).toList(),
        if (records.length > 100) 'truncated': true,
        'actor': newest.actor,
        'via': newest.fields['_via'] as String?,
        ..._time(batch.at),
      },
      id: newest.hlc.toString(),
    );
  }

  void goodbye(String reason) {
    if (_closed) return;
    _event('goodbye', {'reason': reason});
    unawaited(close());
    if (!controller.isClosed) unawaited(controller.close());
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    stream._subscribers.remove(this);
    _ping?.cancel();
    await _batches?.cancel();
  }
}
