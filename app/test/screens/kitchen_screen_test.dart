import 'package:den_app/features/kitchen_screen/kitchen_screen.dart';
import 'package:den_app/features/advanced/screens/displays_screen.dart';
import 'package:den_app/platform/sync/pairing.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';

/// Kitchen screens that join with a code: the tablet showing it, and a parent's phone typing it
/// (Settings, Kitchen screen, Add a screen) and saying Add.

/// A screen showing K7QM-3RXA at the family's hub, with nine minutes left.
class FakeScreenCode extends ScreenCodeSession {
  FakeScreenCode({this.stage = ScreenStage.waiting, this.error});

  @override
  ScreenStage stage;

  @override
  String? error;

  @override
  String get code => 'K7QM3RXA';

  @override
  Uri get hub => Uri.parse('https://den.example.com');

  @override
  int get expires => demoNow.add(const Duration(minutes: 9)).millisecondsSinceEpoch;

  @override
  Future<void> cancel() async {}
}

const _ipad = ScreenAsk(
  name: 'Kitchen iPad',
  kind: DeviceKind.tablet,
  device: 'TABLETDEVICEID',
  pubkey: 'pubkey',
  xpub: 'xpub',
  code: 'K7QM3RXA',
  expires: 0,
);

/// A parent's phone talking to the hub: finds the iPad under K7QM3RXA and adds it.
class ScreenPairing extends LocalOnlyPairing {
  ScreenPairing();

  final List<String> found = [];
  final List<(String, String)> added = [];

  @override
  Future<ScreenAsk> findScreen(String code) async {
    found.add(code);
    if (code != 'K7QM3RXA') {
      throw const PairingException("That code isn't right, or it ran out. Check the code on the screen and try again.");
    }
    return _ipad;
  }

  @override
  Future<void> addScreen(ScreenAsk screen, {required String name}) async => added.add((screen.device, name));
}

void main() {
  group('on the tablet', () {
    for (final night in [false, true]) {
      testWidgets('shows its code big, and the same as a QR code${night ? ', at night' : ''}', (tester) async {
        final state = await empty(tester);
        await pumpScreen(
          tester,
          ScreenCodeScreen(session: FakeScreenCode(), now: () => demoNow),
          state: state,
          size: tablet,
          night: night,
        );
        expect(find.text('K7QM-3RXA'), findsOneWidget);
        expect(
          find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'K 7 Q M, 3 R X A'),
          findsOneWidget,
          reason: 'read out one character at a time',
        );
        expect(findWords('Works for 9 more minutes'), findsOneWidget);
        expect(findWords('Waiting for a parent to type it'), findsOneWidget);
        await matchShot(night ? 'kitchen_screen_code_pad_dark' : 'kitchen_screen_code_pad');
      });
    }

    testWidgets('fits on a phone-sized screen too', (tester) async {
      final state = await empty(tester);
      await pumpScreen(tester, ScreenCodeScreen(session: FakeScreenCode(), now: () => demoNow), state: state);
      expect(find.text('K7QM-3RXA'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a code that ran out offers a new one', (tester) async {
      final state = await empty(tester);
      await pumpScreen(tester, ScreenCodeScreen(session: FakeScreenCode(stage: ScreenStage.expired), now: () => demoNow), state: state, size: tablet);
      expect(find.text('This code ran out.'), findsOneWidget);
      expect(find.text('Get a new code'), findsOneWidget);
      expect(find.text('K7QM-3RXA'), findsNothing);
    });

    testWidgets('once a parent added it, it says so and hides the code', (tester) async {
      final state = await empty(tester);
      await pumpScreen(tester, ScreenCodeScreen(session: FakeScreenCode(stage: ScreenStage.joining), now: () => demoNow), state: state, size: tablet);
      expect(findWords('A parent added this screen. Joining the family'), findsOneWidget);
      expect(find.text('K7QM-3RXA'), findsNothing);
    });

    testWidgets('outside a browser, it asks for the family\'s Den address first', (tester) async {
      final state = await empty(tester);
      await pumpScreen(tester, const ScreenCodeScreen(browser: false), state: state, size: tablet);
      expect(find.text("Your family's Den address"), findsOneWidget);
      expect(find.text('Show the code'), findsOneWidget);
    });
  });

  group("on a parent's phone", () {
    testWidgets('the code step: types the way the screen shows it', (tester) async {
      final state = await demo(tester);
      final pairing = ScreenPairing();
      await pumpScreen(tester, const AddScreenScreen(scan: false), state: state, pairing: pairing, pushed: true);
      await tester.enterText(find.byType(TextField), 'k7qm 3rxa');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'K7QM-3RXA',
          reason: 'upper case, one dash, whatever was typed');
      await matchShot('add_screen_code_phone');
    });

    testWidgets('one question with a name she can change, then Add, approved on her phone', (tester) async {
      final state = await demo(tester);
      final pairing = ScreenPairing();
      await pumpScreen(tester, const AddScreenScreen(scan: false), state: state, pairing: pairing, pushed: true);
      await tester.enterText(find.byType(TextField), 'K7QM-3RXA');
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(pairing.found, ['K7QM3RXA']);
      expect(find.text('Add Kitchen iPad as a kitchen screen?'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Kitchen');
      await tester.pumpAndSettle();
      expect(find.text('Add Kitchen as a kitchen screen?'), findsOneWidget);
      await tester.tap(find.text('Add Kitchen'));
      await tester.pumpAndSettle();
      expect(pairing.added, [('TABLETDEVICEID', 'Kitchen')]);
      expect(find.text('Kitchen is a kitchen screen now'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('a wrong code says so, and nothing is added', (tester) async {
      final state = await demo(tester);
      final pairing = ScreenPairing();
      await pumpScreen(tester, const AddScreenScreen(scan: false), state: state, pairing: pairing, pushed: true);
      await tester.enterText(find.byType(TextField), 'K7QM-3RXB');
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.textContaining("That code isn't right"), findsOneWidget);
      expect(pairing.added, isEmpty);

      await tester.enterText(find.byType(TextField), 'K7QM');
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.textContaining(RegExp(r'8\sletters\sand\snumbers')), findsOneWidget);
    });

    testWidgets('opens with an empty code and asks the hub nothing until she types one', (tester) async {
      final state = await demo(tester);
      final pairing = ScreenPairing();
      await pumpScreen(tester, const AddScreenScreen(scan: false), state: state, pairing: pairing, pushed: true);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
      expect(pairing.found, isEmpty, reason: 'no link fills in a code or looks one up');
    });

    test("a screen's QR code is for Den's own scanner, not a link anyone can send", () {
      final qr = FakeScreenCode().qr;
      expect(qr, 'den://screen/K7QM3RXA');
      expect(qr, isNot(contains('http')));
    });

    testWidgets('the question', (tester) async {
      final state = await demo(tester);
      await shootWith(tester, 'add_screen_confirm_phone', const AddScreenScreen(found: _ipad, scan: false),
          state: state, pairing: ScreenPairing(), pushed: true);
    });

    testWidgets('done', (tester) async {
      final state = await demo(tester);
      await shootWith(tester, 'add_screen_done_phone', const AddScreenScreen(found: _ipad, added: true, scan: false),
          state: state, pairing: ScreenPairing(), pushed: true);
      expect(find.text('Kitchen iPad is a kitchen screen now'), findsOneWidget);
    });

    testWidgets('Kitchen screen offers Add a screen first, an invite link second', (tester) async {
      final state = await demo(tester);
      await pumpScreen(tester, const DisplaysScreen(), state: state, pushed: true);
      expect(find.text('Add a screen'), findsOneWidget);
      expect(find.text('Send it an invite link instead'), findsOneWidget);
    });

    testWidgets('a shared screen is not where screens are added', (tester) async {
      final state = await kitchen(tester);
      await pumpScreen(tester, const AddScreenScreen(scan: false), state: state, pairing: ScreenPairing());
      expect(findWords("Kitchen screens are added on a parent's own phone."), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });
  });
}
