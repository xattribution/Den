import 'dart:ui' show Tristate;

import 'package:den_app/app/app_state.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/features/shared_screens/screens/wall_screen.dart';
import 'package:den_app/features/shared_screens/state/display.dart';
import 'package:den_app/features/shared_screens/widgets/kid_tiles.dart';
import 'package:den_app/features/shared_screens/widgets/wall_chores.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/kid_family.dart';
import '../helpers/shots.dart';
import 'family_fakes.dart';

/// The wall's chores board (KIDS_MODE_AND_SOFT_THEME.md, phase 4): a column per kid, behind the
/// Chores tab in the wall's top bar.

/// Two more kids for boards of four and five.
const _more = [
  FixtureKid('Mia', Marker.bubblegum, stars: 3, tier: Tier.little, [
    FixtureJob('Feed the fish', 'fish'),
    FixtureJob('Put away the laundry and fold the towels', 't-shirt', stars: 2),
  ]),
  FixtureKid('Noor', Marker.lavender, stars: 9, tier: Tier.little, [
    FixtureJob('Take out the recycling', 'recycle', done: true),
    FixtureJob('Practice spelling words', 'pencil-simple', stars: 2),
  ]),
];

WallScreen _wallAt() => WallScreen(now: () => demoNow, keepAwake: false);

/// The wall mock's kids and [extra], on a wall showing Chores.
Future<AppState> _board(WidgetTester tester, {int kids = 3}) async {
  final (state, _) = await kidFamily(tester, [...wallMock, ..._more].take(kids).toList(), wall: true);
  state.device.wallView = WallView.chores.name;
  return state;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the view: a parent picks Week or Today; the tabs at the wall add Chores, kept on the wall', () {
    expect(WallView.values.map((v) => v.label), ['Week', 'Today', 'Chores']);
    expect(wallViewOf(null, null), WallView.week);
    expect(wallViewOf(null, 'chores'), WallView.chores);
    expect(wallViewOf(null, 'sepia'), WallView.week, reason: 'an unknown view follows the layout');
  });

  testWidgets("a parent's Today layout opens on Today; the Chores tab switches and the wall keeps it", (tester) async {
    final state = await kitchen(tester, layout: 'today');
    await pumpScreen(tester, _wallAt(), state: state, size: wall);
    expect(tester.getSemantics(find.bySemanticsLabel('Today, tab')).flagsCollection.isSelected, Tristate.isTrue);
    await tester.tap(find.text('Chores'));
    await tester.pumpAndSettle();
    expect(state.device.wallView, 'chores');
    expect(find.byType(WallChoresBoard), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getString('den.wallView'), 'chores');
    expect((await DevicePrefs.load()).wallView, 'chores', reason: 'a restart keeps it');
    await tester.tap(find.text('Week'));
    await tester.pumpAndSettle();
    expect(find.byType(WallChoresBoard), findsNothing);
  });

  testWidgets('one column per kid, side by side', (tester) async {
    final state = await _board(tester);
    await pumpScreen(tester, _wallAt(), state: state, size: wall, theme: DenColors.softDay);
    final columns = find.byType(WallKidColumn);
    expect(columns, findsNWidgets(3));
    final xs = [for (var i = 0; i < 3; i++) tester.getTopLeft(columns.at(i)).dx];
    expect(xs, orderedEquals([...xs]..sort()));
    expect(xs.toSet(), hasLength(3));
    for (final (i, name) in ['Leo', 'Ava', 'Sam'].indexed) {
      expect(find.descendant(of: columns.at(i), matching: find.text(name)), findsOneWidget);
    }
    expect(find.descendant(of: columns.at(0), matching: find.byType(WallJobRow)), findsNWidgets(4));
    expect(find.text('2 of 4 done'), findsOneWidget);
    expect(find.text('3 of 4 done'), findsOneWidget);
  });

  testWidgets("on the wall a disc is its kid's color, never a kid primary", (tester) async {
    final state = await _board(tester);
    await pumpScreen(tester, _wallAt(), state: state, size: wall, theme: DenColors.softDay);
    for (final column in tester.widgetList<WallKidColumn>(find.byType(WallKidColumn))) {
      final person = DenColors.softDay.marker(column.kid.marker);
      final discs = tester.widgetList<KidDisc>(find.descendant(of: find.byWidget(column), matching: find.byType(KidDisc)));
      expect(discs, isNotEmpty);
      for (final d in discs) {
        expect(d.color, person, reason: column.kid.name);
      }
    }
  });

  testWidgets('rows are 156 tall (120 in a narrow column); to do has an empty ring, done a check; titles wrap, never cut', (tester) async {
    final state = await _board(tester, kids: 4);
    await pumpScreen(tester, _wallAt(), state: state, size: wall, theme: DenColors.softDay);
    final rows = find.byType(WallJobRow);
    for (var i = 0; i < tester.widgetList(rows).length; i++) {
      final size = tester.getSize(rows.at(i));
      // 156 in a roomy column; four kids to a wall step the row down, still far over 64.
      expect(size.height, greaterThanOrEqualTo(size.width >= 520 ? KidLayout.wallRowHeight : 120));
    }
    final row = tester.widget<WallJobRow>(rows.first);
    expect(row.day.done, isTrue);
    expect(find.descendant(of: rows.first, matching: find.byType(TodoRing)), findsNothing);
    final todo = find.ancestor(of: find.text('Feed Biscuit'), matching: find.byType(WallJobRow));
    expect(find.descendant(of: todo, matching: find.byType(TodoRing)), findsOneWidget);
    final long = find.text('Put away the laundry and fold the towels');
    expect(tester.widget<Text>(long).maxLines, isNull);
    expect(tester.widget<Text>(long).overflow, isNull);
    expect(tester.getSize(long).height, greaterThan(60), reason: 'it wraps');
  });

  for (final kids in [2, 3, 4, 5]) {
    testWidgets('$kids kids render without clipping', (tester) async {
      final state = await _board(tester, kids: kids);
      await pumpScreen(tester, _wallAt(), state: state, size: wall, theme: DenColors.softDay);
      expect(tester.takeException(), isNull);
      final shown = find.byType(WallKidColumn);
      expect(tester.widgetList(shown).length, kids <= 4 ? kids : 4, reason: 'five or more page sideways');
      for (var i = 0; i < tester.widgetList(shown).length; i++) {
        final rect = tester.getRect(shown.at(i));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(wall.width));
        expect(rect.width, greaterThanOrEqualTo(WallChoresBoard.minColumn));
      }
      if (kids == 5) {
        await tester.drag(find.byType(PageView), const Offset(-1200, 0));
        await tester.pumpAndSettle();
        expect(find.text('Noor'), findsOneWidget);
      }
    });
  }

  testWidgets('one tap anywhere on a row checks it', (tester) async {
    final state = await _board(tester);
    await pumpScreen(tester, _wallAt(), state: state, size: wall, theme: DenColors.softDay);
    final row = find.ancestor(of: find.text('Water plants'), matching: find.byType(WallJobRow));
    await tester.runAsync(() async {
      await tester.tapAt(tester.getTopRight(row) + const Offset(-40, 40));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pumpAndSettle();
    expect(state.den.choresOn(state.today).firstWhere((d) => d.chore.title == 'Water plants').done, isTrue);
    expect(find.text('4 of 4 done'), findsOneWidget);
  });

  testWidgets('screen reader: each kid is a heading, each row says its job and state', (tester) async {
    final handle = tester.ensureSemantics();
    final state = await _board(tester);
    await pumpScreen(tester, _wallAt(), state: state, size: wall, theme: DenColors.softDay);
    expect(find.bySemanticsLabel('Leo, 2 of 4 done, 7 stars'), findsOneWidget);
    expect(find.bySemanticsLabel('Make bed, Done'), findsNWidgets(2));
    expect(find.bySemanticsLabel('Feed Biscuit, +2 stars'), findsOneWidget);
    handle.dispose();
  });

  group('goldens', () {
    for (final (suffix, theme) in [
      ('_soft', DenColors.softDay),
      ('_soft_night', DenColors.softNight),
      ('', DenColors.day),
      ('_night', DenColors.night),
    ]) {
      testWidgets('1080p$suffix (mocks/kid-chore-board-wall.png)', (tester) async {
        final state = await _board(tester);
        await shootWith(tester, 'wall_chores_1080p$suffix', _wallAt(), state: state, size: wall, theme: theme);
      });
    }

    testWidgets('1080p, Soft, five kids: four, then a page', (tester) async {
      final state = await _board(tester, kids: 5);
      await shootWith(tester, 'wall_chores_5kids_1080p_soft', _wallAt(), state: state, size: wall, theme: DenColors.softDay);
    });

    testWidgets('1080p, Soft, two kids', (tester) async {
      final state = await _board(tester, kids: 2);
      await shootWith(tester, 'wall_chores_2kids_1080p_soft', _wallAt(), state: state, size: wall, theme: DenColors.softDay);
    });

    testWidgets('tablet, Soft', (tester) async {
      final state = await _board(tester);
      await shootWith(tester, 'wall_chores_tablet_soft', _wallAt(), state: state, size: tablet, theme: DenColors.softDay);
    });

    testWidgets('phone, Soft', (tester) async {
      final state = await _board(tester);
      await shootWith(tester, 'wall_chores_phone_soft', _wallAt(), state: state, theme: DenColors.softDay);
    });

    testWidgets('1080p, Soft, 200 % text', (tester) async {
      final state = await _board(tester);
      withTextScale(tester, 2);
      await shootWith(tester, 'wall_chores_1080p_soft_text200', _wallAt(), state: state, size: wall, theme: DenColors.softDay);
    });

    testWidgets('1080p, Soft, a row held down', (tester) async {
      final state = await _board(tester);
      await pumpScreen(tester, _wallAt(), state: state, size: wall, theme: DenColors.softDay);
      final gesture = await tester.startGesture(tester.getCenter(find.text('Feed Biscuit')));
      await tester.pumpAndSettle();
      await matchShot('wall_chores_1080p_soft_pressed');
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });
}
