import 'dart:convert';

import 'package:den_actions/assistant.dart' show assistantTools;
import 'package:den_actions/den_actions.dart' show ActionContext, Surface, standardRunner;
import 'package:den_app/app/app_state.dart' hide Receipt;
import 'package:den_app/features/add/add.dart' show Capture;
import 'package:den_app/features/add/screens/add_sheet.dart' show AddSheet;
import 'package:den_app/features/assistant/assistant.dart';
import 'package:den_app/features/assistant/screens/ask_screen.dart';
import 'package:den_app/features/assistant/state/ask_chats.dart';
import 'package:den_app/features/assistant/state/ask_session.dart';
import 'package:den_app/features/assistant/state/snapshot.dart';
import 'package:den_app/features/assistant/words/assistant_words.dart';
import 'package:den_assistant/den_assistant.dart';
import 'package:den_assistant/testing.dart';
import 'package:den_capture/den_capture.dart' show RulesReader;
import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/shots.dart';
import 'calendar_shots.dart' show shootAt, tallPhone, write;
import 'capture_test.dart' show openAdd, serviceFor;
import 'family_fakes.dart' show matchShot, pumpScreen, real;

/// What the hub says for a parent with Claude set up.
const claude = HelperStatus(
  provider: ModelProvider.anthropic,
  speaker: 'Claude',
  models: ['claude-haiku-5-5', 'claude-sonnet-5-5'],
  allowed: true,
  month: '2026-10',
);

/// The helper's link, with a scripted model in place of the hub.
class FakeLink implements HelperLink {
  FakeLink(this.chat, {this.answer = claude});

  final ChatModel chat;
  HelperStatus answer;
  int asked = 0;

  @override
  Future<HelperStatus> status() async {
    asked++;
    return answer;
  }

  @override
  Future<ChatModel> model(HelperStatus status) async => chat;
}

/// The hub's model proxy, faked at the HTTP level: the real Claude adapter sends its request to
/// `/api/v1/assistant/model` and gets back the hub's refusal ([status] with the hub's error body).
class ProxyLink implements HelperLink {
  ProxyLink(this.statusCode, this.code, this.message, {this.answer = claude});

  final int statusCode;
  final String code;
  final String message;
  final HelperStatus answer;
  final List<http.Request> requests = [];

  @override
  Future<HelperStatus> status() async => answer;

  @override
  Future<ChatModel> model(HelperStatus status) async => chatModelFor(
        status.provider!,
        model: status.model,
        endpoint: ModelEndpoint.hub(
          Uri.parse('http://hub.test/api/v1/assistant/model'),
          sign: (method, url, body) async => {'x-den-device': 'test-device'},
        ),
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({
              'error': {'code': code, 'message': message},
            }),
            statusCode,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
}

/// Turns the AI helper on for the family (parents), and for [members].
Future<void> helperOnFor(WidgetTester tester, Den den, {Set<String> members = const {}}) =>
    write(tester, () => den.updateFamily({'assistant': AssistantPolicy(enabled: true, members: members).toJson()}));

/// Maya's own phone (a teen), in a family where the helper is on for parents and, when
/// [allowed], for her; with [on] false it is off for the whole family.
Future<AppState> kidPhone(WidgetTester tester, {required bool allowed, bool on = true}) => real(tester, () async {
      final parent = await createDemoFamily(now: demoNow);
      final maya = parent.members.firstWhere((m) => m.name == 'Maya');
      await parent.updateFamily({
        'assistant': AssistantPolicy(enabled: on, members: allowed ? {maya.id} : const {}).toJson(),
      });
      final own = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: () => demoNow.millisecondsSinceEpoch);
      await own.requestJoin(
        familyId: parent.familyId!,
        founderPubkey: parent.founderPubkey!,
        deviceName: "Maya's phone",
        kind: DeviceKind.phone,
        memberId: maya.id,
      );
      await parent.ingest(own.changesSince(parent.versionVector));
      await parent.approveDevice(own.deviceId, member: maya.id);
      await own.ingest(
        parent.changesSince(own.versionVector, spaces: parent.spacesForDevice(own.deviceId)),
        through: parent.completeVector,
      );
      return AppState(own);
    });

/// The session Ask is showing: a test's own, or the one the device keeps.
AskSession? shownSession(WidgetTester tester) {
  final screens = find.byType(AskScreen);
  if (screens.evaluate().isEmpty) return null;
  final screen = tester.widget<AskScreen>(screens.first);
  return screen.session ?? screen.request?.session ?? AskChats.of(DenScope.read(tester.element(screens.first))).current;
}

/// Lets the helper's turn finish on the real clock (the engine signs what it writes), then the
/// screen catch up.
Future<void> settleAsk(WidgetTester tester) async {
  for (var i = 0; i < 200; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    final s = shownSession(tester);
    if (s != null && !s.busy && s.exchanges.isNotEmpty && !s.exchanges.last.working) break;
  }
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await tester.pumpAndSettle();
}

/// Taps [finder] on the real clock and waits for what it starts.
Future<void> tapAsk(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await settleAsk(tester);
}

/// Types [words] into the Add sheet's own field (Today's groceries field is behind it) and waits
/// for Den's reader.
Future<void> typeInSheet(WidgetTester tester, String words) async {
  await tester.enterText(find.descendant(of: find.byType(AddSheet), matching: find.byType(TextField)), words);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// Opens Add: the tab bar's round button on a phone, the sidebar's pill on an iPad.
Future<void> openAddAnywhere(WidgetTester tester) async {
  if (find.byTooltip('Add').evaluate().isNotEmpty) {
    await openAdd(tester);
    return;
  }
  await tester.tap(find.text('Add').first);
  await tester.pumpAndSettle();
}

/// Types [words] into Add, then sends them to the helper with Ask.
Future<void> askFromAdd(WidgetTester tester, String words) async {
  await openAddAnywhere(tester);
  await typeInSheet(tester, words);
  // Add's own Ask (the iPad's sidebar has an "Ask" too).
  final ask = find.descendant(of: find.byType(AddSheet), matching: find.text('Ask'));
  expect(ask, findsOneWidget);
  await tester.tap(ask);
  await tester.pumpAndSettle();
  await settleAsk(tester);
}

/// The dentist moved to Tuesday at 4 and lemons on the groceries, in one request.
ScriptedChatModel twoChanges() => ScriptedChatModel([
      ScriptedChatModel.calls([
        ScriptedChatModel.toolCall('c1', 'update_event', {'event': 'Dentist', 'start': '2026-10-20T16:00', 'end': '2026-10-20T17:00'}),
        ScriptedChatModel.toolCall('c2', 'add_items', {
          'list': 'Groceries',
          'items': [
            {'text': 'Lemons'},
          ],
        }),
      ]),
      ScriptedChatModel.text('I moved the dentist to Tuesday at 4:00 PM and put lemons on the groceries.'),
    ]);

/// Taking Feed the cat off the chores, which waits for a tap.
ScriptedChatModel removeCat({required String after}) => ScriptedChatModel([
      ScriptedChatModel.calls([
        ScriptedChatModel.toolCall('d1', 'delete_chore', {'chore': 'Feed the cat'}),
      ], text: 'I can remove that chore.'),
      ScriptedChatModel.text(after),
    ]);

/// [inner], calling [onCall] with each request's number before it answers.
class _Hook extends ChatModel {
  _Hook(this.inner, {required this.onCall});

  final ChatModel inner;
  final void Function(int n) onCall;
  int _n = 0;

  @override
  ModelInfo get info => inner.info;

  @override
  Future<ModelReply> respond(ModelRequest request) {
    onCall(++_n);
    return inner.respond(request);
  }
}

Event dentist(Den den) => den.events.firstWhere((e) => e.title == 'Dentist');
bool hasLemons(Den den) => den.lists.firstWhere((l) => l.list.title == 'Groceries').items.any((i) => i.text == 'Lemons');
bool hasCat(Den den) => den.chores.any((c) => c.title == 'Feed the cat');

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Capture.service = serviceFor(readers: const [RulesReader()]);
    Assistant.links = (_) => null;
  });
  tearDown(() => Assistant.links = Assistant.hubLink);

  group('Where Add sends the words', () {
    test('plain adds stay with Den\'s reader; questions and changes go to the helper', () {
      expect(addOrAsk('milk', found: true), AddRoute.add);
      expect(addOrAsk('Soccer every Wednesday at 5 for Leo', found: true), AddRoute.add);
      expect(addOrAsk('milk, eggs and bread', found: true), AddRoute.add);
      expect(addOrAsk('Clear the table every night', found: true), AddRoute.add);
      expect(addOrAsk('Do laundry Saturday', found: true), AddRoute.add);
      expect(addOrAsk('Will’s party Saturday at 2', found: true), AddRoute.add);

      expect(addOrAsk("What's on Friday", found: true), AddRoute.ask);
      expect(addOrAsk('who is driving Leo to soccer', found: false), AddRoute.ask);
      expect(addOrAsk('soccer at 5?', found: true), AddRoute.ask);
      expect(addOrAsk('Do we have anything Saturday', found: true), AddRoute.ask);
      expect(addOrAsk('Please move soccer to 6 on Tuesday', found: true), AddRoute.ask);
      expect(addOrAsk('add milk and cancel the dentist', found: true), AddRoute.ask, reason: 'a second step changes something');
      expect(addOrAsk('Give Maya 5 stars', found: true), AddRoute.ask);
      expect(addOrAsk('undo that', found: false), AddRoute.ask);
      expect(addOrAsk('plan dinners for next week', found: false), AddRoute.ask);
      expect(addOrAsk('blorp', found: false), AddRoute.ask, reason: 'Den couldn\'t place it');
    });

    test('limits and outages are said plainly', () {
      HelperProblem p(int status, String code) => problemFor(
            ModelException('x', status: status, code: code),
            fallback: 'x',
            speaker: 'Claude',
            name: 'Maya',
            dailyLimit: 20,
            month: '2026-10',
          );
      expect(p(429, 'daily_limit').message, "That's 20 questions today. Ask a parent for more.");
      expect(p(429, 'daily_limit').kind, ProblemKind.limit);
      expect(p(402, 'budget_spent').message, "The family's AI budget is used up for October.");
      expect(p(403, 'assistant_off').message, 'The AI helper is off. A parent can turn it on in Settings.');
      expect(p(403, 'not_allowed').message, "The AI helper isn't on for Maya. A parent can turn it on in Settings.");
      expect(p(502, 'provider_unreachable').kind, ProblemKind.down);
      expect(p(429, 'busy').retry, isTrue);
    });
  });

  group('Off by default', () {
    testWidgets('Add stays "Type or say anything" and nothing offers to ask', (tester) async {
      final state = await demoIn(tester);
      final link = FakeLink(ScriptedChatModel(const []));
      Assistant.links = (_) => link;
      expect(state.den.family!.assistant.enabled, isFalse);
      await shootAt(tester, 'assistant_off_add_phone', state: state, location: '/today', act: () async {
        await openAdd(tester);
        await typeInSheet(tester, "What's on Friday?");
      });
      expect(find.text('Type or say anything'), findsOneWidget);
      expect(find.text('Add or ask anything'), findsNothing);
      expect(find.text('Ask'), findsNothing);
      expect(find.text('Ask instead'), findsNothing);
      expect(link.asked, 0);
    });

    testWidgets('without a hub there is nothing to run it through, even when it is on', (tester) async {
      final state = await demoIn(tester);
      await helperOnFor(tester, state.den);
      await shootAt(tester, 'assistant_no_hub_add_phone', state: state, location: '/today', act: () => openAdd(tester));
      expect(find.text('Type or say anything'), findsOneWidget);
      expect(find.text('Add or ask anything'), findsNothing);
    });

    testWidgets('a wall display never gets it', (tester) async {
      final state = await demoIn(tester, wall: true);
      await helperOnFor(tester, state.den);
      Assistant.links = (_) => FakeLink(ScriptedChatModel(const []));
      expect(helperOn(state, linked: true), isFalse);
    });
  });

  group('Kids', () {
    testWidgets('a kid a parent didn\'t turn it on for never sees ask', (tester) async {
      final state = await kidPhone(tester, allowed: false);
      final link = FakeLink(ScriptedChatModel(const []));
      Assistant.links = (_) => link;
      expect(state.den.actor!.name, 'Maya');
      expect(helperOn(state, linked: true), isFalse);
      await shootAt(tester, 'assistant_kid_not_allowed_phone', state: state, location: '/today', act: () async {
        await openAdd(tester);
        if (find.descendant(of: find.byType(AddSheet), matching: find.byType(TextField)).evaluate().isNotEmpty) await typeInSheet(tester, 'What are my chores today?');
      });
      expect(find.text('Ask anything'), findsNothing);
      expect(find.text('Add or ask anything'), findsNothing);
      expect(find.text('Ask'), findsNothing);
      expect(find.textContaining('Ask instead'), findsNothing);
      expect(link.asked, 0);
    });

    testWidgets('a kid it is on for: big buttons, read-aloud, kid words and fewer tools', (tester) async {
      final state = await kidPhone(tester, allowed: true);
      final chat = ScriptedChatModel([
        ScriptedChatModel.calls([ScriptedChatModel.toolCall('k1', 'complete_chore', {'chore': 'Make bed'})]),
        ScriptedChatModel.text('I checked off Make bed. You still have Take out the trash tonight.'),
      ]);
      Assistant.links = (_) => FakeLink(chat, answer: const HelperStatus(
        provider: ModelProvider.anthropic,
        speaker: 'Claude',
        models: ['claude-haiku-5-5'],
        allowed: true,
        usedToday: 3,
        dailyLimit: 20,
        month: '2026-10',
      ));
      expect(helperOn(state, linked: true), isTrue);
      await shootAt(tester, 'assistant_kid_phone', state: state, location: '/today', size: tallPhone, act: () async {
        await askFromAdd(tester, 'I made my bed, can you check it off?');
      });
      expect(find.text('Read it to me'), findsOneWidget);
      expect(findWords('Checked off Make bed'), findsOneWidget);
      expect(tester.getSize(find.widgetWithText(OutlinedButton, 'Undo')).height, greaterThanOrEqualTo(72));
      final request = chat.requests.first;
      expect(request.system.first.text, kidStaticPrompt, reason: 'kid-level words from the packer');
      final parent = state.den.members.firstWhere((m) => m.isParent);
      final parentTools = assistantTools(standardRunner(), ActionContext(state.den, member: parent.id, surface: Surface.assistant));
      expect(request.tools.length, lessThan(parentTools.length), reason: 'only what Maya may do');
      expect(request.tools.map((t) => t.name), isNot(contains('adjust_points')));
    });
  });

  group('Answers', () {
    testWidgets('a two-step request writes through actions, shows each change with Undo, and "undo that" takes the last back', (tester) async {
      final state = await demoIn(tester);
      await helperOnFor(tester, state.den);
      final chat = twoChanges();
      Assistant.links = (_) => FakeLink(chat);
      final before = dentist(state.den).start;
      expect(hasLemons(state.den), isFalse);

      await shootAt(tester, 'assistant_answer_phone', state: state, location: '/today', act: () async {
        await askFromAdd(tester, 'Move the dentist to Tuesday at 4 and add lemons');
      });
      expect(find.text('Ask'), findsWidgets);
      expect(find.text('I moved the dentist to Tuesday at 4:00 PM and put lemons on the groceries.'), findsOneWidget);
      expect(findWords('Moved Dentist to 4:00 PM Tue'), findsOneWidget);
      expect(findWords('Added Lemons to Groceries'), findsOneWidget);
      expect(dentist(state.den).start, isNot(before));
      expect(hasLemons(state.den), isTrue);

      // History says where they came from.
      final fromHelper = state.den.history(limit: 10).where((h) => h.from?.kind == CaptureKind.assistant).toList();
      expect(fromHelper, isNotEmpty);
      expect(fromHelper.every((h) => h.from!.reader == 'Claude'), isTrue);

      // The system prompt was packed from the app's views, within budget.
      final system = chat.requests.first.system;
      expect(system.map((b) => b.name), containsAll(['static', 'family', 'speaker', 'today']));
      expect(system.firstWhere((b) => b.name == 'today').text, contains('Swim lesson'));
      expect(system.fold(0, (n, b) => n + estimateTokens(b.text)), lessThanOrEqualTo(8000));

      // Undo on a row takes back exactly that change.
      await tapAsk(tester, find.text('Undo').first);
      expect(dentist(state.den).start, before);
      expect(findWords('Took back: Moved Dentist to 4:00 PM Tue'), findsOneWidget);
      expect(hasLemons(state.den), isTrue);

      // "Undo that" takes back the newest change still in place, with no model call.
      final calls = chat.requests.length;
      await tester.enterText(find.byType(TextField).last, 'undo that');
      await tester.pump();
      await tapAsk(tester, find.widgetWithText(FilledButton, 'Ask'));
      expect(hasLemons(state.den), isFalse);
      expect(findWords('Took that back: Added Lemons to Groceries.'), findsOneWidget);
      expect(chat.requests.length, calls);
    });

    testWidgets('a change that needs a tap waits on "Do it / Not now": Not now leaves it, Do it does it', (tester) async {
      final state = await demoIn(tester);
      await helperOnFor(tester, state.den);
      final chat = removeCat(after: 'OK, I left Feed the cat as it is.');
      chat.add(ScriptedChatModel.calls([ScriptedChatModel.toolCall('d2', 'delete_chore', {'chore': 'Feed the cat'})]));
      chat.add(ScriptedChatModel.text('Done. Feed the cat is off the chores.'));
      final session = AskSession(app: state, link: FakeLink(chat));
      addTearDown(session.dispose);
      await pumpScreen(tester, AskScreen(session: session), state: state);
      await tester.runAsync(() => session.ask('Take feed the cat off the chores'));
      await tester.pumpAndSettle();

      expect(findWords('Remove the chore Feed the cat?'), findsOneWidget);
      expect(findWords('Removes Feed the cat'), findsOneWidget, reason: 'the preview from the runner\'s fork');
      expect(find.text('Do it'), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);
      expect(find.text('I can remove that chore.'), findsOneWidget, reason: 'what the helper said with it');
      expect(hasCat(state.den), isTrue, reason: 'nothing changes before the tap');
      await matchShot('assistant_confirm_phone');

      await tapAsk(tester, find.text('Not now'));
      expect(hasCat(state.den), isTrue);
      expect(find.text('Do it'), findsNothing);
      expect(find.text('OK, I left Feed the cat as it is.'), findsOneWidget);

      await tester.runAsync(() => session.ask('Actually, take it off'));
      await tester.pumpAndSettle();
      expect(find.text('Do it'), findsOneWidget);
      await tapAsk(tester, find.text('Do it'));
      expect(hasCat(state.den), isFalse);
      expect(findWords('Removed Feed the cat'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);

      await tapAsk(tester, find.text('Undo'));
      expect(hasCat(state.den), isTrue);
    });
  });

  group('Undo', () {
    testWidgets('when the helper takes a change back itself, its row says so', (tester) async {
      final state = await demoIn(tester);
      await helperOnFor(tester, state.den);
      final chat = ScriptedChatModel([
        ScriptedChatModel.calls([
          ScriptedChatModel.toolCall('a', 'add_items', {
            'list': 'Groceries',
            'items': [
              {'text': 'Lemons'},
            ],
          }),
        ]),
        ScriptedChatModel.text('Added lemons.'),
        ScriptedChatModel.calls([ScriptedChatModel.toolCall('b', 'undo')]),
        ScriptedChatModel.text('I took the lemons back off.'),
      ]);
      final session = AskSession(app: state, link: FakeLink(chat));
      addTearDown(session.dispose);
      await tester.runAsync(() => session.ask('add lemons'));
      expect(hasLemons(state.den), isTrue);
      await tester.runAsync(() => session.ask('actually take them off again'));
      expect(hasLemons(state.den), isFalse);
      expect(session.exchanges.first.changes.single.undone, isTrue);
      expect(session.exchanges.first.changes.single.canUndo, isFalse);
    });
  });

  group('Session only', () {
    testWidgets('closing Ask stops the helper: a turn still running changes nothing more', (tester) async {
      final state = await demoIn(tester);
      await helperOnFor(tester, state.den);
      late AskSession session;
      final chat = _Hook(twoChanges(), onCall: (n) {
        if (n == 1) session.close();
      });
      session = AskSession(app: state, link: FakeLink(chat));
      addTearDown(session.dispose);
      await tester.runAsync(() => session.ask('Move the dentist to Tuesday at 4 and add lemons'));
      expect(hasLemons(state.den), isFalse);
      expect(session.exchanges.single.changes, isEmpty);
      await tester.runAsync(() => session.ask('Add lemons'));
      expect(session.exchanges, hasLength(1), reason: 'nothing new is sent once Ask is closed');
    });

    testWidgets('an iPad turning from the panel to the sheet keeps the conversation', (tester) async {
      final state = await demoIn(tester);
      await helperOnFor(tester, state.den);
      Assistant.links = (_) => FakeLink(twoChanges());
      await shootAt(tester, 'assistant_tablet_turned', state: state, location: '/today', size: tablet, act: () async {
        await askFromAdd(tester, 'Move the dentist to Tuesday at 4 and add lemons');
        final before = shownSession(tester);
        expect(find.byType(AskScreen), findsOneWidget);
        tester.view.physicalSize = const Size(834, 1194);
        await tester.pumpAndSettle();
        expect(shownSession(tester), same(before));
        expect(before!.closed, isFalse);
        expect(findWords('Added Lemons to Groceries'), findsOneWidget);
      });
    });
  });

  group('Refusals from the hub', () {
    Future<void> refused(WidgetTester tester, ProxyLink link, String words, {String? golden, bool kid = false}) async {
      final state = kid ? await kidPhone(tester, allowed: true) : await demoIn(tester);
      if (!kid) await helperOnFor(tester, state.den);
      final session = AskSession(app: state, link: link);
      addTearDown(session.dispose);
      await pumpScreen(tester, AskScreen(session: session), state: state);
      await tester.runAsync(() => session.ask('What is on Saturday?'));
      await tester.pumpAndSettle();
      expect(link.requests.single.url.path, '/api/v1/assistant/model', reason: 'every model call goes through the hub');
      expect(link.requests.single.headers['x-den-provider'], 'anthropic');
      expect(findWords(words), findsOneWidget);
      if (golden != null) await matchShot(golden);
    }

    testWidgets('403: the helper is off', (tester) async {
      await refused(
        tester,
        ProxyLink(403, 'assistant_off', 'The assistant is off. A parent can turn it on in Settings.'),
        'The AI helper is off. A parent can turn it on in Settings.',
      );
    });

    testWidgets('429: a kid\'s questions for the day', (tester) async {
      await refused(
        tester,
        ProxyLink(429, 'daily_limit', "That's all the assistant for today, Maya. Ask a parent if you need more."),
        "That's 20 questions today. Ask a parent for more.",
        golden: 'assistant_limit_kid_phone',
        kid: true,
      );
    });

    testWidgets('402: the month\'s budget', (tester) async {
      await refused(
        tester,
        ProxyLink(402, 'budget_spent', 'The assistant has used this month\'s budget.'),
        "The family's AI budget is used up for October.",
        golden: 'assistant_budget_phone',
      );
    });

    testWidgets('502: the company behind it is down, with Try again', (tester) async {
      await refused(
        tester,
        ProxyLink(502, 'provider_unreachable', "Couldn't reach Claude."),
        "Claude can't be reached right now. Try again in a few minutes.",
        golden: 'assistant_down_phone',
      );
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('the hub\'s word comes first: a spent budget is said without a model call', (tester) async {
      final state = await demoIn(tester);
      await helperOnFor(tester, state.den);
      final chat = ScriptedChatModel(const []);
      final session = AskSession(
        app: state,
        link: FakeLink(chat, answer: const HelperStatus(provider: ModelProvider.anthropic, speaker: 'Claude', models: ['claude-haiku-5-5'], allowed: true, month: '2026-10', stopped: true)),
      );
      addTearDown(session.dispose);
      await pumpScreen(tester, AskScreen(session: session), state: state);
      await tester.runAsync(() => session.ask('What is on Saturday?'));
      await tester.pumpAndSettle();
      expect(findWords("The family's AI budget is used up for October."), findsOneWidget);
      expect(chat.requests, isEmpty);
    });
  });

  group('Context', () {
    testWidgets('the snapshot is the asker\'s own view: today, the week, what they may do, their history', (tester) async {
      final state = await demoIn(tester);
      final snap = assistantSnapshot(state, now: state.den.now());
      expect(snap.speaker.member.name, state.den.actor!.name);
      expect(snap.speaker.may, contains('add and change events'));
      expect(snap.events.map((e) => e.title), contains('Swim lesson'));
      expect(snap.week, isNotEmpty);
      expect(snap.family.lists.map((l) => l.title), contains('Groceries'));
      final packed = const ContextPacker().pack(snap);
      expect(packed.tokens, lessThanOrEqualTo(8000));
    });
  });

  group('Screenshots', () {
    Future<AppState> on(WidgetTester tester) async {
      final state = await demoIn(tester);
      await helperOnFor(tester, state.den);
      return state;
    }

    Future<void> conversation(WidgetTester tester) async {
      await askFromAdd(tester, 'Move the dentist to Tuesday at 4 and add lemons');
      final session = shownSession(tester)!;
      await tester.runAsync(() => session.ask('And take Feed the cat off the chores'));
      await tester.pumpAndSettle();
    }

    ScriptedChatModel script() {
      final chat = twoChanges();
      chat.add(ScriptedChatModel.calls([ScriptedChatModel.toolCall('d1', 'delete_chore', {'chore': 'Feed the cat'})]));
      return chat;
    }

    testWidgets('Add or ask anything', (tester) async {
      final state = await on(tester);
      Assistant.links = (_) => FakeLink(ScriptedChatModel(const []));
      await shootAt(tester, 'assistant_add_or_ask_phone', state: state, location: '/today', act: () async {
        await openAdd(tester);
        await typeInSheet(tester, 'lemons');
      });
      expect(find.text('Add or ask anything'), findsOneWidget);
      expect(find.text('Add to Groceries'), findsOneWidget, reason: 'a plain add still adds at once');
      expect(find.text('Ask instead'), findsOneWidget);
    });

    testWidgets('a question in Add goes to the helper', (tester) async {
      final state = await on(tester);
      Assistant.links = (_) => FakeLink(ScriptedChatModel(const []));
      await shootAt(tester, 'assistant_add_question_phone', state: state, location: '/today', act: () async {
        await openAdd(tester);
        await typeInSheet(tester, "Who's driving Leo to soccer Tuesday?");
      });
      expect(find.text('Ask'), findsOneWidget);
      expect(find.text('Den found'), findsNothing, reason: 'a question isn\'t offered as an add');
    });

    testWidgets('phone', (tester) async {
      final state = await on(tester);
      Assistant.links = (_) => FakeLink(script());
      await shootAt(tester, 'assistant_phone', state: state, location: '/today', act: () => conversation(tester));
      expect(find.text('Do it'), findsOneWidget);
    });

    testWidgets('phone, night', (tester) async {
      final state = await on(tester);
      Assistant.links = (_) => FakeLink(script());
      await shootAt(tester, 'assistant_phone_night', state: state, location: '/today', night: true, act: () => conversation(tester));
    });

    testWidgets('iPad: a side panel from 840 pt', (tester) async {
      final state = await on(tester);
      Assistant.links = (_) => FakeLink(script());
      await shootAt(tester, 'assistant_tablet', state: state, location: '/today', size: tablet, act: () => conversation(tester));
      final panel = tester.getRect(find.byType(AskScreen));
      expect(panel.right, tablet.width);
      expect(panel.width, lessThanOrEqualTo(420));
    });

    testWidgets('iPad, night', (tester) async {
      final state = await on(tester);
      Assistant.links = (_) => FakeLink(script());
      await shootAt(tester, 'assistant_tablet_night', state: state, location: '/today', size: tablet, night: true, act: () => conversation(tester));
    });

    testWidgets('200 % text', (tester) async {
      final state = await on(tester);
      Assistant.links = (_) => FakeLink(script());
      await shootAt(tester, 'assistant_phone_200', state: state, location: '/today', size: tallPhone, text: 2, act: () => conversation(tester));
      expect(find.text('Do it'), findsOneWidget);
    });
  });
}
