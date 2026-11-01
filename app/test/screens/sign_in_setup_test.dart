import 'package:den_app/app/app_state.dart';
import 'package:den_app/features/advanced/screens/sign_in_setup_screen.dart';
import 'package:den_app/platform/sync/hub_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/shots.dart' show phone;
import 'family_fakes.dart';

const String _clientId = '1234567890-abc123def456.apps.googleusercontent.com';
const String _secret = 'GOCSPX-only-the-hub-keeps-this';

/// The family's hub, as far as setting up sign-in goes, answering at once. It keeps what it was
/// given to check the screen sent it, and, like the hub, never says it back.
class FakeSetup implements SignInSetupSource {
  FakeSetup({this.families = const ['den.example.com', 'den-smith.example.com']});

  final List<String> families;
  bool google = false;
  bool apple = false;
  HubException? refuse;
  final sent = <Map<String, String>>[];

  ProviderSetup _one(bool on, String provider) => ProviderSetup(
        on: on,
        setAt: on ? DateTime(2026, 10, 3) : null,
        setBy: on ? 'Alex' : null,
        redirects: [for (final f in families) 'https://$f/auth/oidc/$provider/callback'],
        domains: provider == 'apple' ? families : const [],
      );

  SignInSetupStatus get _status =>
      SignInSetupStatus(google: _one(google, 'google'), apple: _one(apple, 'apple'), https: families.isNotEmpty);

  @override
  Future<SignInSetupStatus> status() async {
    if (refuse != null) throw refuse!;
    return _status;
  }

  @override
  Future<SignInSetupStatus> turnOnGoogle({required String clientId, required String clientSecret}) async {
    sent.add({'client_id': clientId, 'client_secret': clientSecret});
    if (refuse != null) throw refuse!;
    google = true;
    return _status;
  }

  @override
  Future<SignInSetupStatus> turnOnApple({required String servicesId, required String teamId, required String keyId, required String key}) async {
    sent.add({'services_id': servicesId, 'team_id': teamId, 'key_id': keyId, 'key': key});
    if (refuse != null) throw refuse!;
    apple = true;
    return _status;
  }

  @override
  Future<SignInSetupStatus> turnOff(String provider) async {
    if (provider == 'google') google = false;
    if (provider == 'apple') apple = false;
    return _status;
  }
}

/// Text holding [part], whatever spaces the line-breaking helpers made unbreakable.
Finder words(String part) => find.byWidgetPredicate(
      (w) => w is Text && ((w.data ?? w.textSpan?.toPlainText())?.replaceAll(RegExp('[  ]'), ' ').contains(part) ?? false),
      description: 'text containing "$part"',
    );

const String _p8 ='-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg\n-----END PRIVATE KEY-----\n';

/// Settings → Advanced → Sign in with Google or Apple: turning it on for the server from a
/// parent's phone, with the steps and addresses Google's console asks for.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late AppState state;
  late FakeSetup hub;
  final opened = <Uri>[];

  Widget screen({Future<PickedKey?> Function()? pick}) => SignInSetupScreen(
        source: hub,
        open: (u) async {
          opened.add(u);
          return true;
        },
        pickKey: pick,
      );

  Future<void> start(WidgetTester tester, {FakeSetup? with_, Size size = const Size(390, 2200)}) async {
    state = await demo(tester);
    hub = with_ ?? FakeSetup();
    opened.clear();
    await pumpScreen(tester, screen(), state: state, size: size, pushed: true);
    await tester.pumpAndSettle();
  }

  testWidgets('the steps, every family\'s address to copy, then the client: Google is on, and its secret never shows again',
      (tester) async {
    await start(tester);
    expect(words('Sign in with Google or Apple'), findsWidgets);
    expect(words('one for each family on your server'), findsOneWidget);
    expect(find.text('https://den.example.com/auth/oidc/google/callback'), findsOneWidget);
    expect(find.text('https://den-smith.example.com/auth/oidc/google/callback'), findsOneWidget);
    await tester.tap(find.text('Open Google\'s console'));
    expect(opened.single.host, 'console.cloud.google.com');

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    await tester.tap(find.text('Copy').first);
    await tester.pumpAndSettle();
    expect(copied, 'https://den.example.com/auth/oidc/google/callback');
    expect(find.text('Copied'), findsOneWidget);

    await tester.tap(find.text('Turn on Google'));
    await tester.pumpAndSettle();
    expect(words('Paste both'), findsOneWidget);
    expect(hub.sent, isEmpty);

    await tester.enterText(find.widgetWithText(TextField, '1234567890-abc.apps.googleusercontent.com'), ' $_clientId ');
    await tester.enterText(find.widgetWithText(TextField, 'GOCSPX-...'), _secret);
    await tester.tap(find.text('Turn on Google'));
    await tester.pumpAndSettle();
    expect(hub.sent.single, {'client_id': _clientId, 'client_secret': _secret});
    expect(find.text('On'), findsOneWidget);
    expect(find.text('Turned on by Alex, Oct 3'), findsOneWidget);
    expect(words(_secret), findsNothing);
    expect(words(_clientId), findsNothing);

    await tester.tap(find.text('Turn off'));
    await tester.pumpAndSettle();
    expect(words('Their accounts stay set up'), findsOneWidget);
    await tester.tap(find.text('Turn off').last);
    await tester.pumpAndSettle();
    expect(hub.google, isFalse);
    expect(find.text('Turn on Google'), findsOneWidget);
  });

  testWidgets('what the hub says is wrong is said under the boxes, and nothing turns on', (tester) async {
    await start(tester);
    hub.refuse = const HubException('Google doesn\'t know that client ID and secret together. Copy both again from the client\'s page.');
    await tester.enterText(find.widgetWithText(TextField, '1234567890-abc.apps.googleusercontent.com'), _clientId);
    await tester.enterText(find.widgetWithText(TextField, 'GOCSPX-...'), 'GOCSPX-wrong');
    await tester.tap(find.text('Turn on Google'));
    await tester.pumpAndSettle();
    expect(words('doesn\'t know that client ID'), findsOneWidget);
    expect(find.text('On'), findsNothing);
  });

  testWidgets('Apple: the .p8 picked as a file names its Key ID; the key goes to the hub, not the screen', (tester) async {
    state = await demo(tester);
    hub = FakeSetup();
    await pumpScreen(
      tester,
      screen(pick: () async => (name: 'AuthKey_XYZ987ABCD.p8', text: _p8)),
      state: state,
      size: const Size(390, 3000),
      pushed: true,
    );
    await tester.pumpAndSettle();
    expect(words('paid Apple Developer membership'), findsOneWidget);
    await tester.tap(find.text('Set up Apple'));
    await tester.pumpAndSettle();
    expect(find.text('den-smith.example.com'), findsOneWidget);
    expect(find.text('https://den.example.com/auth/oidc/apple/callback'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'family.den.signin'), 'family.den.signin');
    await tester.enterText(find.widgetWithText(TextField, 'ABCDE12345'), 'ABCDE12345');
    await tester.tap(find.text('Choose the .p8 file'));
    await tester.pumpAndSettle();
    expect(find.text('AuthKey_XYZ987ABCD.p8'), findsOneWidget);
    await tester.tap(find.text('Turn on Apple'));
    await tester.pumpAndSettle();
    expect(hub.sent.single, {'services_id': 'family.den.signin', 'team_id': 'ABCDE12345', 'key_id': 'XYZ987ABCD', 'key': _p8});
    expect(hub.apple, isTrue);
    expect(words('BEGIN PRIVATE KEY'), findsNothing);
  });

  testWidgets('a file that isn\'t a .p8 is said so, and nothing is sent', (tester) async {
    state = await demo(tester);
    hub = FakeSetup();
    await pumpScreen(tester, screen(pick: () async => (name: 'notes.txt', text: 'hello')), state: state, size: const Size(390, 3000));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set up Apple'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose the .p8 file'));
    await tester.pumpAndSettle();
    expect(words('notes.txt isn\'t a .p8 key'), findsOneWidget);
    expect(hub.sent, isEmpty);
  });

  testWidgets('another family on the server sees only who sets it up', (tester) async {
    await start(tester, with_: FakeSetup()..refuse = const HubException('nope', code: 'host_family_only'));
    expect(words('Whoever runs your family\'s server sets this up'), findsOneWidget);
    expect(find.text('Turn on Google'), findsNothing);
    expect(words('auth/oidc'), findsNothing);
  });

  group('shots', () {
    testWidgets('off, two families on the server', (tester) async {
      state = await demo(tester);
      hub = FakeSetup();
      await shootWith(tester, 'settings_sign_in_setup_phone', screen(), state: state, size: const Size(390, 1900), pushed: true);
    });

    testWidgets('Google on', (tester) async {
      state = await demo(tester);
      hub = FakeSetup(families: const ['den.example.com'])..google = true;
      await shootWith(tester, 'settings_sign_in_setup_on_phone', screen(), state: state, pushed: true);
    });

    testWidgets('Google on, night', (tester) async {
      state = await demo(tester);
      hub = FakeSetup(families: const ['den.example.com'])..google = true;
      await shootWith(tester, 'settings_sign_in_setup_on_phone_night', screen(), state: state, night: true, pushed: true);
    });

    testWidgets('Apple, set up with Google on', (tester) async {
      state = await demo(tester);
      hub = FakeSetup(families: const ['den.example.com'])..google = true;
      await pumpScreen(tester, screen(), state: state, size: const Size(390, 1900), pushed: true);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set up Apple'));
      await tester.pumpAndSettle();
      await matchShot('settings_sign_in_setup_apple_phone');
    });

    testWidgets('another family', (tester) async {
      state = await demo(tester);
      hub = FakeSetup()..refuse = const HubException('nope', code: 'host_family_only');
      await shootWith(tester, 'settings_sign_in_setup_other_family_phone', screen(), state: state, size: phone, pushed: true);
    });
  });
}
