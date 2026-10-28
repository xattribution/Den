@Timeout(Duration(seconds: 90))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/dart.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_hub/src/edge.dart';
import 'package:den_hub/src/http_util.dart' show requestBase;
import 'package:den_hub/src/web.dart';
import 'package:den_net/den_net.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'support/test.dart';

import 'support/fixture.dart';

class FakeConnection implements HttpConnectionInfo {
  FakeConnection(String address) : remoteAddress = InternetAddress(address);
  @override
  final InternetAddress remoteAddress;
  @override
  int get remotePort => 50000;
  @override
  int get localPort => 47733;
}

Request from(String peer, [Map<String, String> headers = const {}]) => Request(
      'GET',
      Uri.parse('http://hub.example/api/v1/hub/status'),
      headers: headers,
      context: {'shelf.io.connection_info': FakeConnection(peer)},
    );

/// A WebSocket frame header from a client (masked) announcing [length] bytes.
List<int> frameHeader(int length, {int opcode = 2, bool fin = true}) => [
      (fin ? 0x80 : 0) | opcode,
      ...(length < 126
          ? [0x80 | length]
          : length < 65536
              ? [0x80 | 126, length >> 8, length & 0xff]
              : [0x80 | 127, for (var i = 7; i >= 0; i--) (length >> (8 * i)) & 0xff]),
      1, 2, 3, 4,
    ];

/// Opens a WebSocket on `/ws` at [port] by hand; the future completes when the server closes it.
Future<(Socket, Future<void>)> rawWebSocket(int port) async {
  final socket = await Socket.connect('127.0.0.1', port);
  final closed = Completer<void>();
  void close() {
    if (!closed.isCompleted) closed.complete();
  }

  final received = <int>[];
  socket.listen(received.addAll, onDone: close, onError: (Object _) => close());
  final key = base64.encode(List.generate(16, (i) => i));
  socket.write('GET /ws HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
      'Sec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\n\r\n');
  await eventually(() => utf8.decode(received, allowMalformed: true).contains('\r\n\r\n'));
  expect(utf8.decode(received, allowMalformed: true), startsWith('HTTP/1.1 101'));
  return (socket, closed.future);
}

void main() {
  group('client addresses', () {
    final proxies = IpNetwork.parseList('172.30.73.0/24, ::1');

    test('networks parse and match, IPv4-mapped addresses as IPv4', () {
      expect(proxies.first.contains(InternetAddress('172.30.73.2')), isTrue);
      expect(proxies.first.contains(InternetAddress('172.30.74.2')), isFalse);
      expect(proxies.first.contains(InternetAddress('::ffff:172.30.73.9')), isTrue);
      expect(proxies.last.contains(InternetAddress('::1')), isTrue);
      expect(() => IpNetwork.parse('10.0.0.0/33'), throwsFormatException);
      expect(() => IpNetwork.parse('den.example.com'), throwsFormatException);
    });

    test('X-Forwarded-For counts only from a trusted proxy, right-most untrusted hop first', () {
      final spoofed = from('203.0.113.5', {'x-forwarded-for': '10.9.9.9'});
      expect(clientAddress(spoofed, proxies)!.address, '203.0.113.5', reason: 'a stranger can\'t pick its address');
      final proxied = from('172.30.73.2', {'x-forwarded-for': '10.9.9.9, 198.51.100.7, 172.30.73.3'});
      expect(clientAddress(proxied, proxies)!.address, '198.51.100.7');
      expect(clientAddress(from('172.30.73.2'), proxies)!.address, '172.30.73.2');
      expect(clientKey(InternetAddress('2001:db8:1:2:3:4:5:6')), clientKey(InternetAddress('2001:db8:1:2:ffff::1')),
          reason: 'one IPv6 /64 is one client');
      final base = requestBase(from('172.30.73.2', {'x-forwarded-proto': 'https', 'x-forwarded-host': 'den.example.com'}), null,
          trusted: proxies);
      expect(base.toString(), 'https://den.example.com');
      final ignored = requestBase(from('203.0.113.5', {'x-forwarded-proto': 'https', 'x-forwarded-host': 'evil.example', 'host': 'hub.example'}),
          null, trusted: proxies);
      expect(ignored.host, 'hub.example');
    });

    test('rate limits refill over time and are kept per client', () {
      var now = 0;
      final limits = RateLimiter(now: () => now);
      const rate = Rate(3, Duration(minutes: 1));
      expect([for (var i = 0; i < 4; i++) limits.allow('t', 'a', rate)], [true, true, true, false]);
      expect(limits.allow('t', 'b', rate), isTrue);
      expect(limits.retryAfter('t', 'a', rate), 20);
      now += 20000;
      expect(limits.allow('t', 'a', rate), isTrue);
      expect(limits.allow('t', 'a', rate), isFalse);
    });
  });

  group('WebSocket frames', () {
    test('a message past the limit is refused while its header arrives', () {
      final guard = FrameGuard(const FrameLimits());
      expect(guard.feed([...frameHeader(20), ...List.filled(20, 0)]), isTrue);
      expect(guard.feed(frameHeader(1 << 30).sublist(0, 6)), isTrue, reason: 'not all of the header yet');
      expect(guard.feed(frameHeader(1 << 30).sublist(6)), isFalse);
      final split = FrameGuard(const FrameLimits());
      expect(split.feed([...frameHeader(40000, fin: false), ...List.filled(40000, 0)]), isTrue);
      expect(split.feed(frameHeader(40000, opcode: 0)), isFalse, reason: 'fragments add up to one message');
      final later = FrameGuard(const FrameLimits());
      expect(later.feed([...frameHeader(100), ...List.filled(100, 0)]), isTrue);
      expect(later.feed([...frameHeader(1024 * 1024), ...List.filled(1024 * 1024, 0)]), isTrue,
          reason: 'after a first hello, session-sized messages pass (a phone answering as the session server sends the family next)');
      expect(later.feed(frameHeader(4 * 1024 * 1024)), isFalse, reason: 'nothing a session sends is that large');
    });

    test('a guarded channel ends its stream and closes the connection past a limit', () async {
      final raw = StreamChannelController<List<int>>();
      var refused = false;
      var closes = 0;
      final guarded = guardChannel(raw.local, const FrameLimits(), onRefused: () => refused = true, onClose: () => closes++);
      final done = Completer<void>();
      // Paused before anything arrives and resumed later, as a WebSocket listens.
      final sub = guarded.stream.listen((_) {}, onDone: done.complete)..pause();
      raw.foreign.sink.add([...frameHeader(1 << 30), ...List.filled(100, 7)]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      sub.resume();
      await done.future.timeout(const Duration(seconds: 5));
      expect(refused, isTrue);
      expect(closes, 1);
      await raw.foreign.stream.toList().timeout(const Duration(seconds: 5));
    });

    test('a guarded WebSocket upgrade closes a connection that announces a huge first message', () async {
      var refused = false;
      final handler = webSocketHandler((WebSocketChannel ws, String? _) => ws.stream.listen((_) {}));
      final server = await shelf_io.serve(
        (Request r) => handler(guardUpgrade(r, const FrameLimits(), onRefused: () => refused = true)),
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      final (socket, closed) = await rawWebSocket(server.port);
      addTearDown(socket.destroy);
      socket.add([...frameHeader(1 << 30), ...List.filled(1000, 7)]);
      await eventually(() => refused, timeout: const Duration(seconds: 5));
      await closed.timeout(const Duration(seconds: 12));
    });

    test('the hub closes a connection that announces a huge first message instead of buffering it', () async {
      final logged = <String>[];
      final f = await HubFixture.start(
        configure: (c) =>
            HubConfig(port: 0, host: InternetAddress.loopbackIPv4, mdns: false, log: HubLog(level: LogLevel.debug, sink: logged.add)),
      );
      addTearDown(f.stop);
      final (socket, closed) = await rawWebSocket(f.hub.port);
      addTearDown(socket.destroy);
      socket.add([...frameHeader(1 << 30), ...List.filled(1000, 7)]);
      try {
        await eventually(() => logged.any((l) => l.contains('over the size limit')), timeout: const Duration(seconds: 5));
      } on TimeoutException {
        fail('no refusal; the hub logged: ${logged.join(' | ')}');
      }
      await closed.timeout(const Duration(seconds: 12));
    });
  });

  group('behind a trusted proxy', () {
    late HubFixture f;
    setUp(() async {
      f = await HubFixture.start(
        configure: (c) => HubConfig(
          port: 0,
          host: InternetAddress.loopbackIPv4,
          mdns: false,
          log: c.log,
          trustedProxies: IpNetwork.parseList('127.0.0.1'),
        ),
      );
    });
    tearDown(() => f.stop());

    const proxied = {'x-forwarded-proto': 'https', 'x-forwarded-host': 'den.example.com', 'x-forwarded-for': '198.51.100.7'};

    test('OAuth metadata, HSTS and the WebSocket origin follow the forwarded scheme and host', () async {
      final meta = await f.call('GET', '/.well-known/oauth-authorization-server', headers: proxied);
      expect(meta.body['issuer'], 'https://den.example.com');
      expect(meta.headers['strict-transport-security'], 'max-age=31536000');
      expect(meta.headers['x-content-type-options'], 'nosniff');
      expect(meta.headers['referrer-policy'], 'no-referrer');
      expect(meta.headers['content-security-policy'], contains("default-src 'none'"));
      final direct = await f.call('GET', '/.well-known/oauth-authorization-server');
      expect(direct.body['issuer'], f.base.toString());
      expect(direct.headers.containsKey('strict-transport-security'), isFalse);
    });

    test('limits count each client behind the proxy on its own', () async {
      for (var i = 0; i < Limits.pairing.burst; i++) {
        expect((await f.call('POST', '/api/v1/link', headers: proxied)).status, 201);
      }
      final limited = await f.call('POST', '/api/v1/link', headers: proxied);
      expect(limited.status, 429);
      expect(limited.error['code'], 'rate_limited');
      expect(int.parse(limited.headers['retry-after']!), greaterThan(0));
      final other = await f.call('POST', '/api/v1/link', headers: {...proxied, 'x-forwarded-for': '198.51.100.8'});
      expect(other.status, 201, reason: 'another client behind the same proxy has its own budget');
    });
  });

  group('public posture', () {
    late HubFixture f;
    setUp(() async {
      f = await HubFixture.start(
        configure: (c) => HubConfig(port: 0, host: InternetAddress.loopbackIPv4, mdns: false, log: c.log, public: true),
      );
    });
    tearDown(() => f.stop());

    test('health and status say nothing that identifies the hub', () async {
      final health = await f.call('GET', '/health');
      expect(health.body, {'ok': true, 'api': 1, 'ready': true});
      final status = await f.call('GET', '/api/v1/hub/status');
      expect(status.body, {'paired': true, 'setup_needed': false, 'stage': 'ready'});
    });

    test('browsers can ask to link only while a parent has Add a device open', () async {
      final closed = await f.call('POST', '/api/v1/link');
      expect(closed.status, 403);
      expect(closed.error['code'], 'link_closed');
      final url = f.base.resolve('/api/v1/link/window');
      final unsigned = await f.call('POST', '/api/v1/link/window');
      expect(unsigned.status, 401);
      final headers = await DeviceRequest.sign(
        keys: f.phone.keys, method: 'POST', url: url, body: const [], hub: f.hubDen.deviceId, actorId: f.phone.actor?.id);
      final opened = await f.call('POST', '/api/v1/link/window', headers: headers);
      expect(opened.status, 200);
      expect(opened.body['open_until_ms'], greaterThan(DateTime.now().millisecondsSinceEpoch));
      expect((await f.call('POST', '/api/v1/link')).status, 201);
    });

    test('the owner can open linking from the server with den_hub open-linking', () async {
      final dir = await Directory.systemTemp.createTemp('den-public');
      addTearDown(() => dir.delete(recursive: true));
      final hosted = await HubFixture.start(
        dataDir: dir.path,
        configure: (c) => HubConfig(port: 0, host: InternetAddress.loopbackIPv4, mdns: false, log: c.log, public: true, dataDir: dir.path),
      );
      addTearDown(hosted.stop);
      expect((await hosted.call('POST', '/api/v1/link')).status, 403);
      File('${dir.path}/hub/$linkOpenFile')
        ..createSync(recursive: true)
        ..writeAsStringSync('${DateTime.now().millisecondsSinceEpoch + 60000}');
      expect((await hosted.call('POST', '/api/v1/link')).status, 201);
      File('${dir.path}/hub/$linkOpenFile').writeAsStringSync('${DateTime.now().millisecondsSinceEpoch - 1}');
      expect((await hosted.call('POST', '/api/v1/link')).status, 403, reason: 'only until the time written');
    });
  });

  group('web app', () {
    late Directory dir;
    late HubFixture f;
    const inline = 'window.denBoot = 1;';
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('den-web');
      File('${dir.path}/index.html').writeAsStringSync(
          '<!DOCTYPE html><html><head><script>$inline</script></head><body><script src="flutter_bootstrap.js" async></script></body></html>');
      File('${dir.path}/main.dart.js').writeAsStringSync('// main');
      File('${dir.path}/main.dart.3f2a9c1b.js').writeAsStringSync('// hashed');
      File('${dir.path}/canvaskit.wasm').writeAsBytesSync([0, 97, 115, 109]);
      f = await HubFixture.start(
        configure: (c) => HubConfig(port: 0, host: InternetAddress.loopbackIPv4, mdns: false, log: c.log, webDir: dir.path),
      );
    });
    tearDown(() async {
      await f.stop();
      await dir.delete(recursive: true);
    });

    test('the page gets a CSP that needs no CDN, and caching that lets a new build in at once', () async {
      final page = await f.call('GET', '/');
      expect(page.status, 200);
      final csp = page.headers['content-security-policy']!;
      final hash = base64.encode(const DartSha256().hashSync(utf8.encode(inline)).bytes);
      expect(csp, contains("script-src 'self' 'wasm-unsafe-eval' 'sha256-$hash'"));
      expect(csp, contains("connect-src 'self' ws://127.0.0.1:${f.hub.port}"));
      expect(csp, contains("frame-ancestors 'none'"));
      expect(csp, isNot(contains('gstatic')));
      expect(page.headers['cache-control'], 'no-cache');
      expect(page.headers['x-frame-options'], 'DENY');
      expect((await f.call('GET', '/today/chores')).headers['cache-control'], 'no-cache', reason: 'the app\'s routes are index.html');
      expect((await f.call('GET', '/main.dart.js')).headers['cache-control'], 'no-cache');
      expect((await f.call('GET', '/main.dart.3f2a9c1b.js')).headers['cache-control'], 'public, max-age=31536000, immutable');
      expect((await f.call('GET', '/canvaskit.wasm')).headers['content-type'], 'application/wasm');
      expect(webAppPolicy(connect: 'wss://den.example.com'), contains("object-src 'none'"));
      expect(cacheControlFor('assets/fonts/Icon-192.png'), 'no-cache');
    });
  });
}
