import 'package:den_app/app/app_state.dart';
import 'package:den_app/app/den_app.dart' show buildRouter;
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/features/assistant/assistant.dart';
import 'package:den_app/features/assistant/screens/ask_screen.dart';
import 'package:den_app/features/lists/screens/list_detail.dart';
import 'package:den_app/features/lists/words/list_words.dart';
import 'package:den_app/platform/web/web_app.dart';
import 'package:den_app/platform/web/web_insets.dart';
import 'package:den_assistant/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/shots.dart';
import 'assistant_test.dart' show FakeLink, helperOnFor;
import 'chores_shots.dart';

/// The keyboard on a Home Screen iPhone: Flutter's own reading of it can go stale when the
/// keyboard is closed with its own button, so the app takes den_web.js's (web/den_web.js;
/// test/web/viewport_test.mjs covers that side).
void main() {
  group('The keyboard inset', () {
    test('is Flutter\'s where the page doesn\'t say', () {
      expect(webViewInsets(const EdgeInsets.only(bottom: 300), null), const EdgeInsets.only(bottom: 300));
    });

    test('is the page\'s where it does, stale or missing in Flutter', () {
      // Closed with the arrow: Flutter still has the keyboard, the page knows it's gone.
      expect(webViewInsets(const EdgeInsets.only(bottom: 336), const WebViewport(keyboard: 0, editing: true)), EdgeInsets.zero);
      // Up while Flutter had stopped editing.
      expect(webViewInsets(EdgeInsets.zero, const WebViewport(keyboard: 336, editing: true)), const EdgeInsets.only(bottom: 336));
    });

    test('reads the page\'s answer', () {
      expect(
        WebViewport.fromJson({'keyboard': 336, 'width': 390, 'height': 844, 'top': 0, 'scrolled': 0, 'editing': true}),
        const WebViewport(keyboard: 336, width: 390, height: 844, editing: true),
      );
      expect(WebViewport.fromJson('nope'), isNull);
      expect(WebViewport.fromJson(const {}), const WebViewport());
    });
  });

  testWidgets('The safe area comes back under a keyboard that closed without Return', (tester) async {
    final page = ValueNotifier<WebViewport?>(const WebViewport(keyboard: 336, editing: true));
    addTearDown(page.dispose);
    late MediaQueryData seen;
    await tester.pumpWidget(MediaQuery(
      // Flutter's own reading stays at the keyboard's height: it heard no resize after it closed.
      data: const MediaQueryData(size: Size(390, 844), viewInsets: EdgeInsets.only(bottom: 336)),
      child: WebSafeArea(
        insets: const [0, 0, 34, 0],
        viewport: page,
        child: Builder(builder: (context) {
          seen = MediaQuery.of(context);
          return const SizedBox.shrink();
        }),
      ),
    ));
    expect(seen.viewInsets.bottom, 336);
    expect(seen.padding.bottom, 0, reason: 'the keyboard covers the home indicator');
    page.value = const WebViewport(keyboard: 0, editing: true);
    await tester.pump();
    expect(seen.viewInsets.bottom, 0, reason: 'nothing stays lifted over a keyboard that is gone');
    expect(seen.padding.bottom, 34, reason: 'and the home indicator is padded again');
  });

  testWidgets('An item\'s sheet over the keyboard, then the close arrow: back down, still typing', (tester) async {
    final state = await demo(tester);
    await loadFonts();
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final page = ValueNotifier<WebViewport?>(const WebViewport());
    addTearDown(page.dispose);
    final errors = <FlutterErrorDetails>[];
    await tester.pumpWidget(DenScope(
      state: state,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: denTheme(DenColors.night),
        builder: (context, child) => WebSafeArea(insets: const [47, 0, 34, 0], viewport: page, child: child),
        home: Scaffold(body: SafeArea(child: ListDetailScreen(id: groceriesList(state.den)!.list.id))),
      ),
    ));
    await tester.pumpAndSettle();
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previous);

    await tester.longPress(find.text('Toothpaste'));
    await tester.pumpAndSettle();
    final field = find.byWidgetPredicate((w) => w is TextField && w.controller?.text == 'Toothpaste');
    expect(field, findsOneWidget);
    final controller = tester.widget<TextField>(field).controller!;
    final focus = tester.widget<EditableText>(find.descendant(of: field, matching: find.byType(EditableText))).focusNode;
    await tester.enterText(field, 'Toothpaste, mint');
    // The keyboard comes up: Flutter and the page agree.
    tester.view.viewInsets = const FakeViewPadding(bottom: 336);
    page.value = const WebViewport(keyboard: 336, editing: true);
    await tester.pumpAndSettle();
    final save = find.text('Save');
    expect(tester.getBottomLeft(save).dy, lessThanOrEqualTo(844 - 336), reason: 'Save sits over the keyboard');
    expect(tester.getTopLeft(find.text('Edit item')).dy, greaterThan(47), reason: 'the sheet stays under the status bar');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/web_keyboard_up_phone_night.png'));

    // The keyboard's close arrow: Flutter heard nothing, the page says it's gone.
    page.value = const WebViewport(keyboard: 0, editing: true);
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(save).dy, greaterThan(844 - 120), reason: 'the sheet is back at the bottom');
    expect(controller.text, 'Toothpaste, mint', reason: 'what was typed is still there');
    expect(focus.hasFocus, isTrue, reason: 'the field keeps the focus, so the next tap on it brings the keyboard back');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/web_keyboard_closed_phone_night.png'));
    expect(errors, isEmpty, reason: 'nothing overflows on the way');
  });

  testWidgets('Ask\'s field over the keyboard, then the close arrow: back down, still typing', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = await demo(tester);
    await helperOnFor(tester, state.den);
    Assistant.links = (_) => FakeLink(ScriptedChatModel(const []));
    addTearDown(() => Assistant.links = Assistant.hubLink);
    await loadFonts();
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final page = ValueNotifier<WebViewport?>(const WebViewport());
    addTearDown(page.dispose);
    final router = buildRouter(state);
    await tester.pumpWidget(DenScope(
      state: state,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: denTheme(DenColors.night),
        routerConfig: router,
        builder: (context, child) => WebSafeArea(insets: const [47, 0, 34, 0], viewport: page, child: child),
      ),
    ));
    await tester.pumpAndSettle();
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previous);

    // Today's pill opens Ask; its field takes the words.
    await tester.tap(find.text('Ask about your day'));
    await tester.pumpAndSettle();
    final field = find.descendant(of: find.byType(AskScreen), matching: find.byType(TextField));
    await tester.tap(field);
    await tester.enterText(field, 'Who is driving Zoe');
    final controller = tester.widget<TextField>(field).controller!;
    final focus = tester.widget<TextField>(field).focusNode!;
    final ask = find.descendant(of: find.byType(AskScreen), matching: find.widgetWithText(FilledButton, 'Ask'));
    final resting = tester.getBottomLeft(ask).dy;

    // The keyboard comes up: Flutter and the page agree.
    tester.view.viewInsets = const FakeViewPadding(bottom: 336);
    page.value = const WebViewport(keyboard: 336, editing: true);
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(ask).dy, lessThanOrEqualTo(844 - 336), reason: 'the field and Ask sit over the keyboard');
    expect(tester.getTopLeft(find.text('Done')).dy, greaterThan(47), reason: 'Ask stays under the status bar');

    // The keyboard's close arrow: Flutter heard nothing, the page says it's gone.
    page.value = const WebViewport(keyboard: 0, editing: true);
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(ask).dy, resting, reason: 'Ask is back where it was');
    expect(controller.text, 'Who is driving Zoe', reason: 'what was typed is still there');
    expect(focus.hasFocus, isTrue, reason: 'the field keeps the focus, so the next tap brings the keyboard back');
    expect(errors, isEmpty, reason: 'nothing overflows on the way');
  });
}
