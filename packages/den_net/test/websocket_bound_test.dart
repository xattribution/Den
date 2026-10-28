import 'dart:async';
import 'dart:io';

import 'package:den_net/io.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

/// A masked client frame header for a payload of [length] bytes.
List<int> header(int length, {int opcode = 2, bool fin = true}) {
  final first = (fin ? 0x80 : 0) | opcode;
  if (length < 126) return [first, 0x80 | length, 1, 2, 3, 4];
  if (length < 65536) return [first, 0x80 | 126, length >> 8, length & 0xff, 1, 2, 3, 4];
  return [first, 0x80 | 127, 0, 0, 0, 0, (length >> 24) & 0xff, (length >> 16) & 0xff, (length >> 8) & 0xff, length & 0xff, 1, 2, 3, 4];
}

void main() {
  group('frame guard', () {
    test('passes frames up to the limit, split anywhere across chunks', () {
      final guard = WebSocketFrameGuard(1000);
      final bytes = [...header(1000), ...List.filled(1000, 7), ...header(200), ...List.filled(200, 7)];
      for (var i = 0; i < bytes.length; i += 3) {
        expect(guard.accept(bytes.sublist(i, i + 3 > bytes.length ? bytes.length : i + 3)), isTrue);
      }
    });

    test('refuses a frame announcing more as soon as its header arrives', () {
      expect(WebSocketFrameGuard(1000).accept(header(1001)), isFalse);
      expect(WebSocketFrameGuard(100000).accept(header(1 << 20)), isFalse);
      final split = WebSocketFrameGuard(1000);
      final big = header(70000);
      expect(split.accept(big.sublist(0, 3)), isTrue);
      expect(split.accept(big.sublist(3)), isFalse);
      expect(split.accept([1, 2, 3]), isFalse, reason: 'and stays refused');
    });

    test('counts a fragmented message as a whole, and control frames separately', () {
      final guard = WebSocketFrameGuard(1000);
      expect(guard.accept([...header(600, fin: false), ...List.filled(600, 1)]), isTrue);
      expect(guard.accept([...header(10, opcode: 9), ...List.filled(10, 1)]), isTrue, reason: 'a ping in between');
      expect(guard.accept(header(500, opcode: 0)), isFalse);
      expect(WebSocketFrameGuard(1000).accept(header(126, opcode: 9)), isFalse, reason: 'control frames hold 125 at most');
    });
  });

  test('a served socket closes as soon as a message over the limit starts arriving', () async {
    final received = <Object?>[];
    final server = await shelf_io.serve(
      boundedWebSocketHandler((socket) => socket.stream.listen(received.add, onError: (Object _) {}), maxMessageBytes: 1000),
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    final ws = await WebSocket.connect('ws://127.0.0.1:${server.port}/');
    try {
      ws.add(List.filled(900, 1));
      ws.add(List.filled(50000, 2));
      var ended = false;
      await ws.done
          .timeout(const Duration(seconds: 5))
          .then((_) => ended = true, onError: (Object e) => ended = e is! TimeoutException);
      expect(ended, isTrue, reason: 'the server ended the connection');
      for (var i = 0; i < 100 && received.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(received, hasLength(1), reason: 'the small message arrived; the large one never did');
    } catch (e) {
      // TEMPORARY: CI logs can't be read from here; report through an annotation.
      print('::warning title=websocket bound::$e received=${received.length} state=${ws.readyState}'.replaceAll('\n', ' / '));
      rethrow;
    }
  });
}
