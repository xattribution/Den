import 'dart:convert';

import 'package:den_core/den_core.dart';
import 'package:den_core/src/snapshot.dart';
import 'package:test/test.dart';

import 'support.dart';

/// What people see of a family, as text: every record, History, and the sync state.
String seen(Den den) => jsonEncode({
      'export': den.exportJson(),
      'history': [
        for (final h in den.history(limit: 100000))
          [h.change, h.verb, h.title, for (final d in h.diffs) [d.field, d.before, d.after]],
      ],
      'vv': (den.versionVector.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((e) => [e.key, e.value]).toList(),
    });

/// A copy of [from] with its changes, metadata and snapshot, [edit]ed on the way.
Future<SnapshotMemoryStorage> copyOf(SnapshotMemoryStorage from, {List<Change> Function(List<Change>)? edit}) async {
  final to = SnapshotMemoryStorage();
  final changes = await from.loadChanges();
  await to.appendChanges(edit == null ? changes : edit(changes));
  await to.saveMeta((await from.loadMeta())!);
  to.snapshot = from.snapshot;
  return to;
}

void main() {
  snapshotCheckDelay = Duration.zero;
  late TestClock clock;
  late DeviceKeys keys;
  late SnapshotMemoryStorage storage;
  late Den den;
  late String groceries;

  /// Changes enough that a snapshot is due, a few at a time across a month of evenings.
  Future<void> busyMonth(Den d) async {
    final dana = d.actor!.id;
    final chore = await d.addChore(
      title: 'Dishes',
      owner: OwnerMember(dana),
      schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-04-01'),
      points: 2,
      steps: const [ChoreStep(id: 'load', text: 'Load'), ChoreStep(id: 'wipe', text: 'Wipe')],
    );
    final soccer = await d.addEvent(
      title: 'Soccer',
      start: DateTime.utc(2026, 4, 2, 21).millisecondsSinceEpoch,
      end: DateTime.utc(2026, 4, 2, 22).millisecondsSinceEpoch,
      rrule: 'FREQ=WEEKLY',
      rides: const [Ride('to', null)],
    );
    for (var day = 1; day <= 30; day++) {
      clock.set(DateTime.utc(2026, 4, day, 23));
      final date = '2026-04-${day.toString().padLeft(2, '0')}';
      for (var i = 0; i < 4; i++) {
        await d.addItem(groceries, text: 'Item $day.$i');
      }
      final open = d.list(groceries)!.items.where((i) => !i.checked).take(3).toList();
      for (final item in open) {
        await d.setItemChecked(item.id, true);
      }
      await d.setStep(chore, date, 'load', true);
      if (day.isEven) await d.setStep(chore, date, 'wipe', true);
      if (day % 7 == 2) {
        final o = d.occurrences(DateTime.utc(2026, 4, day).millisecondsSinceEpoch, DateTime.utc(2026, 4, day + 1).millisecondsSinceEpoch).single;
        await d.claimRide(soccer, occurrence: o.seriesStart, leg: 'to', driver: dana);
      }
      if (day % 10 == 0) await d.clearChecked(groceries);
    }
  }

  setUp(() async {
    clock = TestClock.at(DateTime.utc(2026, 4, 1, 15));
    keys = await DeviceKeys.generate();
    storage = SnapshotMemoryStorage();
    den = await openDen(clock, storage: storage, keys: keys);
    await den.createFamily(
      familyName: 'Rivera family',
      timezone: 'America/New_York',
      yourName: 'Dana',
      deviceName: 'Dana phone',
      deviceKind: DeviceKind.phone,
    );
    groceries = await den.addList(title: 'Groceries', kind: ListKind.shopping, pinned: true);
    await busyMonth(den);
    await den.debugIdle();
  });

  test('a device writes a snapshot as its log grows, and opens from it to the same state', () async {
    expect(storage.saves, greaterThan(0));
    expect(SnapshotHeader.parse(storage.snapshot!), isNotNull);
    // A few more after the snapshot: the tail the next open applies on top.
    await den.addItem(groceries, text: 'After the snapshot');
    final expected = seen(den);

    final reopened = await openDen(clock, storage: await copyOf(storage), keys: keys);
    expect(reopened.debugOpenedFromSnapshot, isTrue);
    expect(reopened.debugFullReplays, 0);
    expect(seen(reopened), expected);
    // A preview copies the state rather than replaying it, and then goes its own way.
    final preview = await reopened.fork();
    expect(seen(preview), expected);
    await preview.addItem(groceries, text: 'Only in the preview');
    expect(reopened.list(groceries)!.items.map((i) => i.text), isNot(contains('Only in the preview')));
    expect(seen(reopened), expected);
    await preview.close();
    final plain = MemoryStorage();
    await plain.appendChanges(den.changesSince({}));
    await plain.saveMeta((await storage.loadMeta())!);
    final replayed = await openDen(clock, storage: plain, keys: keys);
    expect(replayed.debugOpenedFromSnapshot, isFalse);
    expect(seen(replayed), expected);
    await replayed.close();

    // And it carries on as if it had replayed: writes, undo, the views.
    final made = await reopened.recording(() => reopened.addItem(groceries, text: 'Next'));
    await reopened.undo(made.changes);
    expect(reopened.list(groceries)!.items.map((i) => i.text), isNot(contains('Next')));
    expect(jsonEncode(reopened.today().chores.map((c) => [c.chore.id, c.done]).toList()),
        jsonEncode(den.today().chores.map((c) => [c.chore.id, c.done]).toList()));
    await reopened.debugIdle();
    await reopened.close();
  });

  test('a partner\'s week offline rewinds a week, both live and when the device opens again', () async {
    final priya = await den.addMember(name: 'Priya', role: Role.parent);
    final partnerClock = TestClock(clock.now);
    final partner = await joinDevice(den, partnerClock, member: priya, name: 'Priya phone');
    await den.debugIdle();
    final week = clock.now - const Duration(days: 7).inMilliseconds;
    partnerClock.set(DateTime.fromMillisecondsSinceEpoch(week, isUtc: true));
    // Offline: the partner's clock is a week behind the family's.
    for (var i = 0; i < 5; i++) {
      partnerClock.advance(const Duration(hours: 20));
      await partner.addItem(groceries, text: 'Partner ${i + 1}');
    }
    final replaysBefore = den.debugFullReplays;
    await sync(partner, den);
    expect(den.debugFullReplays, replaysBefore, reason: 'a week back is inside what it can rewind');
    expect(den.list(groceries)!.items.map((i) => i.text), containsAll(['Partner 1', 'Partner 5']));
    final expected = seen(den);
    await den.debugIdle();

    final reopened = await openDen(clock, storage: await copyOf(storage), keys: keys);
    expect(reopened.debugOpenedFromSnapshot, isTrue);
    expect(reopened.debugFullReplays, 0);
    expect(seen(reopened), expected);
    await partner.close();
    await reopened.close();
  });

  test('a stored change altered after the snapshot vouched for it is caught and dropped', () async {
    final expected = seen(den);
    final victim = den.changesSince({}).lastWhere((c) => c.type == RecordType.item && c.fields['text'] != null);
    final altered = await copyOf(storage, edit: (changes) => [
          for (final c in changes)
            c.id == victim.id
                ? Change.fromJson({...c.toJson(), 'fields': {...c.fields, 'text': 'Altered'}})
                : c,
        ]);
    final reopened = await openDen(clock, storage: altered, keys: keys);
    final changed = <Set<String>>[];
    reopened.onChange.listen(changed.add);
    // Opened from the snapshot, which saw the real change (History still shows the stored one
    // until the check below).
    expect(jsonEncode(reopened.exportJson()), jsonEncode(jsonDecode(expected)['export']));
    await reopened.debugIdle();
    expect(reopened.changesSince({}).map((c) => c.id), isNot(contains(victim.id)));
    expect(reopened.list(groceries)!.items.map((i) => i.text), isNot(contains('Altered')));
    expect(changed, isNotEmpty);
    // What's left is what a replay of the stored changes that verify gives.
    final honestStorage = MemoryStorage();
    await honestStorage.appendChanges([for (final c in den.changesSince({})) if (c.id != victim.id) c]);
    await honestStorage.saveMeta((await storage.loadMeta())!);
    final honest = await openDen(clock, storage: honestStorage, keys: keys);
    expect(jsonEncode(reopened.exportJson()), jsonEncode(honest.exportJson()));
    await reopened.close();
    await honest.close();
  });

  test('a forged change stored after the snapshot is dropped once its signature is checked', () async {
    final expected = seen(den);
    final real = den.changesSince({}).last;
    final forged = Change.fromJson({
      ...real.toJson(),
      'id': '${den.deviceId}:${real.counter + 1}',
      'hlc': Hlc(real.hlc.millis + 1, 0, den.deviceId).toString(),
      'rid': 'forgeditem',
      'fields': {...real.fields, 'text': 'Forged'},
    });
    final tampered = await copyOf(storage);
    await tampered.appendChanges([forged]);
    final reopened = await openDen(clock, storage: tampered, keys: keys);
    await reopened.debugIdle();
    expect(reopened.changesSince({}).map((c) => c.id), isNot(contains(forged.id)));
    expect(seen(reopened), expected);
    await reopened.close();
  });

  test('a snapshot from another format is ignored, and written again in this one', () async {
    final expected = seen(den);
    final old = await copyOf(storage);
    old.snapshot = old.snapshot!.replaceFirst('"v":$snapshotFormat', '"v":0');
    final reopened = await openDen(clock, storage: old, keys: keys);
    expect(reopened.debugOpenedFromSnapshot, isFalse);
    expect(seen(reopened), expected);
    await reopened.debugIdle();
    expect(SnapshotHeader.parse(old.snapshot!), isNotNull);
    final again = await openDen(clock, storage: await copyOf(old), keys: keys);
    expect(again.debugOpenedFromSnapshot, isTrue);
    expect(seen(again), expected);
    await reopened.close();
    await again.close();
  });

  test('a change older than the snapshot\'s window replays the log, then the snapshot is rewritten', () async {
    final priya = await den.addMember(name: 'Priya', role: Role.parent);
    final partnerClock = TestClock(clock.now);
    final partner = await joinDevice(den, partnerClock, member: priya, name: 'Priya phone');
    // Clocked before anything the snapshot can rewind to (before the family, even, so it
    // doesn't count; it still has its place in the log).
    final old = await forge(
      partner.keys,
      counter: 1000,
      millis: DateTime.utc(2026, 3, 1).millisecondsSinceEpoch,
      type: RecordType.category,
      rid: 'old',
      fields: {'name': 'From long ago'},
      actor: priya,
    );
    await den.debugIdle();
    final saves = storage.saves;
    final result = await den.ingest([old]);
    expect(result.added, 1);
    expect(result.invalid, contains(old.id));
    final expected = seen(den);
    await den.debugIdle();
    expect(storage.saves, greaterThan(saves), reason: 'the old snapshot would replay everything');
    final reopened = await openDen(clock, storage: await copyOf(storage), keys: keys);
    expect(reopened.debugOpenedFromSnapshot, isTrue);
    expect(seen(reopened), expected);
    await partner.close();
    await reopened.close();
  });

  test('privacy notices read the same from a snapshot', () async {
    final teen = await den.addMember(name: 'Ana', role: Role.kid, tier: Tier.teen);
    clock.advance(const Duration(days: 1));
    await den.updateFamily({'oversight.$teen': {'parentsSeePrivate': false}});
    for (var i = 0; i < snapshotEvery; i++) {
      clock.advance(const Duration(minutes: 3));
      await den.addItem(groceries, text: 'More $i');
    }
    await den.debugIdle();
    final notice = den.privacyChange(teen)!;
    expect(notice.parentsSee, isFalse);
    final reopened = await openDen(clock, storage: await copyOf(storage), keys: keys);
    expect(reopened.debugOpenedFromSnapshot, isTrue);
    final again = reopened.privacyChange(teen)!;
    expect([again.change, again.by, again.at, again.parentsSee], [notice.change, notice.by, notice.at, notice.parentsSee]);
    await reopened.close();
  });

  test('leaving the family removes the snapshot with the log', () async {
    expect(storage.snapshot, isNotNull);
    await den.leaveFamily();
    expect(storage.snapshot, isNull);
    await den.debugIdle();
    expect(storage.snapshot, isNull);
  });
}
