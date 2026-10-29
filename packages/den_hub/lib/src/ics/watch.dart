import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:den_core/den_core.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';

import '../context.dart';
import '../feed_links.dart';
import '../http_util.dart';
import '../log.dart';
import 'fetch.dart' show feedUri;

/// How long the hub gathers changes before it tells a shared feed's watchers: a burst of edits
/// (or a sync that brings many) is one `changed`.
const Duration shareWatchGather = Duration(seconds: 1);

/// How often a watch stream carries a comment when nothing happens, so the subscriber (and any
/// proxy between) knows it is still open.
const Duration shareWatchPing = Duration(seconds: 25);

/// The watch address of a Den share, or null when [address] isn't one. A calendar link for
/// another family is `https://<hub>/ics/denfeed_<secret>/shared.ics` (or `webcal://`); its watch
/// stream is `/ics/denfeed_<secret>/watch` on the same hub.
Uri? shareWatchUri(String address) {
  final Uri uri;
  try {
    uri = feedUri(address);
  } on FormatException {
    return null;
  }
  if ((!uri.isScheme('https') && !uri.isScheme('http')) || uri.host.isEmpty) return null;
  final s = uri.pathSegments;
  final n = s.length;
  if (n < 3 || s[n - 1] != 'shared.ics' || s[n - 3] != 'ics' || !s[n - 2].startsWith(HubFeedLinks.prefix)) return null;
  return Uri(scheme: uri.scheme, host: uri.host, port: uri.port, pathSegments: [...s.take(n - 1), 'watch']);
}

/// `GET /ics/<secret>/watch`: server-sent events for the subscribers of the family's shared feed
/// (a calendar link for another family), opened with the link's own secret like the feed.
///
/// The stream starts with `hello {etag}`, the feed's ETag now, so a subscriber that missed
/// something while it was away knows to fetch. When the family's Everyone events change (after
/// [gather]), the hub works out the shared feed's ETag again and, only if it differs from what
/// the watchers were last told, sends `changed {etag}`: an edit to a Parents-only or Just-me
/// event, or an event copied in from another family, never makes one. When the link is turned
/// off, or stops working because its maker left or their device was removed, the stream says
/// `revoked` and closes. A comment every [ping] keeps it open.
class ShareWatchServer {
  /// Creates the endpoint; [etag] gives the shared feed's ETag now.
  ShareWatchServer(this.hub, this.links, {required this.etag, this.gather = shareWatchGather, this.ping = shareWatchPing});

  /// Shared hub context.
  final HubContext hub;

  /// The calendar links, to hear when one is turned off.
  final HubFeedLinks links;

  /// The shared feed's ETag now.
  final Future<String> Function() etag;

  /// How long changes are gathered before watchers are told.
  final Duration gather;

  /// Keep-alive interval.
  final Duration ping;

  /// Most streams one link keeps open; a new one closes its oldest (a subscriber that lost its
  /// connection comes back before the hub notices the old one is gone).
  static const int maxPerLink = 4;

  /// Most streams open at once, across every link.
  static const int maxStreams = 200;

  static const Set<String> _types = {
    RecordType.event, RecordType.eventException, RecordType.category, RecordType.family, //
    RecordType.member, RecordType.device,
  };

  final List<_Watcher> _open = [];
  StreamSubscription<Set<String>>? _changes;
  StreamSubscription<String>? _turnedOff;
  Timer? _soon;
  String? _told;
  bool _checking = false;
  bool _again = false;

  /// Streams open now.
  int get openStreams => _open.length;

  /// Opens a stream for [link], which the caller resolved from the request's secret.
  Future<Response> open(FeedLink link) async {
    if (_open.length >= maxStreams) {
      throw ApiError.rateLimited(60, 'Too many calendars are watching this hub right now. Try again later.');
    }
    final same = _open.where((w) => w.link == link.id).toList();
    while (same.length >= maxPerLink) {
      same.removeAt(0).close();
    }
    // Listen before reading the ETag, so a change in between is told, not lost.
    _changes ??= hub.den.onChange.listen((types) {
      if (types.any(_types.contains)) _soon ??= Timer(gather, () => unawaited(_check()));
    });
    _turnedOff ??= links.turnedOff.listen((id) {
      for (final w in [..._open]) {
        if (w.link == id) w.revoked();
      }
    });
    final String now;
    try {
      now = await etag();
    } on Object {
      if (_open.isEmpty) _idle();
      rethrow;
    }
    _told ??= now;
    final watcher = _Watcher(this, link.id);
    _open.add(watcher);
    watcher.start(now);
    return Response.ok(
      watcher.controller.stream,
      headers: {
        'content-type': 'text/event-stream; charset=utf-8',
        // no-transform: a proxy that compresses (Caddy's encode) must pass events on as they come.
        'cache-control': 'no-cache, no-transform',
        'x-accel-buffering': 'no',
      },
      context: {'shelf.io.buffer_output': false},
    );
  }

  Future<void> _check() async {
    _soon = null;
    if (_checking) {
      _again = true;
      return;
    }
    _checking = true;
    try {
      for (final w in [..._open]) {
        if (!links.works(w.link)) w.revoked();
      }
      if (_open.isEmpty) return;
      final now = await etag();
      if (now == _told) return;
      _told = now;
      for (final w in [..._open]) {
        w.changed(now);
      }
    } on Object catch (e, st) {
      hub.log.warn('Couldn\'t tell a shared calendar\'s watchers: ${describeError(e, st)}');
    } finally {
      _checking = false;
      if (_again) {
        _again = false;
        _soon ??= Timer(gather, () => unawaited(_check()));
      }
    }
  }

  void _closed(_Watcher w) {
    _open.remove(w);
    if (_open.isEmpty) _idle();
  }

  /// No one is watching: stop listening.
  void _idle() {
    _soon?.cancel();
    _soon = null;
    _told = null;
    final changes = _changes, off = _turnedOff;
    _changes = null;
    _turnedOff = null;
    unawaited(changes?.cancel());
    unawaited(off?.cancel());
  }

  /// Closes every stream.
  Future<void> shutdown() async {
    for (final w in [..._open]) {
      w.close();
    }
  }
}

class _Watcher {
  _Watcher(this.server, this.link);

  final ShareWatchServer server;
  final String link;
  final StreamController<List<int>> controller = StreamController();
  Timer? _ping;
  bool _done = false;

  void _send(String text) {
    if (_done || controller.isClosed) return;
    controller.add(utf8.encode(text));
  }

  void _event(String name, Map<String, Object?> data) => _send('event: $name\ndata: ${jsonEncode(data)}\n\n');

  void start(String etag) {
    controller.onCancel = close;
    _send('retry: 10000\n\n');
    _event('hello', {'etag': etag});
    _ping = Timer.periodic(server.ping, (_) => _send(': ping\n\n'));
  }

  void changed(String etag) => _event('changed', {'etag': etag});

  void revoked() {
    _event('revoked', const {});
    close();
  }

  void close() {
    if (_done) return;
    _done = true;
    _ping?.cancel();
    if (!controller.isClosed) unawaited(controller.close());
    server._closed(this);
  }
}

enum _Outcome { heard, failed, notAWatch, revoked, stopped }

/// Keeps a watch stream open to a Den share ([shareWatchUri]) on another family's hub, and says
/// what it hears: [onHello] when it connects (with the feed's ETag then, so missed changes are
/// caught), [onChanged] when the shared calendar changes, [onRevoked] when the link was turned
/// off (a `revoked` event, or `401` when connecting). It reconnects after a drop, waiting longer
/// after each failure (up to [maxWait]); an address that answers something other than an event
/// stream is tried again only after [notAWatchWait]. It goes through [client], the hub's guarded
/// one ([NetGuard]), so it reaches what a feed fetch may and nothing else.
class ShareWatcher {
  /// Creates a watcher of [uri]; [start] opens it.
  ShareWatcher({
    required this.client,
    required this.uri,
    required this.onHello,
    required this.onChanged,
    required this.onRevoked,
    required this.log,
    this.idle = const Duration(seconds: 75),
    this.connectTimeout = const Duration(seconds: 15),
    this.maxWait = const Duration(minutes: 5),
    this.notAWatchWait = const Duration(minutes: 15),
  });

  /// The hub's guarded client.
  final http.Client client;

  /// The watch address.
  final Uri uri;

  /// Connected; the shared feed's ETag now (null if the hub didn't say).
  final void Function(String? etag) onHello;

  /// The shared calendar changed; its new ETag.
  final void Function(String? etag) onChanged;

  /// The link was turned off. The watcher has stopped.
  final void Function() onRevoked;

  /// Where it logs.
  final HubLog log;

  /// How long a stream may say nothing (the hub pings every [shareWatchPing]) before it counts
  /// as gone.
  final Duration idle;

  /// How long connecting may take.
  final Duration connectTimeout;

  /// The longest wait between tries.
  final Duration maxWait;

  /// The wait after an answer that wasn't an event stream.
  final Duration notAWatchWait;

  /// Longest line an event stream may send.
  static const int maxLine = 16 * 1024;

  final Random _random = Random();
  bool _stopped = false;
  bool _started = false;
  bool _connected = false;
  Completer<_Outcome>? _current;
  Completer<void>? _sleeping;
  StreamSubscription<String>? _lines;

  /// Whether the stream is open and the hub said hello.
  bool get connected => _connected;

  /// Opens the stream, and keeps it open until [stop].
  void start() {
    if (_started) return;
    _started = true;
    unawaited(_loop());
  }

  /// Closes the stream and stops trying.
  Future<void> stop() async {
    _stopped = true;
    _connected = false;
    final current = _current;
    if (current != null && !current.isCompleted) current.complete(_Outcome.stopped);
    final sleeping = _sleeping;
    if (sleeping != null && !sleeping.isCompleted) sleeping.complete();
    await _lines?.cancel();
  }

  Future<void> _loop() async {
    var failures = 0;
    while (!_stopped) {
      final _Outcome outcome;
      try {
        outcome = await _once();
      } on Object catch (e, st) {
        log.debug('A shared calendar\'s watch stream failed: ${describeError(e, st)}');
        failures++;
        await _sleep(_backoff(failures));
        continue;
      }
      if (_stopped || outcome == _Outcome.stopped) return;
      if (outcome == _Outcome.revoked) {
        _stopped = true;
        onRevoked();
        return;
      }
      failures = outcome == _Outcome.heard ? 0 : failures + 1;
      await _sleep(outcome == _Outcome.notAWatch ? notAWatchWait : _backoff(failures));
    }
  }

  /// 1 to 2 seconds after a stream that worked, then doubling to [maxWait].
  Duration _backoff(int failures) {
    final base = min(maxWait.inMilliseconds, 1000 * (1 << min(failures, 16)));
    return Duration(milliseconds: base + _random.nextInt(max(1, base ~/ 4)));
  }

  Future<void> _sleep(Duration wait) async {
    if (_stopped) return;
    final sleeping = _sleeping = Completer<void>();
    final timer = Timer(wait, () {
      if (!sleeping.isCompleted) sleeping.complete();
    });
    await sleeping.future;
    timer.cancel();
  }

  Future<_Outcome> _once() async {
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers['accept'] = 'text/event-stream'
      ..headers['cache-control'] = 'no-cache'
      ..headers['user-agent'] = 'den_hub (shared calendar)';
    final http.StreamedResponse response;
    try {
      response = await client.send(request).timeout(connectTimeout);
    } on Object catch (e, st) {
      log.debug('A shared calendar\'s hub couldn\'t be reached: ${describeError(e, st)}');
      return _Outcome.failed;
    }
    if (_stopped) {
      unawaited(response.stream.listen(null).cancel());
      return _Outcome.stopped;
    }
    if (response.statusCode != 200) {
      unawaited(response.stream.listen(null).cancel());
      return response.statusCode == 401 ? _Outcome.revoked : _Outcome.failed;
    }
    if (!(response.headers['content-type'] ?? '').startsWith('text/event-stream')) {
      unawaited(response.stream.listen(null).cancel());
      return _Outcome.notAWatch;
    }
    final done = _current = Completer<_Outcome>();
    var heard = false;
    void finish(_Outcome o) {
      if (!done.isCompleted) done.complete(o);
    }

    Timer? quiet;
    void bump() {
      quiet?.cancel();
      quiet = Timer(idle, () => finish(heard ? _Outcome.heard : _Outcome.failed));
    }

    String? event;
    final data = <String>[];
    void line(String l) {
      if (l.isEmpty) {
        final name = event ?? 'message';
        final payload = data.join('\n');
        event = null;
        data.clear();
        String? etag;
        try {
          final json = payload.isEmpty ? null : jsonDecode(payload);
          if (json is Map && json['etag'] is String) etag = json['etag'] as String;
        } on FormatException {
          // Not JSON: no ETag, which only means the subscriber fetches.
        }
        switch (name) {
          case 'hello':
            heard = true;
            _connected = true;
            onHello(etag);
          case 'changed':
            onChanged(etag);
          case 'revoked':
            finish(_Outcome.revoked);
        }
        return;
      }
      if (l.startsWith(':')) return;
      final colon = l.indexOf(':');
      final field = colon < 0 ? l : l.substring(0, colon);
      var value = colon < 0 ? '' : l.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      if (field == 'event') event = value;
      if (field == 'data') data.add(value);
    }

    bump();
    _lines = response.stream.transform(utf8.decoder).transform(_BoundedLines(maxLine)).listen(
      (l) {
        bump();
        line(l);
      },
      onError: (Object _) => finish(heard ? _Outcome.heard : _Outcome.failed),
      onDone: () => finish(heard ? _Outcome.heard : _Outcome.failed),
      cancelOnError: true,
    );
    final outcome = await done.future;
    quiet?.cancel();
    _connected = false;
    _current = null;
    await _lines?.cancel();
    _lines = null;
    return outcome;
  }
}

/// Splits text into lines (`\n`, `\r\n` or `\r`), with an error for a line longer than [max]
/// characters, so a stream that never ends a line can't fill the hub's memory. (Not an `async*`
/// generator: cancelling one waits for the next chunk, which on a quiet stream is the next ping.)
class _BoundedLines extends StreamTransformerBase<String, String> {
  const _BoundedLines(this.max);

  final int max;

  @override
  Stream<String> bind(Stream<String> stream) => Stream.eventTransformed(stream, (sink) => _LineSink(sink, max));
}

class _LineSink implements EventSink<String> {
  _LineSink(this._out, this._max);

  final EventSink<String> _out;
  final int _max;
  final StringBuffer _buffer = StringBuffer();
  bool _afterCr = false;
  bool _failed = false;

  @override
  void add(String chunk) {
    if (_failed) return;
    for (var i = 0; i < chunk.length; i++) {
      final c = chunk[i];
      if (c == '\n' && _afterCr) {
        _afterCr = false;
        continue;
      }
      _afterCr = c == '\r';
      if (c == '\n' || c == '\r') {
        _out.add(_buffer.toString());
        _buffer.clear();
      } else {
        _buffer.write(c);
        if (_buffer.length > _max) {
          _failed = true;
          _out.addError(const FormatException('An event stream line is too long'));
          return;
        }
      }
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _out.addError(error, stackTrace);

  @override
  void close() {
    if (_buffer.isNotEmpty && !_failed) _out.add(_buffer.toString());
    _out.close();
  }
}
