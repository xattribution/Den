import 'dart:convert';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:test/test.dart';

import 'support/family.dart';

void main() {
  late TestFamily family;
  late Den hub;
  late Den kidPhone;
  late Den display;
  late String kid;

  setUpAll(() async {
    family = await TestFamily.create();
    kid = await family.founder.addMember(name: 'Mia', role: Role.kid);
    hub = await family.approvedDevice(mode: DeviceMode.hub, kind: DeviceKind.hub, name: 'Hub');
    kidPhone = await family.approvedDevice(member: kid, name: 'Mia phone');
    display = await family.approvedDevice(mode: DeviceMode.shared, kind: DeviceKind.display, name: 'Kitchen');
    await hub.ingest(family.founder.changesSince(const {}));
  });

  final url = Uri.parse('http://192.168.1.20:47733/api/v1/capture/read?x=1');
  final body = utf8.encode('{"text":"soccer every Wednesday"}');

  Future<DeviceRequestCheck> check(Map<String, String> headers, {List<int>? sent, Uri? to, String method = 'POST', NonceBook? seen, int? now}) =>
      DeviceRequest.verify(hub, method: method, url: to ?? url, headers: headers, body: sent ?? body, seen: seen ?? NonceBook(), now: now);

  Future<Map<String, String>> sign(Den from, {String? actor, String? to, int? now}) =>
      DeviceRequest.sign(keys: from.keys, method: 'POST', url: url, body: body, hub: to ?? hub.deviceId, actorId: actor, now: now);

  test('a parent\'s phone is its owner, and the hub knows it', () async {
    final c = await check(await sign(family.founder));
    expect(c.ok, isTrue, reason: c.problem);
    expect(c.device!.id, family.founder.deviceId);
    expect(c.actor!.id, family.parent);
  });

  test('a personal device acts only for its owner', () async {
    final c = await check(await sign(kidPhone, actor: family.parent));
    expect(c.problem, 'not-the-owner');
    expect((await check(await sign(kidPhone))).actor!.id, kid);
  });

  test('a shared display acts for whoever signed in on it, or nobody', () async {
    expect((await check(await sign(display))).actor, isNull);
    expect((await check(await sign(display, actor: kid))).actor!.id, kid);
    expect((await check(await sign(display, actor: 'NOBODY12345678'))).problem, 'unknown-member');
  });

  test('a changed body, path or method, or another hub, breaks the signature', () async {
    final headers = await sign(family.founder);
    expect((await check(headers, sent: utf8.encode('{"text":"pony"}'))).problem, 'bad-signature');
    expect((await check(headers, to: Uri.parse('http://192.168.1.20:47733/api/v1/capture/reader'))).problem, 'bad-signature');
    expect((await check(headers, method: 'PUT')).problem, 'bad-signature');
    expect((await check(await sign(family.founder, to: kidPhone.deviceId))).problem, 'bad-signature');
  });

  test('the same request twice is refused the second time', () async {
    final headers = await sign(family.founder);
    final seen = NonceBook();
    expect((await check(headers, seen: seen)).ok, isTrue);
    expect((await check(headers, seen: seen)).problem, 'replay');
  });

  test('an old request, an unsigned one and a stranger\'s are refused', () async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    expect((await check(await sign(family.founder, now: now - 6 * 60000))).problem, 'clock');
    expect((await check(const {})).problem, 'unsigned');
    final stranger = await openDen();
    expect((await check(await sign(stranger))).problem, 'unknown-device');
  });

  test('a removed device is refused', () async {
    final lost = await family.approvedDevice(member: family.parent, name: 'Lost phone');
    await family.founder.revokeDevice(lost.deviceId);
    await hub.ingest(family.founder.changesSince(hub.versionVector));
    expect((await check(await sign(lost))).problem, 'unknown-device');
  });
}
