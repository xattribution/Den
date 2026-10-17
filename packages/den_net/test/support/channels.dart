import 'dart:async';

import 'package:stream_channel/stream_channel.dart';

/// Decides what the middle forwards for one message: a list of messages (empty drops it).
typedef Tamper = List<Object?> Function(int index, Object? message);

List<Object?> passThrough(int index, Object? message) => [message];

/// Two channel ends joined through a middle that can inspect, alter, drop, duplicate or delay
/// messages in each direction, like a hostile relay.
class Tap<T> {
  Tap({Tamper toServer = passThrough, Tamper toClient = passThrough}) {
    var up = 0;
    var down = 0;
    _client.local.stream.listen(
      (m) {
        for (final out in toServer(up++, m)) {
          _server.local.sink.add(out as T);
        }
      },
      onDone: () => _server.local.sink.close(),
    );
    _server.local.stream.listen(
      (m) {
        for (final out in toClient(down++, m)) {
          _client.local.sink.add(out as T);
        }
      },
      onDone: () => _client.local.sink.close(),
    );
  }

  final StreamChannelController<T> _client = StreamChannelController<T>(sync: false);
  final StreamChannelController<T> _server = StreamChannelController<T>(sync: false);

  /// The end the client uses.
  StreamChannel<T> get client => _client.foreign;

  /// The end the server uses.
  StreamChannel<T> get server => _server.foreign;
}

/// A plain in-memory pipe.
({StreamChannel<T> a, StreamChannel<T> b}) pipe<T>() {
  final controller = StreamChannelController<T>(sync: false);
  return (a: controller.local, b: controller.foreign);
}

/// Waits until [condition] holds, polling.
Future<void> eventually(bool Function() condition, {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
