// Real networking over localhost: an in-process DenHub, a parent's phone adding it with its
// setup code, a browser linking through it, and a parent's computer keeping the family online.
// Plain `test`s (no widget binding), so sockets and timers are real.
import 'dart:io';

import 'package:den_app/platform/sync/den_network.dart';
import 'package:den_app/platform/sync/hub_client.dart';
import 'package:den_app/platform/sync/hub_keep_alive.dart';
import 'package:den_app/platform/sync/local_hub.dart';
import 'package:den_app/platform/sync/net_pairing.dart';
import 'package:den_app/platform/sync/pairing.dart';
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
    marker: Marker.sky,
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

  test('Reset the hub, keep the family: the new hub takes over its address, and the old one hears it was removed',
      () async {
    // The old hub, added from Sam's phone, and Sam's laptop syncing through it.
    final oldDen = await freshDen();
    final oldHub = await DenHub.start(oldDen, HubConfig(port: 0, mdns: false, log: HubLog.silent(), name: 'Closet hub'));
    final port = oldHub.port;
    final (phone, network, pairing) = await addHub(oldHub);
    await until(() => network.syncedWith(oldDen.deviceId), what: 'the phone to sync with the old hub');
    final laptop = await freshDen();
    await laptop.requestJoin(
      familyId: phone.familyId!,
      founderPubkey: phone.founderPubkey!,
      deviceName: "Sam's laptop",
      kind: DeviceKind.desktop,
    );
    await phone.ingest(laptop.changesSince(const {}));
    await phone.approveDevice(laptop.deviceId, member: phone.owner!.id);
    await laptop.ingest(phone.changesSince(const {}));
    final address = Uri.parse('ws://127.0.0.1:$port/ws');
    final laptopNet = DenNetwork(laptop, hubs: [address], localHub: noHub());
    addTearDown(laptopNet.dispose);
    await laptopNet.start();
    await until(() => laptopNet.syncedWith(oldDen.deviceId), what: 'the laptop to sync with the old hub');

    // The server is reset: the old hub's data is gone, and a fresh hub answers at its address.
    await oldHub.stop();
    final newDen = await freshDen();
    final newHub = await DenHub.start(newDen, HubConfig(port: port, mdns: false, log: HubLog.silent(), name: 'Closet hub'));
    addTearDown(newHub.stop);
    // (The phone's HTTP client may still hold a connection to the old server; the next try opens
    // a new one, as a person trying again would.)
    HubInfo? found;
    for (var tries = 0; found == null && tries < 3; tries++) {
      try {
        found = await pairing.hubStatus('127.0.0.1:$port');
      } on PairingException {
        if (tries == 2) rethrow;
      }
    }
    final info = found!;
    expect(info.device, newDen.deviceId);
    expect(network.hubsAt(info.base, except: info.device).map((d) => d.id), [oldDen.deviceId],
        reason: 'the add-hub flow offers to remove the hub that used this address');
    final session = pairing.setUpHub(info, newHub.setupCode!);
    await until(() => session.stage == HubSetupStage.confirm || session.stage == HubSetupStage.failed, what: 'the new hub to ask');
    await session.approve();
    expect(session.stage, HubSetupStage.done, reason: session.error);

    // Both hubs are approved and both are called "Closet hub"; the phone goes on with the new one.
    await until(() => network.syncedWith(newDen.deviceId), what: 'the phone to sync with the new hub');
    expect(network.hubDevices.map((d) => d.id), [newDen.deviceId, oldDen.deviceId]);
    await phone.revokeDevice(oldDen.deviceId);
    expect(network.hubDevices.map((d) => d.id), [newDen.deviceId]);

    // The laptop never heard of the new hub: the hub shows its record, and the laptop syncs.
    await laptopNet.start();
    await until(() => laptopNet.syncedWith(newDen.deviceId), what: 'the laptop to sync with the new hub');
    await until(() => laptop.device(oldDen.deviceId)?.revoked ?? false, what: 'the laptop to learn the old hub was removed');

    // The old hub comes back somewhere else, still thinking it's in the family. The laptop tries
    // it first, refuses it, tells it why, and goes straight on to the new hub.
    final revived = await DenHub.start(oldDen, HubConfig(port: 0, mdns: false, log: HubLog.silent(), name: 'Closet hub'));
    addTearDown(revived.stop);
    final laptopAgain = DenNetwork(laptop, hubs: [Uri.parse('ws://127.0.0.1:${revived.port}/ws'), address], localHub: noHub());
    addTearDown(laptopAgain.dispose);
    await laptopNet.close();
    await laptopAgain.start();
    await until(() => laptopAgain.syncedWith(newDen.deviceId), what: 'the laptop to move on to the new hub');
    await until(() => oldDen.thisDevice!.revoked, what: 'the old hub to hear it was removed');
    final status = await HubClient().status(Uri.parse('http://127.0.0.1:${revived.port}'));
    expect(status.stage, 'removed');
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
    expect(session.error, "That setup code isn't right. Check it in the hub's log: 4 more tries, then the hub makes you wait a minute.");
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

  test('A browser starts the family, takes in the hub that served it, and invites by message, asking first', () async {
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

    // An invite for Grandma, sent as a message, with "Let them in right away" turned off.
    final grandmaId = await mom.addMember(name: 'Grandma', role: Role.adult, marker: Marker.grass, animal: Animal.bird);
    final grandma = mom.member(grandmaId)!;
    final message = await momPairing.createInvite(memberId: grandma.id, letIn: false);
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

  test('An invite lets Grandma\'s iPad in by itself, and Mom hears of it', () async {
    final (_, hub) = await startHub();
    final served = Uri.parse('http://127.0.0.1:${hub.port}/');
    final mom = await parentPhone();
    final momNet = DenNetwork(mom, localHub: noHub());
    addTearDown(momNet.dispose);
    final momPairing = NetPairing(momNet, servedBy: served);
    final adoption = momPairing.adoptServingHub((await momPairing.servingHub())!, hub.setupCode!);
    await until(() => adoption.stage == HubSetupStage.done || adoption.stage == HubSetupStage.failed, what: 'the hub to be taken in');
    await until(() => momNet.status.state.name == 'live', what: 'Mom to sync with the hub');

    // "Let them in right away" is on by default: Mom's phone writes the invite's key.
    final grandmaId = await mom.addMember(name: 'Grandma', role: Role.adult, marker: Marker.grass, animal: Animal.bird);
    final message = await momPairing.createInvite(memberId: grandmaId);
    final keys = mom.inviteKeys.toList();
    expect(keys, hasLength(1));
    expect(keys.single.member, grandmaId);

    // Grandma's iPad, from the link: one tap, and it's in. Nobody approves.
    final ipad = await freshDen();
    final ipadNet = DenNetwork(ipad, localHub: noHub());
    addTearDown(ipadNet.dispose);
    final ipadPairing = NetPairing(ipadNet, servedBy: served);
    final peek = await ipadPairing.peekInvite(message.words.join('-'));
    expect(peek.letsIn, isTrue);
    final ticket = await ipadPairing.joinWithInvite(
      message.code,
      deviceName: (forName) => "$forName's iPad",
      kind: DeviceKind.tablet,
    );
    expect(ticket.admitted, isTrue);
    await until(() => ipad.isApproved, what: 'the iPad to be in');
    expect(ipad.thisDevice!.member, grandmaId);

    // Mom's phone hears it: an approved iPad for Grandma, let in by her invite, used up.
    await until(() => mom.device(ipad.deviceId)?.approved ?? false, what: 'Mom to hear the iPad joined');
    expect(mom.pendingDevices, isEmpty);
    expect(mom.usedInvite(keys.single.id)?.id, ipad.deviceId);
    expect(mom.inviteUses(keys.single), 0);

    // The same words don't let a second device in.
    final another = await freshDen();
    final anotherNet = DenNetwork(another, localHub: noHub());
    addTearDown(anotherNet.dispose);
    await expectLater(
      NetPairing(anotherNet, servedBy: served).joinWithInvite(message.code, deviceName: (_) => 'iPad', kind: DeviceKind.tablet),
      throwsA(isA<PairingException>()),
    );
  });

  test('A device turned away while it waits hears it and stops asking, also after Den opens again', () async {
    final (_, hub) = await startHub();
    final served = Uri.parse('http://127.0.0.1:${hub.port}/');
    final mom = await parentPhone();
    final momNet = DenNetwork(mom, localHub: noHub());
    addTearDown(momNet.dispose);
    final momPairing = NetPairing(momNet, servedBy: served);
    final adoption = momPairing.adoptServingHub((await momPairing.servingHub())!, hub.setupCode!);
    await until(() => adoption.stage == HubSetupStage.done || adoption.stage == HubSetupStage.failed, what: 'the hub to be taken in');
    await until(() => momNet.status.state.name == 'live', what: 'Mom to sync with the hub');
    final message = await momPairing.createInvite();

    final ipad = await freshDen();
    final ipadNet = DenNetwork(ipad, localHub: noHub());
    await NetPairing(ipadNet, servedBy: served).joinWithInvite(message.code, deviceName: (_) => 'iPad', kind: DeviceKind.tablet);
    await until(() => mom.pendingDevices.any((d) => d.id == ipad.deviceId), what: 'the request to reach Mom');
    await ipadNet.close();
    final reopened = await DenNetwork.load(ipad);
    addTearDown(reopened.dispose);
    await reopened.start();
    await until(() => reopened.status.awaitingApproval, what: 'the iPad to wait on the hub');

    await mom.revokeDevice(ipad.deviceId);
    await until(() => reopened.turnedAway, what: 'the iPad to hear it was turned away');
    expect(reopened.connecting, isFalse, reason: 'it stops asking');
    expect(ipad.isApproved, isFalse);

    // Opened again later: it doesn't ask again, and says why.
    final again = await DenNetwork.load(ipad);
    addTearDown(again.dispose);
    expect(again.turnedAway, isTrue);
    await again.start();
    expect(again.connecting, isFalse);
    final status = await NetPairing(again, servedBy: served).joinStatus.first;
    expect(status.state, JoinState.declined);
    expect(status.message, contains('new invite'));
  });

  test("Keep the family online runs the hub in the app and a tablet joins through it", () async {
    final phone = await parentPhone();
    final sam = phone.owner!.id;
    final dir = await Directory.systemTemp.createTemp('den-hub-test');
    // The hub may still be finishing a save as it stops, and on a busy machine the folder can be
    // gone already: try a few times, and a folder that's gone is fine.
    addTearDown(() async {
      for (var tries = 0; tries < 5 && dir.existsSync(); tries++) {
        try {
          await dir.delete(recursive: true);
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });
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
