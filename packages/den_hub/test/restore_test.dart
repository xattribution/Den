@Timeout(Duration(seconds: 90))
library;

import 'dart:convert';
import 'dart:io';

import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:den_hub/cli_support.dart' show restoreMarkerDoc;
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';
import 'package:http/http.dart' as http;

import 'support/fixture.dart';
import 'support/test.dart';

/// The review's restore_counter_test, at the hub: a hub restored from an older backup that wrote
/// before any phone synced reused a change id it had already used after the backup, and the
/// family forked for good. Now `den_hub restore` leaves a marker and the hub writes nothing of
/// its own until a device of the family has synced with it.
void main() {
  late Directory dir;
  late Den phone;
  late DeviceKeys hubKeys;
  late MemoryStorage hubStorage;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('den_restore_');
    phone = await createDemoFamily();
    hubKeys = await DeviceKeys.generate();
    hubStorage = MemoryStorage();
    final hub = await Den.open(storage: hubStorage, keys: hubKeys);
    await hub.requestJoin(
      familyId: phone.familyId!,
      founderPubkey: phone.founderPubkey!,
      deviceName: 'Hub',
      kind: DeviceKind.hub,
      mode: DeviceMode.hub,
    );
    await phone.ingest(hub.changesSince(const {}));
    await phone.approveDevice(hub.deviceId, mode: DeviceMode.hub);
    await hub.ingest(phone.changesSince(const {}));
    for (final space in phone.spacesForDevice(hub.deviceId)) {
      final key = await phone.spaceKey(space);
      if (key != null) await hub.setSpaceKey(space, key);
    }
    await hub.close();
  });

  tearDown(() async {
    await phone.close();
    await dir.delete(recursive: true);
  });

  Future<MemoryStorage> copyOf(MemoryStorage s) async {
    final out = MemoryStorage();
    await out.appendChanges(await s.loadChanges());
    final meta = await s.loadMeta();
    if (meta != null) await out.saveMeta((jsonDecode(jsonEncode(meta)) as Map).cast<String, Object?>());
    return out;
  }

  Future<(Den, DenHub)> serve(MemoryStorage storage, String data) async {
    final den = await Den.open(storage: storage, keys: hubKeys);
    final hub = await DenHub.start(
      den,
      HubConfig(
        port: 0,
        host: InternetAddress.loopbackIPv4,
        mdns: false,
        dataDir: data,
        log: HubLog(level: LogLevel.warn, sink: (line) => stderr.writeln('[hub] $line')),
      ),
    );
    return (den, hub);
  }

  Map<String, Object?> event(String title) => {'title': title, 'start': '2026-11-03T16:00:00', 'end': '2026-11-03T17:00:00'};

  int ownChanges(Den hub) => hub.changesSince(const {}).where((c) => c.device == hub.deviceId).length;

  test('a restored hub writes nothing until a phone has synced, then numbers past what it wrote before', () async {
    final token = await phone.addTokenConnection(label: 'Claude', scopes: {Scope.read, Scope.calendar});

    // The hub as it ran: last night's backup, then a write of its own the phone synced.
    final first = Directory('${dir.path}/first')..createSync();
    var (hubDen, hub) = await serve(hubStorage, first.path);
    await hubDen.ingest(phone.changesSince(hubDen.versionVector));
    final backup = await copyOf(hubStorage);
    final dentist = await apiCall(hub.localUrl, 'POST', '/api/v1/events', token: token, body: event('Dentist'));
    expect(dentist.status, 201, reason: dentist.text);
    await phone.ingest(hubDen.changesSince(phone.versionVector));
    final dentistChange = phone.changesSince(const {}).lastWhere((c) => c.device == hubDen.deviceId);
    await hub.stop();
    await hubDen.close();

    // The server dies; the owner restores last night's backup, which leaves the marker.
    final second = Directory('${dir.path}/second/hub')..createSync(recursive: true);
    File('${second.path}/$restoreMarkerDoc.json').writeAsStringSync(jsonEncode({'at': 1}));
    (hubDen, hub) = await serve(backup, second.parent.path);
    addTearDown(() async {
      await hub.stop();
      await hubDen.close();
    });
    expect(hub.catchingUp, isTrue);
    final before = ownChanges(hubDen);

    // Nothing the hub would write on its own, or for an app, goes through.
    final write = await apiCall(hub.localUrl, 'POST', '/api/v1/events', token: token, body: event('School concert'));
    expect(write.status, 503);
    expect(write.error['code'], 'catching_up');
    expect(write.error['message'], startsWith('The hub is catching up after a restore'));
    expect(write.headers['retry-after'], '60');
    final action = await apiCall(hub.localUrl, 'POST', '/api/v1/actions/create_event', token: token, body: event('School concert'));
    expect(action.status, 503);
    final preview = await apiCall(hub.localUrl, 'POST', '/api/v1/actions/create_event?preview=1', token: token, body: event('x'));
    expect(preview.status, 200, reason: 'a preview writes nothing');
    final read = await apiCall(hub.localUrl, 'GET', '/api/v1/events?start=2026-11-01&end=2026-11-10', token: token);
    expect(read.status, 200, reason: 'reads go on');

    final init = await apiCall(hub.localUrl, 'POST', '/mcp', token: token, body: {
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {'protocolVersion': '2025-11-25', 'capabilities': {}, 'clientInfo': {'name': 'test', 'version': '1'}},
    });
    final session = init.headers['mcp-session-id']!;
    final tool = await apiCall(hub.localUrl, 'POST', '/mcp', token: token, headers: {
      'mcp-session-id': session,
    }, body: {
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/call',
      'params': {'name': 'create_event', 'arguments': event('School concert')},
    });
    expect(tool.status, 503);
    expect(tool.headers['retry-after'], '60');
    expect(((tool.body['error'] as Map)['message'] as String), startsWith('The hub is catching up after a restore'));
    final stdio = await hub.mcp.callTool(accessForToken(hubDen, token)!, 'create_event', event('School concert'));
    expect(stdio['isError'], isTrue);

    final oauth = await http.post(hub.localUrl.resolve('/oauth/token'), body: {'grant_type': 'refresh_token', 'client_id': 'x'});
    expect(oauth.statusCode, 503);
    expect(oauth.headers['retry-after'], '60');
    expect((jsonDecode(oauth.body) as Map)['error'], 'temporarily_unavailable');

    await hub.feeds.syncAll();
    await hub.oauth.sweep(now: DateTime.now().millisecondsSinceEpoch + const Duration(days: 2).inMilliseconds);
    expect(ownChanges(hubDen), before, reason: 'the hub wrote nothing of its own');

    // Mom opens Den: her phone syncs with the hub and hands back the Dentist.
    final node = SyncNode(phone);
    final client = SyncClient(
      node: node,
      endpoints: [Uri.parse('ws://127.0.0.1:${hub.port}/ws')],
      expectDevice: hubDen.deviceId,
    )..start();
    addTearDown(() async {
      await client.stop();
      await node.close();
    });
    await client.whenLive();
    await eventually(() => !hub.catchingUp);
    // The marker leaves memory at once and its file on the state's write queue, just after.
    await eventually(() => !File('${second.path}/$restoreMarkerDoc.json').existsSync());
    expect(hubDen.events.map((e) => e.title), contains('Dentist'));

    // Now it writes again, under a new change id.
    final concert = await apiCall(hub.localUrl, 'POST', '/api/v1/events', token: token, body: event('School concert'));
    expect(concert.status, 201, reason: concert.text);
    final newest = hubDen.changesSince(const {}).lastWhere((c) => c.device == hubDen.deviceId);
    expect(newest.counter, greaterThan(dentistChange.counter));
    await eventually(() => phone.events.any((e) => e.title == 'School concert'));
    expect(phone.events.map((e) => e.title).toSet(), hubDen.events.map((e) => e.title).toSet(), reason: 'one family, not two');
  });

  test('a device that only asks to join doesn\'t end the wait', () async {
    final data = Directory('${dir.path}/hub')..createSync(recursive: true);
    File('${data.path}/$restoreMarkerDoc.json').writeAsStringSync(jsonEncode({'at': 1}));
    final (hubDen, hub) = await serve(await copyOf(hubStorage), dir.path);
    addTearDown(() async {
      await hub.stop();
      await hubDen.close();
    });
    final stranger = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    final node = SyncNode(stranger);
    final phoneNode = SyncNode(phone);
    addTearDown(() async {
      await node.close();
      await phoneNode.close();
      await stranger.close();
    });
    final invite = phoneNode.createHubInvite(hubDen.deviceId, hubs: [Uri.parse('ws://127.0.0.1:${hub.port}/ws')]);
    hub.node.invites.add(invite);
    final attempt = await node.joinWithInvite(await openInviteChannel(invite), invite,
        deviceName: 'Laptop', kind: DeviceKind.browser);
    await attempt.stages.firstWhere((s) => s == JoinStage.waitingForApproval);
    expect(hub.catchingUp, isTrue);
    await attempt.cancel();
  });
}
