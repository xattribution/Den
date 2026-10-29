@Timeout(Duration(seconds: 180))
library;

import 'dart:convert';
import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_hub/src/push/web_push_crypto.dart';
import 'package:den_net/den_net.dart';
import 'package:test/test.dart';

import 'push_test.dart' show FakePushService, auth, uaPublic;
import 'support/fixture.dart';
import 'support/host_fixture.dart';

/// Web Push on a Den host: every family hands out and signs with its own key, whatever address it
/// is asked at, and a family's own key and browsers come with it to the host.
void main() {
  late Directory dir;
  late FakePushService apple;
  late HostFixture f;
  late HostedFamily a;
  late HostedFamily b;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('den-host-push');
    apple = FakePushService();
    f = await HostFixture.start(
      configure: (c) => HostConfig(port: 0, host: InternetAddress.loopbackIPv4, log: c.log, dataDir: dir.path, httpClient: apple.client),
      hub: (name, c) => HubConfig(mdns: false, publicUrl: c.publicUrl, log: c.log, dataDir: '${dir.path}/$name'),
    );
    a = f['den-a.test'];
    b = f['den-b.test'];
  });

  tearDown(() async {
    await f.stop();
    await dir.delete(recursive: true);
  });

  Map<String, Object?> subscription(String endpoint) => {
        'endpoint': 'https://web.push.apple.com/$endpoint',
        'keys': {'p256dh': b64url(uaPublic), 'auth': b64url(auth)},
      };

  /// The key the last push named, after checking its JWT verifies with that key, one of the
  /// families' own.
  String lastSigner() {
    final header = apple.pushes.last.$1.headers['authorization']!;
    final m = RegExp(r'^vapid t=([^,]+), k=(.+)$').firstMatch(header)!;
    final parts = m[1]!.split('.');
    final key = {for (final t in f.host.tenants) b64url(t.push.keys.publicKey): t.push.keys}[m[2]!];
    expect(key, isNotNull, reason: "a family's own key");
    expect(key!.verify(utf8.encode('${parts[0]}.${parts[1]}'), unb64url(parts[2])), isTrue, reason: 'signed with the key it names');
    return m[2]!;
  }

  Future<String> keyAt(HostedFamily family, String hostname) async {
    final r = await f.signed(family.phone, 'GET', '/api/v1/push', hub: family.hubDen.deviceId, hostname: hostname);
    expect(r.status, 200, reason: r.text);
    return r.body['key']! as String;
  }

  Future<void> subscribeAt(HostedFamily family, String hostname, String endpoint) async {
    final r = await f.signed(family.phone, 'PUT', '/api/v1/push',
        hub: family.hubDen.deviceId, hostname: hostname, body: subscription(endpoint));
    expect(r.status, 200, reason: r.text);
  }

  Future<void> testPush(HostedFamily family, String hostname) async {
    final r = await f.signed(family.phone, 'POST', '/api/v1/push/test', hub: family.hubDen.deviceId, hostname: hostname);
    expect(r.status, 200, reason: r.text);
  }

  test("every family hands out and signs with its own key only, at whatever address it is asked", () async {
    final ka = await keyAt(a, 'den-a.test');
    final kb = await keyAt(b, 'den-b.test');
    expect(ka, isNot(kb), reason: 'each family keeps its own key');
    // b's device asking at a's address still gets b's own key: no family's subscription is ever
    // bound to another family's key.
    expect(await keyAt(b, 'den-a.test'), kb);
    await subscribeAt(b, 'den-a.test', 'b-at-a');
    await testPush(b, 'den-a.test');
    expect(lastSigner(), kb);
    expect(apple.pushes.last.$2['title'], 'Reminders are on');
    await subscribeAt(a, 'den-a.test', 'a-at-a');
    await testPush(a, 'den-a.test');
    expect(lastSigner(), ka);
  });

  test("a family's own browsers keep its own key, older subscriptions and any key a record names included", () async {
    final ka = await keyAt(a, 'den-a.test');
    final kb = await keyAt(b, 'den-b.test');
    await subscribeAt(b, 'den-b.test', 'b-at-b');
    await testPush(b, 'den-b.test');
    expect(lastSigner(), kb);
    final devices = b.hub.context.state.read('push')['devices']! as Map;
    final record = devices[b.phone.deviceId] as Map;
    expect(record['vapid'], kb);
    // A subscription from before the host names no key: it was made with the family's own.
    record.remove('vapid');
    await testPush(b, 'den-b.test');
    expect(lastSigner(), kb);
    // One naming another family's key (edited by hand, say) is still signed with b's own.
    record['vapid'] = ka;
    await testPush(b, 'den-b.test');
    expect(lastSigner(), kb);
  });

  test("the host keeps no family's key: each is in the family's own data, and goes with it", () async {
    final ka = await keyAt(a, 'den-a.test');
    final kb = await keyAt(b, 'den-b.test');
    expect(File('${dir.path}/$hostStateDir/vapid.json').existsSync(), isFalse);
    for (final (family, key) in [(a, ka), (b, kb)]) {
      await family.hub.context.state.flush();
      final saved = jsonDecode(File('${dir.path}/${family.hostname}/hub/push.json').readAsStringSync()) as Map;
      expect(b64url(VapidKeys.fromPrivate(unb64url(saved['vapid'] as String)).publicKey), key, reason: family.hostname);
    }
    // A keyring an earlier host kept is deleted when the host starts.
    final old = File('${dir.path}/$hostStateDir/vapid.json')..writeAsStringSync('{"keys": {}}');
    final again = await DenHost.start(HostConfig(port: 0, host: InternetAddress.loopbackIPv4, dataDir: dir.path, log: HubLog.silent()));
    await again.stop();
    expect(old.existsSync(), isFalse);
  });

  test('a hub moved onto a host keeps its key and every browser it had', () async {
    final own = await Directory.systemTemp.createTemp('den-own-hub');
    addTearDown(() => own.delete(recursive: true));
    final hub = await HubFixture.start(
      dataDir: own.path,
      configure: (c) => HubConfig(
        port: 0,
        host: InternetAddress.loopbackIPv4,
        mdns: false,
        dataDir: own.path,
        log: c.log,
        publicUrl: Uri.parse('https://den-c.test'),
        httpClient: apple.client,
      ),
    );
    final before = (await apiCall(hub.base, 'GET', '/api/v1/push',
            headers: {...await _sign(hub.phone, 'GET', hub.base.resolve('/api/v1/push'), hub.hubDen.deviceId), 'host': 'den-c.test'}))
        .body['key']! as String;
    final put = await apiCall(hub.base, 'PUT', '/api/v1/push', body: subscription('c-phone'), headers: {
      ...await _sign(hub.phone, 'PUT', hub.base.resolve('/api/v1/push'), hub.hubDen.deviceId, body: subscription('c-phone')),
      'host': 'den-c.test',
    });
    expect(put.status, 200, reason: put.text);
    await hub.hub.stop();

    // Its data, as it was, now one family of the host, at the same address.
    final c = await f.host.add(hub.hubDen, HubConfig(mdns: false, publicUrl: Uri.parse('https://den-c.test'), dataDir: own.path));
    addTearDown(() async {
      await f.host.remove(c);
      await hub.hubDen.close();
      await hub.phone.close();
    });
    final family = HostedFamily('den-c.test', hub.phone, hub.hubDen, c);
    expect(await keyAt(family, 'den-c.test'), before, reason: "the app sees the key it subscribed with, so it keeps its subscription");
    await testPush(family, 'den-c.test');
    expect(lastSigner(), before);
  });
}

Future<Map<String, String>> _sign(Den den, String method, Uri url, String hub, {Object? body}) => DeviceRequest.sign(
      keys: den.keys,
      method: method,
      url: url,
      body: body == null ? const [] : utf8.encode(jsonEncode(body)),
      hub: hub,
      actorId: den.actor?.id,
    );
