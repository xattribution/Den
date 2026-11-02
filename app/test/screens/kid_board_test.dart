import 'package:den_app/app/app_state.dart';
import 'package:den_app/design/chunky.dart';
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/features/shared_screens/screens/kid_screen.dart';
import 'package:den_app/features/shared_screens/widgets/kid_parts.dart';
import 'package:den_app/features/shared_screens/widgets/kid_star_card.dart';
import 'package:den_app/features/shared_screens/widgets/kid_tiles.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../helpers/kid_family.dart';
import '../helpers/shots.dart';
import 'family_fakes.dart';

/// Kids mode's tiles (KIDS_MODE_AND_SOFT_THEME.md, phase 3): the chunky press, the job tile, the
/// star card with pips and the pinned "Read my jobs to me", on a kid's own board.

/// The haptics a test sees, by type ("HapticFeedbackType.lightImpact").
List<String> _haptics(WidgetTester tester) {
  final seen = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') seen.add(call.arguments as String);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return seen;
}

/// What the kid board reads aloud.
List<String> _spoken(WidgetTester tester) {
  final said = <String>[];
  const channel = MethodChannel('flutter_tts');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
    if (call.method == 'speak') said.add(call.arguments as String);
    return 1;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
  return said;
}

/// [child] alone in the app's theme, centered in a phone.
Future<void> _pumpPart(
  WidgetTester tester,
  Widget child, {
  DenColors theme = DenColors.softDay,
  bool reduced = false,
  Size size = phone,
  bool settle = true,
}) async {
  await loadFonts();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: denTheme(theme),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: child!,
      ),
      home: Scaffold(
        body: Center(child: Padding(padding: const EdgeInsets.all(16), child: child)),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

Widget _tile({bool done = false, String title = 'Feed Biscuit', VoidCallback? onTap, VoidCallback? onLongPress}) => SizedBox(
      width: 171,
      child: KidJobTile(
        title: title,
        glyph: PhosphorIconsFill.pawPrint,
        disc: KidColors.tangerine.face,
        person: const Color(0xFF71C8FF),
        done: done,
        meta: '+2 stars',
        metaStar: true,
        onTap: onTap ?? () {},
        onLongPress: onLongPress,
        toggled: done,
        semanticLabel: [title, done ? 'Done' : '+2 stars'].join(', '),
      ),
    );

void main() {
  group('ChunkyPressable', () {
    testWidgets('a press sinks the face 6 onto its lip, and it springs back', (tester) async {
      await _pumpPart(tester, _tile());
      final chunky = tester.element(find.byType(ChunkyPressable));
      expect(ChunkyPressable.sunk(chunky), 0);
      final gesture = await tester.startGesture(tester.getCenter(find.byType(ChunkyPressable)));
      await tester.pumpAndSettle();
      expect(ChunkyPressable.sunk(chunky), Lip.tile);
      expect(Lip.tile, 6);
      final face = tester.widget<Transform>(find.descendant(of: find.byType(ChunkyPressable), matching: find.byType(Transform)).first);
      expect(face.transform.getTranslation().y, 6);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(ChunkyPressable.sunk(chunky), 0);
    });

    testWidgets('a drag past the slop lets go', (tester) async {
      await _pumpPart(tester, _tile());
      final chunky = tester.element(find.byType(ChunkyPressable));
      final gesture = await tester.startGesture(tester.getCenter(find.byType(ChunkyPressable)));
      await tester.pumpAndSettle();
      await gesture.moveBy(const Offset(0, 40));
      await tester.pumpAndSettle();
      expect(ChunkyPressable.sunk(chunky), 0);
      await gesture.up();
    });

    testWidgets('under Reduce Motion nothing moves: the face shades for 100 ms instead', (tester) async {
      await _pumpPart(tester, _tile(), reduced: true);
      final chunky = tester.element(find.byType(ChunkyPressable));
      Color face() => (tester
              .widget<DecoratedBox>(find.descendant(of: find.byType(ChunkyPressable), matching: find.byType(DecoratedBox)).first)
              .decoration as BoxDecoration)
          .color!;
      final resting = face();
      final gesture = await tester.startGesture(tester.getCenter(find.byType(ChunkyPressable)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(ChunkyPressable.sunk(chunky), 0);
      expect(face(), isNot(resting));
      expect(face().a, 1, reason: 'the shade is blended to an opaque color: nothing translucent');
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(face(), resting);
    });

    testWidgets('one light haptic per toggle', (tester) async {
      final haptics = _haptics(tester);
      var taps = 0;
      await _pumpPart(tester, _tile(onTap: () => taps++));
      await tester.tap(find.byType(ChunkyPressable));
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(haptics, ['HapticFeedbackType.lightImpact']);
      await tester.tap(find.byType(ChunkyPressable));
      await tester.pumpAndSettle();
      expect(haptics, hasLength(2));
    });

    testWidgets('a long press is a second way in, with its hint for the screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      var read = 0;
      await _pumpPart(tester, _tile(onLongPress: () => read++));
      await tester.longPress(find.byType(ChunkyPressable));
      expect(read, 1);
      final node = tester.getSemantics(find.byType(ChunkyPressable));
      expect(node.label, 'Feed Biscuit, +2 stars');
      expect(node.hintOverrides?.onLongPressHint, 'Read it to me');
      handle.dispose();
    });

    testWidgets('the keyboard activates it', (tester) async {
      var taps = 0;
      await _pumpPart(tester, _tile(onTap: () => taps++));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(taps, 1);
    });
  });

  group('job tile', () {
    testWidgets('to do: a disc with the pictogram; done: a white disc with a check. A shape for each', (tester) async {
      await _pumpPart(tester, _tile());
      expect(find.byIcon(PhosphorIconsFill.pawPrint), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is CheckPainter), findsNothing);
      await _pumpPart(tester, _tile(done: true));
      expect(find.byIcon(PhosphorIconsFill.pawPrint), findsNothing);
      expect(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is CheckPainter), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('at least 136 tall and 64 wide; a long title wraps and the tile grows', (tester) async {
      await _pumpPart(tester, _tile());
      final short = tester.getSize(find.byType(KidJobTile));
      expect(short.height, greaterThanOrEqualTo(KidLayout.tileMinHeight + Lip.tile));
      expect(short.width, greaterThanOrEqualTo(64));
      await _pumpPart(tester, _tile(title: 'Return the library books to the shelf'));
      final title = tester.widget<Text>(find.text('Return the library books to the shelf'));
      expect(title.maxLines, isNull);
      expect(title.overflow, isNull, reason: 'titles never truncate');
      expect(tester.getSize(find.text('Return the library books to the shelf')).height, greaterThan(40));
      expect(tester.getSize(find.byType(KidJobTile)).height, greaterThan(short.height));
    });
  });

  group('star pips', () {
    testWidgets('one per star needed, earned ones gold; past 12 a bar', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpPart(tester, const SizedBox(width: 240, child: StarPips(have: 7, need: 10)));
      final pips = find.descendant(of: find.byType(StarPips), matching: find.byType(Container));
      expect(pips, findsNWidgets(10));
      final gold = tester.widgetList<Container>(pips).where((p) => (p.decoration! as BoxDecoration).color == DenColors.softDay.star);
      expect(gold, hasLength(7));
      expect(find.bySemanticsLabel('7 of 10 stars'), findsOneWidget);
      await _pumpPart(tester, const SizedBox(width: 240, child: StarPips(have: 15, need: 15)));
      expect(find.descendant(of: find.byType(StarPips), matching: find.byType(Container)), findsNothing);
      expect(find.byType(FractionallySizedBox), findsOneWidget);
      handle.dispose();
    });
  });

  group('star card', () {
    late Reward parkTrip;
    KidTarget park(int have) => KidTarget(
          name: 'Park trip',
          have: have,
          need: 10,
          words: have >= 10 ? 'Park trip is ready' : '${10 - have} more stars for Park trip',
          reward: parkTrip,
        );
    Future<void> reward(WidgetTester tester) async {
      final (state, _) = await kidFamily(tester, const []);
      parkTrip = state.den.points().rewards.single;
    }

    for (final (name, stars, target) in [
      ('0', 0, (int s) => KidTarget(name: 'Park trip', have: s, need: 10, words: '10 more stars for Park trip')),
      ('7_of_10', 7, null),
      ('10_of_10', 10, null),
      ('15', 15, (int s) => KidTarget(name: 'Movie night', have: s, need: 15, words: 'Reached Movie night this week')),
    ]) {
      testWidgets('$name stars', (tester) async {
        await reward(tester);
        await _pumpPart(
          tester,
          KidStarCard(stars: stars, target: target == null ? park(stars) : target(stars), onGetIt: () {}),
          size: const Size(390, 320),
        );
        await matchShot('kid_star_card_$name');
      });
    }

    testWidgets('a reward reached: "Park trip is ready", Get it, a heavy haptic then a light one', (tester) async {
      await reward(tester);
      final haptics = _haptics(tester);
      Widget card(int s) => KidStarCard(stars: s, target: park(s), onGetIt: () {});
      await _pumpPart(tester, card(9));
      expect(find.text('Get it'), findsNothing);
      await _pumpPart(tester, card(10), settle: false);
      await tester.pump(const Duration(milliseconds: 60));
      expect(findWords('Park trip is ready'), findsOneWidget);
      expect(find.text('Get it'), findsOneWidget);
      expect(haptics, ['HapticFeedbackType.heavyImpact', 'HapticFeedbackType.heavyImpact']);
      await tester.pump(const Duration(milliseconds: 120));
      expect(haptics.last, 'HapticFeedbackType.lightImpact');
      expect(tester.getSize(find.byType(FilledButton)).height, greaterThanOrEqualTo(64));
    });

    testWidgets('a star earned lands with one spring; under Reduce Motion a fade, and the haptic stays', (tester) async {
      await reward(tester);
      final haptics = _haptics(tester);
      await _pumpPart(tester, KidStarCard(stars: 3, target: park(3)), reduced: true);
      await _pumpPart(tester, KidStarCard(stars: 4, target: park(4)), reduced: true, settle: false);
      await tester.pump(const Duration(milliseconds: 40));
      expect(haptics, ['HapticFeedbackType.heavyImpact']);
      final fade = tester.widget<FadeTransition>(find.descendant(of: find.byType(KidStarCard), matching: find.byType(FadeTransition)).first);
      expect(fade.opacity.value, lessThan(1), reason: 'fading in');
      expect(find.byType(Transform), findsWidgets);
      await tester.pumpAndSettle();
      expect(fade.opacity.value, 1);
    });
  });

  group('the board', () {
    Future<AppState> mock(WidgetTester tester, {bool reader = true}) async {
      final (state, _) = await kidFamily(tester, [
        if (reader) leoMock else FixtureKid('Leo', Marker.sky, leoMock.jobs, stars: 7, tier: Tier.little),
      ]);
      return state;
    }

    Member leo(AppState state) => state.den.members.firstWhere((m) => m.name == 'Leo');

    testWidgets('two columns on a phone', (tester) async {
      final state = await mock(tester);
      await pumpScreen(tester, KidScreen(memberId: leo(state).id), state: state, theme: DenColors.softDay);
      final tiles = find.byType(KidJobTile);
      final xs = {for (final e in tester.widgetList(tiles).indexed) tester.getTopLeft(tiles.at(e.$1)).dx.round()};
      expect(xs, hasLength(2));
    });

    testWidgets('three columns on a tablet', (tester) async {
      final state = await mock(tester);
      await pumpScreen(tester, KidScreen(memberId: leo(state).id), state: state, size: const Size(834, 1194), theme: DenColors.softDay);
      final tiles = find.byType(KidJobTile);
      final xs = {for (var i = 0; i < 6; i++) tester.getTopLeft(tiles.at(i)).dx.round()};
      expect(xs, hasLength(3));
    });

    testWidgets('large text: two columns while titles fit two lines, one when one would wrap to a third', (tester) async {
      final state = await mock(tester);
      withTextScale(tester, 2);
      await pumpScreen(tester, KidScreen(memberId: leo(state).id), state: state, size: const Size(390, 2600), theme: DenColors.softDay);
      final mockTiles = find.byType(KidJobTile, skipOffstage: false);
      expect({for (var i = 0; i < 6; i++) tester.getTopLeft(mockTiles.at(i)).dx.round()}, hasLength(2));
      await tester.runAsync(() => state.den.addChore(
            title: 'Return library books',
            icon: 'books',
            owner: OwnerMember(leo(state).id),
            schedule: ChoreSchedule.once(state.today),
          ));
      await pumpScreen(tester, KidScreen(memberId: leo(state).id), state: state, size: const Size(390, 2600), theme: DenColors.softDay);
      final tiles = find.byType(KidJobTile, skipOffstage: false);
      await tester.pumpAndSettle();
      final xs = {for (var i = 0; i < 7; i++) tester.getTopLeft(tiles.at(i)).dx.round()};
      expect(xs, hasLength(1));
    });

    testWidgets('every tile at least 136 tall and 64 wide; the semantics labels as before', (tester) async {
      final handle = tester.ensureSemantics();
      final state = await mock(tester);
      await pumpScreen(tester, KidScreen(memberId: leo(state).id), state: state, size: const Size(390, 1400), theme: DenColors.softDay);
      for (final e in tester.widgetList(find.byType(KidJobTile)).indexed) {
        final size = tester.getSize(find.byType(KidJobTile).at(e.$1));
        expect(size.height, greaterThanOrEqualTo(136));
        expect(size.width, greaterThanOrEqualTo(64));
      }
      expect(find.bySemanticsLabel('Make bed, Done'), findsOneWidget);
      expect(find.bySemanticsLabel('Feed Biscuit, +2 stars'), findsOneWidget);
      expect(find.bySemanticsLabel('Toys away, 1 of 3'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('Read my jobs to me is pinned on a phone and the last tile scrolls clear of it', (tester) async {
      final state = await mock(tester);
      await pumpScreen(tester, KidScreen(memberId: leo(state).id), state: state, theme: DenColors.softDay);
      final bar = find.byKey(const Key('read-to-me-pinned'));
      expect(bar, findsOneWidget);
      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      final last = tester.getRect(find.byType(KidJobTile).last);
      final top = tester.getRect(find.byType(ReadToMeBar)).top;
      expect(top - last.bottom, greaterThanOrEqualTo(16), reason: 'never overlaps the last tile');
    });

    testWidgets('on a tablet it sits under the star card instead', (tester) async {
      final state = await mock(tester);
      await pumpScreen(tester, KidScreen(memberId: leo(state).id), state: state, size: const Size(834, 1194), theme: DenColors.softDay);
      expect(find.byKey(const Key('read-to-me-pinned')), findsNothing);
      expect(tester.getRect(find.byType(ReadToMeBar)).top, greaterThan(tester.getRect(find.byType(KidStarCard)).bottom));
      expect(tester.getRect(find.byType(ReadToMeBar)).bottom, lessThan(tester.getRect(find.byType(KidJobTile).first).top));
    });

    testWidgets('it reads the whole list of jobs to do; a long press reads one', (tester) async {
      final said = _spoken(tester);
      final state = await mock(tester);
      await pumpScreen(tester, KidScreen(memberId: leo(state).id), state: state, theme: DenColors.softDay);
      await tester.tap(find.byType(ReadToMeBar));
      await tester.pumpAndSettle();
      expect(said.single, startsWith('Feed Biscuit. Pack bag. Read 10 min. Toys away'));
      expect(said.single, isNot(contains('Make bed')), reason: 'only what is left');
      await tester.longPress(find.text('Pack bag'));
      await tester.pumpAndSettle();
      expect(said.last, 'Pack bag');
    });

    testWidgets("a tap checks a job off: the tile fills in the kid's color", (tester) async {
      final state = await mock(tester);
      await pumpScreen(tester, KidScreen(memberId: leo(state).id), state: state, size: const Size(390, 1400), theme: DenColors.softDay);
      await tester.runAsync(() async {
        await tester.tap(find.text('Pack bag'));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pumpAndSettle();
      final day = state.den.choresOn(state.today).firstWhere((d) => d.chore.title == 'Pack bag');
      expect(day.done, isTrue);
      final face = tester.widget<KidJobTile>(find.ancestor(of: find.text('Pack bag'), matching: find.byType(KidJobTile)));
      expect(face.done, isTrue);
    });
  });

  group('goldens', () {
    Future<(AppState, Member)> board(WidgetTester tester, {Tier tier = Tier.preReader}) async {
      final (state, kids) = await kidFamily(tester, [
        FixtureKid('Leo', Marker.sky, leoMock.jobs, stars: 7, tier: tier),
      ]);
      return (state, kids['Leo']!);
    }

    for (final (suffix, theme) in [
      ('', DenColors.day),
      ('_night', DenColors.night),
      ('_soft', DenColors.softDay),
      ('_soft_night', DenColors.softNight),
    ]) {
      testWidgets('phone$suffix (mocks/kid-chore-board-phone.png)', (tester) async {
        final (state, leo) = await board(tester);
        await shootWith(tester, 'kid_board_phone$suffix', KidScreen(memberId: leo.id, handed: true), state: state, theme: theme);
      });

      testWidgets('tablet$suffix', (tester) async {
        final (state, leo) = await board(tester);
        await shootWith(tester, 'kid_board_tablet$suffix', KidScreen(memberId: leo.id, handed: true), state: state, size: const Size(834, 1194), theme: theme);
      });
    }

    testWidgets('little kid, tablet landscape, Soft: star card and today side by side', (tester) async {
      final (state, leo) = await board(tester, tier: Tier.little);
      await tester.runAsync(() => state.den.addEvent(
            title: 'Swim lesson',
            start: DateTime.utc(2026, 10, 16, 21).millisecondsSinceEpoch,
            end: DateTime.utc(2026, 10, 16, 22).millisecondsSinceEpoch,
            assignees: [leo.id],
          ));
      await shootWith(tester, 'kid_board_little_tablet_soft', KidScreen(memberId: leo.id, handed: true), state: state, size: tablet, theme: DenColors.softDay);
    });

    testWidgets('phone, Soft, 200 % text: a long title wraps, so one column', (tester) async {
      final (state, leo) = await board(tester);
      await tester.runAsync(() => state.den.addChore(
            title: 'Return library books',
            icon: 'books',
            owner: OwnerMember(leo.id),
            schedule: ChoreSchedule.once(state.today),
          ));
      withTextScale(tester, 2);
      await shootWith(tester, 'kid_board_phone_soft_text200', KidScreen(memberId: leo.id, handed: true), state: state, size: const Size(390, 3000), theme: DenColors.softDay);
    });

    for (final reduced in [false, true]) {
      testWidgets('phone, Soft, a tile held down${reduced ? ', Reduce Motion' : ''}', (tester) async {
        final (state, leo) = await board(tester);
        await pumpScreen(tester, KidScreen(memberId: leo.id, handed: true), state: state, theme: DenColors.softDay);
        if (reduced) tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(tester.getCenter(find.text('Feed Biscuit')));
        await tester.pumpAndSettle();
        await matchShot('kid_board_phone_soft_pressed${reduced ? '_reduced' : ''}');
        await gesture.up();
        await tester.pumpAndSettle();
      });
    }
  });
}
