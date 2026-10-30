import 'package:den_core/den_core.dart';

import 'support.dart';

/// Two families, each with a log of its own, and a group of both ("Cousins soccer"), as the
/// app sets them up (FAMILY-LINKS-PLAN 5.2): Alex starts the group and brings the Kotvas family
/// in, invites the Smiths, and Dana's phone lets itself in and brings the Smith family in. Every
/// device holds one engine per log.
class Families {
  Families(this.clock);
  final TestClock clock;

  // The Kotvas family's own log: Alex's phone, Priya's phone, Leo's tablet and the family's hub.
  late Den kotvas;
  late Den priyaF;
  late Den leoF;
  late Den kHubF;
  late String kAlex, kPriya, kLeo;

  // The Smith family's own log: Dana's phone, Mia's tablet and the family's hub.
  late Den smith;
  late Den miaF;
  late Den sHubF;
  late String sDana, sMia;

  // The group, one engine per device: the founder's (Alex's phone), and everyone else's.
  late Den alex;
  late Den priya;
  late Den leo;
  late Den kHub;
  late Den dana;
  late Den mia;
  late Den sHub;
  late String kotvasHome, smithHome;
  late String gAlex, gPriya, gLeo, gDana, gMia;
  late GroupInvitation invitation;

  String get group => alex.familyId!;

  /// The Kotvas devices in the group, Alex's phone first.
  List<Den> get kotvasDevices => [alex, priya, leo, kHub];

  /// The Smith devices in the group, Dana's phone first.
  List<Den> get smithDevices => [dana, mia, sHub];
}

/// Syncs a group the way its devices do: each device with its own family's hub, and the hubs
/// with each other, until nothing moves.
Future<void> settle(Families f, {bool smiths = true}) async {
  for (var round = 0; round < 3; round++) {
    for (final d in [f.alex, f.priya, f.leo]) {
      await exchange(d, f.kHub);
    }
    if (smiths) {
      await exchange(f.kHub, f.sHub);
      for (final d in [f.dana, f.mia]) {
        await exchange(d, f.sHub);
      }
      await exchange(f.kHub, f.sHub);
    }
  }
}

/// Lets a fresh engine into the group through [via] with [admission].
Future<Den> admit(Families f, GroupAdmission admission, Den via, {required String name, DeviceKind kind = DeviceKind.phone}) async {
  // A device joins after the key that lets it in was made (a fresh engine's clock knows nothing
  // of the group's yet).
  f.clock.advance(const Duration(seconds: 1));
  final engine = await openDen(f.clock);
  await engine.joinGroup(admission, deviceName: name, kind: kind);
  final result = await via.ingest(engine.changesSince(const {}));
  if (result.invalid.isNotEmpty) throw StateError('$name wasn\'t let in: ${result.invalid.values.first}');
  await sync(via, engine);
  return engine;
}

/// A device of a family's own log opens its sealed admission into the group and lets a fresh
/// engine in with it, through [via].
Future<Den> admitFrom(Families f, Den familyDevice, Den familyParent, Den via, {required String name}) async {
  await sync(familyParent, familyDevice);
  final admission = await familyDevice.openGroupInvite(f.group);
  if (admission == null) throw StateError('$name has no admission');
  return admit(f, admission, via, name: name, kind: familyDevice.thisDevice!.kind);
}

/// The Kotvas family alone in its new group.
Future<Families> kotvasGroup(TestClock clock) async {
  final f = Families(clock);
  f.kotvas = await foundFamily(clock, name: 'Alex');
  f.kAlex = f.kotvas.actor!.id;
  f.kPriya = await f.kotvas.addMember(name: 'Priya', role: Role.parent);
  f.kLeo = await f.kotvas.addMember(name: 'Leo', role: Role.kid, tier: Tier.big);
  f.priyaF = await joinDevice(f.kotvas, clock, member: f.kPriya, name: "Priya's phone", kind: DeviceKind.phone);
  f.leoF = await joinDevice(f.kotvas, clock, member: f.kLeo, name: "Leo's tablet");
  f.kHubF = await joinDevice(f.kotvas, clock, mode: DeviceMode.hub, name: 'Kotvas hub', kind: DeviceKind.hub);

  f.alex = await openDen(clock);
  f.kotvasHome = await f.alex.createGroup(
    name: 'Cousins soccer',
    timezone: 'America/New_York',
    homeName: 'Kotvas',
    yourName: 'Alex',
    link: f.kAlex,
    ownFamily: f.kotvas.familyId,
    hubs: const ['https://den.kotvas.app/ws'],
    deviceName: "Alex's phone",
    deviceKind: DeviceKind.phone,
  );
  f.gAlex = f.alex.actor!.id;
  clock.advance(const Duration(seconds: 1));
  await f.alex.addToGroup(family: f.kotvas, people: [f.kAlex, f.kPriya, f.kLeo]);
  f.gPriya = f.kotvas.groupLink(f.group)!.members[f.kPriya]!;
  f.gLeo = f.kotvas.groupLink(f.group)!.members[f.kLeo]!;
  // The hub first (the app's POST /api/v1/groups), then everyone else through it.
  f.kHub = await admitFrom(f, f.kHubF, f.kotvas, f.alex, name: 'Kotvas hub');
  await exchange(f.alex, f.kHub);
  f.priya = await admitFrom(f, f.priyaF, f.kotvas, f.kHub, name: "Priya's phone");
  f.leo = await admitFrom(f, f.leoF, f.kotvas, f.kHub, name: "Leo's tablet");
  for (final d in [f.alex, f.priya, f.leo]) {
    await exchange(d, f.kHub);
  }
  return f;
}

/// Alex invites the Smiths: their home, Dana as its first parent, and keys for her phone and
/// the Smith hub.
Future<void> inviteSmiths(Families f) async {
  f.clock.advance(const Duration(seconds: 1));
  f.smith = await foundFamily(f.clock, name: 'Dana');
  f.sDana = f.smith.actor!.id;
  f.sMia = await f.smith.addMember(name: 'Mia', role: Role.kid, tier: Tier.little);
  f.miaF = await joinDevice(f.smith, f.clock, member: f.sMia, name: "Mia's tablet");
  f.sHubF = await joinDevice(f.smith, f.clock, mode: DeviceMode.hub, name: 'Smith hub', kind: DeviceKind.hub);
  f.invitation = await f.alex.inviteFamily(familyName: 'Smiths', parentName: 'Dana');
  f.smithHome = f.invitation.home;
  f.gDana = f.invitation.member;
  await exchange(f.alex, f.kHub);
}

/// Dana's phone lets itself in with the invitation, the Smith hub with its key, and Dana brings
/// the rest of the Smith family in.
Future<void> smithsJoin(Families f) async {
  f.clock.advance(const Duration(seconds: 1));
  f.dana = await admit(f, f.invitation.parent, f.kHub, name: "Dana's phone");
  f.sHub = await admit(f, f.invitation.hub, f.kHub, name: 'Smith hub', kind: DeviceKind.hub);
  await exchange(f.dana, f.sHub);
  await f.dana.updateHome(active: true, ownFamily: f.smith.familyId, hubs: const ['https://den.smith.example/ws']);
  await f.dana.addToGroup(family: f.smith, people: [f.sDana, f.sMia], hubs: false);
  f.gMia = f.smith.groupLink(f.group)!.members[f.sMia]!;
  await exchange(f.dana, f.sHub);
  f.mia = await admitFrom(f, f.miaF, f.smith, f.sHub, name: "Mia's tablet");
  await settle(f);
}

/// Both families in the group, everyone's devices in and in sync.
Future<Families> bothFamilies(TestClock clock) async {
  final f = await kotvasGroup(clock);
  await inviteSmiths(f);
  await smithsJoin(f);
  return f;
}

/// A change [device] signs as [actor], skipping the checks its engine makes before writing: how a
/// misbehaving device (or another family's app) would make one. Numbered after what it wrote.
Future<Change> forgeAs(
  Den device, {
  required String type,
  required String rid,
  required Map<String, Object?> fields,
  String? actor,
  String space = Space.family,
  int? millis,
  int skip = 0,
}) async {
  final mine = device.changesSince(const {}).where((c) => c.device == device.deviceId).map((c) => c.counter);
  final counter = (mine.isEmpty ? 0 : mine.reduce((a, b) => a > b ? a : b)) + 1 + skip;
  return forge(
    device.keys,
    counter: counter,
    millis: millis ?? device.now() + 1000,
    type: type,
    rid: rid,
    fields: fields,
    space: space,
    actor: actor,
  );
}

/// Why [target] refuses [c] (a fork of it, so nothing sticks), or null when it counts.
Future<String?> refusal(Den target, Change c) async {
  final fork = await target.fork();
  final result = await fork.ingest([c]);
  if (result.rejected.isNotEmpty) return 'signature: ${result.rejected.values.first}';
  return result.invalid[c.id];
}
