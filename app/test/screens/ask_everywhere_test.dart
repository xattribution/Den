import 'dart:async';

import 'package:den_app/app/app_state.dart' hide Receipt;
import 'package:den_app/design/widgets.dart' show DenSidebar;
import 'package:den_app/features/add/add.dart' show Capture;
import 'package:den_app/features/add/screens/add_sheet.dart' show AddSheet;
import 'package:den_app/features/assistant/assistant.dart';
import 'package:den_app/features/assistant/screens/ask_screen.dart';
import 'package:den_app/features/assistant/state/ask_chats.dart';
import 'package:den_app/features/assistant/state/suggestions.dart';
import 'package:den_app/features/assistant/words/assistant_words.dart';
import 'package:den_app/features/settings/screens/assistant_screen.dart';
import 'package:den_assistant/den_assistant.dart';
import 'package:den_assistant/testing.dart';
import 'package:den_capture/den_capture.dart' show RulesReader;
import 'package:den_core/demo.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../helpers/shots.dart';
import 'assistant_test.dart' show FakeLink, askFromAdd, hasLemons, helperOnFor, kidPhone, shownSession, tapAsk;
import 'calendar_shots.dart' show pumpAt, shootAt, tallPhone;
import 'capture_test.dart' show openAdd, serviceFor;
import 'family_fakes.dart' show matchShot;

/// The way into Ask on Today.
Finder get todayPill => find.text(askTodayLabel);

/// The sidebar's "Ask".
Finder get sidebarAsk => find.descendant(of: find.byType(DenSidebar), matching: find.text('Ask'));

/// The kept conversation's field.
Finder get askField => find.descendant(of: find.byType(AskScreen), matching: find.byType(TextField));

/// ⌘K, or Ctrl+K with [control].
Future<void> pressAskKey(WidgetTester tester, {bool control = false}) async {
  final modifier = control ? LogicalKeyboardKey.controlLeft : LogicalKeyboardKey.metaLeft;
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
  await tester.sendKeyUpEvent(modifier);
  await tester.pumpAndSettle();
}

/// Opens Ask from Today's pill and waits for what the hub says as it opens.
Future<void> openFromToday(WidgetTester tester) async {
  await tester.tap(todayPill);
  await tester.pumpAndSettle();
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  await tester.pumpAndSettle();
}

/// Closes Ask with Done.
Future<void> closeAsk(WidgetTester tester) async {
  await tester.tap(find.descendant(of: find.byType(AskScreen), matching: find.text('Done')));
  await tester.pumpAndSettle();
  expect(find.byType(AskScreen), findsNothing);
}

/// A model whose first answer waits for [release]: the helper still working.
class HeldModel extends ChatModel {
  HeldModel(this.inner);

  final ChatModel inner;
  final Completer<void> release = Completer();
  int calls = 0;

  @override
  ModelInfo get info => inner.info;

  @override
  Future<ModelReply> respond(ModelRequest request) async {
    if (++calls == 1) await release.future;
    return inner.respond(request);
  }
}

/// "Swim lesson at 4:30 PM" for what's on today, then [more].
ScriptedChatModel today([List<Object> more = const []]) => ScriptedChatModel([
      ScriptedChatModel.text('Zoe has her swim lesson at 4:30 PM. Nobody is driving her yet.'),
      ...more,
    ]);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Capture.service = serviceFor(readers: const [RulesReader()]);
    Assistant.links = (_) => null;
  });
  tearDown(() => Assistant.links = Assistant.hubLink);

  group('Who sees Ask', () {
    testWidgets('on: Today\'s pill, Add\'s row, the iPad sidebar and ⌘K', (tester) async {
      final state = await demoIn(tester);
      await helperOnFor(tester, state.den);
      final link = FakeLink(today());
      Assistant.links = (_) => link;
      expect(askEntry(state, linked: true), AskEntry.open);

      await shootAt(tester, 'ask_today_phone', state: state, location: '/today');
      expect(todayPill, findsOneWidget);
      expect(find.text(askSetUpLabel), findsNothing);
      expect(tester.getSize(find.ancestor(of: todayPill, matching: find.byType(ConstrainedBox)).first).height, greaterThanOrEqualTo(52));
      expect(find.bySemanticsLabel(askTodayLabel), findsOneWidget, reason: 'one button, named once');

      await openAdd(tester);
      expect(find.descendant(of: find.byType(AddSheet), matching: find.text(askOpenLabel)), findsOneWidget);
      await tester.tap(find.text(askOpenLabel));
      await tester.pumpAndSettle();
      expect(find.byType(AddSheet), findsNothing);
      expect(find.byType(AskScreen), findsOneWidget, reason: 'Add\'s row opens the conversation as it is');
      await closeAsk(tester);

      await pumpAt(tester, state: state, location: '/today', size: tablet);
      expect(sidebarAsk, findsOneWidget);
      await tester.tap(sidebarAsk);
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(AskScreen)).right, tablet.width, reason: 'the panel at the right edge');
      await closeAsk(tester);

      await pressAskKey(tester);
      expect(find.byType(AskScreen), findsOneWidget);
    });

    testWidgets('off, a parent: a quiet way to set it up at the end of Today, and ⌘K says how', (tester) async {
      final state = await demoIn(tester);
      final link = FakeLink(today());
      Assistant.links = (_) => link;
      expect(state.den.family!.assistant.enabled, isFalse);
      expect(askEntry(state, linked: true), AskEntry.setUp);
      expect(askEntry(state, linked: false), AskEntry.setUp, reason: 'no hub yet: Settings says to set one up first');

      await shootAt(tester, 'ask_set_up_today_phone', state: state, location: '/today', size: tallPhone);
      expect(todayPill, findsNothing);
      expect(find.text(askSetUpLabel), findsOneWidget);
      expect(findWords(askSetUpDetail), findsOneWidget);
      await openAdd(tester);
      expect(find.text(askOpenLabel), findsNothing, reason: 'Add stays as it was while it\'s off');
      await tester.tap(find.descendant(of: find.byType(AddSheet), matching: find.text('Done')));
      await tester.pumpAndSettle();

      await tester.tap(find.text(askSetUpLabel));
      await tester.pumpAndSettle();
      expect(find.byType(AssistantScreen), findsOneWidget, reason: 'Settings, AI helper');

      await pumpAt(tester, state: state, location: '/today', size: tablet);
      expect(sidebarAsk, findsNothing, reason: 'the sidebar only carries what works');

      await pumpAt(tester, state: state, location: '/today');
      await pressAskKey(tester);
      expect(findWords(askSetUpWords), findsOneWidget);
      expect(findWords(askOffForParentWords), findsOneWidget);
      expect(askField, findsNothing, reason: 'nothing to type into while it\'s off');
      expect(find.text(newChatLabel), findsNothing);
      await matchShot('ask_set_up_phone');
      await tester.tap(find.text(askSetUpAction));
      await tester.pumpAndSettle();
      expect(find.byType(AskScreen), findsNothing);
      expect(find.byType(AssistantScreen), findsOneWidget);
      expect(link.asked, 0, reason: 'nothing asks the hub while it\'s off');
    });

    Future<void> nothingFor(WidgetTester tester, AppState state, FakeLink link) async {
      await pumpAt(tester, state: state, location: '/today', size: tallPhone);
      expect(todayPill, findsNothing);
      expect(find.text(askSetUpLabel), findsNothing);
      await pressAskKey(tester);
      expect(find.byType(AskScreen), findsNothing, reason: '⌘K stays the browser\'s');
      await openAdd(tester);
      expect(find.text(askOpenLabel), findsNothing);
      await tester.tap(find.descendant(of: find.byType(AddSheet), matching: find.text('Done')));
      await tester.pumpAndSettle();
      await pumpAt(tester, state: state, location: '/today', size: tablet);
      expect(sidebarAsk, findsNothing);
      expect(link.asked, 0);
    }

    testWidgets('off, a kid: nothing anywhere', (tester) async {
      final state = await kidPhone(tester, allowed: true, on: false);
      final link = FakeLink(today());
      Assistant.links = (_) => link;
      expect(state.den.actor!.name, 'Maya');
      expect(askEntry(state, linked: true), AskEntry.hidden);
      await nothingFor(tester, state, link);
    });

    testWidgets('on, but not for this person: nothing anywhere', (tester) async {
      final state = await kidPhone(tester, allowed: false);
      final link = FakeLink(today());
      Assistant.links = (_) => link;
      expect(askEntry(state, linked: true), AskEntry.hidden);
      await nothingFor(tester, state, link);
    });

    testWidgets('a wall display or a shared screen: nothing, as the family\'s rules have it', (tester) async {
      final state = await demoIn(tester, wall: true);
      await helperOnFor(tester, state.den);
      expect(askEntry(state, linked: true), AskEntry.hidden);
      expect(helperOn(state, linked: true), isFalse);
    });

    testWidgets('a kid at the day\'s limit: the friendly limit words, not a dead field', (tester) async {
      final state = await kidPhone(tester, allowed: true);
      final link = FakeLink(
        ScriptedChatModel(const []),
        answer: const HelperStatus(
          provider: ModelProvider.anthropic,
          speaker: 'Claude',
          models: ['claude-haiku-5-5'],
          allowed: true,
          usedToday: 20,
          dailyLimit: 20,
          month: '2026-10',
        ),
      );
      Assistant.links = (_) => link;
      await shootAt(tester, 'ask_kid_limit_phone', state: state, location: '/today', act: () => openFromToday(tester));
      expect(find.byType(AskScreen), findsOneWidget, reason: 'the pill opens Ask, never nothing');
      expect(find.text('Hi Maya. What do you want to know?'), findsOneWidget);
      expect(findWords(dailyLimitWords(20)), findsOneWidget);
      expect(askField, findsNothing);
      expect(find.text('How many stars do I have?'), findsNothing);
      expect(link.asked, 1, reason: 'asked the hub as Ask opened');
    });
  });

  group('Opening Ask directly', () {
    testWidgets('an empty chat greets the person with things to ask for now', (tester) async {
      final state = await demoIn(tester);
      await helperOnFor(tester, state.den);
      final chat = today();
      Assistant.links = (_) => FakeLink(chat);
      await shootAt(tester, 'ask_empty_phone', state: state, location: '/today', act: () => openFromToday(tester));
      expect(find.text('Hi Alex. What can I help with?'), findsOneWidget);
      for (final words in ["What's on today?", "Who's driving to Swim lesson?", 'Add milk to Costco', 'Who still has chores today?']) {
        expect(find.text(words), findsOneWidget, reason: words);
      }
      expect(find.text(newChatLabel), findsNothing, reason: 'nothing to start over yet');
      expect(find.bySemanticsLabel("Ask: What's on today?"), findsOneWidget, reason: 'a screen reader hears it asks');
      expect(find.bySemanticsLabel('Start a message: Add milk to Costco'), findsOneWidget);
      expect(find.bySemanticsLabel('Hi Alex. What can I help with?'), findsOneWidget);
      expect(tester.getSize(find.ancestor(of: find.text("What's on today?"), matching: find.byType(ConstrainedBox)).first).height, greaterThanOrEqualTo(44));

      // A change goes in the field to finish, its example word chosen: nothing is sent.
      await tester.tap(find.text('Add milk to Costco'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(askField);
      expect(field.controller!.text, 'Add milk to Costco');
      expect(field.controller!.selection, const TextSelection(baseOffset: 4, extentOffset: 8));
      expect(chat.requests, isEmpty);

      // A question is asked at once.
      field.controller!.clear();
      await tapAsk(tester, find.text("What's on today?"));
      expect(find.text('Zoe has her swim lesson at 4:30 PM. Nobody is driving her yet.'), findsOneWidget);
      expect(chat.requests.single.messages.last, isA<UserMessage>());
    });

    testWidgets('an empty chat, night', (tester) async {
      final state = await demoIn(tester);
      await helperOnFor(tester, state.den);
      Assistant.links = (_) => FakeLink(today());
      await shootAt(tester, 'ask_empty_phone_night', state: state, location: '/today', night: true, act: () => openFromToday(tester));
      expect(find.text('Hi Alex. What can I help with?'), findsOneWidget);
    });

    testWidgets('the iPad panel from the sidebar', (tester) async {
      final state = await demoIn(tester);
      await helperOnFor(tester, state.den);
      Assistant.links = (_) => FakeLink(today());
      await shootAt(tester, 'ask_panel_tablet', state: state, location: '/today', size: tablet, act: () async {
        await tester.tap(sidebarAsk);
        await tester.pumpAndSettle();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pumpAndSettle();
      });
      final panel = tester.getRect(find.byType(AskScreen));
      expect(panel.right, tablet.width);
      expect(panel.width, lessThanOrEqualTo(420));
      expect(find.text('Hi Alex. What can I help with?'), findsOneWidget);
    });

    testWidgets('things to ask follow the hour, and a kid gets their own', (tester) async {
      tzdata.initializeTimeZones();
      Future<AppState> at(DateTime now) async => AppState((await tester.runAsync(() => createDemoFamily(now: now)))!);
      // Friday 8 AM in Chicago.
      final morning = await at(demoNow);
      expect(askSuggestions(morning).map((s) => s.words), [
        "What's on today?",
        "Who's driving to Swim lesson?",
        'Add milk to Costco',
        'Who still has chores today?',
      ]);
      expect(askSuggestions(morning)[2].send, isFalse, reason: 'a change is never sent by a chip');
      // Friday 6 PM: Today looks ahead to tomorrow, and so does Ask.
      final evening = await at(DateTime.utc(2026, 10, 16, 23));
      expect(askSuggestions(evening).first.words, "What's on tomorrow?");
      expect(askSuggestions(evening)[1].words, "Who's driving to Sophie's birthday party?");
      // Maya, a teen, on her own phone.
      final maya = await kidPhone(tester, allowed: true);
      expect(askSuggestions(maya).map((s) => s.words), [
        'What are my chores today?',
        'How many stars do I have?',
        "What's on today?",
      ]);
    });
  });

  group('One conversation while the app runs', () {
    testWidgets('closing and opening Ask brings it back; New chat clears it', (tester) async {
      final state = await demoIn(tester);
      await helperOnFor(tester, state.den);
      Assistant.links = (_) => FakeLink(today());
      await pumpAt(tester, state: state, location: '/today');
      await openFromToday(tester);
      await tapAsk(tester, find.text("What's on today?"));
      final kept = shownSession(tester);
      await closeAsk(tester);
      expect(kept!.closed, isFalse, reason: 'closing Ask keeps the conversation');

      await shootAt(tester, 'ask_chat_phone', state: state, location: '/today', act: () => openFromToday(tester));
      expect(shownSession(tester), same(kept));
      expect(find.text('Zoe has her swim lesson at 4:30 PM. Nobody is driving her yet.'), findsOneWidget);
      expect(find.text('Hi Alex. What can I help with?'), findsNothing);
      expect(find.text(newChatLabel), findsOneWidget);

      await tester.tap(find.text(newChatLabel));
      await tester.pumpAndSettle();
      expect(find.text('Zoe has her swim lesson at 4:30 PM. Nobody is driving her yet.'), findsNothing);
      expect(find.text('Hi Alex. What can I help with?'), findsOneWidget);
      expect(find.text(newChatLabel), findsNothing);
      expect(kept.closed, isTrue, reason: 'the old one is let go');
      expect(AskChats.of(state).current, isNot(same(kept)));
    });

    testWidgets('Add goes on from the conversation Ask is keeping', (tester) async {
      final state = await demoIn(tester);
      await helperOnFor(tester, state.den);
      final chat = today([ScriptedChatModel.text('Priya is driving Leo to soccer on Tuesday.')]);
      Assistant.links = (_) => FakeLink(chat);
      await pumpAt(tester, state: state, location: '/today');
      await openFromToday(tester);
      await tapAsk(tester, find.text("What's on today?"));
      await closeAsk(tester);

      await askFromAdd(tester, "Who's driving Leo to soccer Tuesday?");
      expect(find.text('Zoe has her swim lesson at 4:30 PM. Nobody is driving her yet.'), findsOneWidget);
      expect(find.text('Priya is driving Leo to soccer on Tuesday.'), findsOneWidget);
      expect(shownSession(tester)!.exchanges, hasLength(2));
      expect(chat.requests.last.messages.whereType<UserMessage>(), hasLength(2), reason: 'the helper hears the first question too');
    });

    testWidgets('closing Ask while the helper works stops it; Ask again asks anew', (tester) async {
      final state = await demoIn(tester);
      await helperOnFor(tester, state.den);
      ScriptedChatModel lemons() => ScriptedChatModel([]);
      final script = lemons()
        ..add(ScriptedChatModel.calls([
          ScriptedChatModel.toolCall('a', 'add_items', {
            'list': 'Groceries',
            'items': [
              {'text': 'Lemons'},
            ],
          }),
        ]))
        ..add(ScriptedChatModel.calls([
          ScriptedChatModel.toolCall('b', 'add_items', {
            'list': 'Groceries',
            'items': [
              {'text': 'Lemons'},
            ],
          }),
        ]))
        ..add(ScriptedChatModel.text('Added lemons to the groceries.'));
      final held = HeldModel(script);
      Assistant.links = (_) => FakeLink(held);
      await pumpAt(tester, state: state, location: '/today');
      await openFromToday(tester);
      await tester.enterText(askField, 'Add lemons');
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Ask'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      final session = shownSession(tester)!;
      expect(session.busy, isTrue);

      await closeAsk(tester);
      await tester.runAsync(() async {
        held.release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(session.busy, isFalse);
      expect(hasLemons(state.den), isFalse, reason: 'nothing changes once Ask closed');
      expect(session.exchanges.single.problem?.message, stoppedWords);

      await openFromToday(tester);
      expect(findWords(stoppedWords), findsOneWidget);
      await tapAsk(tester, find.text('Ask again'));
      expect(hasLemons(state.den), isTrue);
      expect(find.text('Added lemons to the groceries.'), findsOneWidget);
      expect(session.exchanges, hasLength(2), reason: 'the stopped one stays as it was');
    });

    testWidgets('a conversation left for hours, or since yesterday, starts over', (tester) async {
      final state = await demoIn(tester);
      await helperOnFor(tester, state.den);
      final link = FakeLink(today());
      final chats = AskChats.of(state);
      var now = DateTime(2026, 10, 16, 8);
      chats.clock = () => now;
      final first = chats.session(link);
      expect(chats.session(link), same(first));
      now = now.add(const Duration(hours: 2));
      expect(chats.session(link), same(first), reason: 'two hours: still the same conversation');
      now = now.add(AskChats.idle);
      final second = chats.session(link);
      expect(second, isNot(same(first)));
      expect(first.closed, isTrue);
      second.attach();
      now = now.add(const Duration(hours: 9));
      expect(chats.session(link), same(second), reason: 'kept while Ask shows it');
      second.detach();
      expect(chats.session(null), isNot(same(second)), reason: 'a family without a hub starts over');
    });
  });

  group('Screen readers', () {
    testWidgets('once the sheet has come up, its field and Ask are there to reach', (tester) async {
      final semantics = tester.ensureSemantics();
      final state = await demoIn(tester);
      await helperOnFor(tester, state.den);
      Assistant.links = (_) => FakeLink(today());
      await pumpAt(tester, state: state, location: '/today');
      await openFromToday(tester);
      // The sheet slid up from below the screen. The tree has the field and Ask where they are
      // drawn, not where they were mid-slide (a browser leaves what's off the screen out).
      Rect onScreen(SemanticsNode node) {
        var rect = node.rect;
        for (SemanticsNode? n = node; n != null; n = n.parent) {
          if (n.transform != null) rect = MatrixUtils.transformRect(n.transform!, rect);
        }
        return rect;
      }

      final field = find.semantics.byPredicate((n) => n.flagsCollection.isTextField);
      final ask = find.semantics.byPredicate((n) => n.label == 'Ask' && n.flagsCollection.isButton);
      expect(field, findsOne);
      expect(ask, findsOne);
      for (final (node, drawn) in [
        (field.evaluate().single, tester.getRect(askField)),
        (ask.evaluate().single, tester.getRect(find.widgetWithText(FilledButton, 'Ask'))),
      ]) {
        expect(node.flagsCollection.isHidden, isFalse);
        expect(onScreen(node).center.dy, closeTo(drawn.center.dy, 2));
        expect(onScreen(node).bottom, lessThanOrEqualTo(844));
      }
      semantics.dispose();
    });
  });

  group('Keyboard', () {
    testWidgets('⌘K and Ctrl+K open Ask with the field ready to type', (tester) async {
      final state = await demoIn(tester);
      await helperOnFor(tester, state.den);
      Assistant.links = (_) => FakeLink(today());
      await pumpAt(tester, state: state, location: '/calendar', size: tablet);
      for (final control in [false, true]) {
        await pressAskKey(tester, control: control);
        expect(find.byType(AskScreen), findsOneWidget);
        final editable = tester.widget<EditableText>(find.descendant(of: find.byType(AskScreen), matching: find.byType(EditableText)));
        expect(editable.focusNode.hasFocus, isTrue, reason: 'type straight away');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(AskScreen), findsNothing, reason: 'Escape closes it');
      }
    });
  });
}
