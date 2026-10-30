import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:den_core/den_core.dart';
import 'package:den_core/src/groups.dart' show GroupStarts, closesWindow, deviceOutOfGroup, homeAt;
import 'package:den_core/src/materializer.dart';
import 'package:den_core/src/recovery.dart';
import 'package:den_core/src/snapshot.dart';
import 'package:den_core/src/validity.dart';
import 'package:test/test.dart';

import 'group_support.dart';
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
          final leg = random.nextBool() ? 'to' : 'from';
          final driver = [dana, priya, null][random.nextInt(3)];
          if (e.rrule != null && occ.isNotEmpty && random.nextBool()) {
            final o = occ[random.nextInt(occ.length)];
            switch (random.nextInt(5)) {
              case 0:
                await d.updateEvent(e.id, {'title': 'Moved ${random.nextInt(9)}'}, scope: EditScope.one, occurrence: o.seriesStart);
              case 1:
                await d.claimRide(e.id, occurrence: o.seriesStart, leg: 'to', driver: random.nextBool() ? dana : priya);
              case 2:
                // A leg each, one at a time: `patch.drivers.<leg>`.
                await d.claimRide(e.id, occurrence: o.seriesStart, leg: leg, driver: driver);
              case 3:
                // A version that knows only `rides`: the occurrence's whole list.
                forged.add(await forge(
                  d.keys,
                  counter: forgedCounter++,
                  millis: c.now,
                  type: RecordType.eventException,
                  rid: '${e.id}@${o.seriesStart}',
                  space: e.space,
                  fields: {
                    'event': e.id,
                    'occurrence': o.seriesStart,
                    'patch.rides': [
                      {'leg': leg, 'driver': driver},
                    ],
                  },
                  actor: d.actor?.id,
                ));
              default:
                await d.deleteEvent(e.id, scope: EditScope.one, occurrence: o.seriesStart);
            }
          } else if (random.nextInt(4) == 0) {
            await d.deleteEvent(e.id);
          } else {
            switch (random.nextInt(4)) {
              case 0:
                await d.claimRide(e.id, occurrence: e.start, leg: leg, driver: driver);
              case 1:
                await d.updateEvent(e.id, {
                  'rides': [if (random.nextBool()) Ride('to', driver), if (random.nextBool()) Ride('from', driver)],
                });
              case 2:
                forged.add(await forge(
                  d.keys,
                  counter: forgedCounter++,
                  millis: c.now,
                  type: RecordType.event,
                  rid: e.id,
                  space: e.space,
                  fields: {
                    'rides': [
                      {'leg': leg, 'driver': driver},
                    ],
                  },
                  actor: d.actor?.id,
                ));
              default:
                await d.updateEvent(e.id, {'title': 'Renamed ${random.nextInt(99)}', 'location': 'Room ${random.nextInt(5)}'});
            }
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
  // Priya's phone, not updated yet, takes the drive home the old way, after everything else.
  final latest = clocks.map((c) => c.now).reduce(max) + 60000;
  for (final e in b.events) {
    forged.add(await forge(
      b.keys,
      counter: forgedCounter++,
      millis: latest,
      type: RecordType.event,
      rid: e.id,
      space: e.space,
      fields: {
        'rides': [
          {'leg': 'from', 'driver': priya},
        ],
      },
      actor: priya,
    ));
  }
  final pool = {
    for (final d in devices)
      for (final c in d.changesSince({})) c.id: c,
    for (final c in forged) c.id: c,
  }.values.toList();
  return (TrustRoot(familyId: a.familyId, founderPubkey: a.founderPubkey), pool, before);
}

/// A family's log with what makes revocation cutoffs hard: a stolen phone answering its removal
/// with removals of its own clocked before it (of its remover's other device, naming that
/// device's genesis record, and of another, naming less than its request to join), a device it
/// lets in on the quiet, and a removal clocked after its own; two parents' devices removing
/// each other while out of touch; and a chain, where whether one removal counts decides
/// whether the next does, one naming a low cutoff a parent's device may name.
Future<(TrustRoot, List<Change>, List<Change>)> buildRevocationPool(int seed) async {
  final random = Random(seed);
  final clock = TestClock.at(DateTime.utc(2026, 5, 1, 15));
  final a = await foundFamily(clock);
  final dana = a.actor!.id;
  final priya = await a.addMember(name: 'Priya', role: Role.parent);
  final leo = await a.addMember(name: 'Leo', role: Role.kid, grants: {Grant.events, Grant.lists});
  clock.advance(const Duration(minutes: 1));
  final b = await joinDevice(a, clock, member: priya, name: 'Priya phone', kind: DeviceKind.phone);
  final c = await joinDevice(a, clock, member: dana, name: 'Dana laptop', kind: DeviceKind.desktop);
  final d = await joinDevice(a, clock, member: priya, name: 'Priya tablet');
  final h = await joinDevice(a, clock, mode: DeviceMode.hub, name: 'Hub', kind: DeviceKind.hub);
  await exchange(a, b);
  // Leo's tablet is let in by Priya's phone, so a cutoff on that phone could reach it.
  final t = await joinDevice(b, clock, member: leo, name: 'Leo tablet');
  final devices = [a, b, c, d, t, h];
  for (final x in devices) {
    await exchange(x, h);
  }
  for (final x in devices) {
    await exchange(h, x);
  }
  final forged = <Change>[];

  Future<void> op(Den x) async {
    clock.advance(Duration(seconds: 1 + random.nextInt(300)));
    try {
      switch (random.nextInt(5)) {
        case 0:
          await x.addEvent(title: 'Event ${random.nextInt(99)}', start: clock.now, end: clock.now + 3600000);
        case 1:
          await x.addCategory(name: 'Category ${random.nextInt(99)}');
        case 2:
          final events = x.events;
          if (events.isNotEmpty) await x.updateEvent(events[random.nextInt(events.length)].id, {'location': 'Room ${random.nextInt(9)}'});
        case 3:
          await x.addList(title: 'List ${random.nextInt(99)}', kind: ListKind.checklist);
        default:
          final lists = x.lists;
          if (lists.isNotEmpty) await x.addItem(lists[random.nextInt(lists.length)].list.id, text: 'Item ${random.nextInt(99)}');
      }
    } on PermissionDenied {
      // Not theirs to make, or removed by now.
    } on InvalidInput {
      // Gone by now.
    }
  }

  Future<void> rounds(int n, List<Den> who) async {
    for (var i = 0; i < n; i++) {
      await op(who[random.nextInt(who.length)]);
      if (random.nextInt(3) == 0) await exchange(who[random.nextInt(who.length)], h);
    }
  }

  int last(Den x) => x.changesSince(const {}).where((ch) => ch.device == x.deviceId).map((ch) => ch.counter).fold(0, max);
  Future<Change> removal(Den by, String device, {required int counter, required int millis, required int after, required String actor}) =>
      forge(by.keys, counter: counter, millis: millis, type: RecordType.device, rid: device, actor: actor, fields: {'revoked': true, 'revokedAfter': after});

  await rounds(60, devices);
  for (final x in devices) {
    await exchange(x, h);
  }
  final before = {
    for (final x in devices)
      for (final ch in x.changesSince(const {})) ch.id: ch,
  }.values.toList();

  // Priya's phone is stolen, with some of its changes still unsent. Dana's laptop removes it.
  await rounds(4, [b]);
  await exchange(h, c);
  clock.advance(Duration(minutes: 1 + random.nextInt(30)));
  final removedAt = clock.now;
  await c.revokeDevice(b.deviceId);
  await exchange(c, h);
  // The thief answers, with Priya's phone's key: a removal of Dana's phone clocked just before,
  // naming its genesis record (allowed, and it would erase everything Dana's phone did since);
  // one of Priya's tablet naming less than its request to join (refused); a device let in on
  // the quiet, and what it writes; and a removal of the laptop clocked after its own removal.
  var n = last(b) + 1;
  forged.add(await removal(b, a.deviceId, counter: n++, millis: removedAt - 1 - random.nextInt(60000), after: 3, actor: priya));
  forged.add(await removal(b, d.deviceId, counter: n++, millis: removedAt - 2 - random.nextInt(60000), after: 0, actor: priya));
  final z = await openDen(TestClock(removedAt - 120000));
  await z.requestJoin(familyId: a.familyId!, founderPubkey: a.founderPubkey!, deviceName: 'Quiet', kind: DeviceKind.phone);
  forged.addAll(z.changesSince(const {}));
  forged.add(await forge(b.keys, counter: n++, millis: removedAt - 60000, type: RecordType.device, rid: z.deviceId, actor: priya, fields: {
    'approved': true,
    'approvedBy': priya,
    'member': priya,
    'mode': 'personal',
  }));
  forged.add(await forge(z.keys, counter: 2, millis: removedAt - 30000, type: RecordType.category, rid: 'quiet', actor: priya, fields: {'name': 'Quiet'}));
  forged.add(await removal(b, c.deviceId, counter: n++, millis: removedAt + 1 + random.nextInt(60000), after: 1, actor: priya));

  // Dana's phone and Priya's tablet remove each other while out of touch, either first.
  await rounds(6, [a, c, d, t]);
  clock.advance(const Duration(minutes: 5));
  final first = random.nextBool() ? a : d, second = identical(first, a) ? d : a;
  await first.revokeDevice(second.deviceId);
  clock.advance(Duration(seconds: 1 + random.nextInt(120)));
  await second.revokeDevice(first.deviceId);
  await exchange(first, h);
  await exchange(second, h);

  // A chain: Dana's phone removes Leo's tablet, which counts only if neither the thief's removal
  // of Dana's phone nor the race above does; Dana's laptop names a low cutoff for the tablet,
  // which a parent's device may.
  // The laptop also names less than Priya's tablet's request to join: refused. (Each device
  // takes back what is signed with its key here, so it never numbers a change of its own alike.)
  await rounds(6, [c, t]);
  await exchange(h, a);
  clock.advance(const Duration(minutes: 3));
  final chain = await removal(a, t.deviceId, counter: last(a) + 1, millis: clock.now, after: last(t), actor: dana);
  await a.ingest([chain]);
  clock.advance(const Duration(minutes: 3));
  final low = await removal(c, t.deviceId, counter: last(c) + 1, millis: clock.now, after: 1 + random.nextInt(max(1, last(t))), actor: dana);
  await c.ingest([low]);
  final refused = await removal(c, d.deviceId, counter: last(c) + 1, millis: clock.now + 1000, after: 0, actor: dana);
  await c.ingest([refused]);
  forged.addAll([chain, low, refused]);
  await rounds(20, [a, c, d, h]);
  final pool = {
    for (final x in devices)
      for (final ch in x.changesSince(const {})) ch.id: ch,
    for (final ch in forged) ch.id: ch,
  }.values.toList();
  return (TrustRoot(familyId: a.familyId, founderPubkey: a.founderPubkey), pool, before);
}

/// A group of families' log (groups.dart) with what makes its scoped rules hard to replay: two
/// families' devices editing at once, out of touch with each other; a kid whose edits count only
/// after their own parent's grant; another family's parent, the other family's hub and a kid
/// overreaching; an invited family's window (a second key for its first parent, used before or
/// after the first, which counts only while the window is open); "That wasn't them" by the
/// inviting family; a family leaving while one of its devices keeps writing, unaware; the
/// inviting family turning on the invited one once it is in (the review's R1-R10, now or dated
/// inside its window, each voided by its "we're in"); and two "we're in" for one family, the
/// first of which wins (the known limit).
Future<(TrustRoot, List<Change>, List<Change>)> buildGroupPool(int seed) async {
  final random = Random(seed);
  final clock = TestClock.at(DateTime.utc(2026, 6, 1, 15));
  final f = await bothFamilies(clock);
  final people = {f.alex: f.gAlex, f.priya: f.gPriya, f.leo: f.gLeo, f.dana: f.gDana, f.mia: f.gMia};
  final phones = [f.alex, f.priya, f.leo, f.dana, f.mia];
  final forged = <Change>[];
  var forgedCounter = 7000;
  final start = DateTime.utc(2026, 6, 6, 15).millisecondsSinceEpoch;

  Future<void> op(Den x) async {
    clock.advance(Duration(seconds: 1 + random.nextInt(300)));
    final me = people[x];
    final drivers = [f.gAlex, f.gPriya, f.gDana, f.gLeo, null];
    try {
      switch (random.nextInt(12)) {
        case 0:
          await x.addEvent(
            title: 'Game ${random.nextInt(99)}',
            start: start + random.nextInt(9) * 86400000,
            end: start + random.nextInt(9) * 86400000 + 86400000,
            rides: const [Ride('to', null), Ride('from', null)],
          );
        case 1:
        case 2:
          final events = x.events;
          if (events.isEmpty) return;
          final e = events[random.nextInt(events.length)];
          await x.claimRide(e.id, occurrence: e.start, leg: random.nextBool() ? 'to' : 'from', driver: drivers[random.nextInt(drivers.length)]);
        case 3:
          final events = x.events;
          if (events.isNotEmpty) await x.updateEvent(events[random.nextInt(events.length)].id, {'location': 'Field ${random.nextInt(9)}'});
        case 4:
          await x.addList(title: 'List ${random.nextInt(99)}', kind: ListKind.packing);
        case 5:
          final lists = x.lists;
          if (lists.isNotEmpty) await x.addItem(lists[random.nextInt(lists.length)].list.id, text: 'Item ${random.nextInt(99)}');
        case 6:
        case 7:
          final items = [for (final l in x.lists) ...l.items];
          if (items.isNotEmpty) await x.setItemChecked(items[random.nextInt(items.length)].id, random.nextBool());
        case 8:
          final items = [for (final l in x.lists) ...l.items];
          if (items.isNotEmpty) await x.updateItem(items[random.nextInt(items.length)].id, {'text': 'Renamed ${random.nextInt(99)}'});
        case 9:
          // A hub acting for one of its family's people, through a connection.
          final hub = random.nextBool() ? f.kHub : f.sHub;
          final who = hub == f.kHub ? f.gPriya : f.gDana;
          hub.actAs(who, via: 'Claude');
          try {
            await hub.addEvent(title: 'From Claude ${random.nextInt(99)}', start: start, end: start + 3600000);
          } finally {
            hub.actAs(null);
          }
        case 10:
          // Overreach, signed past the engine's checks: refused wherever it lands.
          final which = random.nextInt(4);
          forged.add(await switch (which) {
            0 => forge(f.dana.keys, counter: forgedCounter++, millis: clock.now, type: RecordType.member, rid: f.gLeo, fields: {'grants': ['events']}, actor: f.gDana),
            1 => forge(f.sHub.keys, counter: forgedCounter++, millis: clock.now, type: RecordType.list, rid: newId(), fields: {'title': 'For Alex', '_via': 'Claude'}, actor: f.gAlex),
            2 => forge(f.leo.keys, counter: forgedCounter++, millis: clock.now, type: RecordType.list, rid: newId(), space: Space.parents, fields: {'title': 'Parents'}, actor: f.gLeo),
            _ => forge(f.alex.keys, counter: forgedCounter++, millis: clock.now, type: RecordType.member, rid: f.gMia, fields: {'role': 'adult'}, actor: f.gAlex),
          });
        default:
          if (me != null) await x.addCategory(name: 'Category ${random.nextInt(99)}');
      }
    } on PermissionDenied {
      // Not theirs to make (a kid without a grant), or out by now.
    } on InvalidInput {
      // Gone by now, or a kid named to drive.
    }
  }

  Future<void> rounds(int n, List<Den> who) async {
    for (var i = 0; i < n; i++) {
      await op(who[random.nextInt(who.length)]);
      if (random.nextInt(4) == 0) await settle(f);
    }
  }

  final snacks = await f.dana.addList(title: 'Snacks', kind: ListKind.shopping);
  final oranges = await f.dana.addItem(snacks, text: 'Oranges');
  final game = await f.alex.addEvent(title: 'Opening game', start: start, end: start + 3600000, rides: const [Ride('to', null)]);
  await settle(f);
  await rounds(40, phones);
  await settle(f);
  // Overreach of each kind, at random times among the rest: refused wherever it lands.
  // (The Smiths' devices' are cut later, by their leaving, which names their last real changes;
  // the Kotvas hub's stay refused for what they are.)
  for (final which in [0, 1, 2, 3, 4]..shuffle(random)) {
    final millis = clock.now - random.nextInt(3600000);
    forged.add(await switch (which) {
      0 => forge(f.dana.keys, counter: forgedCounter++, millis: millis, type: RecordType.member, rid: f.gLeo, fields: {'grants': ['events']}, actor: f.gDana),
      1 => forge(f.sHub.keys, counter: forgedCounter++, millis: millis, type: RecordType.list, rid: newId(), fields: {'title': 'For Alex', '_via': 'Claude'}, actor: f.gAlex),
      4 => forge(f.kHub.keys, counter: forgedCounter++, millis: millis, type: RecordType.list, rid: newId(), fields: {'title': 'For Dana', '_via': 'Claude'}, actor: f.gDana),
      2 => forge(f.alex.keys, counter: forgedCounter++, millis: millis, type: RecordType.event, rid: game, fields: {'drivers.to': f.gLeo}, actor: f.gAlex),
      _ => forge(f.alex.keys, counter: forgedCounter++, millis: millis, type: RecordType.member, rid: f.gMia, fields: {'role': 'adult'}, actor: f.gAlex),
    });
  }
  final before = {
    for (final x in [...f.kotvasDevices, ...f.smithDevices])
      for (final ch in x.changesSince(const {})) ch.id: ch,
  }.values.toList();

  // Leo's own parent grants him events: his edit clocked just before doesn't count, just after
  // does, whichever arrives first.
  clock.advance(const Duration(minutes: 1));
  final grantAt = clock.now;
  await f.priya.updateMember(f.gLeo, {'grants': [Grant.events]});
  for (final (offset, title) in [(-2000, 'Too early'), (2000, 'Just after')]) {
    forged.add(await forge(f.leo.keys, counter: forgedCounter++, millis: grantAt + offset, type: RecordType.event, rid: game, fields: {'title': title}, actor: f.gLeo));
  }
  await rounds(6, [f.leo, f.alex, f.dana]);
  await settle(f);
  await rounds(6, [f.leo, f.mia]);

  // Alex invites the Lees; Jun joins with the invitation's key, and someone else with the same
  // key, clocked before or after Jun.
  final lees = await f.alex.inviteFamily(familyName: 'Lees', parentName: 'Jun');
  final keyAt = clock.now;
  await exchange(f.alex, f.kHub);
  final jun = await admit(f, lees.parent, f.kHub, name: "Jun's phone");
  final other = await DeviceKeys.generate();
  final at = random.nextBool() ? keyAt + 100 + random.nextInt(800) : clock.now + 500 + random.nextInt(1500);
  final proof = await (await lees.parent.key()).prove(family: f.group, member: lees.member, devicePubkey: other.pubkey, expires: at + 600000);
  forged.add(await forge(other, counter: 1, millis: at, type: RecordType.device, rid: await other.deviceId(), fields: {
    'name': 'Not Jun',
    'kind': 'phone',
    'pubkey': other.pubkey,
    'member': lees.member,
    'mode': 'personal',
    'approved': true,
    'home': lees.home,
    'invite': proof.toJson(),
  }));
  await jun.addList(title: 'Lee snacks');
  await exchange(jun, f.kHub);
  await settle(f);
  // "That wasn't them" before the Lees said they were in: Alex takes the invitation back.
  clock.advance(const Duration(minutes: 2));
  await f.alex.disownInvite(jun.deviceId);
  await settle(f);

  // Dana copies her words in; then the Smiths leave, while Mia's tablet keeps writing, unaware.
  await f.dana.setRecoveryKey(f.gDana, (await RecoveryKey.generate()).publicKey);
  await rounds(8, phones);
  await settle(f);

  // The Kotvases turn on the Smiths, who said they were in long ago (the reviews' R1-R10 and
  // V1-V3): each signed past the engines' checks, now or dated inside the Smiths' window, and
  // refused wherever it lands, since the Smiths' "we're in" shut that window.
  final attacks = groupAttacks[seed] = [];
  Change attack(Change c) {
    attacks.add(c.id);
    return c;
  }

  Change ownJoin(Den d) => d.changesSince(const {}).firstWhere((c) => c.device == d.deviceId && c.type == RecordType.device && c.rid == d.deviceId);
  final invitedAt = f.kHub.home(f.smithHome)!.rec.created.millis;
  final danaJoin = ownJoin(f.dana), hubJoin = ownJoin(f.sHub);
  final inWindow = danaJoin.hlc.millis + 1 + random.nextInt(200);
  final smithsIn = f.dana.changesSince(const {}).firstWhere((c) => c.type == RecordType.home && c.fields.containsKey('heard'));
  groupKept[seed] = [danaJoin.id, hubJoin.id, smithsIn.id];
  Future<Change> alexForges(String type, String rid, Map<String, Object?> fields, {int? millis}) =>
      forge(f.alex.keys, counter: forgedCounter++, millis: millis ?? clock.now, type: type, rid: rid, fields: fields, actor: f.gAlex);
  Future<Change> joinWith(GroupAdmission admission, int millis, {DeviceKeys? keys, DeviceMode? mode}) async {
    final device = keys ?? await DeviceKeys.generate();
    final m = mode ?? admission.mode;
    final member = mode == null ? admission.member : null;
    final proof =
        await (await admission.key()).prove(family: f.group, member: member, mode: m, devicePubkey: device.pubkey, expires: millis + 600000);
    return forge(device, counter: 1, millis: millis, type: RecordType.device, rid: await device.deviceId(), fields: {
      'name': 'Evil',
      'kind': m == DeviceMode.hub ? 'hub' : 'phone',
      'pubkey': device.pubkey,
      'member': member,
      'mode': m.name,
      'approved': true,
      'home': admission.home,
      'invite': proof.toJson(),
    });
  }

  clock.advance(const Duration(minutes: 1));
  for (final millis in [clock.now, inWindow]) {
    // R1: the invitation's key taken back; R2: Dana's phone removed; R3: her words turned off.
    forged.add(attack(await alexForges(RecordType.inviteKey, f.invitation.parent.invite, {'key': null, 'kept': <String>[]}, millis: millis)));
    forged.add(attack(await alexForges(RecordType.device, f.dana.deviceId, {'revoked': true, 'revokedAfter': danaJoin.counter}, millis: millis + 2)));
    forged.add(attack(await alexForges(RecordType.member, f.gDana, {
      'recovery': {'key': null, 'kept': <String>[]},
    }, millis: millis + 3)));
  }
  // R4: the invitation taken back, dated before Dana joined.
  forged.add(attack(await alexForges(RecordType.home, f.smithHome, {'status': 'left'}, millis: invitedAt + 500)));
  // R5 and V1: devices let in with the invitation's own key, dated before Dana's phone, as a
  // phone or as a hub, and with a key made afresh, dated in the window too; R10: a hub now.
  forged.add(attack(await joinWith(f.invitation.parent, danaJoin.hlc.millis - 100)));
  forged.add(attack(await joinWith(f.invitation.parent, danaJoin.hlc.millis - 50, mode: DeviceMode.hub)));
  forged.add(attack(await joinWith(f.invitation.parent, clock.now, mode: DeviceMode.hub)));
  final fresh = await InviteKey.generate();
  forged.add(attack(await alexForges(RecordType.inviteKey, fresh.id, {
    'member': f.gDana,
    'home': f.smithHome,
    'key': fresh.publicKey,
    'by': f.gAlex,
    'device': f.alex.deviceId,
    'expires': invitedAt + 3600000,
  }, millis: invitedAt + 200)));
  forged.add(attack(await joinWith(
      GroupAdmission(group: f.group, founder: f.alex.founderPubkey!, name: 'x', home: f.smithHome, member: f.gDana, mode: DeviceMode.personal,
          invite: fresh.id, seed: await fresh.seed(), expires: invitedAt + 1800000),
      invitedAt + 300)));
  // A device of the Kotvases the Smiths never heard of, approved now but dated in the window,
  // taking the invitation back: it counts, its window power doesn't.
  final laptop = await DeviceKeys.generate();
  final laptopId = await laptop.deviceId();
  forged.add(await forge(laptop, counter: 1, millis: invitedAt + 100, type: RecordType.device, rid: laptopId, fields: {
    'name': 'Laptop',
    'kind': 'desktop',
    'pubkey': laptop.pubkey,
    'mode': 'personal',
    'approved': false,
    'home': f.kotvasHome,
  }));
  forged.add(await alexForges(RecordType.device, laptopId, {'approved': true, 'approvedBy': f.gAlex, 'member': f.gAlex, 'mode': 'personal'},
      millis: invitedAt + 150));
  forged.add(attack(await forge(laptop, counter: 2, millis: inWindow + 10, type: RecordType.home, rid: f.smithHome, actor: f.gAlex,
      fields: {'status': 'left'})));
  // R6b: "Cancel invitation" on Priya's phone, which hadn't heard the Smiths were in.
  forged.add(attack(await forge(f.priya.keys, counter: forgedCounter++, millis: clock.now + 200, type: RecordType.home, rid: f.smithHome,
      actor: f.gPriya, fields: {'status': 'left'})));
  // R8: someone's own space in a group.
  forged.add(attack(await forge(f.priya.keys, counter: forgedCounter++, millis: clock.now + 300, type: RecordType.list, rid: newId(),
      space: Space.member(f.gPriya), actor: f.gPriya, fields: {'title': 'Mine'})));
  // "That wasn't them" more than a day after the Smiths said they were in.
  forged.add(attack(await alexForges(RecordType.home, f.smithHome, {'disowned': true},
      millis: smithsIn.hlc.millis + disownWindow.inMilliseconds + random.nextInt(3600000))));

  // R7: Dana drives the way to the final; once the Smiths leave, Alex may say the whole list
  // again with her on it, but never put her on the other leg.
  final finalGame = await f.alex.addEvent(title: 'Final', start: start, end: start + 3600000, rides: const [Ride('to', null), Ride('from', null)]);
  await settle(f);
  await f.dana.claimRide(finalGame, occurrence: start, leg: 'to', driver: f.gDana);
  await settle(f);
  clock.advance(const Duration(minutes: 5));
  await f.sHub.ingest(await f.dana.leaveGroup(family: f.smith));
  clock.advance(const Duration(seconds: 30));
  forged.add(attack(await alexForges(RecordType.event, finalGame, {'drivers.from': f.gDana})));
  forged.add(await alexForges(RecordType.event, finalGame, {
    'rides': [
      {'leg': 'to', 'driver': f.gDana},
      {'leg': 'from', 'driver': f.gAlex},
    ],
  }, millis: clock.now + 1));
  groupKept[seed]!.add(forged.last.id);
  await f.mia.setItemChecked(oranges, true);
  await rounds(4, [f.mia]);
  await settle(f);
  await rounds(10, [f.alex, f.priya, f.leo]);
  await settle(f);

  // The Parks: Kim's phone lets itself in and says they're in; the Kotvases write another
  // beginning for them with the invitation's key, a device of their own saying the Parks are
  // in just before Kim did. Two "we're in"s: no beginning wins, and the Parks' place ends from
  // their invitation on, in every order (GroupStarts).
  clock.advance(const Duration(minutes: 1));
  final parks = await f.alex.inviteFamily(familyName: 'Parks', parentName: 'Kim');
  await exchange(f.alex, f.kHub);
  final kim = await admit(f, parks.parent, f.kHub, name: "Kim's phone");
  clock.advance(const Duration(seconds: 2));
  await kim.updateHome(active: true, family: null);
  final kimIn = kim.changesSince(const {}).lastWhere((c) => c.type == RecordType.home);
  clock.advance(const Duration(seconds: 1));
  final parkSnacks = await kim.addList(title: 'Park snacks');
  await exchange(kim, f.kHub);
  // The cascade: Kim invites the Ries, whose phone says they're in, and the Tans, whose phone
  // never does. The Parks' place ends; the Ries stand, the Tans end with the Parks.
  clock.advance(const Duration(seconds: 1));
  final ries = await kim.inviteFamily(familyName: 'Ries', parentName: 'Rae');
  final tans = await kim.inviteFamily(familyName: 'Tans', parentName: 'Tam');
  await exchange(kim, f.kHub);
  final rae = await admit(f, ries.parent, f.kHub, name: "Rae's phone");
  final tam = await admit(f, tans.parent, f.kHub, name: "Tam's phone");
  clock.advance(const Duration(seconds: 1));
  await rae.updateHome(active: true, family: null);
  final raeEvent = await rae.addEvent(title: 'Ries barbecue', start: start, end: start + 3600000);
  await exchange(rae, f.kHub);
  await exchange(tam, f.kHub);
  groupKept[seed]!.addAll([
    rae.changesSince(const {}).lastWhere((c) => c.type == RecordType.home).id,
    rae.changesSince(const {}).lastWhere((c) => c.type == RecordType.event && c.rid == raeEvent).id,
    ownJoin(rae).id,
  ]);
  attacks.add(ownJoin(tam).id);
  final evil = await DeviceKeys.generate();
  forged.add(await joinWith(parks.parent, ownJoin(kim).hlc.millis + 1, keys: evil));
  forged.add(attack(await forge(evil, counter: 2, millis: kimIn.hlc.millis - 1, type: RecordType.home, rid: parks.home, actor: parks.member,
      fields: {'status': 'active', 'heard': kimIn.fields['heard']})));
  attacks.add(kimIn.id);
  // From the Parks' invitation on, nothing of theirs counts: their list, Kim's way in and the
  // Kotvases' device stay on record only, as a family's that left (groups.dart, endsJudgedPast).
  attacks.add(kim.changesSince(const {}).firstWhere((c) => c.type == RecordType.list && c.rid == parkSnacks).id);
  groupOnRecord[seed] = [kim.deviceId, await evil.deviceId()];
  groupStanding[seed] = [rae.deviceId];
  // The Ohs: Ann's phone lets itself in and says they're in; within the day, the phone that sent
  // the invitation says that wasn't them, and the Ohs' place ends.
  clock.advance(const Duration(minutes: 1));
  final ohs = await f.alex.inviteFamily(familyName: 'Ohs', parentName: 'Ann');
  await exchange(f.alex, f.kHub);
  final ann = await admit(f, ohs.parent, f.kHub, name: "Ann's phone");
  clock.advance(const Duration(seconds: 2));
  await ann.updateHome(active: true, family: null);
  attacks.add(ann.changesSince(const {}).lastWhere((c) => c.type == RecordType.home).id);
  groupOnRecord[seed]!.add(ann.deviceId);
  await exchange(ann, f.kHub);
  await exchange(f.alex, f.kHub);
  clock.advance(Duration(hours: 1 + random.nextInt(20)));
  await f.alex.disownInvite(ann.deviceId);
  groupKept[seed]!.add(f.alex.changesSince(const {}).lastWhere((c) => c.type == RecordType.home && c.rid == ohs.home).id);
  await rounds(6, [f.alex, f.priya, f.leo]);
  await settle(f, smiths: false);

  final pool = {
    for (final x in [...f.kotvasDevices, ...f.smithDevices, jun, kim, ann, rae, tam])
      for (final ch in x.changesSince(const {})) ch.id: ch,
    for (final ch in forged) ch.id: ch,
  }.values.toList();
  return (TrustRoot(familyId: f.group, founderPubkey: f.alex.founderPubkey), pool, before);
}

/// The group pool's attacks, by seed, and the "we're in"s of the families whose place ended (the
/// Parks', contested, and the Ohs', disowned): each counts for nothing.
final groupAttacks = <int, List<String>>{};

/// What the group pool's attacks leave counting, by seed: the Smiths' beginning, Alex saying a
/// ride list again with a driver on the leg she held, what came before the Parks' first "we're
/// in", the Kotvases' "That wasn't them" for the Ohs, and the Ries' beginning (invited by the
/// Parks, they stand once they said they're in).
final groupKept = <int, List<String>>{};

/// The devices of the families whose place ended (the Parks' and the Ohs'), by seed: on record,
/// counting for nothing.
final groupOnRecord = <int, List<String>>{};

/// Devices of a family invited by one whose place ended, that said it was in: they count.
final groupStanding = <int, List<String>>{};
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
      // In a group: the homes whose place ended, read from the log alone (groups.dart).
      'ended': {for (final e in m.store.endedHomes.entries) e.key: [e.value.at.toString(), e.value.why, e.value.by]},
      // Who drives, as people see it: from per-leg drivers, or a whole list an older version wrote.
      'rides': [
        for (final e in m.store.liveOfType(RecordType.event)) [e.space, e.id, ridesText(Event(e.rec).rides)],
        for (final x in m.store.liveOfType(RecordType.eventException))
          if (m.store.liveAt(x.space, RecordType.event, '${x.fields['event']}') case final e?)
            [x.space, x.id, ridesText(EventException(x.rec).rides(Event(e.rec).rides))],
      ],
    });

String ridesText(List<Ride> rides) => [for (final r in rides) '${r.leg}=${r.driver}'].join(' ');

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
  for (final (name, seed) in [
    for (final s in [11, 12, 13]) ('pool', s),
    for (final s in [21, 22, 23, 24]) ('revocation pool', s),
    for (final s in [31, 32, 33]) ('group pool', s),
  ]) {
    final revocations = name == 'revocation pool';
    final groups = name == 'group pool';
    group('$name $seed', () {
      late TrustRoot root;
      late List<Change> pool, beforeRevocation;
      late String expected;
      late List<int> clocks;

      setUpAll(() async {
        (root, pool, beforeRevocation) =
            await (revocations ? buildRevocationPool(seed) : (groups ? buildGroupPool(seed) : buildPool(seed)));
        final reference = Materializer(() => root)..add(pool);
        reference.replay();
        expected = stateOf(reference);
        clocks = [for (final c in pool) c.hlc.millis]..sort();
        expect(reference.rejected, isNotEmpty, reason: 'the pool has changes that don\'t count');
        expect(reference.validator.cutoffs, isNotEmpty, reason: 'the pool has a revocation with a cutoff');
        if (groups) {
          final reasons = reference.rejected.values;
          expect(reasons.where((r) => r.contains('own parents')), isNotEmpty, reason: 'another family\'s parent overreaching');
          expect(reasons.where((r) => r.contains('its own family\'s people')), isNotEmpty, reason: 'a hub acting for another family');
          expect(reasons.where((r) => r.contains('can\'t drive')), isNotEmpty, reason: 'a kid named to drive');
          expect(reasons.where((r) => r.contains('can\'t add or change events')), isNotEmpty, reason: 'a kid before their grant');
          expect(reasons.where((r) => r.contains('removed')), isNotEmpty, reason: 'a device writing after its family left');
          expect(reference.store.liveOfType(RecordType.event).any((e) => e.fields['title'] == 'Just after'), isTrue);
          expect(reference.validator.retiredRecoveryKeys.isEmpty, isFalse, reason: 'invitation keys taken away');
          final homes = [for (final e in reference.store.ofType(RecordType.home)) Home(e.rec)];
          // The review's attacks (R1-R10) count for nothing; what they aimed at stays.
          for (final id in groupAttacks[seed]!) {
            expect(reference.rejected.containsKey(id), isTrue, reason: 'attack $id');
          }
          for (final id in groupKept[seed]!) {
            expect(reference.rejected[id], isNull, reason: 'kept $id');
          }
          expect(reasons.where((r) => r.contains('said it was in')), isNotEmpty, reason: 'something dated in a window that was shut');
          expect(reasons.where((r) => r.contains('no one\'s own space')), isNotEmpty);
          // Windows shut by their family's own "we're in": the Smiths' and the Ries'. The Parks'
          // two "we're in"s ended their place, and with it the Tans' invitation (they never said
          // they were in); the Kotvases disowned the Ohs within the day.
          expect(reference.validator.retiredRecoveryKeys.closures.map((w) => w.home).toSet(), hasLength(2));
          final ended = reference.starts.ended.values;
          expect(ended.where((e) => e.contested), hasLength(1));
          expect(ended.where((e) => !e.contested && e.disowned != null), hasLength(1));
          expect(ended.where((e) => !e.began), hasLength(1), reason: 'the Tans, invited by the Parks');
          expect(homes.where((h) => h.left), hasLength(2), reason: 'the Smiths and the Lees left (the ended ones read as left in views)');
          expect([for (final e in reference.store.ofType(RecordType.home)) homeAt(reference.store, e.id)!].where((h) => h.left), hasLength(5));
          // The ended families' devices stay on record, counting for nothing; the Ries' count.
          Device? device(String id) => switch (reference.store.at(Space.family, RecordType.device, id)) { final e? => Device(e.rec), null => null };
          for (final id in groupOnRecord[seed]!) {
            expect(device(id), isNotNull, reason: 'on record: $id');
            expect(deviceOutOfGroup(reference.store, device(id)!), isTrue, reason: 'counts for nothing: $id');
          }
          for (final id in groupStanding[seed]!) {
            expect(deviceOutOfGroup(reference.store, device(id)!), isFalse, reason: 'stands: $id');
          }
          return;
        }
        if (revocations) {
          final founder = deviceIdOf(root.founderPubkey!)!;
          final reasons = reference.rejected.values;
          expect(reasons.where((r) => r.contains('request to join')), isNotEmpty, reason: 'a cutoff below a request to join');
          expect(reasons.where((r) => r.contains('removed')), isNotEmpty, reason: 'changes signed after a removal');
          // The stolen phone's removal of Dana's phone, which would cut everything it did since
          // its record, counts for nothing once the laptop's removal of the stolen phone does,
          // and its cutoff with it.
          final contest = pool.firstWhere((c) => c.type == RecordType.device && c.rid == founder && c.fields['revokedAfter'] == 3);
          expect(reference.rejected[contest.id], contains('removed'));
          expect(reference.validator.cutoffs[founder]?.where((k) => k.after == 3) ?? const <Cutoff>[], isEmpty);
          expect(reference.store.liveOfType(RecordType.category).where((e) => e.fields['name'] == 'Quiet'), isEmpty);
          return;
        }
        expect(reference.store.liveOfType(RecordType.photo), isNotEmpty, reason: 'the pool has photos');
        bool perLeg(Change c) => c.fields.keys.any((k) => k.startsWith('drivers.') || k.startsWith('patch.drivers.'));
        expect(pool.where(perLeg), isNotEmpty, reason: 'and ride legs claimed one at a time');
        expect(reference.store.liveOfType(RecordType.event).where((e) => e.fields.containsKey('drivers') && !Event(e.rec).readsDrivers),
            isNotEmpty,
            reason: 'and rides an older version wrote after the drivers');
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

      test('with no revocation, replaced recovery key or closed window to decide, a late change only ever rewinds', () {
        final random = Random(seed * 17);
        // (Nor how an invited family began in a group: its invitation, the phone it let in.)
        final starts = GroupStarts.of([...beforeRevocation]..sort(changeOrder));
        final plain = [
          for (final c in beforeRevocation)
            if (!setsRecoveryKey(c) && !closesWindow(c) && !GroupStarts.isInvitation(c) && starts.windowJoinInto(c) == null) c,
        ];
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
