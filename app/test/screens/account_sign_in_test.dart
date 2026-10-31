import 'package:den_app/app/app_state.dart';
import 'package:den_app/features/family/state/family_needs.dart';
import 'package:den_app/features/settings/screens/sign_in_account_screen.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/shots.dart' show demoState;
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

/// The hub's proof that [member] of [state]'s family signed in with the Google account [sub],
/// from a hub device the family approves here.
Future<AccountRef> _proved(WidgetTester tester, AppState state, String member, String sub) async => (await tester.runAsync(() async {
      final den = state.den;
      final hub = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
      await hub.requestJoin(
          familyId: den.familyId!, founderPubkey: den.founderPubkey!, deviceName: 'Hub', kind: DeviceKind.hub, mode: DeviceMode.hub);
      await den.ingest(hub.changesSince(const {}));
      await den.approveDevice(hub.deviceId, mode: DeviceMode.hub);
      return AccountProof.sign(
        keys: hub.keys,
        hub: hub.deviceId,
        family: den.familyId!,
        member: member,
        provider: 'google',
        hash: accountHash(den.familyId!, 'google', sub),
        nonce: b64e(randomBytes(32)),
        expires: den.clockMillis + accountProofLife.inMilliseconds,
      );
    }))!;

Future<void> _tapAndWait(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 600));
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

    final account = await _proved(tester, state, me.id, '108812345');
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

  test('a start link opens only on one of the hub\'s own https addresses (finding F5)', () {
    final bases = [Uri.parse('https://den.example.com'), Uri.parse('http://192.168.1.20:47733')];
    expect(startUrlAllowed(Uri.parse('https://den.example.com/auth/oidc/google/start?bind=t'), bases), isTrue);
    expect(startUrlAllowed(Uri.parse('https://DEN.example.com/auth/oidc/google/start?bind=t'), bases), isTrue);
    for (final bad in [
      'https://evil.example/auth/oidc/google/start?bind=t',
      'https://den.example.com.evil.example/auth',
      'https://den.example.com:8443/auth',
      'https://user@den.example.com/auth',
      'http://den.example.com/auth',
      'http://192.168.1.20:47733/auth',
      'https://192.168.1.20:47733/auth',
    ]) {
      expect(startUrlAllowed(Uri.parse(bad), bases), isFalse, reason: bad);
    }
  });

  test('an account two parents bound while apart is said in Needs you, and signs in as neither', () async {
    final app = await demoState();
    final den = app.den;
    final priya = den.members.firstWhere((m) => m.name == 'Priya').id;
    Future<Den> device(String name, DeviceMode mode, {String? member}) async {
      final d = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: den.now);
      await d.requestJoin(familyId: den.familyId!, founderPubkey: den.founderPubkey!, deviceName: name, kind: DeviceKind.phone, mode: mode, memberId: member);
      await den.ingest(d.changesSince(const {}));
      await den.approveDevice(d.deviceId, member: member, mode: mode);
      await d.ingest(den.changesSince(const {}));
      return d;
    }

    final hub = await device('Hub', DeviceMode.hub);
    final priyaPhone = await device('Priya phone', DeviceMode.personal, member: priya);
    Future<AccountRef> proved(String member) => AccountProof.sign(
          keys: hub.keys,
          hub: hub.deviceId,
          family: den.familyId!,
          member: member,
          provider: 'google',
          hash: accountHash(den.familyId!, 'google', 'shared-sub'),
          nonce: b64e(randomBytes(32)),
          expires: den.clockMillis + accountProofLife.inMilliseconds,
        );
    await den.setAccount(den.actor!.id, await proved(den.actor!.id));
    await priyaPhone.setAccount(priya, await proved(priya));
    await den.ingest(priyaPhone.changesSince(den.versionVector));
    final notice = familyNeeds(app, const []).whereType<SharedAccountNotice>().single;
    expect([for (final m in notice.members) m.name]..sort(), ['Alex', 'Priya']);
    expect(den.memberWithAccount(notice.account), isNull);
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
