// End-to-end tests of real den_core engines syncing and pairing through a real relay. Each test
// skips itself (markTestSkipped) while den_core's engine is unimplemented.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:den_relay/den_relay.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

late Directory tmp;
late RelayServer relay;
Uri get relayUrl => Uri.parse('http://127.0.0.1:${relay.port}');

void main() {
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('den_relay_sync_');
    relay = await RelayServer.start(RelayConfig(dataDir: tmp.path), address: InternetAddress.loopbackIPv4, port: 0);
  });

  tearDown(() async {
    await relay.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('three dens sync through the hub\'s relay tunnel and end with identical exports', () async {
    if (await skipUnlessDenCore()) return;
    final fam = await TestFamily.create();
    final hub = await fam.approvedDevice(mode: DeviceMode.hub, kind: DeviceKind.hub, name: 'Hub');
    final laptop = await fam.approvedDevice(member: fam.parent, kind: DeviceKind.desktop, name: 'Pat laptop');
    final phoneNode = SyncNode(fam.founder);
    final hubNode = SyncNode(hub);
    final laptopNode = SyncNode(laptop);
    addTearDown(() => Future.wait([phoneNode.close(), hubNode.close(), laptopNode.close()]));
    await fam.founder.addEvent(title: 'Dentist', start: at(15), end: at(16));

    final boot = await link(phoneNode, hubNode);
    await boot.live;
    await boot.close();

    final tunnel = RelayTunnel(relay: relayUrl, keys: hub.keys, onClient: (c) => unawaited(hubNode.serve(c)));
    tunnel.start();
    addTearDown(tunnel.stop);
    await tunnel.whenOnline();

    final endpoint = relayConnectUri(relayUrl, hub.deviceId);
    final phoneClient = SyncClient(node: phoneNode, endpoints: [endpoint]);
    final laptopClient = SyncClient(node: laptopNode, endpoints: [endpoint]);
    addTearDown(phoneClient.stop);
    addTearDown(laptopClient.stop);
    phoneClient.start();
    laptopClient.start();
    await phoneClient.whenLive();
    await laptopClient.whenLive();
    await converge([fam.founder, hub, laptop]);

    final listId = await laptop.addList(title: 'Groceries', kind: ListKind.shopping);
    await laptop.addItem(listId, text: 'Apples');
    await fam.founder.addEvent(title: 'Anniversary', start: at(19), end: at(21), audience: Audience.parents);
    await converge([fam.founder, hub, laptop]);
    expect(fam.founder.list(listId)!.items.single.text, 'Apples');
  });

  test('QR join with no hub: the inviting phone waits at the relay rendezvous', () async {
    if (await skipUnlessDenCore()) return;
    final fam = await TestFamily.create();
    await fam.founder.addEvent(title: 'Recital', start: at(18), end: at(19));
    final phoneNode = SyncNode(fam.founder);
    addTearDown(phoneNode.close);
    final invite = await phoneNode.createInvite(relay: relayUrl);
    unawaited(phoneNode.hostRendezvous(relayUrl, await invite.rendezvousSlot()).catchError((Object _) {}));
    await eventually(() => relay.slots.count == 1);

    final tablet = await openDen();
    final tabletNode = SyncNode(tablet);
    addTearDown(tabletNode.close);
    final scanned = await Invite.parse(invite.toUrl());
    final channel = await openInviteChannel(scanned);
    final pendingList = phoneNode.pendingJoinsChanges.firstWhere((l) => l.isNotEmpty);
    final attempt = await tabletNode.joinWithInvite(channel, scanned, deviceName: 'Pat tablet', kind: DeviceKind.tablet);
    final pending = (await pendingList).single;
    expect(pending.matchingWords, attempt.matchingWords);
    expect(tablet.isApproved, isFalse);
    await phoneNode.approve(pending, member: fam.parent);
    await attempt.completed;
    await converge([fam.founder, tablet]);
  });

  test('spoken-code join through the relay: the relay sees only the slot hash', () async {
    if (await skipUnlessDenCore()) return;
    final fam = await TestFamily.create();
    final grandmaId = await fam.founder.addMember(name: 'Grandma', role: Role.adult);
    final phoneNode = SyncNode(fam.founder);
    addTearDown(phoneNode.close);
    final code = phoneNode.createSpokenCode();
    unawaited(phoneNode.hostRendezvous(relayUrl, await codeRendezvousSlot(code.text)).catchError((Object _) {}));
    await eventually(() => relay.slots.count == 1);

    final grandma = await openDen();
    final grandmaNode = SyncNode(grandma);
    addTearDown(grandmaNode.close);
    // Read aloud as "first four letters" works too.
    final typed = code.words.map((w) => w.length > 4 ? w.substring(0, 4) : w).join(' ');
    final channel = await rendezvous(relayUrl, await codeRendezvousSlot(typed), host: false);
    final pendingList = phoneNode.pendingJoinsChanges.firstWhere((l) => l.isNotEmpty);
    final attempt = await grandmaNode.joinWithCode(channel, typed, deviceName: 'Grandma phone', kind: DeviceKind.phone);
    final pending = (await pendingList).single;
    expect(pending.matchingWords, attempt.matchingWords);
    await phoneNode.approve(pending, member: grandmaId);
    await attempt.completed;
    expect(grandma.isApproved, isTrue);
    expect(grandma.owner?.id, grandmaId);
  });

  test('two devices with no hub sync through the relay\'s sealed mailboxes', () async {
    if (await skipUnlessDenCore()) return;
    final fam = await TestFamily.create();
    final laptop = await fam.approvedDevice(member: fam.parent, name: 'laptop');
    final phoneNode = SyncNode(fam.founder);
    final laptopNode = SyncNode(laptop);
    addTearDown(phoneNode.close);
    addTearDown(laptopNode.close);
    final boot = await link(phoneNode, laptopNode);
    await boot.live;
    await boot.close();

    final phoneMail = MailboxSync(node: phoneNode, relay: RelayMailbox(relayUrl));
    final laptopMail = MailboxSync(node: laptopNode, relay: RelayMailbox(relayUrl));
    await fam.founder.addEvent(title: 'Plumber', start: at(10), end: at(11));
    await laptop.addEvent(title: 'Book club', start: at(19), end: at(21), audience: Audience.parents);
    await phoneMail.syncOnce();
    await laptopMail.syncOnce();
    await phoneMail.syncOnce();
    await converge([fam.founder, laptop]);
    expect(relay.mailboxes.mailboxCount, greaterThanOrEqualTo(2));
  });

  test('a revocation\'s rotated keys travel through the relay; the revoked phone reads nothing after', () async {
    if (await skipUnlessDenCore()) return;
    final fam = await TestFamily.create();
    final laptop = await fam.approvedDevice(member: fam.parent, name: 'laptop');
    final oldPhone = await fam.approvedDevice(member: fam.parent, name: 'old phone');
    final phoneNode = SyncNode(fam.founder);
    final laptopNode = SyncNode(laptop);
    final oldNode = SyncNode(oldPhone);
    addTearDown(() => Future.wait([phoneNode.close(), laptopNode.close(), oldNode.close()]));
    for (final node in [laptopNode, oldNode]) {
      final boot = await link(phoneNode, node);
      await boot.live;
      await boot.close();
    }
    final mails = [
      for (final node in [phoneNode, laptopNode, oldNode]) MailboxSync(node: node, relay: RelayMailbox(relayUrl)),
    ];
    for (final m in mails) {
      await m.syncOnce();
    }

    await fam.founder.revokeDevice(oldPhone.deviceId);
    final listId = await laptop.addList(title: 'Before the laptop heard');
    await mails[1].syncOnce();
    await fam.founder.addEvent(title: 'After the revocation', start: at(9), end: at(10));
    await mails[0].syncOnce();
    expect(fam.founder.list(listId), isNotNull, reason: 'the old epoch is still read');
    await mails[1].syncOnce();
    expect(laptop.spaceKeyEpoch(Space.family), 1);
    await mails[0].syncOnce();
    await converge([fam.founder, laptop]);

    await mails[2].syncOnce();
    expect(oldPhone.spaceKeyEpoch(Space.family), 0);
    expect(jsonEncode(oldPhone.exportJson()), isNot(contains('After the revocation')));
  });
}

// ------------------------------------------------------------------------------------- helpers

bool? _ready;

Future<bool> skipUnlessDenCore() async {
  if (_ready == null) {
    try {
      final den = await openDen();
      await den.createFamily(
        familyName: 'Probe',
        timezone: 'America/Chicago',
        yourName: 'P',
        marker: Marker.sky,
        animal: Animal.cat,
        deviceName: 'probe',
        deviceKind: DeviceKind.phone,
      );
      _ready = den.isApproved;
    } on UnimplementedError {
      _ready = false;
    }
  }
  if (_ready!) return false;
  markTestSkipped('den_core is not implemented yet (Den.open or createFamily throws UnimplementedError)');
  return true;
}

Future<Den> openDen() async => Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());

class TestFamily {
  TestFamily._(this.founder, this.parent);
  final Den founder;
  final String parent;

  static Future<TestFamily> create() async {
    final den = await openDen();
    await den.createFamily(
      familyName: 'The Parks',
      timezone: 'America/Chicago',
      yourName: 'Pat',
      marker: Marker.sky,
      animal: Animal.cat,
      deviceName: 'Pat phone',
      deviceKind: DeviceKind.phone,
    );
    return TestFamily._(den, den.owner!.id);
  }

  Future<Den> approvedDevice({
    String? member,
    DeviceMode mode = DeviceMode.personal,
    DeviceKind kind = DeviceKind.phone,
    String name = 'device',
  }) async {
    final den = await openDen();
    await den.requestJoin(
      familyId: founder.familyId!,
      founderPubkey: founder.keys.pubkey,
      deviceName: name,
      kind: kind,
      mode: mode,
    );
    await founder.ingest(den.changesSince(const {}));
    await founder.approveDevice(den.deviceId, member: member, mode: mode);
    return den;
  }
}

Future<SyncPeer> link(SyncNode server, SyncNode client) async {
  final controller = StreamChannelController<dynamic>();
  unawaited(server.serve(controller.foreign));
  return client.connect(controller.local, expectDevice: server.den.deviceId);
}

Future<void> eventually(bool Function() condition, {Duration timeout = const Duration(seconds: 15)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> converge(List<Den> dens) async {
  String export(Den d) => jsonEncode(d.exportJson());
  try {
    await eventually(() => dens.map(export).toSet().length == 1);
  } on TimeoutException {
    fail('replicas did not converge:\n${dens.map(export).join('\n-----\n')}');
  }
}

int at(int hour) => DateTime.utc(2026, 10, 20, hour).millisecondsSinceEpoch;
