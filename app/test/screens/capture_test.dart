import 'dart:io';
import 'dart:typed_data';

import 'package:den_app/capture/capture_controller.dart';
import 'package:den_app/capture/capture_service.dart';
import 'package:den_app/capture/capture_settings.dart';
import 'package:den_app/capture/capture_sources.dart';
import 'package:den_app/capture/platform_capture.dart';
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/screens/capture/capture_screen.dart';
import 'package:den_app/screens/settings/connections_screen.dart';
import 'package:den_app/state/app_state.dart';
import 'package:den_capture/den_capture.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/shots.dart';
import 'calendar_shots.dart' show shootAt, tallPhone, write;
import 'family_fakes.dart' show matchShot, pumpScreen, real;

/// The recorded fixtures den_capture's own tests read.
String fixture(String name) => File('../packages/den_capture/test/fixtures/$name').readAsStringSync();

final flyerPhoto = CaptureFile(Uint8List.fromList(const [0xff, 0xd8, 0xff, 0xe0]), 'image/jpeg', name: 'IMG_4471.jpg');

/// A phone that finds the flyer's text in any photo, the way Vision or ML Kit would.
class FlyerPhone extends PlatformCapture {
  const FlyerPhone();
  @override
  Future<DeviceAbilities> abilities() async => const DeviceAbilities(text: true);
  @override
  Future<String?> findText(CaptureFile file) async => fixture('flyer_ocr.txt');
  @override
  Future<Uint8List?> toJpeg(Uint8List bytes, {int maxSide = 2000}) async => null;
}

class FakeSources implements CaptureSources {
  @override
  bool get canSnap => true;
  @override
  bool get canSpeak => true;
  @override
  Future<CaptureFile?> snap() async => flyerPhoto;
  @override
  Future<CaptureFile?> pick() async => flyerPhoto;
  @override
  Future<String?> listen({required void Function(String words) onWords}) async {
    onWords('soccer every Wednesday');
    return 'soccer every Wednesday at 5 for Leo';
  }

  @override
  Future<void> stopListening() async {}
}

CaptureService serviceFor({List<CaptureReader>? readers, CaptureSettings? settings}) => CaptureService(
      settings: settings ?? CaptureSettings(secrets: MemoryCaptureSecrets()),
      platform: const FlyerPhone(),
      sources: FakeSources(),
      readers: readers,
    );

/// The coach's email, as Claude read it in den_capture's recorded response.
CaptureResult emailResult(AppState state) {
  final draft = draftFor(
    state.den,
    ClaudeReader.parse(200, fixture('claude_email.json')),
    const CaptureOrigin(CaptureKind.email, reader: 'Claude'),
  );
  return CaptureResult(
    draft: draft,
    reader: ClaudeReader(apiKey: 'k').info,
    read: 'Tigers U10: fall schedule and snack sign-up\n\nPractice moves to Tuesdays and Thursdays 5:30 to 7 at Riverside Park, Field 4.',
  );
}

const emailInput = CaptureInput(kind: CaptureKind.email, text: 'Practice moves to Tuesdays and Thursdays 5:30 to 7.');

/// Lets the engine finish signing on the real clock, then the screen catch up.
Future<void> settle(WidgetTester tester, CaptureController c) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 250 && (c.busy || c.stage == CaptureStage.reading); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  });
  await tester.pumpAndSettle();
}

Future<void> setReview(WidgetTester tester, AppState state, bool review) =>
    write(tester, () => state.den.updateFamily({'capture': review ? 'review' : 'direct'}));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Capture.service = serviceFor(readers: const [RulesReader()]);
  });

  group('The Add sheet', () {
    testWidgets('type, snap or say, over the one-thing choices', (tester) async {
      final state = await demoIn(tester);
      await shootAt(tester, 'capture_add_sheet_phone', state: state, location: '/today', act: () => tester.tap(find.text('Add')));
    });

    testWidgets('night', (tester) async {
      final state = await demoIn(tester);
      await shootAt(
        tester,
        'capture_add_sheet_phone_night',
        state: state,
        location: '/today',
        night: true,
        act: () async {
          await tester.tap(find.text('Add'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), 'Leo has soccer every Wednesday at 5');
        },
      );
    });

    testWidgets('what was said fills the field, and sending reads it', (tester) async {
      final state = await demoIn(tester);
      await setReview(tester, state, true);
      await shootAt(
        tester,
        'capture_said_review_phone',
        state: state,
        location: '/today',
        act: () async {
          await tester.tap(find.text('Add'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Say it'));
          await tester.pumpAndSettle();
          expect(find.text('soccer every Wednesday at 5 for Leo'), findsOneWidget);
          await tester.tap(find.byTooltip('Read it'));
          await tester.pumpAndSettle();
          expect(find.text('From what you said'), findsOneWidget);
          expect(find.text('Soccer'), findsOneWidget);
          expect(find.text('Add 1 thing'), findsOneWidget);
        },
      );
    });

  });

  group('Review', () {
    testWidgets('a coach\'s email read by Claude, shown first', (tester) async {
      final state = await demoIn(tester);
      await setReview(tester, state, true);
      final c = CaptureController(service: Capture.service, den: state.den, input: emailInput, result: emailResult(state));
      await pumpScreen(tester, CaptureScreen(controller: c), state: state, size: tallPhone);
      expect(find.text('Add 4 things'), findsOneWidget);
      expect(find.text('No one in the family is called Coach Dan'), findsOneWidget);
      await matchShot('capture_review_phone');
    });

    testWidgets('night', (tester) async {
      final state = await demoIn(tester);
      await setReview(tester, state, true);
      final c = CaptureController(service: Capture.service, den: state.den, input: emailInput, result: emailResult(state));
      await pumpScreen(tester, CaptureScreen(controller: c), state: state, night: true);
      await matchShot('capture_review_phone_night');
    });

    testWidgets('tablet', (tester) async {
      final state = await demoIn(tester);
      await setReview(tester, state, true);
      final c = CaptureController(service: Capture.service, den: state.den, input: emailInput, result: emailResult(state));
      await pumpScreen(tester, CaptureScreen(controller: c), state: state, size: tablet);
      await matchShot('capture_review_tablet');
    });

    testWidgets('editing an entry: the game with a name nobody has', (tester) async {
      final state = await demoIn(tester);
      await setReview(tester, state, true);
      final c = CaptureController(service: Capture.service, den: state.den, input: emailInput, result: emailResult(state));
      await pumpScreen(tester, CaptureScreen(controller: c), state: state, size: tallPhone);
      await tester.tap(find.text('Soccer game vs. the Hawks'));
      await tester.pumpAndSettle();
      await matchShot('capture_edit_event_phone');
      await tester.tap(find.text('Save event'));
      await tester.pumpAndSettle();
      expect(find.text('No one in the family is called Coach Dan'), findsNothing);
      expect(find.text('Add 5 things'), findsOneWidget);
    });

    testWidgets('choosing and adding writes through the engine, marked as from an email; Undo takes it back', (tester) async {
      final state = await demoIn(tester);
      await setReview(tester, state, true);
      final c = CaptureController(service: Capture.service, den: state.den, input: emailInput, result: emailResult(state));
      await pumpScreen(tester, CaptureScreen(controller: c), state: state, size: tallPhone);
      await tester.tap(find.text('Add 4 things'));
      await settle(tester, c);
      expect(find.text('Added 4 things'), findsOneWidget);
      final den = state.den;
      expect(den.events.where((e) => e.title == 'Soccer practice' && e.rrule == 'FREQ=WEEKLY;BYDAY=TU,TH'), hasLength(2));
      final added = den.history(limit: 10).where((h) => h.from != null).toList();
      expect(added, hasLength(4));
      expect(added.every((h) => h.from == const CaptureOrigin(CaptureKind.email, reader: 'Claude')), isTrue);
      await matchShot('capture_added_phone');

      await tester.tap(find.text('Undo'));
      await settle(tester, c);
      expect(find.text('Add 4 things'), findsNothing, reason: 'nothing is chosen again after Undo');
      expect(den.events.where((e) => e.title == 'Soccer practice'), hasLength(1));
    });
  });

  group('Direct', () {
    testWidgets('a photo of the school flyer: added right away, with Undo', (tester) async {
      final state = await demoIn(tester);
      final c = CaptureController(
        service: serviceFor(readers: const [RulesReader()]),
        den: state.den,
        input: CaptureInput.shared(files: [flyerPhoto]),
      );
      await real(tester, c.start);
      expect(c.stage, CaptureStage.ready);
      await pumpScreen(tester, CaptureScreen(controller: c), state: state);
      expect(find.text('Added 6 things'), findsOneWidget);
      expect(find.text('Fall Soccer Clinic'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^Sat, Oct 24 · 9:00\sAM to 10:30\sAM · Every Saturday')), findsOneWidget);
      await matchShot('capture_direct_flyer_phone');
    });

    testWidgets('what needs a look waits; the rest is added', (tester) async {
      final state = await demoIn(tester);
      final c = CaptureController(service: Capture.service, den: state.den, input: emailInput, result: emailResult(state));
      await real(tester, c.start);
      await pumpScreen(tester, CaptureScreen(controller: c), state: state, size: tallPhone);
      expect(find.text('Added 4 things'), findsOneWidget);
      expect(find.text('Soccer game vs. the Hawks'), findsOneWidget);
      await matchShot('capture_direct_mixed_phone');
    });
  });

  group('Reading and failing', () {
    testWidgets('while reading', (tester) async {
      final state = await demoIn(tester);
      final c = CaptureController(service: Capture.service, den: state.den, input: CaptureInput.shared(files: [flyerPhoto]));
      await loadFonts();
      tester.view.physicalSize = phone;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        DenScope(
          state: state,
          child: MaterialApp(debugShowCheckedModeBanner: false, theme: denTheme(DenColors.day), home: CaptureScreen(controller: c)),
        ),
      );
      // The spinner never settles; one frame part way through is the picture.
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Reading the photo'), findsOneWidget);
      expect(find.text('Nothing leaves this device.'), findsOneWidget);
      await matchShot('capture_reading_phone');
    });

    testWidgets('a photo this device can\'t read says what a parent can do', (tester) async {
      final state = await demoIn(tester);
      final service = CaptureService(
        settings: CaptureSettings(secrets: MemoryCaptureSecrets()),
        platform: const PlatformCapture(),
        sources: FakeSources(),
        readers: const [RulesReader()],
      );
      final c = CaptureController(service: service, den: state.den, input: CaptureInput.shared(files: [flyerPhoto]));
      await real(tester, c.start);
      expect(c.stage, CaptureStage.failed);
      await pumpScreen(tester, CaptureScreen(controller: c), state: state);
      expect(find.textContaining('This device can\'t read photos on its own.'), findsOneWidget);
      await matchShot('capture_failed_phone');
    });
  });

  group('Settings', () {
    testWidgets('AI and automations: reading what you share, with Claude', (tester) async {
      final state = await demoIn(tester);
      final settings = CaptureSettings(secrets: MemoryCaptureSecrets('sk-ant-test'), reader: ReaderChoice.claude, hasClaudeKey: true);
      Capture.service = serviceFor(settings: settings);
      await pumpScreen(tester, const ConnectionsScreen(), state: state, size: tallPhone);
      expect(find.text('API key saved on this device'), findsOneWidget);
      await matchShot('settings_capture_claude_phone');
      final readers = await tester.runAsync(Capture.service.readers);
      expect([for (final r in readers!) r.info.id], ['rules', 'claude']);
    });

    testWidgets('choosing "Show me first" sets the family to review', (tester) async {
      final state = await demoIn(tester);
      await pumpScreen(tester, const ConnectionsScreen(), state: state, size: tallPhone);
      await tester.runAsync(() async {
        await tester.tap(find.text('Show me first'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      expect(state.den.family!.captureNeedsReview, isTrue);
      await matchShot('settings_capture_device_phone');
    });

    testWidgets('a parent choosing Claude first, without the device', (tester) async {
      final settings = CaptureSettings(secrets: MemoryCaptureSecrets('sk-ant-test'), reader: ReaderChoice.claude, deviceFirst: false, hasClaudeKey: true);
      final readers = await tester.runAsync(serviceFor(settings: settings).readers);
      expect([for (final r in readers!) r.info.id], ['claude', 'rules']);
      settings.reader = ReaderChoice.home;
      settings.homeAddress = '192.168.1.20';
      final home = await tester.runAsync(serviceFor(settings: settings).readers);
      expect([for (final r in home!) r.info.id], ['home', 'rules']);
    });
  });

  testWidgets('History says where things came from', (tester) async {
    final state = await demoIn(tester);
    await write(tester, () async {
      final c = CaptureController(service: serviceFor(readers: const [RulesReader()]), den: state.den, input: CaptureInput.shared(files: [flyerPhoto]));
      await c.start();
    });
    await shootAt(tester, 'history_capture_phone', state: state, location: '/history');
    expect(find.textContaining('from a photo'), findsWidgets);
  });
}
