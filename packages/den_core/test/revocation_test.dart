import 'package:den_core/den_core.dart';
import 'package:den_core/src/materializer.dart';
import 'package:den_core/src/validity.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Revocation cutoffs (ARCHITECTURE.md, "Genesis and trust"): a removal names the last change
/// of the removed device its author held (`revokedAfter`), and the device's changes past it
/// clocked before the removal count for nothing. What a cutoff may never do: reach past the
/// device's own request to join, or stay in effect once the removal that named it stops
/// counting. Either would let one removal erase a device, everything it wrote and every device
/// it let in.
void main() {
  late TestClock clock;
  late DeviceKeys momKeys;
  late Den mom;
  late Den dad;
  late Den hub;
  late String momId;
  late String dadId;
  late String leo;

  setUp(() async {
    clock = TestClock.at(DateTime.utc(2026, 10, 1, 15));
    momKeys = await DeviceKeys.generate();
    mom = await Den.open(storage: MemoryStorage(), keys: momKeys, now: clock.call);
    await mom.createFamily(
      familyName: 'Rivera family',
      timezone: 'America/New_York',
      yourName: 'Mom',
      deviceName: 'Mom phone',
      deviceKind: DeviceKind.phone,
    );
    momId = mom.actor!.id;
    dadId = await mom.addMember(name: 'Dad', role: Role.parent);
    leo = await mom.addMember(name: 'Leo', role: Role.kid);
    dad = await joinDevice(mom, clock, member: dadId, name: 'Dad phone', kind: DeviceKind.phone);
    hub = await joinDevice(mom, clock, mode: DeviceMode.hub, name: 'Hub', kind: DeviceKind.hub);
    await exchange(mom, hub);
    await exchange(dad, hub);
  });

  /// Months of Dad's phone: it lets Leo's tablet in and adds an event. Returns the tablet.
  Future<Den> dadsMonths() async {
    clock.advance(const Duration(days: 30));
    final tablet = await joinDevice(dad, clock, member: leo, name: 'Leo tablet');
    await dad.addEvent(title: 'Soccer', start: clock.now + 3600000, end: clock.now + 7200000);
    await exchange(dad, hub);
    await exchange(tablet, hub);
    await exchange(mom, hub);
    clock.advance(const Duration(days: 30));
    return tablet;
  }

  /// A removal of [device] signed with [keys] directly, naming [revokedAfter].
  Future<Change> removal(
    DeviceKeys keys,
    String device, {
    required int counter,
    required int millis,
    required int revokedAfter,
    required String actor,
  }) => forge(
    keys,
    counter: counter,
    millis: millis,
    type: RecordType.device,
    rid: device,
    actor: actor,
    fields: {'revoked': true, 'revokedAfter': revokedAfter},
  );

  /// Everything [reference] holds, added to a fresh materializer one change at a time, newest
  /// first, reaches what a replay from scratch does, and what [reference] (which took the
  /// changes as they came) did.
  void expectSameFromScratch(Den reference) {
    final root = TrustRoot(familyId: reference.familyId, founderPubkey: reference.founderPubkey);
    final all = reference.changesSince(const {})..sort(changeOrder);
    final full = Materializer(() => root)
      ..add(all)
      ..replay();
    final late = Materializer(() => root);
    for (final c in all.reversed) {
      late.add([c]);
    }
    String state(Materializer m) => canonicalJson({
      'records': [
        for (final e in m.store.all) [e.type, e.space, e.id, e.fields],
      ]..sort((a, b) => '${a[0]}/${a[1]}/${a[2]}'.compareTo('${b[0]}/${b[1]}/${b[2]}')),
      'rejected': m.rejected,
    });
    expect(state(late), state(full));
    for (final d in reference.devices) {
      expect(Device(full.store.at(Space.family, RecordType.device, d.id)!.rec).revoked, d.revoked, reason: d.name);
    }
    expect(
      [for (final e in full.store.liveOfType(RecordType.event)) e.fields['title']]..sort(),
      [for (final e in reference.events) e.title]..sort(),
    );
  }

  test('a removal naming a counter below the device\'s request to join is refused, and erases nothing', () async {
    final tablet = await dadsMonths();
    final last = mom.versionVector[mom.deviceId]!;
    // Mom's phone (stolen and not yet removed, or misbehaving) removes Dad's phone, naming
    // revokedAfter 0 instead of what it holds.
    final c = await removal(momKeys, dad.deviceId, counter: last + 1, millis: clock.now, revokedAfter: 0, actor: momId);
    final result = await hub.ingest([c]);
    expect(result.invalid[c.id], contains('request to join'));
    expect(hub.device(dad.deviceId)!.revoked, isFalse);
    expect(hub.device(tablet.deviceId)!.approved, isTrue, reason: 'what Dad\'s phone let in stays in');
    expect(hub.events.map((e) => e.title), ['Soccer'], reason: 'what Dad\'s phone wrote stays');
    expect(hub.spacesForDevice(dad.deviceId), isNotEmpty);
    expectSameFromScratch(hub);
  });

  test('a removal of the founder\'s phone can\'t reach the family\'s own genesis', () async {
    // The founder's phone signed the family (1) and its parent (2) before its own record (3).
    clock.advance(const Duration(hours: 1));
    final last = dad.versionVector[dad.deviceId]!;
    final c = await removal(
      dad.keys,
      mom.deviceId,
      counter: last + 1,
      millis: clock.now,
      revokedAfter: 2,
      actor: dadId,
    );
    final result = await hub.ingest([c]);
    expect(result.invalid[c.id], contains('request to join'));
    expect(hub.hasFamily, isTrue);
    expect(hub.member(momId)?.isParent, isTrue);
    // At the record itself, the removal counts and erases nothing before it.
    final ok = await removal(
      dad.keys,
      mom.deviceId,
      counter: last + 2,
      millis: clock.now + 1,
      revokedAfter: 3,
      actor: dadId,
    );
    expect((await hub.ingest([ok])).invalid, isEmpty);
    expect(hub.device(mom.deviceId)!.revoked, isTrue);
    expect(hub.hasFamily, isTrue);
    expect(hub.member(momId)?.name, 'Mom');
  });

  test('a stolen phone\'s backdated removal of the phone that removed it, naming 0, counts for nothing', () async {
    clock.advance(const Duration(hours: 1));
    await mom.addCategory(name: 'Before');
    await exchange(mom, hub);
    await exchange(dad, hub);
    // Mom's phone is stolen. Dad removes it.
    clock.advance(const Duration(hours: 1));
    final removedAt = clock.now;
    await dad.revokeDevice(mom.deviceId);
    await exchange(dad, hub);
    final cut = hub.device(mom.deviceId)!.revokedAfter!;
    // With Mom's key, the thief signs a removal of Dad's phone clocked just before, then
    // something as Mom clocked after.
    clock.advance(const Duration(days: 2));
    final forged = await removal(
      momKeys,
      dad.deviceId,
      counter: cut + 1,
      millis: removedAt - 1,
      revokedAfter: 0,
      actor: momId,
    );
    final later = await forge(
      momKeys,
      counter: cut + 2,
      millis: removedAt + 1,
      type: RecordType.member,
      rid: dadId,
      actor: momId,
      fields: {'role': 'kid'},
    );
    final result = await hub.ingest([forged, later]);
    expect(result.invalid.keys, unorderedEquals([forged.id, later.id]));
    expect(hub.device(mom.deviceId)!.revoked, isTrue, reason: 'the stolen phone stays out');
    expect(hub.device(dad.deviceId)!.revoked, isFalse);
    expect(hub.member(dadId)!.role, Role.parent);
    expect(hub.spacesForDevice(dad.deviceId), isNotEmpty);
    await exchange(hub, dad);
    expect(dad.exportJson(), hub.exportJson());
    expectSameFromScratch(hub);
  });

  test('a cutoff stops counting when the removal that named it does', () async {
    final tablet = await dadsMonths();
    // Dad also has a laptop, his own device.
    final laptop = await joinDevice(mom, clock, member: dadId, name: 'Dad laptop', kind: DeviceKind.desktop);
    await exchange(mom, hub);
    await exchange(laptop, hub);
    // Mom's phone is stolen. Dad's laptop removes it.
    clock.advance(const Duration(hours: 1));
    final removedAt = clock.now;
    await laptop.revokeDevice(mom.deviceId);
    await exchange(laptop, hub);
    final cut = hub.device(mom.deviceId)!.revokedAfter!;
    // The thief answers with a removal of Dad's phone clocked just before, naming its request
    // to join: everything Dad's phone did since would count for nothing, if this counted.
    final joined = hub.changesSince(const {}).firstWhere((c) => c.device == dad.deviceId).counter;
    final forged = await removal(
      momKeys,
      dad.deviceId,
      counter: cut + 1,
      millis: removedAt - 1,
      revokedAfter: joined,
      actor: momId,
    );
    final result = await hub.ingest([forged]);
    expect(result.invalid[forged.id], contains('removed'), reason: 'signed after its removal, by the laptop\'s cutoff');
    expect(hub.device(mom.deviceId)!.revoked, isTrue);
    expect(hub.device(dad.deviceId)!.revoked, isFalse);
    expect(hub.device(tablet.deviceId)!.approved, isTrue, reason: 'its cutoff went with it');
    expect(hub.events.map((e) => e.title), ['Soccer']);
    expectSameFromScratch(hub);
  });
}
