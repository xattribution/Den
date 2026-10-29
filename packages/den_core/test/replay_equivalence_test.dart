import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:den_core/den_core.dart';
import 'package:den_core/src/materializer.dart';
import 'package:den_core/src/recovery.dart';
import 'package:den_core/src/snapshot.dart';
import 'package:den_core/src/validity.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A family's log with what makes replays hard: four devices editing with skewed clocks,
/// entries of map fields, removals and restores, moves between spaces, changes that don't count
/// (a kid overreaching, a device nobody approved), and a revoked device that keeps signing with
/// clocks from before its revocation.
Future<(TrustRoot, List<Change>, List<Change>)> buildPool(int seed) async {
  final random = Random(seed);
  final clock = TestClock.at(DateTime.utc(2026, 3, 1, 15));
  final a = await foundFamily(clock);
  final dana = a.actor!.id;
  final priya = await a.addMember(name: 'Priya', role: Role.parent);
  final leo = await a.addMember(name: 'Leo', role: Role.kid);
  final sitter = await a.addMember(name: 'Sam', role: Role.guest);
  final photo = File('test/fixtures/canvas_photo.jpg').readAsBytesSync();
  final reward = await a.addReward(title: 'Movie night', cost: 2);
  await a.adjustPoints(leo, 40, 'Start');
  final clockB = TestClock(clock.now), clockT = TestClock(clock.now), clockH = TestClock(clock.now);
  final b = await joinDevice(a, clockB, member: priya, name: 'Priya phone', kind: DeviceKind.phone);
  final t = await joinDevice(a, clockT, member: leo, name: 'Leo tablet');
  final h = await joinDevice(a, clockH, mode: DeviceMode.hub, name: 'Hub', kind: DeviceKind.hub);
  final stranger = await openDen(TestClock(clock.now));
  await stranger.requestJoin(familyId: a.familyId!, founderPubkey: a.founderPubkey!, deviceName: 'Stranger', kind: DeviceKind.phone);
  final devices = [a, b, t, h];
  final clocks = [clock, clockB, clockT, clockH];
  for (final d in devices) {
    await sync(a, d);
  }
  final forged = <Change>[...stranger.changesSince({})];
  var forgedCounter = 5000;

  Future<void> op(int who) async {
    final d = devices[who];
    final c = clocks[who];
    c.advance(Duration(seconds: 1 + random.nextInt(600)));
    final kid = d == t;
    try {
      switch (random.nextInt(21)) {
        case 0:
          final start = c.now + random.nextInt(7) * 86400000;
          await d.addEvent(
            title: 'Event ${random.nextInt(99)}',
            start: start,
            end: start + (1 + random.nextInt(3)) * 3600000,
            rrule: random.nextBool() ? 'FREQ=WEEKLY;COUNT=6' : null,
            assignees: [if (random.nextBool()) leo, if (random.nextBool()) dana],
            rides: const [Ride('to', null)],
            audience: kid || random.nextInt(3) > 0 ? Audience.everyone : Audience.parents,
          );
        case 1:
        case 14:
        case 15:
          final events = d.events;
          if (events.isEmpty) return;
          final e = events[random.nextInt(events.length)];
          final occ = d.occurrences(e.start, e.start + 30 * 86400000).where((o) => o.event.id == e.id).toList();
          if (e.rrule != null && occ.isNotEmpty && random.nextBool()) {
            final o = occ[random.nextInt(occ.length)];
            switch (random.nextInt(3)) {
              case 0:
                await d.updateEvent(e.id, {'title': 'Moved ${random.nextInt(9)}'}, scope: EditScope.one, occurrence: o.seriesStart);
              case 1:
                await d.claimRide(e.id, occurrence: o.seriesStart, leg: 'to', driver: random.nextBool() ? dana : priya);
              default:
                await d.deleteEvent(e.id, scope: EditScope.one, occurrence: o.seriesStart);
            }
          } else if (random.nextInt(4) == 0) {
            await d.deleteEvent(e.id);
          } else {
            await d.updateEvent(e.id, {'title': 'Renamed ${random.nextInt(99)}', 'location': 'Room ${random.nextInt(5)}'});
          }
        case 2:
          await d.addChore(
            title: 'Chore ${random.nextInt(99)}',
            owner: random.nextBool() ? OwnerMember(leo) : const OwnerAnyone(),
            schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-03-01'),
            points: random.nextInt(3),
            steps: const [ChoreStep(id: 's1', text: 'One'), ChoreStep(id: 's2', text: 'Two')],
          );
        case 3:
          final chores = d.chores;
          if (chores.isEmpty) return;
          final ch = chores[random.nextInt(chores.length)];
          final date = '2026-03-0${1 + random.nextInt(5)}';
          switch (random.nextInt(3)) {
            case 0:
              await d.setStep(ch.id, date, random.nextBool() ? 's1' : 's2', random.nextInt(4) > 0);
            case 1:
              await d.setChoreDone(ch.id, date, random.nextBool());
            default:
              await d.swapForDay(ch.id, date, random.nextBool() ? dana : null);
          }
        case 4:
          await d.addList(title: 'List ${random.nextInt(99)}', kind: ListKind.shopping);
        case 5:
        case 6:
          final lists = d.lists;
          if (lists.isEmpty) return;
          final l = lists[random.nextInt(lists.length)];
          if (l.items.isEmpty || random.nextInt(3) == 0) {
            await d.addItem(l.list.id, text: 'Item ${random.nextInt(99)}');
          } else {
            final item = l.items[random.nextInt(l.items.length)];
            switch (random.nextInt(3)) {
              case 0:
                await d.setItemChecked(item.id, !item.checked);
              case 1:
                await d.removeItem(item.id);
              default:
                await d.updateItem(item.id, {'qty': '${random.nextInt(5)}'});
            }
          }
        case 7:
          final lists = d.lists;
          if (lists.isEmpty) return;
          final l = lists[random.nextInt(lists.length)];
          if (random.nextBool()) {
            await d.updateList(l.list.id, {'audience': random.nextBool() ? Audience.parents : Audience.everyone});
          } else {
            await d.deleteList(l.list.id);
            if (random.nextBool()) await d.restore(RecordType.list, l.list.id);
          }
        case 8:
          await d.adjustPoints(leo, random.nextInt(5) - 2, 'Bonus');
        case 9:
          await d.updateFamily({'oversight.$leo': {'parentsSeePrivate': random.nextBool()}});
        case 10:
          await d.addCategory(name: 'Category ${random.nextInt(99)}');
        case 11:
          // A change the device has no business making, signed anyway.
          forged.add(await forge(
            d.keys,
            counter: forgedCounter++,
            millis: c.now,
            type: RecordType.adjustment,
            rid: 'forged$forgedCounter',
            fields: {'member': leo, 'delta': 50, 'reason': 'Forged', 'by': leo},
            actor: leo,
          ));
        case 16:
          // Photos: a record of up to 40 KB that a member's picture names; the kid's own when
          // allowed, else refused.
          if (random.nextBool()) {
            await d.setPhoto(kid ? leo : (random.nextBool() ? leo : dana), photo);
          } else {
            await d.setPicture(leo, random.nextBool() ? Picture.pack[random.nextInt(8)] : Picture.initial);
          }
        case 17:
          final setting = random.nextBool() ? OversightSetting.rewardsNeedOk : OversightSetting.ownPicture;
          await d.updateFamily({'oversight.$leo.$setting': random.nextBool()});
        case 18:
          // Asking for a reward, approved at once when Leo's parents turned off "needs my OK".
          final r = await d.requestReward(reward, member: leo);
          if (!kid && random.nextBool()) await d.decideRedemption(r, approve: random.nextBool());
        case 19:
          await d.updateMember(sitter, {'until': '2026-03-${10 + random.nextInt(18)}'});
        default:
          final lists = d.lists;
          if (lists.isEmpty) return;
          await d.updateList(lists.first.list.id, {'title': 'Title ${random.nextInt(99)}'});
      }
    } on PermissionDenied {
      // Not theirs to make.
    } on InvalidInput {
      // Gone or not allowed by now.
    }
  }

  // Recovery: Dana's words, the hub's key, phones they let in, a reused proof, keys replaced
  // (one phone kept, one not), and a phone signing with the old words clocked before.
  final words = await RecoveryKey.fromSeed(List.generate(32, (i) => i + seed));
  final server = await RecoveryKey.generate();
  final recovered = <Den>[];
  Future<Change> recoverWith(RecoveryKey key, RecoveryKind kind, {RecoveryProof? reuse, int? millis}) async {
    clock.advance(const Duration(seconds: 2));
    final phoneKeys = await DeviceKeys.generate();
    final phone = await Den.open(storage: MemoryStorage(), keys: phoneKeys, now: () => millis ?? clock.now);
    final proof = reuse ??
        await key.prove(
          family: a.familyId!,
          kind: kind,
          member: dana,
          devicePubkey: phoneKeys.pubkey,
          expires: (millis ?? clock.now) + 600000,
        );
    await phone.requestRecovery(
      familyId: a.familyId!,
      founderPubkey: a.founderPubkey!,
      deviceName: 'Recovered',
      kind: DeviceKind.phone,
      proof: proof,
    );
    final change = phone.changesSince({}).single;
    forged.add(change);
    await a.ingest([change]);
    recovered.add(phone);
    return change;
  }

  late Change keptPhone;
  late int wordsReplacedAt;
  for (var round = 0; round < 160; round++) {
    switch (round) {
      case 20:
        await a.setRecoveryKey(dana, words.publicKey);
      case 40:
        keptPhone = await recoverWith(words, RecoveryKind.words);
        // The same proof again, from another phone: its nonce is used.
        await recoverWith(words, RecoveryKind.words, reuse: RecoveryProof.parse(keptPhone.fields['recovery']));
      case 60:
        await a.setServerRecoveryKey(server.publicKey);
      case 70:
        await recoverWith(server, RecoveryKind.hub);
      case 90:
        // New words, naming the phone the old ones let in.
        clock.advance(const Duration(minutes: 1));
        wordsReplacedAt = clock.now;
        await a.setRecoveryKey(dana, (await RecoveryKey.generate()).publicKey);
      case 100:
        // Old words, clocked before they were replaced: counts for nothing.
        await recoverWith(words, RecoveryKind.words, millis: wordsReplacedAt - 30000);
        // Server help off, knowing of no phone it let in.
        clock.advance(const Duration(minutes: 1));
        await a.setServerRecoveryKey(null);
    }
    // The kid's tablet less often: most of what it tries isn't allowed.
    await op(random.nextInt(7) == 0 ? 2 : const [0, 1, 3][random.nextInt(3)]);
    if (random.nextInt(4) == 0) {
      final x = random.nextInt(devices.length), y = random.nextInt(devices.length);
      if (x != y) await exchange(devices[x], devices[y]);
    }
  }
  // The tablet is lost: a parent removes it, and it keeps signing, some with clocks from before.
  await sync(t, a);
  final before = {
    for (final d in devices)
      for (final c in d.changesSince({})) c.id: c,
    for (final c in forged) c.id: c,
  }.values.toList();
  clock.advance(const Duration(minutes: 5));
  final revokedAt = clock.now;
  await a.revokeDevice(t.deviceId);
  final last = t.changesSince({}).where((c) => c.device == t.deviceId).map((c) => c.counter).fold(0, max);
  for (var i = 1; i <= 3; i++) {
    forged.add(await forge(
      t.keys,
      counter: last + i,
      millis: revokedAt - i * 60000,
      type: RecordType.category,
      rid: 'backdated$i',
      fields: {'name': 'Backdated $i'},
      actor: leo,
    ));
  }
  for (var round = 0; round < 40; round++) {
    await op(const [0, 1, 3][random.nextInt(3)]);
    if (random.nextInt(4) == 0) await exchange(a, b);
  }
  forged.add(await forge(
    t.keys,
    counter: forgedCounter++,
    millis: clockT.now,
    type: RecordType.photo,
    rid: 'forgedphoto',
    fields: {'member': dana, 'mime': 'image/jpeg', 'data': base64Encode(photo)},
    actor: leo,
  ));
  final pool = {
    for (final d in devices)
      for (final c in d.changesSince({})) c.id: c,
    for (final c in forged) c.id: c,
  }.values.toList();
  return (TrustRoot(familyId: a.familyId, founderPubkey: a.founderPubkey), pool, before);
}

/// Everything a materializer holds, as text: the log's order, every record as stored (and the
/// order the store keeps them in), what didn't count and why, how each valid change applied,
/// and the revocation cutoffs.
String stateOf(Materializer m) => canonicalJson({
      'log': [for (final c in m.log) c.id],
      'order': [for (final e in m.store.all) '${e.type}/${e.space}/${e.id}'],
      'records': [
        for (final e in m.store.all)
          [
            e.type, e.space, e.id, '${e.created}', e.createdBy, e.createdDevice, '${e.updated}', e.updatedBy,
            e.fields, {for (final t in e.times.entries) t.key: '${t.value}'},
          ],
      ],
      'rejected': m.rejected,
      // Read before the history, which a restored snapshot reads only when asked.
      'family': [for (final a in m.appliedToFamily) [a.change.id, a.before, a.absent.toList()..sort()]],
      'applied': [
        for (final a in m.applied) [a.change.id, a.created, a.verb, a.title, a.before, a.absent.toList()..sort()],
      ],
      'cutoffs': {
        for (final e in m.validator.cutoffs.entries) e.key: [for (final k in e.value) [k.after, '${k.at}']],
      },
      'retired': m.validator.retiredRecoveryKeys.toJson(),
    });

/// What [Den.open] does with a snapshot: restore it over everything stored, then add the rest.
Materializer reopen(TrustRoot root, String snapshot, List<Change> stored) {
  final m = Materializer(() => root);
  final header = SnapshotHeader.parse(snapshot);
  final rest = header == null ? null : m.restore(header, stored, root: root);
  m.add(rest ?? stored);
  return m;
}

Future<String> snapshotOf(Materializer m, TrustRoot root, int windowFrom) =>
    m.capture(root: root, windowFrom: windowFrom, digest: const [0]).encode(breathe: () async {});

void main() {
  for (final seed in [11, 12, 13]) {
    group('pool $seed', () {
      late TrustRoot root;
      late List<Change> pool, beforeRevocation;
      late String expected;
      late List<int> clocks;

      setUpAll(() async {
        (root, pool, beforeRevocation) = await buildPool(seed);
        final reference = Materializer(() => root)..add(pool);
        reference.replay();
        expected = stateOf(reference);
        clocks = [for (final c in pool) c.hlc.millis]..sort();
        expect(reference.rejected, isNotEmpty, reason: 'the pool has changes that don\'t count');
        expect(reference.validator.cutoffs, isNotEmpty, reason: 'the pool has a revocation with a cutoff');
        expect(reference.store.liveOfType(RecordType.photo), isNotEmpty, reason: 'the pool has photos');
        expect(reference.validator.retiredRecoveryKeys.isEmpty, isFalse, reason: 'and replaced recovery keys');
        expect(reference.rejected.values.where((r) => r.contains('replaced')), isNotEmpty);
        expect(reference.rejected.values.where((r) => r.contains('already used')), isNotEmpty);
        expect(pool.where((c) => c.type == RecordType.redemption), isNotEmpty, reason: 'and rewards asked for');
      });

      test('adding changes in any order and any batches gives what a full replay gives', () {
        final random = Random(seed * 100);
        for (var trial = 0; trial < 40; trial++) {
          final m = Materializer(() => root);
          final order = [...pool]..shuffle(random);
          var i = 0;
          while (i < order.length) {
            final n = 1 + random.nextInt(random.nextInt(5) == 0 ? 40 : 4);
            m.add(order.sublist(i, min(i + n, order.length)));
            i += n;
          }
          expect(stateOf(m), expected, reason: 'trial $trial');
          expect(m.fullReplays, lessThan(order.length ~/ 2), reason: 'most late changes rewind, not replay');
        }
      });

      test('with no revocation or replaced recovery key to decide, a late change only ever rewinds', () {
        final random = Random(seed * 17);
        final plain = [for (final c in beforeRevocation) if (!setsRecoveryKey(c)) c];
        final reference = Materializer(() => root)..add(plain);
        reference.replay();
        final want = stateOf(reference);
        for (var trial = 0; trial < 20; trial++) {
          final m = Materializer(() => root);
          final order = [...plain]..shuffle(random);
          var i = 0;
          while (i < order.length) {
            final n = 1 + random.nextInt(3);
            m.add(order.sublist(i, min(i + n, order.length)));
            i += n;
          }
          expect(stateOf(m), want, reason: 'trial $trial');
          expect(m.fullReplays, 0);
          expect(m.replays, greaterThan(0));
        }
      });

      test('a snapshot plus the changes after it gives what a full replay gives', () async {
        final random = Random(seed * 1000);
        for (var trial = 0; trial < 40; trial++) {
          final m = Materializer(() => root);
          final order = [...pool]..shuffle(random);
          final cut = random.nextInt(order.length);
          var i = 0;
          while (i < cut) {
            final n = 1 + random.nextInt(4);
            m.add(order.sublist(i, min(i + n, cut)));
            i += n;
          }
          // A window from everything to nothing, through the middle of the family's history.
          final windowFrom = switch (random.nextInt(4)) {
            0 => 0,
            1 => clocks.last + 1,
            _ => clocks[random.nextInt(clocks.length)],
          };
          final text = await snapshotOf(m, root, windowFrom);
          // Some changes reached storage after the snapshot was written; the rest arrive later.
          final stored = cut + random.nextInt(order.length - cut + 1);
          final reopened = reopen(root, text, order.sublist(0, stored));
          if (random.nextBool()) reopened.applied; // History read early, or only at the end.
          i = stored;
          while (i < order.length) {
            final n = 1 + random.nextInt(6);
            reopened.add(order.sublist(i, min(i + n, order.length)));
            i += n;
          }
          expect(stateOf(reopened), expected, reason: 'trial $trial (cut $cut, stored $stored, window from $windowFrom)');
        }
      });

      test('a snapshot of everything restores everything, the validator\'s cutoffs and replaced keys included', () async {
        final m = Materializer(() => root)..add(pool);
        for (final windowFrom in [0, clocks[clocks.length ~/ 2], clocks.last + 1]) {
          final reopened = reopen(root, await snapshotOf(m, root, windowFrom), pool);
          expect(reopened.fullReplays, 0, reason: 'nothing to replay');
          expect(stateOf(reopened), expected);
        }
      });

      test('a snapshot of a snapshot keeps the history it never read', () async {
        final random = Random(seed * 7);
        final order = [...pool]..shuffle(random);
        final m = Materializer(() => root)..add(order.sublist(0, order.length ~/ 2));
        final middle = clocks[clocks.length ~/ 2];
        final first = reopen(root, await snapshotOf(m, root, middle), order.sublist(0, order.length ~/ 2));
        first.add(order.sublist(order.length ~/ 2, order.length * 3 ~/ 4));
        final second = reopen(root, await snapshotOf(first, root, clocks[clocks.length * 3 ~/ 4]), order.sublist(0, order.length * 3 ~/ 4));
        second.add(order.sublist(order.length * 3 ~/ 4));
        expect(stateOf(second), expected);
      });

      test('removing changes and adding them again gives what a full replay gives', () {
        final random = Random(seed * 31);
        for (final (label, changes) in [('everything', pool), ('before the revocation', beforeRevocation)]) {
          final reference = Materializer(() => root)..add(changes);
          reference.replay();
          final want = stateOf(reference);
          for (var trial = 0; trial < 20; trial++) {
            final m = Materializer(() => root)..add(changes);
            final drop = [for (final c in changes) if (random.nextInt(trial.isEven ? 8 : 40) == 0) c];
            m.remove([for (final c in drop) c.id]);
            final without = Materializer(() => root)..add([for (final c in changes) if (!drop.contains(c)) c]);
            without.replay();
            expect(stateOf(m), stateOf(without), reason: '$label, trial $trial, after removing');
            m.add(drop..shuffle(random));
            expect(stateOf(m), want, reason: '$label, trial $trial, after adding them back');
          }
        }
      });

      test('a snapshot that doesn\'t fit is ignored and the log replayed', () async {
        final m = Materializer(() => root)..add(pool);
        final text = await snapshotOf(m, root, clocks[clocks.length ~/ 2]);
        // Another family's, a format from elsewhere, damage, and a change it covers gone missing.
        final other = Materializer(() => TrustRoot(familyId: 'other', founderPubkey: root.founderPubkey));
        expect(other.restore(SnapshotHeader.parse(text)!, pool, root: TrustRoot(familyId: 'other', founderPubkey: root.founderPubkey)), isNull);
        expect(SnapshotHeader.parse(text.replaceFirst('"v":$snapshotFormat', '"v":${snapshotFormat + 1}')), isNull);
        expect(SnapshotHeader.parse('not a snapshot'), isNull);
        final damaged = text.replaceFirst('"records":[[', '"records":[["broken",');
        expect(stateOf(reopen(root, damaged, pool)), expected);
        expect(stateOf(reopen(root, text, pool.sublist(1))), stateOf(Materializer(() => root)..add(pool.sublist(1))..replay()));
      });
    });
  }
}
