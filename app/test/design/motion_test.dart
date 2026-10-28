import 'dart:math' as math;

import 'package:den_app/design/motion.dart';
import 'package:den_app/design/sheet.dart';
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_test/flutter_test.dart';

/// The most a spring from 0 to 1 passes its target, sampled over two seconds.
double _peak(SpringDescription spring) {
  final simulation = SpringSimulation(spring, 0, 1, 0);
  var peak = 0.0;
  for (var t = 0.0; t < 2; t += 1 / 480) {
    peak = math.max(peak, simulation.x(t));
  }
  return peak;
}

const Key _box = Key('box');

Widget _app(Widget home, {bool reduced = false}) => MaterialApp(
      theme: denTheme(DenColors.day),
      builder: (context, child) =>
          MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: reduced), child: child!),
      home: Scaffold(body: home),
    );

double _scaleOf(WidgetTester tester) => tester
    .widget<ScaleTransition>(find.descendant(of: find.byType(DenPressable), matching: find.byType(ScaleTransition)))
    .scale
    .value;

Future<void> _phone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// A screen with a button that opens a 300 pt sheet.
Widget _opener({double height = 300}) => Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => showDenSheet<void>(
            context,
            builder: (_) => SizedBox(height: height, child: const Center(child: Text('In the sheet'))),
          ),
          child: const Text('Open'),
        ),
      ),
    );

void main() {
  group('springs', () {
    test('the UI spring passes its target by less than 2 %', () {
      expect(_peak(DenMotion.ui), lessThan(1.02));
    });

    test('the sheet spring never passes its target', () {
      expect(_peak(DenMotion.sheet), lessThanOrEqualTo(1.0 + 1e-9));
    });

    test('the check spring settles once, a little', () {
      expect(_peak(DenMotion.check), greaterThan(1.0));
      expect(_peak(DenMotion.check), lessThan(1.06));
    });

    test('response sets the stiffness: (2π / response)²', () {
      expect(DenMotion.ui.stiffness, closeTo(math.pow(2 * math.pi / 0.32, 2), 1e-6));
      expect(DenMotion.sheet.stiffness, closeTo(math.pow(2 * math.pi / 0.38, 2), 1e-6));
    });

    test('they settle quickly', () {
      expect(DenMotion.uiSettle, lessThan(const Duration(milliseconds: 700)));
      expect(DenMotion.sheetSettle, lessThan(const Duration(milliseconds: 800)));
    });

    test('a spring curve runs from 0 to 1', () {
      expect(DenMotion.uiCurve.transform(0), 0);
      expect(DenMotion.uiCurve.transform(1), 1);
      expect(DenMotion.uiCurve.transform(0.5), inExclusiveRange(0.5, 1.02));
    });

    testWidgets('a spring lands exactly on its target', (tester) async {
      final controller = AnimationController.unbounded(vsync: const TestVSync(), value: 1);
      addTearDown(controller.dispose);
      controller.springTo(0, spring: DenMotion.sheet, velocity: -3);
      await tester.pumpAndSettle();
      expect(controller.value, 0);
      expect(controller.isAnimating, isFalse);
    });

    testWidgets('a spring grabbed mid-flight keeps its velocity', (tester) async {
      final controller = AnimationController.unbounded(vsync: const TestVSync());
      addTearDown(controller.dispose);
      controller.springTo(1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final velocity = controller.velocity;
      expect(velocity, greaterThan(0));
      controller.springTo(0.5);
      expect(controller.velocity, closeTo(velocity, velocity * 0.05));
      controller.stop();
    });
  });

  group('press feedback', () {
    testWidgets('scales on pointer down, in the same frame, and springs back', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_app(Center(
        child: DenPressable(onTap: () => taps++, color: Colors.white, child: const SizedBox(key: _box, width: 120, height: 44)),
      )));
      final gesture = await tester.startGesture(tester.getCenter(find.byKey(_box)));
      // The fill shades in the very next frame; the scale starts its spring in it.
      await tester.pump();
      final fill = tester.widget<DecoratedBox>(
        find.descendant(of: find.byType(DenPressable), matching: find.byType(DecoratedBox)).first,
      );
      // White, 6 % darker.
      expect((fill.decoration as ShapeDecoration).color!.r, closeTo(0.94, 0.005));
      await tester.pump(const Duration(milliseconds: 16));
      expect(_scaleOf(tester), lessThan(1));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_scaleOf(tester), closeTo(DenMotion.pressScale, 0.005));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_scaleOf(tester), closeTo(1, 0.001));
      expect(taps, 1);
    });

    testWidgets('a scroll that leaves the slop lets go', (tester) async {
      await tester.pumpWidget(_app(Center(
        child: DenPressable(onTap: () {}, child: const SizedBox(key: _box, width: 120, height: 44)),
      )));
      final gesture = await tester.startGesture(tester.getCenter(find.byKey(_box)));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, 40));
      await tester.pumpAndSettle();
      expect(_scaleOf(tester), closeTo(1, 0.001));
      await gesture.up();
    });

    testWidgets('under Reduce Motion a press shades but never scales', (tester) async {
      await tester.pumpWidget(_app(
        Center(child: DenPressable(onTap: () {}, child: const SizedBox(key: _box, width: 120, height: 44))),
        reduced: true,
      ));
      final gesture = await tester.startGesture(tester.getCenter(find.byKey(_box)));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(_scaleOf(tester), 1);
      }
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('is a button to screen readers and works from the keyboard', (tester) async {
      var taps = 0;
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(_app(Center(
        child: DenPressable(
          onTap: () => taps++,
          focusNode: focus,
          semanticLabel: 'Approve',
          child: const SizedBox(width: 120, height: 44),
        ),
      )));
      expect(
        tester.getSemantics(find.bySemanticsLabel('Approve')),
        containsSemantics(label: 'Approve', isButton: true, hasTapAction: true),
      );
      focus.requestFocus();
      await tester.pump();
      // What Enter and Space do on a focused control.
      Actions.invoke(focus.context!, const ActivateIntent());
      await tester.pump();
      expect(taps, 1);
    });
  });

  group('sheet', () {
    testWidgets('rises on a spring and settles open', (tester) async {
      await _phone(tester);
      await tester.pumpWidget(_app(_opener()));
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final rising = tester.getTopLeft(find.text('In the sheet')).dy;
      await tester.pumpAndSettle();
      final open = tester.getTopLeft(find.text('In the sheet')).dy;
      expect(rising, greaterThan(open));
      // Bottom-anchored on a phone.
      final sheet = find.ancestor(of: find.text('In the sheet'), matching: find.byType(Material)).first;
      expect(tester.getBottomLeft(sheet).dy, 844);
      expect(tester.getSize(sheet).width, 390);
    });

    testWidgets('closes when flung down', (tester) async {
      await _phone(tester);
      await tester.pumpWidget(_app(_opener()));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.fling(find.text('In the sheet'), const Offset(0, 120), 1500);
      await tester.pumpAndSettle();
      expect(find.text('In the sheet'), findsNothing);
    });

    testWidgets('closes when dragged slowly past 35 % of its height', (tester) async {
      await _phone(tester);
      await tester.pumpWidget(_app(_opener()));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.timedDrag(find.text('In the sheet'), const Offset(0, 200), const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('In the sheet'), findsNothing);
    });

    testWidgets('settles back after a short slow drag, following the finger 1:1', (tester) async {
      await _phone(tester);
      await tester.pumpWidget(_app(_opener()));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final open = tester.getTopLeft(find.text('In the sheet')).dy;
      final gesture = await tester.startGesture(tester.getCenter(find.text('In the sheet')));
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump(const Duration(milliseconds: 200));
      // The drag slop is taken from the first move; after that the sheet tracks the finger.
      expect(tester.getTopLeft(find.text('In the sheet')).dy - open, inInclusiveRange(30, 60));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('In the sheet')).dy, closeTo(open, 0.5));
    });

    testWidgets('closes with a tap outside it', (tester) async {
      await _phone(tester);
      await tester.pumpWidget(_app(_opener()));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(20, 40));
      await tester.pumpAndSettle();
      expect(find.text('In the sheet'), findsNothing);
    });

    testWidgets('completes with what it pops', (tester) async {
      await _phone(tester);
      String? result;
      await tester.pumpWidget(_app(Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await showDenSheet<String>(
              context,
              builder: (sheet) => TextButton(onPressed: () => Navigator.pop(sheet, 'picked'), child: const Text('Pick')),
            );
          },
          child: const Text('Open'),
        ),
      )));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pick'));
      await tester.pumpAndSettle();
      expect(result, 'picked');
      expect(find.text('Pick'), findsNothing);
    });

    testWidgets('is a centered form sheet at most 560 wide on iPad', (tester) async {
      tester.view.physicalSize = const Size(1180, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(_opener()));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final sheet = find.ancestor(of: find.text('In the sheet'), matching: find.byType(Material)).first;
      expect(tester.getSize(sheet).width, 560);
      expect(tester.getCenter(sheet).dx, closeTo(590, 0.5));
      expect(tester.getCenter(sheet).dy, closeTo(410, 0.5));
    });

    testWidgets('under Reduce Motion it fades in place and never slides', (tester) async {
      await _phone(tester);
      await tester.pumpWidget(_app(_opener(), reduced: true));
      await tester.tap(find.text('Open'));
      await tester.pump();
      final first = tester.getTopLeft(find.text('In the sheet')).dy;
      final fade = tester.widget<FadeTransition>(
        find.ancestor(of: find.text('In the sheet'), matching: find.byType(FadeTransition)).first,
      );
      expect(fade.opacity.value, lessThan(1));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.getTopLeft(find.text('In the sheet')).dy, first);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('In the sheet')).dy, first);
      expect(fade.opacity.value, 1);

      await tester.tapAt(const Offset(20, 40));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.getTopLeft(find.text('In the sheet')).dy, first);
      await tester.pumpAndSettle();
      expect(find.text('In the sheet'), findsNothing);
    });
  });

  group('inline changes', () {
    testWidgets('a reveal grows on the spring', (tester) async {
      var visible = false;
      late StateSetter setVisible;
      await tester.pumpWidget(_app(StatefulBuilder(builder: (context, setState) {
        setVisible = setState;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [DenReveal(visible: visible, child: const SizedBox(key: _box, height: 100, width: 100))],
        );
      })));
      expect(tester.getSize(find.byType(DenReveal)).height, 0);
      setVisible(() => visible = true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final growing = tester.getSize(find.byType(DenReveal)).height;
      expect(growing, inExclusiveRange(0, 100));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(DenReveal)).height, closeTo(100, 0.5));
    });

    testWidgets('under Reduce Motion a reveal takes its size at once and only fades', (tester) async {
      var visible = false;
      late StateSetter setVisible;
      await tester.pumpWidget(_app(
        StatefulBuilder(builder: (context, setState) {
          setVisible = setState;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [DenReveal(visible: visible, child: const SizedBox(key: _box, height: 100, width: 100))],
          );
        }),
        reduced: true,
      ));
      setVisible(() => visible = true);
      await tester.pump();
      expect(tester.getSize(find.byType(DenReveal)).height, 100);
      await tester.pump(const Duration(milliseconds: 50));
      final fade = tester.widget<FadeTransition>(
        find.descendant(of: find.byType(DenReveal), matching: find.byType(FadeTransition)),
      );
      expect(fade.opacity.value, inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      expect(fade.opacity.value, 1);
    });

    testWidgets('a crossfade swaps one state for the other', (tester) async {
      var done = false;
      late StateSetter setDone;
      await tester.pumpWidget(_app(StatefulBuilder(builder: (context, setState) {
        setDone = setState;
        return DenCrossfade(
          child: done
              ? const Text('You’re driving Leo', key: ValueKey('done'))
              : const Text('Nobody is driving Leo', key: ValueKey('open')),
        );
      })));
      setDone(() => done = true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('Nobody is driving Leo'), findsOneWidget);
      expect(find.text('You’re driving Leo'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Nobody is driving Leo'), findsNothing);
    });
  });
}
