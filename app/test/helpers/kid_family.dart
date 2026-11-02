import 'package:den_app/app/app_state.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shots.dart';

/// One job in a [KidFixture]: its title and pictogram, its stars, its steps (with how many are
/// checked), and whether it's done.
class FixtureJob {
  const FixtureJob(this.title, this.icon, {this.stars = 1, this.done = false, this.steps = 0, this.stepsDone = 0});

  final String title;
  final String icon;
  final int stars;
  final bool done;
  final int steps;
  final int stepsDone;
}

/// One kid in a [KidFixture]: name, color, tier, stars to start with, and today's jobs.
class FixtureKid {
  const FixtureKid(this.name, this.marker, this.jobs, {this.stars = 0, this.tier = Tier.preReader});

  final String name;
  final Marker marker;
  final List<FixtureJob> jobs;
  final int stars;
  final Tier tier;
}

/// The kids on the phone mock (docs/design/mocks/kid-chore-board-phone.png): Leo, a pre-reader in
/// sky, with 7 stars toward a 10-star Park trip, two jobs done, two with stars, one to read and
/// one with steps.
const leoMock = FixtureKid('Leo', Marker.sky, stars: 7, [
  FixtureJob('Make bed', 'bed', done: true),
  FixtureJob('Brush teeth', 'tooth', done: true),
  FixtureJob('Feed Biscuit', 'paw-print', stars: 2),
  FixtureJob('Pack bag', 'backpack'),
  FixtureJob('Read 10 min', 'book-open', stars: 2),
  FixtureJob('Toys away', 'game-controller', steps: 3, stepsDone: 1),
]);

/// The three kids on the wall mock (docs/design/mocks/kid-chore-board-wall.png).
const wallMock = [
  FixtureKid('Leo', Marker.sky, stars: 7, [
    FixtureJob('Make bed', 'bed', done: true),
    FixtureJob('Brush teeth', 'tooth', done: true),
    FixtureJob('Feed Biscuit', 'paw-print', stars: 2),
    FixtureJob('Pack bag', 'backpack'),
  ]),
  FixtureKid('Ava', Marker.grass, stars: 12, tier: Tier.little, [
    FixtureJob('Make bed', 'bed', done: true),
    FixtureJob('Practice piano', 'music-notes', stars: 2, done: true),
    FixtureJob('Set the table', 'fork-knife', done: true),
    FixtureJob('Water plants', 'potted-plant'),
  ]),
  FixtureKid('Sam', Marker.tangerine, stars: 4, [
    FixtureJob('Brush teeth', 'tooth', done: true),
    FixtureJob('Toys away', 'game-controller'),
    FixtureJob('Read 10 min', 'book-open', stars: 2),
    FixtureJob('Shoes by door', 'sneaker'),
  ]),
];

/// A family with Mom and [kids], each with today's jobs as given, [reward] (if any) for stars,
/// built on the real clock at [demoNow]. Returns the state and the kids by name.
Future<(AppState, Map<String, Member>)> kidFamily(
  WidgetTester tester,
  List<FixtureKid> kids, {
  (String, int)? reward = ('Park trip', 10),
  bool wall = false,
}) async =>
    (await tester.runAsync(() async {
      final den = await Den.open(
        storage: MemoryStorage(),
        keys: await DeviceKeys.generate(),
        now: () => demoNow.millisecondsSinceEpoch,
      );
      await den.createFamily(
        familyName: 'Rivera',
        timezone: 'America/Chicago',
        yourName: 'Mom',
        marker: Marker.lavender,
        deviceName: "Mom's phone",
        deviceKind: DeviceKind.phone,
      );
      final state = AppState(den, wall: wall);
      final today = state.today;
      final byName = <String, Member>{};
      for (final k in kids) {
        final id = await den.addMember(name: k.name, role: Role.kid, tier: k.tier, marker: k.marker);
        for (final j in k.jobs) {
          final chore = await den.addChore(
            title: j.title,
            icon: j.icon,
            owner: OwnerMember(id),
            schedule: ChoreSchedule.once(today),
            points: j.stars,
            steps: [for (var i = 0; i < j.steps; i++) ChoreStep(id: 's$i', text: ['Blocks in the box', 'Books on the shelf', 'Cars in the bin'][i % 3])],
          );
          if (j.done) await den.setChoreDone(chore, today, true);
          for (var i = 0; i < j.stepsDone; i++) {
            await den.setStep(chore, today, 's$i', true);
          }
        }
        // Done jobs earned their stars; make up the rest so the total is the kid's.
        final earned = den.points().available(id);
        if (k.stars != earned) await den.adjustPoints(id, k.stars - earned, 'Stars so far');
        byName[k.name] = den.member(id)!;
      }
      if (reward != null) await den.addReward(title: reward.$1, cost: reward.$2, icon: 'tree');
      return (state, byName);
    }))!;
