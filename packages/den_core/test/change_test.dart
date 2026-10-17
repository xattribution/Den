import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'support.dart';

Change _with(Change c, {String? space, Map<String, Object?>? fields, String? actor, Hlc? hlc, String? sig}) => Change(
      id: c.id,
      space: space ?? c.space,
      hlc: hlc ?? c.hlc,
      type: c.type,
      rid: c.rid,
      fields: fields ?? c.fields,
      device: c.device,
      actor: actor ?? c.actor,
      sig: sig ?? c.sig,
    );

void main() {
  test('canonical JSON sorts keys recursively without whitespace', () {
    expect(
      canonicalJson({
        'b': 1,
        'a': [
          {'z': true, 'y': null},
        ],
      }),
      '{"a":[{"y":null,"z":true}],"b":1}',
    );
  });

  test('device keys round-trip and ids hash the public key', () async {
    final keys = await DeviceKeys.generate();
    final restored = await DeviceKeys.fromJson(await keys.toJson());
    expect(await restored.deviceId(), await keys.deviceId());
    expect(deviceIdOf(keys.pubkey), await keys.deviceId());
    final sig = await restored.sign([1, 2, 3]);
    expect(await verifySignature([1, 2, 3], sig, keys.pubkey), isTrue);
    expect(await verifySignature([1, 2, 4], sig, keys.pubkey), isFalse);
    expect(await verifySignature([1, 2, 3], 'not-a-signature', keys.pubkey), isFalse);
  });

  test('the family id commits to the founder key and creation time', () async {
    final clock = TestClock.at(DateTime.utc(2026, 1, 5, 12));
    final den = await foundFamily(clock);
    final genesis = den.changesSince({}).first;
    expect(genesis.type, RecordType.family);
    expect(den.familyId, familyIdFor(den.keys.pubkey, genesis.hlc.millis));
    expect(familyIdFor(den.keys.pubkey, genesis.hlc.millis + 1), isNot(den.familyId));
    expect(den.familyId, hasLength(16));
  });

  test('every change a device writes is signed over its canonical bytes', () async {
    final clock = TestClock.at(DateTime.utc(2026, 1, 5, 12));
    final den = await foundFamily(clock);
    await den.addEvent(title: 'Dentist', start: clock.now, end: clock.now + 3600000);
    for (final c in den.changesSince({})) {
      expect(await verifySignature(c.signedBytes, c.sig, den.keys.pubkey), isTrue);
      final json = Change.fromJson(c.toJson());
      expect(json.signedBytes, c.signedBytes);
    }
  });

  test('tampered changes are refused and never shadow the genuine one', () async {
    final clock = TestClock.at(DateTime.utc(2026, 1, 5, 12));
    final parent = await foundFamily(clock);
    final other = await joinDevice(parent, clock, member: parent.actor!.id, name: 'Second phone');
    clock.advance(const Duration(minutes: 1));
    await parent.addEvent(title: 'Dentist', start: clock.now, end: clock.now + 3600000);
    final genuine = parent.changesSince(other.versionVector).single;

    final tampered = [
      _with(genuine, fields: {...genuine.fields, 'title': 'Cancelled'}),
      _with(genuine, space: Space.parents),
      _with(genuine, hlc: Hlc(genuine.hlc.millis + 1, 0, genuine.device)),
      _with(genuine, sig: b64e(List.filled(64, 7))),
    ];
    for (final t in tampered) {
      final result = await other.ingest([t]);
      expect(result.added, 0);
      expect(result.rejected.keys, [genuine.id]);
    }
    expect(other.events, isEmpty);
    final result = await other.ingest([genuine]);
    expect(result.added, 1);
    expect(other.events.single.title, 'Dentist');
  });

  test('duplicates and replays are ignored by id', () async {
    final clock = TestClock.at(DateTime.utc(2026, 1, 5, 12));
    final parent = await foundFamily(clock);
    final other = await joinDevice(parent, clock, member: parent.actor!.id, name: 'Second phone');
    await parent.addEvent(title: 'Soccer', start: clock.now, end: clock.now + 3600000);
    final changes = parent.changesSince(other.versionVector);
    final first = await other.ingest([...changes, ...changes]);
    expect(first.added, changes.length);
    expect(first.duplicate, changes.length);
    final again = await other.ingest(parent.changesSince({}));
    expect(again.added, 0);
    expect(again.duplicate, parent.changesSince({}).length);
    expect(other.events, hasLength(1));
    expect(other.history().where((h) => h.title == 'Soccer'), hasLength(1));
  });
}
