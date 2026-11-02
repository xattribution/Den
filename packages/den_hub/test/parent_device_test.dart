@Timeout(Duration(seconds: 60))
library;

import 'dart:convert';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';

import 'support/fixture.dart';
import 'support/test.dart';

/// What needs "a parent's own phone" needs a personal device of that parent, or a hub-mode
/// device whose owner is the parent acting. A hub can name any member as its actor (den_net's
/// DeviceRequest takes it at its word), so an old server hub left in the family after a reset
/// could otherwise admit apps, set the assistant's key, open linking or make calendar links as any
/// parent.
void main() {
  late HubFixture f;
  late Den oldHub;
  late Den alexsTablet;

  setUpAll(() async {
    f = await HubFixture.start();
    oldHub = await HubFixture.approvedHub(f.phone, name: 'Old server hub');
    alexsTablet = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    await alexsTablet.requestJoin(
      familyId: f.phone.familyId!,
      founderPubkey: f.phone.founderPubkey!,
      deviceName: 'Alex\'s tablet keeping the family online',
      kind: DeviceKind.tablet,
      mode: DeviceMode.hub,
    );
    await f.phone.ingest(alexsTablet.changesSince(const {}));
    await f.phone.approveDevice(alexsTablet.deviceId, member: f.id('Alex'), mode: DeviceMode.hub);
    await f.toHub();
  });

  tearDownAll(() async {
    await oldHub.close();
    await alexsTablet.close();
    await f.stop();
  });

  Future<ApiResult> as(Den device, String actor, String method, String path, [Object? body]) async {
    final text = body == null ? null : jsonEncode(body);
    final headers = await DeviceRequest.sign(
      keys: device.keys,
      method: method,
      url: f.base.resolve(path),
      body: text == null ? const [] : utf8.encode(text),
      hub: f.hubDen.deviceId,
      actorId: f.id(actor),
    );
    return f.call(method, path, body: text, headers: headers);
  }

  final trustAdjacent = <(String, String, Object?)>[
    ('POST', '/api/v1/link/window', null),
    ('GET', '/api/v1/connections/requests', null),
    ('POST', '/api/v1/connections/requests/nope', {'decision': 'admit'}),
    ('GET', '/api/v1/connections/clients', null),
    ('POST', '/api/v1/connections/clients', {'name': 'Alexa', 'redirect_uris': ['https://example.com/cb']}),
    ('DELETE', '/api/v1/connections/clients/nope', null),
    ('PUT', '/api/v1/assistant', {'provider': 'anthropic', 'key': 'sk-ant-api03-test'}),
    ('PUT', '/api/v1/capture/reader', {'kind': 'none'}),
    ('GET', '/api/v1/recovery/key', null),
    ('GET', '/api/v1/feeds', null),
    ('POST', '/api/v1/feeds', {'feed': 'family', 'label': 'A calendar'}),
    ('DELETE', '/api/v1/feeds/nope', null),
  ];

  test('a hub nobody owns is refused everything a parent\'s own phone does, whoever it names', () async {
    for (final (method, path, body) in trustAdjacent) {
      final r = await as(oldHub, 'Alex', method, path, body);
      expect(r.status, 403, reason: '$method $path: ${r.text}');
      expect(r.error['code'], 'permission_denied');
    }
  });

  test('a hub owned by a parent may act for that parent, and for nobody else', () async {
    final mine = await as(alexsTablet, 'Alex', 'POST', '/api/v1/link/window');
    expect(mine.status, 200, reason: mine.text);
    final clients = await as(alexsTablet, 'Alex', 'GET', '/api/v1/connections/clients');
    expect(clients.status, 200, reason: clients.text);
    for (final (method, path, body) in trustAdjacent) {
      final r = await as(alexsTablet, 'Priya', method, path, body);
      expect(r.status, 403, reason: '$method $path as Priya: ${r.text}');
    }
  });

  test('a parent\'s own phone still does them', () async {
    final r = await as(f.phone, 'Alex', 'POST', '/api/v1/link/window');
    expect(r.status, 200, reason: r.text);
    final reader = await as(f.phone, 'Alex', 'PUT', '/api/v1/capture/reader', {'kind': 'none'});
    expect(reader.status, 200, reason: reader.text);
  });
}
