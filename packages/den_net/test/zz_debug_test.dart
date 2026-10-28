// TEMPORARY diagnostics for CI, whose logs can't be read from here: reports through workflow
// annotations. Removed before the PR is ready.
import 'dart:async';
import 'dart:io';

import 'package:den_net/io.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void note(String title, Object message) =>
    print('::warning title=$title::${'$message'.replaceAll('\n', ' / ').replaceAll('%', '%25')}');

Handler logged(String name, Handler h) => (Request r) async {
      try {
        return await h(r);
      } on HijackException {
        rethrow;
      } catch (e, s) {
        note('$name threw', '$e ${s.toString().split('\n').take(8).join(' / ')}');
        rethrow;
      }
    };

Future<String> probe(String name, Handler handler) async {
  final server = await shelf_io.serve(logged(name, handler), InternetAddress.loopbackIPv4, 0);
  try {
    final ws = await WebSocket.connect('ws://127.0.0.1:${server.port}/').timeout(const Duration(seconds: 5));
    ws.add('hello');
    final reply = await ws.first.timeout(const Duration(seconds: 5));
    await ws.close();
    return 'ok: $reply';
  } catch (e) {
    return 'failed: ${e.runtimeType}: $e';
  } finally {
    await server.close(force: true);
  }
}

void echo(WebSocketChannel s) => s.stream.listen(s.sink.add, onError: (Object e) => note('stream error', e));

void main() {
  test('debug websocket upgrades', () async {
    note('plain', await probe('plain', webSocketHandler((WebSocketChannel s, String? _) => echo(s))));
    note('bounded', await probe('bounded', boundedWebSocketHandler(echo, maxMessageBytes: 1000)));

    // A copy of the request handed the real socket unchanged, with the same hijack ordering.
    final upgrade = webSocketHandler((WebSocketChannel s, String? _) => echo(s));
    Future<Response> copied(Request request) async {
      final raw = Completer<StreamChannel<List<int>>>();
      final guarded = Request(
        request.method,
        request.requestedUri,
        protocolVersion: request.protocolVersion,
        headers: request.headersAll,
        handlerPath: request.handlerPath,
        url: request.url,
        context: request.context,
        onHijack: (callback) => unawaited(raw.future.then((channel) {
          note('copy', 'socket arrived');
          callback(channel);
        })),
      );
      try {
        final response = await upgrade(guarded);
        note('copy', 'upgrade answered ${response.statusCode}');
        return response;
      } on HijackException {
        note('copy', 'hijacking the real request');
        request.hijack(raw.complete);
      }
    }

    note('copied', await probe('copied', copied));

    // The guard alone, on a real client's bytes.
    final guard = WebSocketFrameGuard(1000);
    final sock = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final got = <bool>[];
    sock.listen((s) => s.listen((chunk) => got.add(guard.accept(chunk))));
    unawaited(WebSocket.connect('ws://127.0.0.1:${sock.port}/').then((_) {}, onError: (Object _) {}));
    await Future<void>.delayed(const Duration(seconds: 1));
    note('guard on handshake bytes', got);
    await sock.close();
  });
}
