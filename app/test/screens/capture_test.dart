import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:den_app/features/add/state/capture_controller.dart';
import 'package:den_app/features/add/state/capture_service.dart';
import 'package:den_app/features/add/state/capture_settings.dart';
import 'package:den_app/platform/capture/capture_sources.dart';
import 'package:den_app/platform/capture/platform_capture.dart';
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/features/add/screens/capture_screen.dart';
import 'package:den_app/features/advanced/screens/connections_screen.dart';
import 'package:den_app/app/app_state.dart';
import 'package:den_capture/den_capture.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

CaptureService serviceFor({List<CaptureReader>? readers, CaptureSettings? settings, HubCaptureClient? hub}) => CaptureService(
      settings: settings ?? CaptureSettings(secrets: MemoryCaptureSecrets()),
      platform: const FlyerPhone(),
      sources: FakeSources(),
      readers: readers,
      hubClient: hub,
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

  group('The family\'s hub', () {
    const claudeOnHub = {
      'kind': 'claude',
      'reader': {
        'id': 'claude',
        'name': 'Claude',
        'place': 'provider',
        'inputs': ['text', 'image', 'pdf'],
        'history_name': 'Claude',
      },
      'device_first': true,
      'model': 'claude-opus-5-5',
      'address': null,
      'key_saved': true,
    };

    /// A hub that answers with [status] and keeps what it was asked to save.
    (HubCaptureClient, List<Map<String, Object?>>) fakeHub(Map<String, Object?> status) {
      final saved = <Map<String, Object?>>[];
      var current = status;
      final client = MockClient((r) async {
        if (r.method == 'PUT') {
          final body = jsonDecode(r.body) as Map<String, Object?>;
          saved.add(body);
          current = {
            'kind': body['kind'],
            'reader': body['kind'] == 'home'
                ? {'id': 'home', 'name': 'Home model', 'place': 'home', 'inputs': ['text'], 'history_name': 'the home model'}
                : null,
            'device_first': body['device_first'],
            'model': body['model'],
            'address': body['address'],
            'key_saved': false,
          };
        }
        return http.Response(jsonEncode(current), 200);
      });
      return (
        HubCaptureClient(bases: () => [Uri.parse('http://192.168.1.20:47733')], sign: (m, u, b) async => {'x-den-device': 'PHONE'}, client: client),
        saved,
      );
    }

    /// The demo family with a hub approved by Alex's phone.
    Future<AppState> withHub(WidgetTester tester) => real(tester, () async {
          final state = await demoState();
          final hub = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: () => demoNow.millisecondsSinceEpoch);
          await hub.requestJoin(
            familyId: state.den.familyId!,
            founderPubkey: state.den.founderPubkey!,
            deviceName: 'Closet hub',
            kind: DeviceKind.hub,
            mode: DeviceMode.hub,
          );
          await state.den.ingest(hub.changesSince(const {}));
          await state.den.approveDevice(hub.deviceId, mode: DeviceMode.hub);
          await hub.close();
          return state;
        });

    testWidgets('Claude set up once on the hub, for every device', (tester) async {
      final state = await withHub(tester);
      final (client, _) = fakeHub(claudeOnHub);
      Capture.service = serviceFor(hub: client);
      await pumpScreen(tester, const ConnectionsScreen(), state: state, size: tallPhone);
      expect(find.text('Claude on the hub'), findsOneWidget);
      expect(find.text('API key saved on the hub'), findsOneWidget);
      await matchShot('settings_capture_hub_phone');
    });

    testWidgets('a parent points the hub at a model at home', (tester) async {
      final state = await withHub(tester);
      final (client, saved) = fakeHub(HubReaderStatus.none.toJson());
      Capture.service = serviceFor(hub: client);
      await pumpScreen(tester, const ConnectionsScreen(), state: state, size: tallPhone);
      expect(find.text('Nothing on the hub yet'), findsOneWidget);
      await tester.tap(find.text('A model at home').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Address the hub reaches it at'), '127.0.0.1:11434');
      await tester.tap(find.text('Save on the hub'));
      await tester.pumpAndSettle();
      expect(saved.single, {'kind': 'home', 'address': '127.0.0.1:11434', 'device_first': true});
      expect(find.text('Home model on the hub'), findsOneWidget);
    });

    testWidgets('without a hub there is nothing to set up there', (tester) async {
      final state = await demoIn(tester);
      final (client, _) = fakeHub(claudeOnHub);
      Capture.service = serviceFor(hub: client);
      await pumpScreen(tester, const ConnectionsScreen(), state: state, size: tallPhone);
      expect(find.text('The family\'s hub'), findsNothing);
    });

    testWidgets('the hub reads after the device unless the family put it first', (tester) async {
      Future<List<String>> order(Map<String, Object?> status, {CaptureSettings? settings}) async {
        final (client, _) = fakeHub(status);
        final readers = await tester.runAsync(serviceFor(hub: client, settings: settings).readers);
        return [for (final r in readers!) r.info.id];
      }

      expect(await order(claudeOnHub), ['rules', 'hub']);
      expect(await order({...claudeOnHub, 'device_first': false}), ['hub', 'rules']);
      expect(await order(HubReaderStatus.none.toJson()), ['rules']);
      final own = CaptureSettings(secrets: MemoryCaptureSecrets('sk-ant-test'), reader: ReaderChoice.claude, hasClaudeKey: true);
      expect(await order(claudeOnHub, settings: own), ['rules', 'claude', 'hub']);
    });

    testWidgets('while reading, it says the hub may help', (tester) async {
      final state = await demoIn(tester);
      final (client, _) = fakeHub(claudeOnHub);
      final service = serviceFor(hub: client);
      await tester.runAsync(() => service.hub!.refresh());
      Capture.service = service;
      final c = CaptureController(service: service, den: state.den, input: CaptureInput.shared(files: [flyerPhoto]));
      await loadFonts();
      await tester.pumpWidget(
        DenScope(
          state: state,
          child: MaterialApp(debugShowCheckedModeBanner: false, theme: denTheme(DenColors.day), home: CaptureScreen(controller: c)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('On this device first, then Claude on the hub if it needs help.'), findsOneWidget);
    });
  });

  group('Sharing into Den', () {
    test('what the share sheet hands over becomes something to read', () {
      final shared = SharedThing.fromMap({
        'text': null,
        'subject': 'Tigers schedule',
        'files': [
          {'bytes': Uint8List.fromList(const [1, 2]), 'mimeType': null, 'name': 'Screenshot 2026-10-16.png'},
          {'bytes': 'not bytes', 'mimeType': 'image/png', 'name': 'broken.png'},
        ],
      });
      expect(shared.files.single.mimeType, 'image/png');
      expect(shared.input.kind, CaptureKind.screenshot);
      expect(shared.input.subject, 'Tigers schedule');
    });

    test('a share that arrives while Den is starting waits for it', () async {
      Capture.waiting.clear();
      Capture.deliver(CaptureInput.typed('milk'));
      expect((Capture.waiting.single as CaptureInput).text, 'milk');
      final heard = <Object>[];
      final sub = Capture.inbox.stream.listen(heard.add);
      Capture.deliver(CaptureInput.typed('eggs'));
      await Future<void>.delayed(Duration.zero);
      expect((heard.single as CaptureInput).text, 'eggs');
      await sub.cancel();
      Capture.waiting.clear();
    });

    testWidgets("a share Den couldn't open says so instead of doing nothing", (tester) async {
      final state = await demoIn(tester);
      await shootAt(
        tester,
        'capture_share_unreadable_phone',
        state: state,
        location: '/today',
        act: () async {
          final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
          router.push('/capture', extra: const CaptureProblem("Den couldn't open what was shared. Try sharing it again, or choose it from Add."));
        },
      );
      expect(find.textContaining("Den couldn't open what was shared."), findsOneWidget);
    });

    test('a shared page is read as its words', () {
      expect(
        pageWords('<html><head><title>x</title><script>var a=1;</script></head><body><h1>Spirit week</h1>'
            '<p>Pajama day is Monday&nbsp;Oct 19.</p><style>p{}</style></body></html>'),
        'Spirit week\nPajama day is Monday Oct 19.',
      );
    });
  });

  testWidgets('the sample flyer the end-to-end tests photograph', (tester) async {
    final state = await demoIn(tester);
    await shoot(tester, 'capture_sample_flyer', const _Flyer(), state: state);
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

/// Oak Grove's fall flyer as a parent would photograph it: the same words as
/// ixtures/flyer_ocr.txt, which is what the phone's text recognition returns for it.
class _Flyer extends StatelessWidget {
  const _Flyer();

  @override
  Widget build(BuildContext context) {
    final blocks = fixture('flyer_ocr.txt').trim().split(RegExp(r'\n\s*\n'));
    const ink = Color(0xFF1B3A5C);
    TextStyle style(double size, {bool bold = false}) =>
        TextStyle(fontFamily: DenType.family, fontSize: size, height: 1.3, color: ink, fontWeight: bold ? FontWeight.w700 : FontWeight.w400);
    return Container(
      color: const Color(0xFFE9E4D8),
      padding: const EdgeInsets.all(18),
      child: Container(
        decoration: BoxDecoration(color: const Color(0xFFFFFDF6), border: Border.all(color: const Color(0xFFD9822B), width: 6)),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, block) in blocks.indexed) ...[
              for (final (j, line) in block.split('\n').indexed)
                Text(
                  line,
                  textAlign: i == 0 ? TextAlign.center : TextAlign.left,
                  style: i == 0
                      ? style(j == 0 ? 24 : 15, bold: j == 0)
                      : style(j == 0 && line == line.toUpperCase() ? 19 : 14, bold: j == 0),
                ),
              const SizedBox(height: 14),
            ],
          ],
        ),
      ),
    );
  }
}
