import 'package:den_app/app/app_state.dart';
import 'package:den_app/app/den_app.dart' show buildRouter;
import 'package:den_app/design/layout.dart';
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

/// The keyboard in the web app (web/den_web.js; test/web/viewport_test.mjs and
/// test/web/keyboard_e2e.mjs cover the page's side). A keyboard closed with its own button (the
/// down arrow on Android, the close key on an iPad) hides without a blur. The page then ends the
/// editing (Flutter hears its connection close, as after a tap elsewhere) and has Flutter measure
/// again; meanwhile the app must not stay lifted, nor lay out under a negative inset, nor swap
/// its layout for a keyboard.
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

    test('is never negative (Flutter 3.38.5 on Android after the arrow)', () {
      expect(webViewInsets(const EdgeInsets.only(bottom: -320), null), EdgeInsets.zero);
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

  group('The window\'s size for its layout', () {
    test('is the page\'s height, which no keyboard changes', () {
      // Flutter 3.38.5 on Android, keyboard up: it lays out in the part above the keyboard.
      expect(webWindowSize(const Size(820, 440), const WebViewport(width: 820, height: 760)), const Size(820, 760));
    });

    test('is Flutter\'s where the page hasn\'t answered for this width', () {
      expect(webWindowSize(const Size(820, 760), null), const Size(820, 760));
      // Just turned: the page answers for the old shape a moment longer.
      expect(webWindowSize(const Size(760, 820), const WebViewport(width: 820, height: 760)), const Size(760, 820));
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
        keyboardFromPage: true,
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

  testWidgets('On the Fold, a keyboard neither turns the sidebar into a tab bar nor leaves a negative inset', (tester) async {
    // The Fold open, 820 x 760 in Chrome. Flutter 3.38.5 lays out in the part above the
    // keyboard while it's up, and after the arrow reports a negative inset.
    final page = ValueNotifier<WebViewport?>(const WebViewport(width: 820, height: 760));
    addTearDown(page.dispose);
    var media = const MediaQueryData(size: Size(820, 760));
    late MediaQueryData seen;
    late DenWidth layout;
    Widget app() => MediaQuery(
          data: media,
          child: WebSafeArea(
            insets: const [0, 0, 0, 0],
            viewport: page,
            keyboardFromPage: false,
            child: Builder(builder: (context) {
              seen = MediaQuery.of(context);
              layout = DenLayout.of(context);
              return const SizedBox.shrink();
            }),
          ),
        );
    await tester.pumpWidget(app());
    expect(layout, DenWidth.regular, reason: 'the open Fold has the sidebar');

    // The keyboard is up, and Flutter now draws in the 440 above it.
    media = const MediaQueryData(size: Size(820, 440));
    page.value = const WebViewport(width: 820, height: 760, keyboard: 320, editing: true);
    await tester.pumpWidget(app());
    expect(layout, DenWidth.regular, reason: 'still the sidebar while typing');
    expect(seen.viewInsets.bottom, 0, reason: 'Android\'s keyboard is Flutter\'s to measure');

    // The arrow, as Flutter 3.38.5 has it without the page's help.
    media = const MediaQueryData(size: Size(820, 440), viewInsets: EdgeInsets.only(bottom: -320));
    await tester.pumpWidget(app());
    expect(seen.viewInsets.bottom, 0, reason: 'nothing lays out under a negative inset');
    expect(layout, DenWidth.regular);
  });

  testWidgets('An item\'s sheet over the keyboard, then the close arrow: back down, the words kept, a tap brings the keyboard back', (tester) async {
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
        builder: (context, child) =>
            WebSafeArea(insets: const [47, 0, 34, 0], viewport: page, keyboardFromPage: true, child: child),
        home: Scaffold(body: SafeArea(child: ListDetailScreen(id: groceriesList(state.den)!.list.id))),
      ),
    ));
    await tester.pumpAndSettle();
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;

    await tester.longPress(find.text('Toothpaste'));
    await tester.pumpAndSettle();
    final field = find.byWidgetPredicate((w) => w is TextField && w.controller?.text == 'Toothpaste');
    final controller = tester.widget<TextField>(field).controller!;
    final focus = tester.widget<EditableText>(find.descendant(of: field, matching: find.byType(EditableText))).focusNode;
    await tester.showKeyboard(field);
    await tester.enterText(field, 'Toothpaste, mint');
    // The keyboard comes up: Flutter and the page agree.
    tester.view.viewInsets = const FakeViewPadding(bottom: 336);
    page.value = const WebViewport(keyboard: 336, editing: true);
    await tester.pumpAndSettle();
    final save = find.text('Save');
    final saveOverKeyboard = tester.getBottomLeft(save).dy;
    final titleTop = tester.getTopLeft(find.text('Edit item')).dy;
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/web_keyboard_up_phone_night.png'));

    // The keyboard's close arrow: Flutter heard nothing; the page says the keyboard is gone and
    // lets go of the field, so Flutter's text connection closes.
    page.value = const WebViewport(keyboard: 0, editing: false);
    tester.testTextInput.closeConnection();
    await tester.pumpAndSettle();
    final saveDown = tester.getBottomLeft(save).dy;
    final typed = controller.text;
    final focused = focus.hasFocus;
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/web_keyboard_closed_phone_night.png'));

    // A tap on the field: the keyboard comes back for it.
    await tester.tap(find.byWidgetPredicate((w) => w is TextField && identical(w.controller, controller)));
    await tester.pumpAndSettle();
    final again = tester.testTextInput.isVisible && focus.hasFocus;
    FlutterError.onError = previous;

    expect(saveOverKeyboard, lessThanOrEqualTo(844 - 336), reason: 'Save sits over the keyboard');
    expect(titleTop, greaterThan(47), reason: 'the sheet stays under the status bar');
    expect(saveDown, greaterThan(844 - 120), reason: 'the sheet is back at the bottom');
    expect(typed, 'Toothpaste, mint', reason: 'what was typed is still there');
    expect(focused, isFalse, reason: 'the field let go, as after Return');
    expect(again, isTrue, reason: 'a tap on the field brings the keyboard back');
    expect(errors, isEmpty, reason: 'nothing overflows on the way');
  });

  testWidgets('Ask\'s field over the keyboard, then the close arrow: back down, the words kept', (tester) async {
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
        builder: (context, child) =>
            WebSafeArea(insets: const [47, 0, 34, 0], viewport: page, keyboardFromPage: true, child: child),
      ),
    ));
    await tester.pumpAndSettle();
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;

    // Today's pill opens Ask; its field takes the words.
    await tester.tap(find.text('Ask about your day'));
    await tester.pumpAndSettle();
    final field = find.descendant(of: find.byType(AskScreen), matching: find.byType(TextField));
    await tester.tap(field);
    await tester.enterText(field, 'Who is driving Zoe');
    final controller = tester.widget<TextField>(field).controller!;
    final ask = find.descendant(of: find.byType(AskScreen), matching: find.widgetWithText(FilledButton, 'Ask'));
    final resting = tester.getBottomLeft(ask).dy;

    // The keyboard comes up: Flutter and the page agree.
    tester.view.viewInsets = const FakeViewPadding(bottom: 336);
    page.value = const WebViewport(keyboard: 336, editing: true);
    await tester.pumpAndSettle();
    final lifted = tester.getBottomLeft(ask).dy;
    final doneTop = tester.getTopLeft(find.text('Done')).dy;

    // The keyboard's close arrow: Flutter's own reading stays stale; the page lets go.
    page.value = const WebViewport(keyboard: 0, editing: false);
    tester.testTextInput.closeConnection();
    await tester.pumpAndSettle();
    final down = tester.getBottomLeft(ask).dy;
    FlutterError.onError = previous;

    expect(lifted, lessThanOrEqualTo(844 - 336), reason: 'the field and Ask sit over the keyboard');
    expect(doneTop, greaterThan(47), reason: 'Ask stays under the status bar');
    expect(down, resting, reason: 'Ask is back where it was');
    expect(controller.text, 'Who is driving Zoe', reason: 'what was typed is still there');
    expect(errors, isEmpty, reason: 'nothing overflows on the way');
  });
}
