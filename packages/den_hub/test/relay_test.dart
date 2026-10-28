@Timeout(Duration(seconds: 90))
library;

import 'dart:async';
import 'dart:io';

import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';
import 'package:den_relay/den_relay.dart';
import 'support/test.dart';

import 'support/fixture.dart';

void main() {
  late Directory tmp;
  late RelayServer relay;
  Uri relayUrl() => Uri.parse('http://127.0.0.1:${relay.port}');

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('den_hub_relay');
    relay = await RelayServer.start(RelayConfig(dataDir: tmp.path), address: InternetAddress.loopbackIPv4, port: 0);
  });

  tearDown(() async {
    await relay.close();
    await tmp.delete(recursive: true);
  });

  test('devices reach the hub through its relay tunnel', () async {
    final f = await HubFixture.start(configure: (c) => HubConfig(
          port: 0,
          host: c.host,
          mdns: false,
          log: c.log,
          relay: relayUrl(),
        ));
    addTearDown(f.stop);
    final phoneNode = SyncNode(f.phone);
    final client = SyncClient(node: phoneNode, endpoints: [relayConnectUri(relayUrl(), f.hubDen.deviceId)])..start();
    addTearDown(() async {
      await client.stop();
      await phoneNode.close();
    });
    await client.whenLive();
    final id = await f.phone.addEvent(title: 'Through the relay', start: 1, end: 2);
    await eventually(() => f.hubDen.event(id) != null);
  });

  test('a fresh hub joins by dialing the phone\'s relay rendezvous', () async {
    final codes = <String>[];
    final den = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    final hub = await DenHub.start(den, HubConfig(
      port: 0,
      host: InternetAddress.loopbackIPv4,
      mdns: false,
      log: HubLog.silent(),
      relay: relayUrl(),
      onSetupCode: codes.add,
    ));
    addTearDown(hub.stop);
    final phone = await createDemoFamily();
    final phoneNode = SyncNode(phone);
    addTearDown(phoneNode.close);
    final invite = await phoneNode.createInvite(relay: relayUrl());
    final hosting = phoneNode.hostRendezvous(relayUrl(), await invite.rendezvousSlot());
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final joins = phoneNode.pendingJoinsChanges.firstWhere((j) => j.isNotEmpty);
    final r = await apiCall(hub.localUrl, 'POST', '/api/v1/hub/setup', body: {'code': codes.single, 'invite': invite.toUrl()});
    expect(r.status, 202);
    expect(r.body.containsKey('connect'), isFalse, reason: 'the hub dials out');
    await phoneNode.approve((await joins).single, mode: DeviceMode.hub);
    await eventually(() => hub.ready);
    await eventually(() => den.members.length == phone.members.length);
    for (final p in phoneNode.peers) {
      await p.close();
    }
    await hosting;
  });
}
