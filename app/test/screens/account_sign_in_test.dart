import 'package:den_app/app/app_state.dart';
import 'package:den_app/features/settings/screens/sign_in_account_screen.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'family_fakes.dart';

/// The family's hub, as far as binding goes, answering at once.
class FakeSignIn implements AccountSignInSource {
  List<SignInProvider> offered = const [SignInProvider('google', 'Google'), SignInProvider('apple', 'Apple')];
  final started = <String>[];
  BindingState next = const BindingWaiting();
  int polls = 0;

  @override
  Future<List<SignInProvider>> providers() async => offered;

  @override
  Future<BindingStart> start(String provider) async {
    started.add(provider);
    return BindingStart(id: 'b${started.length}', provider: provider, startUrl: Uri.parse('https://den.example.com/auth/oidc/$provider/start?bind=t'));
  }

  @override
  Future<BindingState> poll(String id) async {
    polls++;
    return next;
  }
}

Future<void> _tapAndWait(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 400));
  });
  await tester.pumpAndSettle();
}

/// Settings → Google or Apple sign-in (phase 1 of docs/auth/ACCOUNT_FIRST_REVIEW.md): a parent's
/// own phone binds the account the hub's sign-in found, after saying which it is.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late AppState state;
  late FakeSignIn hub;
  late List<Uri> opened;
  late bool opens;

  Widget screen() => SignInAccountScreen(
        source: hub,
        open: (url) async {
          opened.add(url);
          return opens;
        },
        pollEvery: const Duration(milliseconds: 100),
      );

  Future<void> start(WidgetTester tester) async {
    state = await demo(tester);
    hub = FakeSignIn();
    opened = [];
    opens = true;
    await pumpScreen(tester, screen(), state: state, size: const Size(390, 1400));
  }

  testWidgets('a parent binds their Google account: the browser signs in, they say yes, their phone writes it', (tester) async {
    await start(tester);
    final me = state.den.actor!;
    expect(find.text('No account yet'), findsOneWidget);
    expect(find.text('Sign in with Google'), findsOneWidget);
    expect(find.text('Sign in with Apple'), findsOneWidget);

    await tester.tap(find.text('Sign in with Google'));
    await tester.pump();
    await tester.pump();
    expect(hub.started, ['google']);
    expect(opened.single.toString(), 'https://den.example.com/auth/oidc/google/start?bind=t');
    expect(find.textContaining('Finish signing in in your browser'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 250));
    expect(hub.polls, greaterThan(0));
    expect(me.account, isNull);

    final account = AccountRef('google', accountHash(state.den.familyId!, 'google', '108812345'));
    hub.next = BindingDone(account, 'alex@example.com');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(find.textContaining('alex@example.com (Google)'), findsOneWidget);
    expect(state.den.member(me.id)!.account, isNull, reason: 'nothing is bound before the parent says yes');

    await _tapAndWait(tester, find.text('Use this account'));
    expect(state.den.member(me.id)!.account, account);
    expect(find.text('Your Google account'), findsOneWidget);
    expect(find.text('alex@example.com'), findsOneWidget);
    expect(find.text('Use another Google account'), findsOneWidget);

    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await _tapAndWait(tester, find.text('Remove it'));
    expect(state.den.member(me.id)!.account, isNull);
    expect(find.text('No account yet'), findsOneWidget);
  });

  testWidgets('a sign-in that didn\'t work says why, and binds nothing', (tester) async {
    await start(tester);
    await tester.tap(find.text('Sign in with Apple'));
    await tester.pump();
    hub.next = const BindingFailed('Den doesn\'t take Hide My Email addresses. Choose Share My Email.');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(find.textContaining('Hide My Email'), findsOneWidget);
    expect(state.den.actor!.account, isNull);
    expect(find.text('Sign in with Apple'), findsOneWidget, reason: 'and it can start again');
  });

  testWidgets('a page that doesn\'t open by itself gets a button that opens it', (tester) async {
    state = await demo(tester);
    hub = FakeSignIn();
    opened = [];
    opens = false;
    await pumpScreen(tester, screen(), state: state);
    await tester.tap(find.text('Sign in with Google'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Open the sign-in page'), findsOneWidget);
    await tester.tap(find.text('Open the sign-in page'));
    await tester.pump();
    expect(opened, hasLength(2));
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(find.text('Sign in with Google'), findsOneWidget);
  });

  testWidgets('a hub that offers neither says so', (tester) async {
    state = await demo(tester);
    hub = FakeSignIn()..offered = const [];
    opened = [];
    opens = true;
    await pumpScreen(tester, screen(), state: state);
    expect(find.textContaining('doesn\'t offer signing in with Google or Apple yet'), findsOneWidget);
    expect(find.text('Sign in with Google'), findsNothing);
  });
}
