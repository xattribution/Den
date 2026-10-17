/// A realistic sample family for screenshots, demos and tests. Pure Dart.
library;

import 'den_core.dart';
import 'src/time.dart';

/// The demo family's time zone.
const String demoTimeZone = 'America/Chicago';

/// Shared-screen sign-ins the demo sets, by member name: PINs, and Zoe's picture pattern
/// (animals as digits 0-8 in [Animal] order).
const Map<String, String> demoSignIns = {
  'Alex': '2468',
  'Priya': '1357',
  'Maya': '1414',
  'Leo': '8080',
  'Zoe': '0123',
};

/// Builds the Carter family on a parent's phone (Alex's) and returns that device's engine.
///
/// [now] is the demo's present moment and becomes the engine's clock: a UTC [DateTime] is taken
/// as that instant, and a local one (`DateTime(2026, 10, 16, 8)`) as that wall-clock time in
/// [demoTimeZone], so "today" doesn't depend on the machine's zone. Without [now] the demo is
/// seeded around the real time and the engine follows the real clock. [storage] must be empty.
///
/// Two parents (Alex, Priya), three kids (Maya 14, Leo 8, Zoe 4) and Grandma Rosa; a kitchen
/// display that the kids check chores off on; this week's school runs, soccer practice with
/// nobody picking up, a dentist visit, a birthday party, dinner at Grandma's, a parents-only
/// dinner, a swim lesson today with no driver, and a beach trip countdown; daily and rotating
/// chores with steps and points, completions through the week, groceries across three stores,
/// a packing list, a meal plan and a dated list; goals, rewards and a pending request.
Future<Den> createDemoFamily({DenStorage? storage, DeviceKeys? keys, DateTime? now}) async {
  const zone = demoTimeZone;
  final fixedNow = now == null
      ? null
      : now.isUtc
          ? now.millisecondsSinceEpoch
          : wallToUtc(zone, DateTime.utc(now.year, now.month, now.day, now.hour, now.minute, now.second));
  final present = fixedNow ?? DateTime.now().toUtc().millisecondsSinceEpoch;
  final today = dateIn(zone, present);
  final weekStart = startOfWeek(today, 0);
  String day(int offset) => addDays(weekStart, offset);
  int at(String date, String time) => dateTimeIn(zone, date, time);

  var seeding = true;
  var cursor = at(day(-14), '19:00');
  int clock() => seeding ? cursor : (fixedNow ?? DateTime.now().toUtc().millisecondsSinceEpoch);
  void moveTo(int millis) {
    if (millis > cursor) cursor = millis;
  }

  final phone = await Den.open(storage: storage ?? MemoryStorage(), keys: keys ?? await DeviceKeys.generate(), now: clock);
  await phone.createFamily(
    familyName: 'Carter family',
    timezone: zone,
    yourName: 'Alex',
    marker: Marker.blue,
    animal: Animal.dog,
    deviceName: 'Alex\'s phone',
    deviceKind: DeviceKind.phone,
  );
  final alex = phone.actor!.id;
  final year = int.parse(today.substring(0, 4));
  final priya = await phone.addMember(name: 'Priya', role: Role.parent, marker: Marker.green, animal: Animal.bird);
  final maya = await phone.addMember(
    name: 'Maya',
    role: Role.kid,
    tier: Tier.teen,
    marker: Marker.orange,
    animal: Animal.horse,
    birthday: '${year - 14}-03-09',
    grants: {Grant.events, Grant.lists},
  );
  final leo = await phone.addMember(
    name: 'Leo',
    role: Role.kid,
    tier: Tier.little,
    marker: Marker.teal,
    animal: Animal.fish,
    birthday: '${year - 8}-07-22',
  );
  final zoe = await phone.addMember(
    name: 'Zoe',
    role: Role.kid,
    tier: Tier.preReader,
    marker: Marker.pink,
    animal: Animal.butterfly,
    birthday: '${year - 4}-11-30',
  );
  await phone.addMember(name: 'Grandma Rosa', role: Role.adult, marker: Marker.plum, animal: Animal.rabbit);
  final names = {alex: 'Alex', priya: 'Priya', maya: 'Maya', leo: 'Leo', zoe: 'Zoe'};
  for (final e in names.entries) {
    await phone.setSignIn(e.key, kind: e.key == zoe ? 'pattern' : 'pin', secret: demoSignIns[e.value]);
  }

  final school = await phone.addCategory(name: 'School', icon: 'school');
  final sports = await phone.addCategory(name: 'Sports', icon: 'sports');
  final health = await phone.addCategory(name: 'Health', icon: 'health');
  final family = await phone.addCategory(name: 'Family', icon: 'family');
  final party = await phone.addCategory(name: 'Birthdays', icon: 'birthday');
  final travel = await phone.addCategory(name: 'Travel', icon: 'travel');

  await phone.addEvent(
    title: 'School drop-off',
    start: at(day(-34), '07:30'),
    end: at(day(-34), '08:00'),
    rrule: 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR',
    assignees: [maya, leo],
    category: school,
    location: 'Oak Grove School',
    rides: [Ride('to', alex)],
  );
  await phone.addEvent(
    title: 'Soccer practice',
    start: at(day(-33), '17:00'),
    end: at(day(-33), '18:30'),
    rrule: 'FREQ=WEEKLY;BYDAY=TU,TH',
    assignees: [leo],
    category: sports,
    location: 'Riverside Park, Field 4',
    reminders: [60],
    rides: [Ride('to', priya), const Ride('from', null)],
  );
  await phone.addEvent(
    title: 'Dentist',
    start: at(day(3), '15:00'),
    end: at(day(3), '16:00'),
    assignees: [zoe, priya],
    category: health,
    location: 'Bright Smiles Dental',
    reminders: [1440, 60],
  );
  await phone.addEvent(
    title: 'Sophie\'s birthday party',
    start: at(day(6), '13:00'),
    end: at(day(6), '15:00'),
    assignees: [leo],
    category: party,
    location: 'Bounce Zone',
    notes: 'Bring the gift from the hall closet.',
    rides: [Ride('to', alex), Ride('from', alex)],
  );
  await phone.addEvent(
    title: 'Dinner at Grandma\'s',
    start: at(day(7), '18:00'),
    end: at(day(7), '20:00'),
    category: family,
    location: 'Grandma Rosa\'s house',
  );
  await phone.addEvent(
    title: 'Anniversary dinner',
    start: at(day(6), '19:30'),
    end: at(day(6), '21:30'),
    assignees: [alex, priya],
    location: 'Luca\'s Trattoria',
    audience: Audience.parents,
  );
  await phone.addEvent(
    title: 'Swim lesson',
    start: at(today, '16:30'),
    end: at(today, '17:15'),
    assignees: [zoe],
    category: sports,
    location: 'YMCA pool',
    reminders: [30],
    rides: const [Ride('to', null)],
  );
  final beachDay = addDays(today, 14);
  final beach = await phone.addEvent(
    title: 'Beach trip',
    start: dayStartIn(zone, beachDay),
    end: dayStartIn(zone, addDays(beachDay, 3)),
    allDay: true,
    category: travel,
    location: 'Gulf Shores',
    countdown: true,
  );

  final daily = ChoreSchedule.repeating('FREQ=DAILY', day(-14));
  final beds = {
    for (final kid in [maya, leo, zoe])
      kid: await phone.addChore(
        title: 'Make bed',
        owner: OwnerMember(kid),
        schedule: daily,
        icon: 'bed',
        dueTime: '09:00',
        points: 1,
      ),
  };
  final dishes = await phone.addChore(
    title: 'Dishes',
    owner: OwnerRotation([maya, leo], 'week', day(-14)),
    schedule: daily,
    icon: 'dishes',
    dueTime: '20:00',
    points: 2,
    steps: const [
      ChoreStep(id: 'clear', text: 'Clear the table', icon: 'dishes'),
      ChoreStep(id: 'load', text: 'Load the dishwasher', icon: 'dishes'),
      ChoreStep(id: 'wipe', text: 'Wipe the counters', icon: 'spray'),
    ],
  );
  final cat = await phone.addChore(
    title: 'Feed the cat',
    owner: OwnerMember(leo),
    schedule: daily,
    icon: 'pet',
    dueTime: '07:30',
    points: 1,
    reminders: [10],
  );
  final kitchen = await phone.addChore(
    title: 'Clean the kitchen',
    owner: OwnerMember(priya),
    schedule: daily,
    icon: 'broom',
    dueTime: '19:30',
    steps: [
      ChoreStep(id: 'sweep', text: 'Sweep the floor', owner: maya, points: 2, icon: 'broom'),
      ChoreStep(id: 'table', text: 'Wipe the table', owner: leo, points: 1, icon: 'spray'),
      ChoreStep(id: 'plant', text: 'Water the plant', owner: zoe, points: 1, icon: 'plant'),
      ChoreStep(id: 'run', text: 'Run the dishwasher', owner: priya, icon: 'dishes'),
    ],
  );
  await phone.addChore(
    title: 'Bring in the mail',
    owner: const OwnerAnyone(),
    schedule: daily,
    icon: 'mail',
    points: 1,
  );
  final trash = await phone.addChore(
    title: 'Take out the trash',
    owner: OwnerMember(maya),
    schedule: ChoreSchedule.repeating('FREQ=WEEKLY;BYDAY=TH', day(-14)),
    icon: 'trash',
    dueTime: '19:00',
    points: 2,
    reminders: [30],
  );
  await phone.addChore(
    title: 'Return library books',
    owner: OwnerMember(leo),
    schedule: ChoreSchedule.once(addDays(today, -2)),
    icon: 'book',
    points: 1,
  );

  final groceries = await phone.addList(title: 'Groceries', kind: ListKind.shopping, icon: 'shopping', pinned: true);
  final groceryItems = <String, String>{};
  for (final (text, qty, store) in [
    ('Paper towels', null, 'Costco'),
    ('Eggs', '2 dozen', 'Costco'),
    ('Chicken thighs', '3 lb', 'Costco'),
    ('Strawberries', null, 'Costco'),
    ('Sparkling water', '2 cases', 'Costco'),
    ('Toothpaste', null, 'Target'),
    ('Laundry detergent', null, 'Target'),
    ('Birthday card', null, 'Target'),
    ('AA batteries', null, 'Target'),
    ('Bananas', null, 'Trader Joe\'s'),
    ('Greek yogurt', '2', 'Trader Joe\'s'),
    ('Frozen dumplings', null, 'Trader Joe\'s'),
    ('Everything bagel seasoning', null, 'Trader Joe\'s'),
    ('Milk', '1 gal', null),
  ]) {
    groceryItems[text] = await phone.addItem(groceries, text: text, qty: qty, store: store);
  }
  final packing = await phone.addList(
    title: 'Beach trip packing',
    kind: ListKind.packing,
    lifecycle: ListLifecycle.event,
    event: beach,
    icon: 'packing',
  );
  for (final text in ['Sunscreen', 'Swimsuits', 'Beach towels', 'Sand toys', 'Snacks for the car', 'Chargers']) {
    await phone.addItem(packing, text: text);
  }
  final meals = await phone.addList(title: 'Meal plan', kind: ListKind.meal, icon: 'meal');
  for (final (text, toGroceries) in [
    ('Sunday: Pancakes', false),
    ('Monday: Sheet-pan chicken', false),
    ('Tuesday: Tacos', false),
    ('Taco shells', true),
    ('Wednesday: Pasta night', false),
    ('Thursday: Leftovers', false),
    ('Friday: Pizza', false),
  ]) {
    await phone.addItem(meals, text: text, toGroceries: toGroceries);
  }
  final science = await phone.addList(
    title: 'Science fair supplies',
    kind: ListKind.checklist,
    lifecycle: ListLifecycle.dated,
    needBy: addDays(today, 3),
    icon: 'checklist',
  );
  for (final text in ['Poster board', 'Glue sticks', 'Markers', 'Baking soda', 'Vinegar']) {
    await phone.addItem(science, text: text);
  }

  final later = await phone.addReward(title: 'Later bedtime', cost: 20, icon: 'moon', needsApproval: false);
  await phone.addReward(title: 'Pick dinner', cost: 30, icon: 'pizza', needsApproval: false);
  final five = await phone.addReward(title: '\$5', cost: 30, icon: 'money', needsApproval: true);
  await phone.addGoal(
    title: 'Movie night pick',
    target: 50,
    repeat: GoalRepeat.monthly,
    start: startOfMonth(addDays(weekStart, -14)),
    reward: 'Pick the movie for family movie night',
  );
  await phone.addGoal(
    title: 'First to 25 stars',
    target: 25,
    mode: GoalMode.race,
    members: [maya, leo],
    repeat: GoalRepeat.weekly,
    start: day(-14),
    reward: 'Choose Saturday breakfast',
  );

  moveTo(at(day(-14), '20:00'));
  final display = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: clock);
  await display.requestJoin(
    familyId: phone.familyId!,
    founderPubkey: phone.founderPubkey!,
    deviceName: 'Kitchen display',
    kind: DeviceKind.display,
    mode: DeviceMode.shared,
  );
  await phone.ingest(display.changesSince(phone.versionVector));
  await phone.approveDevice(display.deviceId, mode: DeviceMode.shared);
  await phone.updateDevice(display.deviceId, {
    'display': {'layout': DisplayLayout.week.name, 'openCheckoff': true},
  });

  Future<void> toDisplay() => display.ingest(
        phone.changesSince(display.versionVector, spaces: phone.spacesForDevice(display.deviceId)),
        through: phone.completeVector,
      );
  Future<void> toPhone() => phone.ingest(display.changesSince(phone.versionVector));
  Future<void> as(String? member, Future<void> Function() body) async {
    display.actAs(member, window: const Duration(days: 1));
    await body();
    display.actAs(null);
  }

  moveTo(at(day(-13), '18:00'));
  await phone.adjustPoints(leo, 20, 'Summer reading challenge');
  await toDisplay();
  moveTo(at(day(-13), '18:05'));
  await as(leo, () => display.requestReward(later));

  final pastDays = [for (var i = 6; i >= 1; i--) addDays(today, -i)];
  final mail = phone.chores.firstWhere((c) => c.title == 'Bring in the mail').id;
  final adjustments = {
    addDays(today, -4): (maya, 10, 'Helped with groceries'),
    addDays(today, -3): (leo, -2, 'Left bike in the driveway'),
    addDays(today, -1): (maya, 15, 'Great report card'),
  };
  for (final d in pastDays) {
    final weekday = weekdayOf(d);
    await toDisplay();
    moveTo(at(d, '07:25'));
    if (weekday != DateTime.wednesday) await as(leo, () => display.setChoreDone(cat, d, true));
    moveTo(at(d, '07:40'));
    await as(zoe, () => display.setChoreDone(beds[zoe]!, d, true));
    await as(leo, () => display.setChoreDone(beds[leo]!, d, true));
    if (weekday != DateTime.tuesday) await as(maya, () => display.setChoreDone(beds[maya]!, d, true));
    final adjustment = adjustments[d];
    if (adjustment != null) {
      moveTo(at(d, '15:50'));
      await phone.adjustPoints(adjustment.$1, adjustment.$2, adjustment.$3);
    }
    moveTo(at(d, '16:15'));
    await as(null, () => display.setChoreDone(mail, d, true));
    if (weekday == DateTime.thursday) {
      moveTo(at(d, '18:50'));
      await as(maya, () => display.setChoreDone(trash, d, true));
    }
    moveTo(at(d, '19:20'));
    await as(maya, () => display.setStep(kitchen, d, 'sweep', true));
    if (weekday != DateTime.monday) await as(leo, () => display.setStep(kitchen, d, 'table', true));
    await as(zoe, () => display.setStep(kitchen, d, 'plant', true));
    moveTo(at(d, '19:35'));
    await toPhone();
    await phone.setStep(kitchen, d, 'run', true);
    moveTo(at(d, '19:50'));
    final dishesOwner = display.choresOn(d).firstWhere((c) => c.chore.id == dishes).owner!;
    await as(dishesOwner, () async {
      await display.setStep(dishes, d, 'clear', true);
      await display.setStep(dishes, d, 'load', true);
      if (weekday != DateTime.friday) await display.setStep(dishes, d, 'wipe', true);
    });
  }

  final yesterday = addDays(today, -1);
  moveTo(at(yesterday, '20:05'));
  await toPhone();
  await toDisplay();
  if ((display.points().totals[maya] ?? 0) >= 30) {
    await as(maya, () => display.requestReward(five));
  }
  moveTo(at(yesterday, '20:30'));
  for (final text in ['Strawberries', 'Birthday card', 'Greek yogurt']) {
    await phone.setItemChecked(groceryItems[text]!, true);
  }
  await toDisplay();
  final glue = display.list(science)!.items.firstWhere((i) => i.text == 'Glue sticks').id;
  await as(maya, () => display.setItemChecked(glue, true));

  moveTo(present - 20 * 60000);
  await as(zoe, () => display.setChoreDone(beds[zoe]!, today, true));
  await as(leo, () => display.setChoreDone(cat, today, true));
  await toPhone();
  seeding = false;
  await display.close();
  return phone;
}
