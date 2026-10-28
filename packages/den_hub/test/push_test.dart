@Timeout(Duration(seconds: 90))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_hub/src/push/web_push_crypto.dart';
import 'package:den_net/den_net.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

/// A browser's push subscription keys: RFC 8291's user agent, whose private key lets the test
/// read what the hub sent.
final uaPublic = unb64url('BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4');
final uaPrivate = unb64url('q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94');
final auth = unb64url('BTBZMqHH6r4Tts7J_aSIgg');

Uint8List hmac(List<int> key, List<int> data) =>
    (HMac(SHA256Digest(), 64)..init(KeyParameter(Uint8List.fromList(key)))).process(Uint8List.fromList(data));

/// Reads a push body the way the browser does (RFC 8291, from the user agent's side).
Map<String, Object?> openPush(Uint8List body) {
  final salt = body.sublist(0, 16);
  final idlen = body[20];
  final asPublic = body.sublist(21, 21 + idlen);
  final ciphertext = body.sublist(21 + idlen);
  final p256 = ECCurve_prime256v1();
  var d = BigInt.zero;
  for (final b in uaPrivate) {
    d = (d << 8) | BigInt.from(b);
  }
  final shared = (ECDHBasicAgreement()..init(ECPrivateKey(d, p256)))
      .calculateAgreement(ECPublicKey(p256.curve.decodePoint(asPublic), p256));
  final secret = Uint8List(32);
  var v = shared;
  for (var i = 31; i >= 0; i--) {
    secret[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  final prkKey = hmac(auth, secret);
  final ikm = hmac(prkKey, [...utf8.encode('WebPush: info'), 0, ...uaPublic, ...asPublic, 1]);
  final prk = hmac(salt, ikm);
  final cek = hmac(prk, [...utf8.encode('Content-Encoding: aes128gcm'), 0, 1]).sublist(0, 16);
  final nonce = hmac(prk, [...utf8.encode('Content-Encoding: nonce'), 0, 1]).sublist(0, 12);
  final gcm = GCMBlockCipher(AESEngine())..init(false, AEADParameters(KeyParameter(cek), 128, nonce, Uint8List(0)));
  final plain = gcm.process(ciphertext);
  return (jsonDecode(utf8.decode(plain.sublist(0, plain.lastIndexOf(2)))) as Map).cast<String, Object?>();
}

/// Apple's push service, recorded: answers [status] and keeps what each push carried.
class FakePushService {
  int status = 201;
  final pushes = <(http.Request, Map<String, Object?>)>[];
  late final client = MockClient((r) async {
    if (r.url.host != 'web.push.apple.com') return http.Response('not here', 404);
    pushes.add((r, openPush(r.bodyBytes)));
    return http.Response('', status);
  });
}

void main() {
  late HubFixture f;
  late FakePushService apple;
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('den-push-hub');
    apple = FakePushService();
    f = await HubFixture.start(
      dataDir: dir.path,
      configure: (base) => HubConfig(
        port: 0,
        host: InternetAddress.loopbackIPv4,
        mdns: false,
        dataDir: dir.path,
        log: HubLog(level: LogLevel.error, sink: (_) {}),
        httpClient: apple.client,
        reminderInterval: const Duration(hours: 1),
      ),
    );
  });

  tearDown(() async {
    await f.stop();
    await dir.delete(recursive: true);
  });

  /// A personal device approved by Alex's phone for [name], or a shared display.
  Future<Den> device(String? name, {DeviceMode mode = DeviceMode.personal}) async {
    final d = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    final member = name == null ? null : f.id(name);
    await d.requestJoin(
      familyId: f.phone.familyId!,
      founderPubkey: f.phone.founderPubkey!,
      deviceName: "${name ?? 'Kitchen'}'s iPhone",
      kind: mode == DeviceMode.shared ? DeviceKind.display : DeviceKind.phone,
      mode: mode,
      memberId: member,
    );
    await f.phone.ingest(d.changesSince(const {}));
    await f.phone.approveDevice(d.deviceId, member: member, mode: mode);
    await f.toHub();
    return d;
  }

  /// Calls the hub as [den], signing with its key.
  Future<ApiResult> signed(Den den, String method, String path, {Object? body}) async {
    final bytes = body == null ? <int>[] : utf8.encode(jsonEncode(body));
    final url = f.base.resolve(path);
    final headers = await DeviceRequest.sign(
      keys: den.keys,
      method: method,
      url: url,
      body: bytes,
      hub: f.hubDen.deviceId,
      actorId: den.actor?.id,
    );
    return f.call(method, path, body: body, headers: headers);
  }

  Map<String, Object?> subscription({String endpoint = 'https://web.push.apple.com/QGuQyavXutnMH-2Ff4c'}) => {
        'endpoint': endpoint,
        'keys': {'p256dh': b64url(uaPublic), 'auth': b64url(auth)},
      };

  test('a device turns reminders on and off with requests signed by its own key', () async {
    final phone = await device('Alex');
    final first = await signed(phone, 'GET', '/api/v1/push');
    expect(first.status, 200, reason: first.text);
    expect(unb64url(first.body['key']! as String), hasLength(65));
    expect(first.body['subscribed'], isFalse);

    final on = await signed(phone, 'PUT', '/api/v1/push', body: subscription());
    expect(on.status, 200, reason: on.text);
    expect(on.body['subscribed'], isTrue);
    expect(on.body['key'], first.body['key'], reason: 'one key for the hub, kept');
    expect(File('${dir.path}/hub/push.json').readAsStringSync(), contains('web.push.apple.com'));

    final test = await signed(phone, 'POST', '/api/v1/push/test');
    expect(test.status, 200, reason: test.text);
    final (request, payload) = apple.pushes.single;
    expect(payload['title'], 'Reminders are on');
    expect(payload['route'], '/today');
    expect(request.headers['content-encoding'], 'aes128gcm');
    expect(request.headers['ttl'], isNotNull);
    final authorization = request.headers['authorization']!;
    expect(authorization, startsWith('vapid t='));
    expect(authorization, endsWith('k=${first.body['key']}'));

    final off = await signed(phone, 'DELETE', '/api/v1/push');
    expect(off.body['subscribed'], isFalse);
  });

  test('refuses unsigned requests, shared screens, and push addresses that are no push service', () async {
    final phone = await device('Alex');
    expect((await f.call('PUT', '/api/v1/push', body: subscription())).status, 401);
    final evil = await signed(phone, 'PUT', '/api/v1/push', body: subscription(endpoint: 'https://192.168.1.1/admin'));
    expect(evil.status, 400);
    expect(evil.error['details'], {'field': 'endpoint'});
    final badKeys = await signed(phone, 'PUT', '/api/v1/push', body: {
      'endpoint': 'https://web.push.apple.com/x',
      'keys': {'p256dh': 'AAAA', 'auth': b64url(auth)},
    });
    expect(badKeys.status, 400);
    final kitchen = await device(null, mode: DeviceMode.shared);
    expect((await signed(kitchen, 'PUT', '/api/v1/push', body: subscription())).status, 403);
  });

  test('reminders reach the subscribed devices of the people they are for', () async {
    final alex = await device('Alex');
    final zoe = await device('Zoe');
    expect((await signed(alex, 'PUT', '/api/v1/push', body: subscription(endpoint: 'https://web.push.apple.com/alex'))).status, 200);
    expect((await signed(zoe, 'PUT', '/api/v1/push', body: subscription(endpoint: 'https://web.push.apple.com/zoe'))).status, 200);
    final now = DateTime.now().millisecondsSinceEpoch;
    final soon = now + 2 * 60000 + 1500;
    await f.phone.addEvent(title: 'Piano recital', start: soon, end: soon + 3600000, assignees: [f.id('Zoe')], reminders: [2]);
    await f.toHub();
    await f.hub.reminders.tick();
    await eventually(() => apple.pushes.isNotEmpty, timeout: const Duration(seconds: 20));
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(apple.pushes, hasLength(1), reason: "the reminder is Zoe's");
    final (request, payload) = apple.pushes.single;
    expect(request.url.path, '/zoe');
    expect(payload['title'], 'Piano recital');
    expect(payload['route'], startsWith('/event/'));
    expect(request.headers['urgency'], 'high');
  });

  test('a subscription the push service says is gone is forgotten', () async {
    final alex = await device('Alex');
    await signed(alex, 'PUT', '/api/v1/push', body: subscription());
    apple.status = 410;
    expect((await signed(alex, 'POST', '/api/v1/push/test')).status, 502);
    expect((await signed(alex, 'GET', '/api/v1/push')).body['subscribed'], isFalse);
  });

  test('parents hear when a device asks to join', () async {
    final alex = await device('Alex');
    await signed(alex, 'PUT', '/api/v1/push', body: subscription());
    final asking = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    await asking.requestJoin(
      familyId: f.phone.familyId!,
      founderPubkey: f.phone.founderPubkey!,
      deviceName: "Grandma's iPhone",
      kind: DeviceKind.phone,
    );
    await f.hubDen.ingest(asking.changesSince(const {}));
    await eventually(() => apple.pushes.isNotEmpty, timeout: const Duration(seconds: 20));
    final (_, payload) = apple.pushes.single;
    expect(payload['title'], "Grandma's iPhone wants to join");
    expect(payload['route'], '/today');
  });
}
