// Real networking over localhost: an in-process DenHub, a parent's phone adding it with its
// setup code, a browser linking through it, and a parent's computer keeping the family online.
// Plain `test`s (no widget binding), so sockets and timers are real.
import 'dart:io';

import 'package:den_app/net/den_network.dart';
import 'package:den_app/net/hub_client.dart';
import 'package:den_app/net/hub_keep_alive.dart';
import 'package:den_app/net/local_hub.dart';
import 'package:den_app/net/net_pairing.dart';
import 'package:den_app/net/pairing.dart';
import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

Future<void> until(bool Function() done, {Duration timeout = const Duration(seconds: 30), String? what}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for ${what ?? 'a condition'}');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<Den> parentPhone() async {
  final den = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
  await den.createFamily(
    familyName: 'The Testers',
    timezone: 'America/Chicago',
    yourName: 'Sam',
    marker: Marker.blue,
    animal: Animal.cat,
    deviceName: "Sam's phone",
    deviceKind: DeviceKind.phone,
  );
  return den;
}

Future<Den> freshDen() async => Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());

/// Records what the in-app hub asks of the platform's keep-alive (Android's foreground service).
class RecordingKeepAlive extends HubKeepAlive {
  final List<String> calls = [];

  @override
  Future<void> start(String detail) async => calls.add('start: $detail');

  @override
  Future<void> update(String detail) async => calls.add('update: $detail');

  @override
  Future<void> stop() async => calls.add('stop');
}

/// A local hub that never runs, for devices that aren't the hub in these tests.
LocalHub noHub() => LocalHub.create(port: 0, mdns: false);

void main() {
  setUpAll(tzdata.initializeTimeZones);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// A fresh hub on a free port, stopped after the test.
  Future<(Den, DenHub)> startHub() async {
    final den = await freshDen();
    final hub = await DenHub.start(den, HubConfig(port: 0, mdns: false, log: HubLog.silent(), name: 'Closet hub'));
    addTearDown(hub.stop);
    return (den, hub);
  }

  /// A parent's phone that has added [hub] with its setup code.
  Future<(Den, DenNetwork, NetPairing)> addHub(DenHub hub) async {
    final phone = await parentPhone();
    final network = DenNetwork(phone, localHub: noHub());
    addTearDown(network.dispose);
    final pairing = NetPairing(network);
    final info = await pairing.hubStatus('127.0.0.1:${hub.port}');
    expect(info.paired, isFalse);
    expect(info.name, 'Closet hub');
    final session = pairing.setUpHub(info, hub.setupCode!);
    await until(() => session.stage == HubSetupStage.confirm || session.stage == HubSetupStage.failed, what: 'the hub to ask');
    expect(session.error, isNull);
    expect(session.words, hasLength(3));
    expect(session.hubWords, session.words, reason: 'the hub reports the words this phone shows');
    expect(session.wordsMatch, isTrue);
    await session.approve();
    expect(session.stage, HubSetupStage.done, reason: session.error);
    return (phone, network, pairing);
  }

  test('A parent adds a fresh hub with its setup code', () async {
    final (hubDen, hub) = await startHub();
    final (phone, network, _) = await addHub(hub);

    await until(() => hub.ready, what: 'the hub to be ready');
    expect(hubDen.isApproved, isTrue);
    expect(hubDen.thisDevice!.mode, DeviceMode.hub);
    expect(hubDen.familyId, phone.familyId);
    expect(isFamilyHub(phone, hubDen.deviceId), isTrue);
    expect(network.hubs.map((h) => h.toString()), ['ws://127.0.0.1:${hub.port}/ws']);
  });

  test('A wrong setup code says how many tries are left', () async {
    final (_, hub) = await startHub();
    final phone = await parentPhone();
    final network = DenNetwork(phone, localHub: noHub());
    addTearDown(network.dispose);
    final pairing = NetPairing(network);
    final info = await pairing.hubStatus('127.0.0.1:${hub.port}');
    final session = pairing.setUpHub(info, 'AAAA-AAAA');
    await until(() => session.stage == HubSetupStage.failed, what: 'the refusal');
    expect(session.error, "That setup code isn't right. 4 tries left before the hub makes a new one.");
  });

  test('A browser links through the hub with a parent phone answering its code', () async {
    final (hubDen, hub) = await startHub();
    final (phone, network, pairing) = await addHub(hub);
    await until(() => hub.ready, what: 'the hub to be ready');
    await until(() => network.status.state.name == 'live', what: 'the phone to sync with the hub');

    final browser = await freshDen();
    final browserNet = DenNetwork(browser, localHub: noHub());
    addTearDown(browserNet.dispose);
    final browserPairing = NetPairing(browserNet, servedBy: Uri.parse('http://127.0.0.1:${hub.port}/'));
    final link = await browserPairing.linkThisBrowser(deviceName: () => 'Kitchen laptop');
    addTearDown(link.dispose);
    expect(link.uri, startsWith('den://link?hub=${hubDen.deviceId}&slot='));

    final hubName = await pairing.answerBrowserLink(link.uri);
    expect(hubName, 'Closet hub');
    await until(() => link.stage == LinkStage.joined || link.stage == LinkStage.failed, what: 'the browser to join');
    expect(link.error, isNull);
    expect(link.ticket!.familyId, phone.familyId);

    await until(() => phone.pendingDevices.any((d) => d.name == 'Kitchen laptop'), what: 'the request to reach the phone');
    final pending = phone.pendingDevices.firstWhere((d) => d.name == 'Kitchen laptop');
    await phone.approveDevice(pending.id, member: phone.owner!.id);
    await until(() => browser.isApproved, what: 'the browser to be approved');
    expect(browser.thisDevice!.kind, DeviceKind.browser);
    expect(browser.family!.name, 'The Testers');
  });

  test('A browser starts the family, takes in the hub that served it, and invites by message', () async {
    final (hubDen, hub) = await startHub();
    final served = Uri.parse('http://127.0.0.1:${hub.port}/');

    // Mom's iPhone, from the Home Screen: starts the family, then the hub with its setup code.
    final mom = await parentPhone();
    final momNet = DenNetwork(mom, localHub: noHub());
    addTearDown(momNet.dispose);
    final momPairing = NetPairing(momNet, servedBy: served);
    final fresh = await momPairing.servingHub();
    expect(fresh!.paired, isFalse);
    final adoption = momPairing.adoptServingHub(fresh, hub.setupCode!);
    await until(() => adoption.stage == HubSetupStage.done || adoption.stage == HubSetupStage.failed, what: 'the hub to be taken in');
    expect(adoption.error, isNull);
    await until(() => hub.ready, what: 'the hub to be ready');
    expect(isFamilyHub(mom, hubDen.deviceId), isTrue, reason: 'approved without a tap: both ends showed the same words');
    await until(() => momNet.status.state.name == 'live', what: 'Mom to sync with the hub');

    // An invite for Grandma, sent as a message.
    final grandmaId = await mom.addMember(name: 'Grandma', role: Role.adult, marker: Marker.green, animal: Animal.bird);
    final grandma = mom.member(grandmaId)!;
    final message = await momPairing.createInvite(memberId: grandma.id);
    expect(message.words, hasLength(4));
    expect(message.link.fragment, '/join/${message.words.join('-')}');
    expect(message.text, contains(message.code));

    // Grandma's iPad, later, from the link: types the words and asks to join.
    final ipad = await freshDen();
    final ipadNet = DenNetwork(ipad, localHub: noHub());
    final ticket = await NetPairing(ipadNet, servedBy: served).joinWithInvite(
      message.code,
      deviceName: (forName) => "$forName's iPad",
      kind: DeviceKind.tablet,
    );
    expect(ticket.familyId, mom.familyId);
    await until(() => mom.pendingDevices.any((d) => d.id == ipad.deviceId), what: 'the request to reach Mom');
    final asking = mom.device(ipad.deviceId)!;
    expect(asking.name, "Grandma's iPad");
    expect(asking.member, grandma.id);

    // Den closed on the iPad before anyone approved; it opens again and waits.
    await ipadNet.close();
    final reopened = await DenNetwork.load(ipad);
    addTearDown(reopened.dispose);
    await reopened.start();

    // Mom approves with one tap, for the person the invite named.
    await mom.approveDevice(ipad.deviceId);
    await until(() => ipad.isApproved, what: 'the iPad to hear it was approved');
    expect(ipad.family!.name, 'The Testers');
  });

  test("Keep the family online runs the hub in the app and a tablet joins through it", () async {
    final phone = await parentPhone();
    final sam = phone.owner!.id;
    final dir = await Directory.systemTemp.createTemp('den-hub-test');
    addTearDown(() => dir.delete(recursive: true));
    final keepAlive = RecordingKeepAlive();
    final network = DenNetwork(phone, localHub: LocalHub.create(port: 0, mdns: false, dataDir: dir.path, keepAlive: keepAlive));
    addTearDown(network.dispose);
    final pairing = NetPairing(network);

    await network.keepOnline(true);
    expect(network.localHub.state, LocalHubState.running, reason: network.localHub.error);
    expect(keepAlive.calls, ['start: No other devices are connected right now.'],
        reason: 'on Android, the foreground service keeps the hub running in the background');
    expect(phone.thisDevice!.mode, DeviceMode.hub);
    expect(phone.actor?.id, sam, reason: 'the parent keeps using their own device');
    expect(network.describe(), "This device is the family's hub. No other devices are connected right now.");

    final tablet = await freshDen();
    final tabletNet = DenNetwork(tablet, localHub: noHub());
    addTearDown(tabletNet.dispose);
    final joins = <List<PendingJoin>>[];
    final sub = pairing.pendingJoins.listen(joins.add);
    addTearDown(sub.cancel);

    final invite = await pairing.createInviteQr();
    final ticket = await NetPairing(tabletNet).joinWithQr(invite, deviceName: "Ava's tablet", kind: DeviceKind.tablet);
    expect(ticket.familyId, phone.familyId);
    await until(() => joins.isNotEmpty && joins.last.isNotEmpty, what: 'the pending join');
    expect(joins.last.single.deviceName, "Ava's tablet");
    await phone.approveDevice(joins.last.single.deviceId, member: sam);
    await until(() => tablet.isApproved, what: 'the tablet to be approved');

    await network.keepOnline(false);
    expect(network.localHub.state, LocalHubState.off);
    expect(keepAlive.calls.last, 'stop');
    expect(keepAlive.calls.where((c) => c.startsWith('start')), hasLength(1));
    expect(phone.thisDevice!.mode, DeviceMode.personal);
    expect(phone.actor?.id, sam);
  });
}
