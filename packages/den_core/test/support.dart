import 'package:den_core/den_core.dart';

/// A clock tests move by hand.
class TestClock {
  TestClock(this.now);
  TestClock.at(DateTime utc) : now = utc.millisecondsSinceEpoch;
  int now;
  int call() => now;
  void advance(Duration d) => now += d.inMilliseconds;
  void set(DateTime utc) => now = utc.millisecondsSinceEpoch;
}

Future<Den> openDen(TestClock clock, {DenStorage? storage, DeviceKeys? keys}) async =>
    Den.open(storage: storage ?? MemoryStorage(), keys: keys ?? await DeviceKeys.generate(), now: clock.call);

/// A family founded on a parent's phone.
Future<Den> foundFamily(
  TestClock clock, {
  String timezone = 'America/New_York',
  String name = 'Dana',
  DeviceMode mode = DeviceMode.personal,
}) async {
  final den = await openDen(clock);
  await den.createFamily(
    familyName: 'Rivera family',
    timezone: timezone,
    yourName: name,
    marker: Marker.blue,
    animal: Animal.cat,
    deviceName: '$name\'s phone',
    deviceKind: DeviceKind.phone,
    mode: mode,
  );
  return den;
}

/// Sends [to] what it lacks from [from], limited to the spaces [from] says [to] may hold.
Future<IngestResult> sync(Den from, Den to) => to.ingest(
      from.changesSince(to.versionVector, spaces: from.spacesForDevice(to.deviceId)),
      through: from.completeVector,
    );

/// Syncs both ways.
Future<void> exchange(Den a, Den b) async {
  await sync(a, b);
  await sync(b, a);
}

/// A new device that asks to join through [parent], gets approved, and receives its spaces.
Future<Den> joinDevice(
  Den parent,
  TestClock clock, {
  String? member,
  DeviceMode mode = DeviceMode.personal,
  String name = 'Tablet',
  DeviceKind kind = DeviceKind.tablet,
  bool approve = true,
}) async {
  final d = await openDen(clock);
  await d.requestJoin(
    familyId: parent.familyId!,
    founderPubkey: parent.founderPubkey!,
    deviceName: name,
    kind: kind,
    mode: mode,
    memberId: member,
  );
  await parent.ingest(d.changesSince(parent.versionVector));
  if (approve) {
    await parent.approveDevice(d.deviceId, member: member, mode: mode);
    await sync(parent, d);
  }
  return d;
}

/// A change signed with [keys] directly, skipping the local checks a [Den] makes before it
/// writes; how a misbehaving device would craft one.
Future<Change> forge(
  DeviceKeys keys, {
  required int counter,
  required int millis,
  required String type,
  required String rid,
  required Map<String, Object?> fields,
  String space = Space.family,
  String? actor,
}) async {
  final device = await keys.deviceId();
  final unsigned = Change(
    id: '$device:$counter',
    space: space,
    hlc: Hlc(millis, 0, device),
    type: type,
    rid: rid,
    fields: fields,
    device: device,
    actor: actor,
    sig: '',
  );
  return Change(
    id: unsigned.id,
    space: space,
    hlc: unsigned.hlc,
    type: type,
    rid: rid,
    fields: fields,
    device: device,
    actor: actor,
    sig: await keys.sign(unsigned.signedBytes),
  );
}

/// Ids in [den] for members by name.
String idOf(Den den, String name) => den.members.firstWhere((m) => m.name == name).id;
