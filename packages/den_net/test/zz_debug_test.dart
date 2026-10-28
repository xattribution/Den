// TEMPORARY diagnostics for CI, whose logs can't be read from here: reports through workflow
// annotations. Removed before the PR is ready.
import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void note(String title, Object message) =>
    print('::warning title=$title::${'$message'.replaceAll('\n', ' / ').replaceAll('%', '%25')}');

Future<String> probe(Handler handler) async {
  final server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
  try {
    final ws = await WebSocket.connect('ws://127.0.0.1:${server.port}/').timeout(const Duration(seconds: 5));
    ws.add('hello');
    final reply = await ws.first.timeout(const Duration(seconds: 3));
    await ws.close();
    return 'ok: $reply';
  } catch (e) {
    return 'failed: ${e.runtimeType}';
  } finally {
    await server.close(force: true);
  }
}

void echo(WebSocketChannel s) => s.stream.listen(s.sink.add, onError: (Object e) => note('stream error', e));

/// Hands shelf_web_socket the hijacked socket as [adapt] makes it.
Handler variant(String name, StreamChannel<List<int>> Function(StreamChannel<List<int>> raw) adapt) {
  final upgrade = webSocketHandler((WebSocketChannel s, String? _) {
    note('$name connection', '${s.runtimeType}');
    echo(s);
  });
  return (Request request) async {
    final raw = Completer<StreamChannel<List<int>>>();
    final copy = Request(
      request.method,
      request.requestedUri,
      protocolVersion: request.protocolVersion,
      headers: request.headersAll,
      handlerPath: request.handlerPath,
      url: request.url,
      context: request.context,
      onHijack: (callback) => unawaited(raw.future.then((channel) {
        note('$name raw', '${channel.runtimeType} stream ${channel.stream.runtimeType} sink ${channel.sink.runtimeType}');
        try {
          callback(adapt(channel));
        } catch (e, s) {
          note('$name callback threw', '$e ${s.toString().split('\n').take(6).join(' / ')}');
        }
      })),
    );
    try {
      return await upgrade(copy);
    } on HijackException {
      request.hijack(raw.complete);
    }
  };
}

void main() {
  test('debug websocket upgrades', () async {
    note('a same', await probe(variant('a', (c) => c)));
    note('b new channel, same stream and sink', await probe(variant('b', (c) => StreamChannel(c.stream, c.sink))));
    note('c changeStream identity', await probe(variant('c', (c) => c.changeStream((s) => s))));
    note('d mapped stream', await probe(variant('d', (c) => StreamChannel(c.stream.map((x) => x), c.sink))));
  });
}
