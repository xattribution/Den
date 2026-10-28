@Timeout(Duration(seconds: 90))
library;

import 'dart:async';
import 'dart:io';

import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';
import 'support/test.dart';

import 'support/fixture.dart';

void main() {
  test('a fresh hub joins with its setup code and a parent approves it on their phone', () async {
    final codes = <String>[];
    final logged = <String>[];
    final den = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    final hub = await DenHub.start(den, HubConfig(
      port: 0,
      host: InternetAddress.loopbackIPv4,
      mdns: false,
      name: 'Basement hub',
      log: HubLog(level: LogLevel.info, sink: logged.add),
      onSetupCode: codes.add,
    ));
    addTearDown(hub.stop);
    Future<ApiResult> call(String method, String path, {String? token, Object? body}) =>
        apiCall(hub.localUrl, method, path, token: token, body: body);

    final health = await call('GET', '/health');
    expect(health.body['ready'], isFalse);
    final status = await call('GET', '/api/v1/hub/status');
    expect(status.body, containsPair('setup_needed', true));
    expect(status.body, containsPair('paired', false));
    expect(status.body['name'], 'Basement hub');
    expect(status.body.containsKey('matching_words'), isFalse, reason: 'no words before a phone connects');
    expect((await call('GET', '/api/v1/members', token: 'x')).error['code'], 'not_ready');
    expect(codes.single, matches(RegExp('^[$setupAlphabet]{4}-[$setupAlphabet]{4}\$')));
    expect(hub.setupCode, codes.single);

    final phone = await createDemoFamily();
    final phoneNode = SyncNode(phone);
    addTearDown(phoneNode.close);
    final invite = await phoneNode.createInvite();

    for (var i = 1; i <= setupTries; i++) {
      final wrong = await call('POST', '/api/v1/hub/setup', body: {'code': 'AAAA-AAAA', 'invite': invite.toUrl()});
      expect(wrong.status, 403);
      expect((wrong.error['details'] as Map)['tries_left'], setupTries - i);
    }
    expect(codes, hasLength(2), reason: 'five wrong tries print a new code');
    final stale = await call('POST', '/api/v1/hub/setup', body: {'code': codes.first, 'invite': invite.toUrl()});
    expect(stale.status, 403, reason: 'the old code is gone');

    final accepted = await call('POST', '/api/v1/hub/setup',
        body: {'code': codes.last.toLowerCase(), 'invite': invite.toUrl(), 'direct': true});
    expect(accepted.status, 202);
    expect(accepted.body['connect'], '/api/v1/hub/setup/ws');

    final joins = phoneNode.pendingJoinsChanges.firstWhere((j) => j.isNotEmpty);
    final socket = await connectWebSocket(Uri.parse('ws://127.0.0.1:${hub.port}/api/v1/hub/setup/ws'));
    final served = phoneNode.serve(socket);
    final join = (await joins).single;
    expect(join.name, 'Basement hub');
    expect(join.kind, DeviceKind.hub);
    await eventually(() async => (await call('GET', '/api/v1/hub/status')).body['stage'] == 'waiting_for_approval');
    final waiting = await call('GET', '/api/v1/hub/status');
    expect(join.matchingWords, hasLength(3));
    expect(waiting.body['matching_words'], join.matchingWords, reason: 'the hub reports the words the phone shows');
    expect(logged.where((l) => l.contains('Matching words: ${join.matchingWords.join(' ')}.')), hasLength(1));
    await phoneNode.approve(join, mode: DeviceMode.hub);
    await eventually(() async => (await call('GET', '/health')).body['ready'] == true);
    await eventually(() => den.events.length == phone.events.length);
    expect(hub.setupCode, isNull);
    expect(den.thisDevice!.mode, DeviceMode.hub);
    final after = await call('GET', '/api/v1/hub/status');
    expect(after.body, containsPair('paired', true));
    expect(after.body.containsKey('matching_words'), isFalse, reason: 'the words go once the session is over');
    expect((await call('POST', '/api/v1/hub/setup', body: {'code': 'x', 'invite': 'y'})).status, 409);
    await socket.sink.close();
    await served;
  });

  test('a browser links through the hub with an invite a parent\'s phone grants', () async {
    final f = await HubFixture.start();
    addTearDown(f.stop);
    final phoneNode = SyncNode(f.phone);
    final phoneClient = SyncClient(
      node: phoneNode,
      endpoints: [Uri.parse('ws://127.0.0.1:${f.hub.port}/ws')],
      expectDevice: f.hubDen.deviceId,
    )..start();
    addTearDown(() async {
      await phoneClient.stop();
      await phoneNode.close();
    });
    await phoneClient.whenLive();

    final slot = await f.call('POST', '/api/v1/link');
    expect(slot.status, 201);
    final id = slot.body['slot'] as String;
    final secret = slot.body['secret'] as String;
    final uri = Uri.parse(slot.body['uri'] as String);
    expect(uri.scheme, 'den');
    expect(uri.queryParameters['hub'], f.hubDen.deviceId);
    expect(uri.queryParameters['slot'], id);
    final waiting = await f.call('GET', '/api/v1/link/$id', headers: {'x-den-link-secret': secret});
    expect(waiting.body['state'], 'waiting');
    expect((await f.call('GET', '/api/v1/link/$id', headers: {'x-den-link-secret': 'guess'})).status, 404);

    final invite = phoneNode.createHubInvite(f.hubDen.deviceId, hubs: [Uri.parse('ws://127.0.0.1:${f.hub.port}/ws')]);
    final kid = await DeviceKeys.generate();
    final forged = await InviteGrant.sign(invite, keys: kid, context: 'link:$id');
    expect((await f.call('POST', '/api/v1/link/$id', body: forged.toJson())).status, 403);
    final grant = await InviteGrant.sign(invite, keys: f.phone.keys, context: 'link:$id');
    final posted = await f.call('POST', '/api/v1/link/$id', body: grant.toJson());
    expect(posted.status, 200);
    expect((await f.call('POST', '/api/v1/link/$id', body: grant.toJson())).status, 409);

    final ready = await f.call('GET', '/api/v1/link/$id', headers: {'x-den-link-secret': secret});
    expect(ready.body['state'], 'ready');
    final browser = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    final browserNode = SyncNode(browser);
    addTearDown(browserNode.close);
    final scanned = await Invite.parse(ready.body['invite'] as String);
    final attempt = await browserNode.joinWithInvite(await openInviteChannel(scanned), scanned,
        deviceName: 'Chrome on the laptop', kind: DeviceKind.browser);
    await attempt.stages.firstWhere((s) => s == JoinStage.waitingForApproval);
    await eventually(() => f.phone.pendingDevices.any((d) => d.id == browser.deviceId));
    await f.phone.approveDevice(browser.deviceId, member: f.id('Alex'));
    await attempt.completed.timeout(const Duration(seconds: 20));
    await eventually(() => browser.events.length == f.phone.events.length);
    expect(browser.owner?.name, 'Alex');
    await attempt.peer.close();
  });
}
