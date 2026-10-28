/// A synthetic large family for Den's engine benchmarks: six people, two years of daily chores
/// with completions, about 3,000 events with repeats and exceptions, 40 lists and points, all
/// written through the public API so every change is signed and valid. A partner's phone that
/// went offline for the last week made 500 changes the founder hasn't seen.
///
/// Signing is slow in pure Dart (milliseconds a change), so the family is built once and kept as
/// JSON ([BigFamily.toJson]); `benchmark/main.dart` keeps it under `.dart_tool/`.
library;

import 'dart:convert';
import 'dart:math';

import 'package:den_core/den_core.dart';

/// Bumped whenever [buildBigFamily] changes what it writes, so cached families are rebuilt.
const int bigFamilyVersion = 2;

/// A clock the generator and the benchmarks move by hand.
class ManualClock {
  ManualClock(this.now);
  int now;
  int call() => now;
}

/// A [DenStorage] that keeps changes and metadata as JSON text and decodes them on every load,
/// the way IndexedDB hands Den strings on the web.
class JsonStorage implements DenStorage {
  JsonStorage({List<String>? changes, String? meta})
      : _changes = changes ?? [],
        _meta = meta;

  final List<String> _changes;
  String? _meta;

  /// A copy holding the same text, for opening the same device again from scratch.
  JsonStorage copy() => JsonStorage(changes: List.of(_changes), meta: _meta);

  @override
  Future<List<Change>> loadChanges() async =>
      [for (final s in _changes) Change.fromJson((jsonDecode(s) as Map).cast<String, Object?>())];

  @override
  Future<void> appendChanges(List<Change> changes) async {
    for (final c in changes) {
      _changes.add(jsonEncode(c.toJson()));
    }
  }

  @override
  Future<Map<String, Object?>?> loadMeta() async =>
      _meta == null ? null : (jsonDecode(_meta!) as Map).cast<String, Object?>();

  @override
  Future<void> saveMeta(Map<String, Object?> meta) async => _meta = jsonEncode(meta);

  @override
  Future<void> clear() async {
    _changes.clear();
    _meta = null;
  }
}

/// The family as the founder's phone holds it at [now], and what the partner's phone made while
/// it was offline.
class BigFamily {
  BigFamily({
    required this.now,
    required this.founderKeys,
    required this.founderMeta,
    required this.log,
    required this.partnerWeek,
    required this.groceries,
    required this.choreToday,
  });

  /// UTC milliseconds the benchmarks run at: an evening in the family's time zone.
  final int now;
  final Map<String, Object?> founderKeys;
  final Map<String, Object?> founderMeta;

  /// Every change the founder's phone holds, as stored JSON.
  final List<String> log;

  /// 500 changes the partner made in the week it was offline, oldest first.
  final List<String> partnerWeek;

  /// The pinned shopping list.
  final String groceries;

  /// A daily chore scheduled today.
  final String choreToday;

  JsonStorage founderStorage() => JsonStorage(changes: List.of(log), meta: jsonEncode(founderMeta));

  Future<DeviceKeys> keys() => DeviceKeys.fromJson(founderKeys);

  List<Change> partnerChanges() =>
      [for (final s in partnerWeek) Change.fromJson((jsonDecode(s) as Map).cast<String, Object?>())];

  Map<String, Object?> toJson() => {
        'version': bigFamilyVersion,
        'now': now,
        'founderKeys': founderKeys,
        'founderMeta': founderMeta,
        'log': log,
        'partnerWeek': partnerWeek,
        'groceries': groceries,
        'choreToday': choreToday,
      };

  static BigFamily? fromJson(Map<String, Object?> json) {
    if (json['version'] != bigFamilyVersion) return null;
    return BigFamily(
      now: json['now']! as int,
      founderKeys: (json['founderKeys']! as Map).cast<String, Object?>(),
      founderMeta: (json['founderMeta']! as Map).cast<String, Object?>(),
      log: (json['log']! as List).cast<String>(),
      partnerWeek: (json['partnerWeek']! as List).cast<String>(),
      groceries: json['groceries']! as String,
      choreToday: json['choreToday']! as String,
    );
  }
}

const String _zone = 'America/New_York';
const int _day = 86400000;
const int _hour = 3600000;

/// Builds the family. Takes a minute or two on the VM, nearly all of it signing.
Future<BigFamily> buildBigFamily({int seed = 7, void Function(String)? progress}) async {
  final random = Random(seed);
  final end = DateTime.utc(2026, 10, 28, 22).millisecondsSinceEpoch; // 6 PM in New York
  final start = end - 730 * _day;
  final clock = ManualClock(start);
  final founderKeys = await DeviceKeys.generate();
  final storage = JsonStorage();
  final den = await Den.open(storage: storage, keys: founderKeys, now: clock.call);
  await den.createFamily(
    familyName: 'Rivera family',
    timezone: _zone,
    yourName: 'Dana',
    deviceName: 'Dana\'s phone',
    deviceKind: DeviceKind.phone,
  );
  final dana = den.actor!.id;
  final priya = await den.addMember(name: 'Priya', role: Role.parent);
  final sam = await den.addMember(name: 'Sam', role: Role.kid, tier: Tier.teen);
  final leo = await den.addMember(name: 'Leo', role: Role.kid, tier: Tier.big);
  final mia = await den.addMember(name: 'Mia', role: Role.kid, tier: Tier.little);
  final gran = await den.addMember(name: 'Grandma', role: Role.adult, grants: {Grant.events, Grant.lists});
  final people = [dana, priya, sam, leo, mia, gran];
  final kids = [sam, leo, mia];
  for (final c in ['School', 'Sports', 'Work', 'Health', 'Music', 'Birthday']) {
    await den.addCategory(name: c, icon: c.toLowerCase());
  }

  // Priya's phone joins now; it goes offline for the last week.
  final partnerKeys = await DeviceKeys.generate();
  final partnerStorage = JsonStorage();
  final partnerClock = ManualClock(start);
  final joining = await Den.open(storage: partnerStorage, keys: partnerKeys, now: partnerClock.call);
  await joining.requestJoin(
    familyId: den.familyId!,
    founderPubkey: den.founderPubkey!,
    deviceName: 'Priya\'s phone',
    kind: DeviceKind.phone,
    memberId: priya,
  );
  await den.ingest(joining.changesSince(den.versionVector));
  await den.approveDevice(joining.deviceId, member: priya);
  final partnerMeta = await partnerStorage.loadMeta();
  await joining.close();

  final startDate = den.dateOf(start);
  final chores = <String>[
    for (final k in kids)
      await den.addChore(
        title: 'Make bed',
        owner: OwnerMember(k),
        schedule: ChoreSchedule.repeating('FREQ=DAILY', startDate),
        icon: 'bed',
        points: 1,
      ),
    await den.addChore(
      title: 'Dishes',
      owner: OwnerRotation(kids, 'day', startDate),
      schedule: ChoreSchedule.repeating('FREQ=DAILY', startDate),
      icon: 'dishes',
      dueTime: '20:00',
      points: 3,
      steps: const [ChoreStep(id: 'load', text: 'Load', points: 1), ChoreStep(id: 'wipe', text: 'Wipe counters', points: 1)],
    ),
    await den.addChore(
      title: 'Feed the cat',
      owner: const OwnerAnyone(),
      schedule: ChoreSchedule.repeating('FREQ=DAILY', startDate),
      icon: 'pet',
      points: 1,
    ),
    for (final k in [leo, mia])
      await den.addChore(
        title: 'Homework',
        owner: OwnerMember(k),
        schedule: ChoreSchedule.repeating('FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR', startDate),
        icon: 'homework',
        dueTime: '19:00',
        points: 2,
      ),
    await den.addChore(
      title: 'Practice piano',
      owner: OwnerMember(mia),
      schedule: ChoreSchedule.repeating('FREQ=DAILY', startDate),
      icon: 'music',
      points: 1,
    ),
    await den.addChore(
      title: 'Walk the dog',
      owner: OwnerRotation(kids, 'week', startDate),
      schedule: ChoreSchedule.repeating('FREQ=DAILY', startDate),
      icon: 'pet',
      points: 2,
    ),
    await den.addChore(
      title: 'Take out the trash',
      owner: OwnerMember(sam),
      schedule: ChoreSchedule.repeating('FREQ=WEEKLY;BYDAY=TU,FR', startDate),
      icon: 'trash',
      points: 2,
    ),
    await den.addChore(
      title: 'Laundry',
      owner: OwnerRotation([dana, priya], 'week', startDate),
      schedule: ChoreSchedule.repeating('FREQ=WEEKLY;BYDAY=SA', startDate),
      icon: 'laundry',
    ),
  ];

  final rewards = [
    await den.addReward(title: 'Movie night pick', cost: 20, icon: 'film'),
    await den.addReward(title: 'Pizza for dinner', cost: 40, icon: 'pizza'),
    await den.addReward(title: 'Stay up late', cost: 15, icon: 'moon', needsApproval: false),
    await den.addReward(title: 'Game time', cost: 10, icon: 'game'),
  ];
  await den.addGoal(title: 'Summer trip', target: 500, members: kids);

  final groceries = await den.addList(title: 'Groceries', kind: ListKind.shopping, pinned: true);
  final costco = await den.addList(title: 'Costco', kind: ListKind.shopping, pinned: true);
  const foods = [
    'Milk', 'Eggs', 'Bread', 'Butter', 'Apples', 'Bananas', 'Rice', 'Pasta', 'Cheese', 'Yogurt',
    'Chicken', 'Coffee', 'Spinach', 'Carrots', 'Tortillas', 'Beans', 'Oats', 'Tomatoes',
  ];
  var lists = 2;

  // Repeating events: weekly activities, some ending with the school year, with rides.
  final series = <String>[];
  Future<void> addSeries(int at) async {
    final weekday = const ['MO', 'TU', 'WE', 'TH', 'FR', 'SA'][random.nextInt(6)];
    final who = people[random.nextInt(people.length)];
    final kid = kids.contains(who);
    final first = _localDayStart(den, at) + (15 + random.nextInt(5)) * _hour + 30 * 60000 * random.nextInt(2);
    final until = random.nextInt(3) == 0 ? ';UNTIL=${_rruleDate(den.dateOf(at + (90 + random.nextInt(200)) * _day))}' : '';
    series.add(await den.addEvent(
      title: const ['Soccer', 'Piano lesson', 'Swim team', 'Book club', 'Choir', 'Karate', 'Team meeting', 'Art class'][random.nextInt(8)],
      start: first,
      end: first + (1 + random.nextInt(2)) * _hour,
      rrule: 'FREQ=WEEKLY;BYDAY=$weekday$until',
      assignees: [who],
      rides: kid ? const [Ride('to', null), Ride('from', null)] : const [],
      location: 'Community center',
      reminders: const [30],
    ));
  }

  for (var i = 0; i < 12; i++) {
    await addSeries(start);
  }

  Future<void> oneDay(Den d, int dayStart) async {
    final date = d.dateOf(dayStart + 12 * _hour);
    clock.now = dayStart + 7 * _hour;
    // Events: a few one-offs, an occasional new series, an exception on a series.
    final count = 2 + random.nextInt(4);
    for (var i = 0; i < count; i++) {
      final at = dayStart + (7 + random.nextInt(14)) * _hour + random.nextInt(4) * 15 * 60000 + random.nextInt(60) * _day;
      final who = [for (final p in people) if (random.nextInt(4) == 0) p];
      await d.addEvent(
        title: const ['Dentist', 'Playdate', 'Birthday party', 'Parent-teacher', 'Haircut', 'Dinner out', 'Vet', 'Recital'][random.nextInt(8)],
        start: at,
        end: at + (1 + random.nextInt(3)) * _hour,
        assignees: who,
        category: null,
        reminders: random.nextBool() ? const [60] : const [],
        rides: random.nextInt(5) == 0 ? const [Ride('to', null)] : const [],
      );
    }
    if (random.nextInt(14) == 0) await addSeries(dayStart);
    if (random.nextInt(5) < 3 && series.isNotEmpty) {
      final id = series[random.nextInt(series.length)];
      final event = d.event(id);
      if (event != null) {
        final next = d.occurrences(dayStart, dayStart + 14 * _day).where((o) => o.event.id == id).firstOrNull;
        if (next != null) {
          switch (random.nextInt(3)) {
            case 0:
              await d.deleteEvent(id, scope: EditScope.one, occurrence: next.seriesStart);
            case 1:
              if (event.rides.isNotEmpty) {
                await d.claimRide(id, occurrence: next.seriesStart, leg: 'to', driver: random.nextBool() ? dana : priya);
              } else {
                await d.updateEvent(id, {'location': 'Field ${1 + random.nextInt(6)}'}, scope: EditScope.one, occurrence: next.seriesStart);
              }
            default:
              await d.updateEvent(id, {'title': '${event.title} (moved)'}, scope: EditScope.one, occurrence: next.seriesStart);
          }
        }
      }
    }
    if (random.nextInt(3) == 0) {
      final upcoming = d.occurrences(dayStart, dayStart + 30 * _day).where((o) => !o.isRepeating).toList();
      if (upcoming.isNotEmpty) {
        final o = upcoming[random.nextInt(upcoming.length)];
        await d.updateEvent(o.event.id, {'notes': 'Bring ${foods[random.nextInt(foods.length)].toLowerCase()}'});
      }
    }

    // Lists: groceries come and go; new lists now and then.
    clock.now = dayStart + 12 * _hour;
    for (var i = 0; i < 3; i++) {
      await d.addItem(random.nextInt(4) == 0 ? costco : groceries, text: foods[random.nextInt(foods.length)]);
    }
    for (final listId in [groceries, costco]) {
      final open = d.list(listId)!.items.where((i) => !i.checked).toList();
      for (final item in open.take(random.nextInt(4))) {
        await d.setItemChecked(item.id, true);
      }
    }
    if (date.endsWith('-01') || date.endsWith('-15')) {
      for (final listId in [groceries, costco]) {
        await d.clearChecked(listId);
      }
    }
    if (lists < 40 && random.nextInt(16) == 0) {
      final kind = const [ListKind.packing, ListKind.checklist, ListKind.meal][random.nextInt(3)];
      final id = await d.addList(title: '${kind.name} ${++lists}', kind: kind);
      for (var i = 0; i < 8 + random.nextInt(10); i++) {
        await d.addItem(id, text: '${foods[random.nextInt(foods.length)]} $i');
      }
    }

    // Chores, done in the evening by whoever had them.
    clock.now = dayStart + 19 * _hour;
    for (final cd in d.choresOn(date)) {
      if (cd.date != date || !chores.contains(cd.chore.id)) continue;
      final roll = random.nextInt(100);
      if (roll < 2) {
        await d.swapForDay(cd.chore.id, date, kids[random.nextInt(kids.length)]);
      } else if (roll < 87) {
        if (cd.chore.steps.isNotEmpty && random.nextBool()) {
          for (final s in cd.chore.steps) {
            await d.setStep(cd.chore.id, date, s.id, true);
          }
        } else {
          await d.setChoreDone(cd.chore.id, date, true);
        }
      }
    }

    // Points: a bonus now and then, rewards asked for and approved.
    clock.now = dayStart + 20 * _hour;
    if (random.nextInt(6) == 0) {
      await d.adjustPoints(kids[random.nextInt(kids.length)], random.nextBool() ? 2 : -1, 'Helped out');
    }
    if (random.nextInt(9) == 0) {
      final kid = kids[random.nextInt(kids.length)];
      final reward = rewards[random.nextInt(rewards.length)];
      try {
        final r = await d.requestReward(reward, member: kid);
        if (d.points().pending.any((p) => p.id == r)) await d.decideRedemption(r, approve: random.nextInt(5) > 0);
      } on InvalidInput {
        // Not enough stars yet.
      }
    }
  }

  final firstDay = _localDayStart(den, start);
  final offline = 723;
  for (var day = 0; day < offline; day++) {
    await oneDay(den, firstDay + day * _day);
    if (day % 30 == 0) progress?.call('day $day: ${den.changesSince({}).length} changes');
  }

  // The partner's phone as it was when it went offline: everything so far.
  final partnerAt = JsonStorage(
    changes: [for (final c in den.changesSince({})) jsonEncode(c.toJson())],
    meta: jsonEncode(partnerMeta),
  );
  partnerClock.now = clock.now;
  final partner = await Den.open(storage: partnerAt, keys: partnerKeys, now: partnerClock.call);

  // The last week: the founder carries on; the partner's 500 changes stay on its phone.
  for (var day = offline; day < 730; day++) {
    final dayStart = firstDay + day * _day;
    await oneDay(den, dayStart);
    {
      final date = partner.dateOf(dayStart + 12 * _hour);
      var n = 0;
      partnerClock.now = dayStart + 8 * _hour;
      while (n < 500 ~/ 7 + (day == 729 ? 500 % 7 : 0)) {
        partnerClock.now += 60000 + random.nextInt(5 * 60000);
        switch (random.nextInt(4)) {
          case 0:
            await partner.addItem(groceries, text: foods[random.nextInt(foods.length)]);
          case 1:
            final open = partner.list(groceries)!.items.where((i) => !i.checked).toList();
            if (open.isEmpty) continue;
            await partner.setItemChecked(open[random.nextInt(open.length)].id, true);
          case 2:
            final todo = partner.choresOn(date).where((cd) => !cd.done && cd.date == date).toList();
            if (todo.isEmpty) continue;
            await partner.setChoreDone(todo[random.nextInt(todo.length)].chore.id, date, true);
          default:
            final at = dayStart + (24 + random.nextInt(24 * 20)) * _hour;
            await partner.addEvent(title: 'Practice', start: at, end: at + _hour, assignees: [kids[random.nextInt(3)]]);
        }
        n++;
      }
    }
  }
  // Everything the partner signed but its join request, which the founder already holds.
  final week = [
    for (final c in partner.changesSince({}))
      if (c.device == partner.deviceId && c.counter > 1) c,
  ];
  progress?.call('done: ${den.changesSince({}).length} changes, partner ${week.length}');
  clock.now = end;
  final today = den.todayDate();
  final choreToday = den.choresOn(today).firstWhere((cd) => cd.chore.title == 'Feed the cat').chore.id;
  final meta = await storage.loadMeta();
  final family = BigFamily(
    now: end,
    founderKeys: await founderKeys.toJson(),
    founderMeta: meta!,
    log: [for (final c in den.changesSince({})) jsonEncode(c.toJson())],
    partnerWeek: [for (final c in week) jsonEncode(c.toJson())],
    groceries: groceries,
    choreToday: choreToday,
  );
  await partner.close();
  await den.close();
  return family;
}

int _localDayStart(Den den, int utc) => den.dayStart(den.dateOf(utc));

String _rruleDate(String date) => '${date.replaceAll('-', '')}T235959Z';
