@Timeout(Duration(seconds: 90))
library;

import 'dart:async';
import 'dart:io';

import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_hub/src/relay_watch.dart';
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

  test('a relay that turns the hub away is reported, and the hub keeps serving', () async {
    await relay.close();
    // No room for tunnels (503 relay full), and no mailbox space for anyone (507, cap client).
    relay = await RelayServer.start(RelayConfig(dataDir: tmp.path, maxTunnels: 0, maxClientBytes: 1),
        address: InternetAddress.loopbackIPv4, port: 0);
    final logged = <String>[];
    final f = await HubFixture.start(configure: (c) => HubConfig(
          port: 0,
          host: c.host,
          mdns: false,
          log: HubLog(level: LogLevel.warn, sink: logged.add),
          relay: relayUrl(),
          mailbox: true,
        ));
    addTearDown(f.stop);
    await eventually(() => logged.any((l) => l.contains('tunnel')));
    await eventually(() => logged.any((l) => l.contains('mailboxes didn\'t take everything')));
    expect((await f.call('GET', '/health')).status, 200);
  });

  test('relay problems are logged once each, and again when they clear', () async {
    final logged = <String>[];
    final watch = RelayWatch(HubLog(level: LogLevel.info, sink: logged.add));
    const full = 'was not upgraded to websocket, HTTP status code: 503';
    watch
      ..tunnelStatus(const TunnelStatus(TunnelState.offline, full))
      ..tunnelStatus(const TunnelStatus(TunnelState.connecting, full))
      ..tunnelStatus(const TunnelStatus(TunnelState.offline, full));
    expect(logged.where((l) => l.contains('the relay is full')), hasLength(1));
    watch.tunnelStatus(const TunnelStatus(TunnelState.online));
    expect(logged.last, contains('tunnel is back'));

    Future<MailboxRound> refused() async => throw RelayException('mailbox read failed', status: 507);
    await watch.mailboxRound(refused);
    await watch.mailboxRound(refused);
    expect(logged.where((l) => l.contains('it is full')), hasLength(1));
    await watch.mailboxRound(() async => const MailboxRound(received: 0, posted: 0, skipped: 0, failed: 2));
    expect(logged.last, contains('2 of this round'));
    await watch.mailboxRound(() async => const MailboxRound(received: 0, posted: 1, skipped: 0));
    expect(logged.last, contains('working again'));
    await watch.stop();
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
