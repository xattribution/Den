// Joining a second family on a device already in one, against a real Den host in this process
// with two families on it (FAMILY-LINKS-PLAN §5.1): the second family's engine has keys of its
// own and syncs through the same address as the first, the hub routing each by its family; one
// Web Push subscription made with the host's key is registered with both; leaving one family
// takes this device out of it and forgets it. Plain `test`s: real sockets and timers.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:den_app/app/household.dart';
import 'package:den_app/features/family/family.dart' show AnotherFamilyPairing, MembershipActions, PastedInvite, JoinRoute, PasteProblem;
import 'package:den_app/platform/sync/den_network.dart';
import 'package:den_app/platform/sync/hub_push.dart';
import 'package:den_app/platform/sync/local_hub.dart';
import 'package:den_app/platform/sync/net_pairing.dart';
import 'package:den_app/platform/sync/pairing.dart';
import 'package:den_app/platform/web/web_app.dart';
import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_hub/src/push/web_push_crypto.dart' show b64url;
import 'package:den_net/den_net.dart' show SyncState;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../helpers/households.dart';

Future<void> until(bool Function() done, {Duration timeout = const Duration(seconds: 40), String? what}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for ${what ?? 'a condition'}');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// A family on the host: its first parent's phone (synced with its hub) and its hub.
class HostedFamily {
  HostedFamily(this.phone, this.network, this.hub);
  final Den phone;
  final DenNetwork network;
  final Den hub;

  NetPairing get pairing => NetPairing(network);

  /// A pre-approved invite for a new grown-up named [name], made on the phone the way Family's
  /// Invite does.
  Future<InviteMessage> invite(String name) async {
    final member = await phone.addMember(name: name, role: Role.adult);
    return pairing.createInvite(memberId: member);
  }
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late DenHost host;
  late Uri served;

  /// A family founded on [parent]'s phone with a hub on the host at [address], both families
  /// opting into the host's push key.
  Future<HostedFamily> family(String name, String parent, String address) async {
    final phone = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    await found(phone, name, you: parent);
    final hub = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    await hub.requestJoin(
      familyId: phone.familyId!,
      founderPubkey: phone.founderPubkey!,
      deviceName: '$name hub',
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
    await host.add(hub, HubConfig(mdns: false, publicUrl: Uri.parse('https://$address'), log: HubLog.silent(), hostPush: true));
    final network = DenNetwork(phone, hubs: [Uri.parse('ws://127.0.0.1:${host.port}/ws')], localHub: LocalHub.create(port: 0, mdns: false));
    addTearDown(network.dispose);
    await network.start();
    await until(() => network.status.state == SyncState.live, what: '$name to sync with its hub');
    return HostedFamily(phone, network, hub);
  }

  setUp(() async {
    host = await DenHost.start(HostConfig(port: 0, host: InternetAddress.loopbackIPv4, log: HubLog.silent()));
    addTearDown(host.stop);
    served = Uri.parse('http://127.0.0.1:${host.port}/');
  });

  test('Grandma joins the Smiths beside the Kotvases: keys of her own, one address, one push subscription', () async {
    final kotvas = await family('Kotvas', 'Alex', 'den.kotvas.test');
    final smith = await family('Smith family', 'Dana', 'den-smith.kotvas.test');

    // Grandma's iPhone, in the Kotvas family first: its first log, as Den always kept it.
    final store = MemoryHouseholdStore(servedBy: served);
    final home = await Household.boot(store);
    addTearDown(() async {
      for (final l in home.logs) {
        await l.network?.close();
      }
    });
    final first = home.active;
    final toKotvas = await kotvas.invite('Grandma');
    final joined = await first.pairing!.joinWithInvite(toKotvas.code, deviceName: (n) => "$n's iPhone", kind: DeviceKind.phone);
    expect(joined.admitted, isTrue);
    await until(() => first.den.isApproved, what: 'Grandma to be in the Kotvas family');
    expect(home.several, isFalse);

    // Dana invites her; Grandma pastes the invite: "Join the Smith family as Grandma?"
    final toSmith = await smith.invite('Grandma');
    // Its link names the Smiths' own address on the server; the app asks its own address.
    final pasted = PastedInvite.read(toSmith.text);
    expect(pasted, isA<JoinRoute>());
    expect((pasted as JoinRoute).hub, Uri.parse('https://den-smith.kotvas.test'));
    final another = AnotherFamilyPairing(home, servedBy: served, web: true);
    final peek = await another.peekInvite(pasted.words, hubUrl: pasted.hub?.toString());
    expect(peek.familyName, 'Smith family');
    expect(peek.memberName, 'Grandma');
    expect(peek.letsIn, isTrue);
    expect(peek.server, served.host, reason: 'the server that answered, for "Join the Smith family on <server>"');
    final ticket = await another.joinWithInvite(pasted.words, hubUrl: pasted.hub?.toString(), deviceName: (n) => "$n's iPhone", kind: DeviceKind.phone);
    expect(ticket.familyId, smith.phone.familyId);

    // The Smiths' own engine, beside the Kotvases', showing now.
    expect(home.logs, hasLength(2));
    final second = home.byId(smith.phone.familyId!)!;
    expect(identical(home.active, second), isTrue);
    await until(() => second.den.isApproved, what: 'Grandma to be in the Smith family');
    expect(home.several, isTrue);
    expect(second.den.deviceId, isNot(first.den.deviceId), reason: 'a device of its own in each family');
    final slot = second.membership.slot!;
    expect(store.keys.values.keys, containsAll(['den.device.keys', 'den.device.keys.$slot']));
    expect(store.storages.keys, containsAll(['den', 'den-$slot']));
    expect(first.den.familyId, kotvas.phone.familyId);
    expect(second.den.thisDevice!.member, isNotNull);

    // Both sync through the one address; the host hands each to its own family.
    await until(() => first.network!.status.state == SyncState.live && second.network!.status.state == SyncState.live,
        what: 'both families live');
    expect(first.network!.status.device, kotvas.hub.deviceId);
    expect(second.network!.status.device, smith.hub.deviceId);
    final lake = await smith.phone.addEvent(title: 'Lake day', start: 1800000000000, end: 1800003600000);
    await until(() => second.den.event(lake) != null, what: "the Smiths' event to reach Grandma");
    expect(first.den.event(lake), isNull, reason: "the Kotvases' engine never sees the Smiths' changes");
    expect(kotvas.phone.event(lake), isNull);
    expect(smith.phone.device(second.den.deviceId)?.approved, isTrue);
    expect(kotvas.phone.device(second.den.deviceId), isNull);

    // One engine per family: the Smiths' invite can't be joined twice on this device.
    final again = await smith.invite('Grandma again');
    await expectLater(another.peekInvite(again.code), throwsA(isA<PairingException>()));
    expect(home.logs, hasLength(2));

    // Reminders in the web app: one subscription with the host's key, registered with each family.
    final plan = await PushPlan.look([
      PushFamily('Smith family', HubPushClient(second.network!)),
      PushFamily('Kotvas', HubPushClient(first.network!)),
    ]);
    expect(plan.shared, isTrue);
    expect(plan.key, b64url(host.pushKey.publicKey));
    expect(plan.on, isFalse);
    expect(plan.unreached, isEmpty);
    const browser = WebPushSubscription(
      endpoint: 'https://web.push.apple.com/grandma',
      p256dh: 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4',
      auth: 'BTBZMqHH6r4Tts7J_aSIgg',
    );
    await plan.register(browser);
    for (final log in [first, second]) {
      final status = await HubPushClient(log.network!).status();
      expect(status.subscribed, isTrue, reason: log.name);
      expect(status.withHost, isTrue, reason: log.name);
    }
    expect((await PushPlan.look([PushFamily('Kotvas', HubPushClient(first.network!))])).on, isFalse,
        reason: 'one family alone keeps its own key, as always');

    // Grandma leaves the Smiths on this iPhone: the Smiths' hub forgets her browser first (no
    // more reminders from them), then the device takes itself out, and is forgotten.
    final smithHub = host.tenants.firstWhere((t) => t.den.familyId == smith.phone.familyId);
    Map<Object?, Object?> pushDevices() => (smithHub.context.state.read('push')['devices'] as Map?) ?? const {};
    expect(pushDevices().containsKey(second.den.deviceId), isTrue);
    final leaving = second.den.deviceId;
    await MembershipActions.leave(home, second, flush: const Duration(milliseconds: 600));
    expect(pushDevices().containsKey(leaving), isFalse, reason: "the Smiths' hub sends this browser nothing more");
    expect(home.logs, hasLength(1));
    expect(home.several, isFalse);
    expect(identical(home.active, first), isTrue);
    await until(() => smith.phone.device(second.den.deviceId)?.revoked ?? false, what: 'the Smiths to see the device go');
    expect(store.storages.keys, isNot(contains('den-$slot')));
    expect(store.keys.values.keys, isNot(contains('den.device.keys.$slot')));
    expect(store.forgotten.map((m) => m.id), [smith.phone.familyId]);
    expect(MembershipActions.canLeave(home, first), isFalse, reason: 'the last family stays');
    await expectLater(MembershipActions.leave(home, first), throwsStateError);
  });

  test('In the web app, an invite from another server says so, and nothing is started', () async {
    final kotvas = await family('Kotvas', 'Alex', 'den.kotvas.test');
    final store = MemoryHouseholdStore(servedBy: served);
    final home = await Household.boot(store);
    addTearDown(() async {
      for (final l in home.logs) {
        await l.network?.close();
      }
    });
    final toKotvas = await kotvas.invite('Grandma');
    await home.active.pairing!.joinWithInvite(toKotvas.code, deviceName: (n) => "$n's iPhone", kind: DeviceKind.phone);
    await until(() => home.active.den.isApproved);

    // An invite whose family's Den is on another server: this server doesn't know its words.
    const elsewhere = 'Join the Lees on Den: https://den.lee.example/#/join/maple-river-canoe-tiger';
    final read = PastedInvite.read(elsewhere) as JoinRoute;
    final another = AnotherFamilyPairing(home, servedBy: served, web: true);
    await expectLater(
      another.peekInvite(read.words, hubUrl: read.hub.toString()),
      throwsA(isA<PairingException>().having((e) => e.message, 'message', contains('another server (den.lee.example)'))),
    );
    await expectLater(
      another.joinWithInvite(read.words, hubUrl: read.hub.toString(), deviceName: (_) => 'iPhone', kind: DeviceKind.phone),
      throwsA(isA<PairingException>().having((e) => e.message, 'message', contains('another server'))),
    );
    expect(home.logs, hasLength(1));
    expect(store.storages.keys, ['den']);
    // Words this server doesn't know, with no link to say where else: wrong or expired, as always.
    await expectLater(
      another.peekInvite(read.words),
      throwsA(isA<PairingException>().having((e) => e.message, 'message', isNot(contains('another server')))),
    );
    expect(PastedInvite.read('nothing here'), isA<PasteProblem>());
    expect((PastedInvite.read('https://den.kotvas.test/#/group/maple-river-canoe-tiger') as PasteProblem).message, contains('group'));
  });

  test("In the native apps, typed words never go to the family the device shows; only to the invite's own server", () async {
    final kotvas = await family('Kotvas', 'Alex', 'den.kotvas.test');
    final smith = await family('Smith family', 'Dana', 'den-smith.kotvas.test');
    final store = MemoryHouseholdStore();
    final home = await Household.boot(store);
    addTearDown(() async {
      for (final l in home.logs) {
        await l.network?.close();
      }
    });
    final toKotvas = await kotvas.invite('Grandma');
    await home.active.pairing!.joinWithInvite(toKotvas.code, hubUrl: served.toString(), deviceName: (n) => "$n's iPhone", kind: DeviceKind.phone);
    await until(() => home.active.den.isApproved);
    final toSmith = await smith.invite('Grandma');
    final another = AnotherFamilyPairing(home, web: false);

    // Four words alone: no server to ask, and the Kotvases' hub is never asked about them.
    await expectLater(
      another.peekInvite(toSmith.code),
      throwsA(isA<PairingException>().having((e) => e.message, 'message', contains('which server'))),
    );
    await expectLater(
      another.joinWithInvite(toSmith.code, deviceName: (_) => 'iPhone', kind: DeviceKind.phone),
      throwsA(isA<PairingException>()),
    );
    expect(home.logs, hasLength(1));
    expect(store.storages.keys, ['den'], reason: 'nothing started');

    // With the server typed (or from the link): asked there, and the answer says where.
    final peek = await another.peekInvite(toSmith.code, hubUrl: served.toString());
    expect(peek.familyName, 'Smith family');
    expect(peek.server, served.host);
    // A QR code says the server it names, before anything starts; one for a family this device
    // holds is refused.
    final qr = await smith.pairing.createInviteQr();
    expect((await another.peekQr(qr)).server, served.host);
    await expectLater(another.peekQr(await kotvas.pairing.createInviteQr()), throwsA(isA<PairingException>()));
    expect(home.logs, hasLength(1));

    // Two joins at once: the second is refused before anything starts.
    final first = another.joinWithInvite(toSmith.code, hubUrl: served.toString(), deviceName: (n) => "$n's iPhone", kind: DeviceKind.phone);
    await expectLater(
      another.joinWithInvite(toSmith.code, hubUrl: served.toString(), deviceName: (n) => "$n's iPhone", kind: DeviceKind.phone),
      throwsA(isA<PairingException>().having((e) => e.message, 'message', contains('Already joining'))),
    );
    final ticket = await first;
    expect(ticket.familyId, smith.phone.familyId);
    expect(home.logs, hasLength(2));
  });

  test("Words for a hub that doesn't hold their slot are never sent to it", () async {
    final kotvas = await family('Kotvas', 'Alex', 'den.kotvas.test');
    final store = MemoryHouseholdStore();
    final home = await Household.boot(store);
    addTearDown(() async {
      for (final l in home.logs) {
        await l.network?.close();
      }
    });
    final toKotvas = await kotvas.invite('Grandma');
    await home.active.pairing!.joinWithInvite(toKotvas.code, hubUrl: served.toString(), deviceName: (n) => "$n's iPhone", kind: DeviceKind.phone);
    await until(() => home.active.den.isApproved);
    // A second server, which holds no invite with these words, records what it is sent.
    final seen = <String>[];
    final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => other.close(force: true));
    other.listen((request) async {
      seen.add(await utf8.decoder.bind(request).join());
      request.response
        ..statusCode = 404
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'error': {'code': 'not_found', 'message': 'No such invite'}}));
      await request.response.close();
    });
    const words = 'maple river canoe tiger';
    final another = AnotherFamilyPairing(home, web: false);
    await expectLater(
      another.peekInvite(words, hubUrl: 'http://127.0.0.1:${other.port}'),
      throwsA(isA<PairingException>().having((e) => e.reason, 'reason', PairingException.unknownCode)),
    );
    expect(seen, hasLength(1), reason: 'asked once, by slot');
    expect(seen.single, contains('"slot"'));
    for (final w in words.split(' ')) {
      expect(seen.single, isNot(contains(w)), reason: 'the words themselves never left the device');
    }
  });
}
