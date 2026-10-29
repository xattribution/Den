import 'package:den_app/app/app_state.dart';
import 'package:den_app/design/widgets.dart' show DenSwitch;
import 'package:den_app/features/advanced/screens/advanced_screen.dart';
import 'package:den_app/features/advanced/screens/connect_guide_screen.dart';
import 'package:den_app/features/advanced/screens/connections_screen.dart';
import 'package:den_app/features/advanced/screens/create_token_screen.dart';
import 'package:den_app/features/advanced/screens/data_screen.dart';
import 'package:den_app/features/advanced/screens/displays_screen.dart';
import 'package:den_app/features/advanced/screens/home_assistant_screen.dart';
import 'package:den_app/features/advanced/widgets/hub_apps_section.dart';
import 'package:den_app/features/settings/screens/assistant_screen.dart';
import 'package:den_app/features/settings/screens/calendars_screen.dart';
import 'package:den_app/features/settings/screens/family_settings_screen.dart';
import 'package:den_app/features/settings/screens/settings_screen.dart';
import 'package:den_app/features/settings/state/assistant_hub.dart';
import 'package:den_app/features/settings/state/feed_links.dart';
import 'package:den_app/platform/web/web_app.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';

/// A demo family with a Home Assistant token, a kid's homework helper and a pending Claude request.
Future<AppState> connected(WidgetTester tester) => real(tester, () async {
      final state = await demoState();
      final den = state.den;
      final kid = kidOf(state);
      await den.addTokenConnection(label: 'Home Assistant', scopes: {Scope.read, Scope.calendar, Scope.chores, Scope.lists});
      await den.addTokenConnection(label: 'Homework helper', scopes: {Scope.read, Scope.lists}, member: kid.id);
      await den.requestOAuthConnection(label: 'Claude', client: 'claude.ai', scopes: {Scope.read, Scope.calendar, Scope.lists});
      return state;
    });

/// The hub's AI helper setup, answering at once.
class FakeAssistant implements AssistantSource {
  FakeAssistant(this.setup);

  AssistantSetup setup;
  final List<Map<String, Object?>> saved = [];

  @override
  Future<AssistantSetup> status() async => setup;

  @override
  Future<AssistantSetup> configure({String? provider, String? key, bool useCaptureKey = false, String? baseUrl}) async {
    saved.add({'provider': provider, 'key': key, 'use_capture_key': useCaptureKey, 'base_url': baseUrl});
    return setup = AssistantSetup(
      provider: provider,
      keySaved: provider != null,
      spentCents: setup.spentCents,
      budgetCents: setup.budgetCents,
    );
  }
}

/// The hub's calendar links, answering at once.
class FakeFeedLinks implements FeedLinksSource {
  final links = <FeedLink>[];
  final made = <(String, String)>[];

  @override
  Future<List<FeedLink>> list() async => [...links];

  @override
  Future<FeedLink> create({required String feed, required String label}) async {
    made.add((feed, label));
    final secret = 'denfeed_q3JxV8kd2Lmw';
    final link = FeedLink(
      id: 'L${made.length}',
      label: label,
      feed: feed,
      feedName: feed == 'family' ? 'The Carters' : 'Leo',
      made: demoNow.millisecondsSinceEpoch,
      url: 'https://den.example.com/ics/$secret/$feed.ics',
      webcal: 'webcal://den.example.com/ics/$secret/$feed.ics',
    );
    links.insert(0, link);
    return link;
  }

  @override
  Future<void> remove(String id) async => links.removeWhere((l) => l.id == id);
}

/// Den opened from an iPhone's Home Screen.
const iPhoneApp = WebAppInfo(ios: true, iosVersion: (major: 18, minor: 1), standalone: true, secure: true, push: true);

/// The apps a parent set up on the hub, answering at once.
class FakeApps implements HubAppsSource {
  FakeApps(this.apps);
  final List<HubApp> apps;

  @override
  Future<List<HubApp>> list() async => [...apps];

  @override
  Future<HubApp> create(String name, List<String> redirects) async {
    final app = HubApp(id: 'c_8Hq2', name: name, redirects: redirects, secret: 'den_s3cr3t_kq29xv', extra: const {
      'authorization_endpoint': 'https://den.example.com/oauth/authorize',
      'token_endpoint': 'https://den.example.com/oauth/token',
    });
    apps.add(app);
    return app;
  }

  @override
  Future<void> remove(String id) async => apps.removeWhere((a) => a.id == id);
}

/// Taps on the real clock, so the engine can sign what the tap writes.
Future<void> _tapAndWait(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 400));
  });
  await tester.pumpAndSettle();
}

const Size _tall = Size(390, 1800);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Settings', () {
    testWidgets('phone, day', (tester) async {
      final state = await connected(tester);
      await shootWith(tester, 'settings_phone', const SettingsScreen(version: '1.0.0'), state: state, size: _tall, pushed: true);
      expect(find.text('Encrypted backup'), findsNothing);
      expect(find.text('Mode'), findsNothing, reason: "a device's owner and mode don't change here");
    });

    testWidgets('phone, night', (tester) async {
      final state = await connected(tester);
      await shootWith(tester, 'settings_phone_night', const SettingsScreen(version: '1.0.0'), state: state, night: true, pushed: true);
    });

    testWidgets('tablet', (tester) async {
      final state = await connected(tester);
      await shootWith(tester, 'settings_tablet', const SettingsScreen(version: '1.0.0'), state: state, size: tablet, pushed: true);
    });

    testWidgets('Night is one tap', (tester) async {
      final state = await connected(tester);
      await pumpScreen(tester, const SettingsScreen(version: '1.0.0'), state: state, size: _tall);
      await tester.tap(find.text('Night'));
      await tester.pumpAndSettle();
      expect(state.theme, ThemeChoice.night);
    });

    testWidgets('in a browser, reminders come from the hub', (tester) async {
      final state = await connected(tester);
      await pumpScreen(tester, const SettingsScreen(version: '1.0.0', web: true), state: state, size: _tall);
      expect(findWords('Reminders on this browser'), findsOneWidget);
    });

    testWidgets('a kid sees no family, AI or Advanced', (tester) async {
      final state = await littleKidTablet(tester);
      await pumpScreen(tester, const SettingsScreen(version: '1.0.0'), state: state, size: _tall);
      expect(find.text('Family'), findsNothing);
      expect(find.text('AI helper'), findsNothing);
      expect(find.text('Advanced'), findsNothing);
    });
  });

  group('Settings, Family', () {
    testWidgets('phone', (tester) async {
      final state = await connected(tester);
      await shootWith(tester, 'settings_family_phone', const FamilySettingsScreen(), state: state, size: _tall, pushed: true);
    });

    testWidgets('a parent turns stars off and on', (tester) async {
      final state = await connected(tester);
      await pumpScreen(tester, const FamilySettingsScreen(), state: state, size: _tall);
      await _tapAndWait(tester, findWords('Points and rewards'));
      expect(state.den.family!.pointsEnabled, isFalse);
      await _tapAndWait(tester, findWords('Points and rewards'));
      expect(state.den.family!.pointsEnabled, isTrue);
    });

    testWidgets('"Show me first" sets the family to review', (tester) async {
      final state = await connected(tester);
      await pumpScreen(tester, const FamilySettingsScreen(), state: state, size: _tall);
      await _tapAndWait(tester, find.text('Show me first'));
      expect(state.den.family!.captureNeedsReview, isTrue);
    });
  });

  group('Settings, Calendars', () {
    testWidgets('a calendar by link, added and listed', (tester) async {
      final state = await connected(tester);
      await pumpScreen(tester, const CalendarsScreen(), state: state, size: _tall, pushed: true);
      await tester.enterText(find.widgetWithText(TextField, 'https://school.example.org/calendar.ics'), 'https://school.example.org/oak.ics');
      await tester.enterText(find.widgetWithText(TextField, 'Oak Grove School'), 'Oak Grove');
      await _tapAndWait(tester, find.text('Add calendar'));
      expect(state.den.subscriptions.single.url, 'https://school.example.org/oak.ics');
      expect(state.den.subscriptions.single.label, 'Oak Grove');
      await matchShot('settings_calendars_phone');
    });

    testWidgets('Show Den in iPhone Calendar is one tap: the hub makes the link and Calendar is asked to subscribe',
        (tester) async {
      final state = await connected(tester);
      final links = FakeFeedLinks();
      final opened = <Uri>[];
      await pumpScreen(
        tester,
        CalendarsScreen(
          feedLinks: links,
          web: iPhoneApp,
          openCalendar: (uri) async {
            opened.add(uri);
            return true;
          },
        ),
        state: state,
        size: _tall,
        pushed: true,
      );
      expect(find.text('Den in iPhone Calendar'), findsOneWidget);
      await _tapAndWait(tester, find.text('Show Den in iPhone Calendar'));
      expect(links.made.single, ('family', "Alex's iPhone"));
      expect(opened.single.toString(), 'webcal://den.example.com/ics/denfeed_q3JxV8kd2Lmw/family.ics');
      expect(find.text("Alex's iPhone"), findsOneWidget);
      expect(find.textContaining('should ask to'), findsOneWidget);
      await matchShot('settings_calendars_iphone_phone');
    });

    testWidgets("where Calendar doesn't open, it says how to add the link, with Copy link", (tester) async {
      final state = await connected(tester);
      final links = FakeFeedLinks();
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await pumpScreen(
        tester,
        CalendarsScreen(feedLinks: links, web: iPhoneApp, openCalendar: (_) async => false),
        state: state,
        size: _tall,
        pushed: true,
      );
      await _tapAndWait(tester, find.text('Show Den in iPhone Calendar'));
      expect(find.textContaining('Add Subscription Calendar'), findsOneWidget);
      await _tapAndWait(tester, find.text('Copy link'));
      expect(copied, 'https://den.example.com/ics/denfeed_q3JxV8kd2Lmw/family.ics');
      expect(find.text('Copied'), findsOneWidget);
      await matchShot('settings_calendars_iphone_fallback_phone');
    });

    testWidgets("one person's calendar, and turning a link off", (tester) async {
      final state = await connected(tester);
      final links = FakeFeedLinks();
      await pumpScreen(
        tester,
        CalendarsScreen(feedLinks: links, web: iPhoneApp, openCalendar: (_) async => true),
        state: state,
        size: _tall,
        pushed: true,
      );
      await tester.tap(find.text("Just one person's events"));
      await tester.pumpAndSettle();
      await _tapAndWait(tester, find.text('Leo'));
      expect(links.made.single.$1, state.den.members.firstWhere((m) => m.name == 'Leo').id);
      expect(find.textContaining("Leo's events"), findsOneWidget);
      await tester.tap(find.text('Turn off'));
      await tester.pumpAndSettle();
      await _tapAndWait(tester, find.text("Turn off Alex's iPhone"));
      expect(links.links, isEmpty);
    });

    testWidgets("an address that isn't one says so where it was typed", (tester) async {
      final state = await connected(tester);
      await pumpScreen(tester, const CalendarsScreen(), state: state, size: _tall);
      await tester.enterText(find.widgetWithText(TextField, 'https://school.example.org/calendar.ics'), 'http://192.168.1.4/cal.ics');
      await _tapAndWait(tester, find.text('Add calendar'));
      expect(state.den.subscriptions, isEmpty);
      await matchShot('settings_calendars_error_phone');
    });
  });

  group('Settings, AI helper', () {
    testWidgets('off by default, with what it shares in plain words', (tester) async {
      final state = await connected(tester);
      await shootWith(
        tester,
        'settings_assistant_off_phone',
        AssistantScreen(source: FakeAssistant(const AssistantSetup(budgetCents: 500))),
        state: state,
        size: _tall,
        pushed: true,
      );
      expect(state.den.family!.assistant.enabled, isFalse);
      expect(find.textContaining('Den keeps no copy of the conversation'), findsWidgets);
    });

    testWidgets('turning it on says what it shares, then saves on the yes', (tester) async {
      final state = await connected(tester);
      await pumpScreen(tester, AssistantScreen(source: FakeAssistant(const AssistantSetup(budgetCents: 500))), state: state, size: _tall);
      await tester.tap(find.byType(DenSwitch).first);
      await tester.pumpAndSettle();
      expect(state.den.family!.assistant.enabled, isFalse);
      await _tapAndWait(tester, find.text('Turn on'));
      expect(state.den.family!.assistant.enabled, isTrue);
    });

    testWidgets('on: who, the limits, this month, and who runs it', (tester) async {
      final state = await connected(tester);
      await real(tester, () => state.den.updateFamily({
            'assistant': const AssistantPolicy(enabled: true, members: {}).toJson(),
          }));
      final source = FakeAssistant(const AssistantSetup(provider: 'anthropic', keySaved: true, spentCents: 120, budgetCents: 500));
      await shootWith(tester, 'settings_assistant_on_phone', AssistantScreen(source: source), state: state, size: const Size(390, 2600), pushed: true);
      expect(findWords('About \$1.20 of \$5 this month'), findsOneWidget);
      final maya = state.den.members.firstWhere((m) => m.name == 'Maya');
      await tester.tap(find.text('Maya'));
      await tester.pumpAndSettle();
      await _tapAndWait(tester, find.text('Turn on'));
      expect(state.den.family!.assistant.members, {maya.id});
    });
  });

  group('Advanced', () {
    testWidgets('phone', (tester) async {
      final state = await connected(tester);
      await shootWith(tester, 'settings_advanced_phone', const AdvancedScreen(), state: state, pushed: true);
    });

    testWidgets('shared displays: the week or today, check-off, and Remove', (tester) async {
      final state = await connected(tester);
      await shootWith(tester, 'settings_displays_phone', const DisplaysScreen(), state: state, size: _tall, pushed: true);
      expect(find.text('Month'), findsNothing);
      expect(find.text('Photos'), findsNothing);
      expect(find.text('Lists'), findsNothing);
    });

    testWidgets('data', (tester) async {
      final state = await connected(tester);
      await shootWith(tester, 'settings_data_phone', const DataScreen(), state: state, pushed: true);
    });
  });

  group('AI and automations', () {
    testWidgets('phone', (tester) async {
      final state = await connected(tester);
      await shootWith(
        tester,
        'settings_connections_phone',
        ConnectionsScreen(apps: FakeApps([const HubApp(id: 'c_2kQ', name: 'Alexa', redirects: ['https://pitangui.amazon.com/api/skill/link/M2'])])),
        state: state,
        size: _tall,
        pushed: true,
      );
    });

    testWidgets('night', (tester) async {
      final state = await connected(tester);
      await shootWith(tester, 'settings_connections_phone_night', ConnectionsScreen(apps: FakeApps([])), state: state, night: true, pushed: true);
    });

    testWidgets('approving a request narrows what it may do', (tester) async {
      final state = await connected(tester);
      await pumpScreen(tester, ConnectionsScreen(apps: FakeApps([])), state: state);
      await tester.tap(find.text('Approve Claude'));
      await tester.pumpAndSettle();
      await matchShot('settings_connection_approve_phone');
    });

    testWidgets('setting up an app for Alexa+ shows its secret once', (tester) async {
      final state = await connected(tester);
      final apps = FakeApps([]);
      await pumpScreen(tester, ConnectionsScreen(apps: apps), state: state, size: _tall);
      await tester.tap(find.text('Set up an app'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'https://pitangui.amazon.com/api/skill/link/M2');
      await tester.tap(find.text('Set up the app'));
      await tester.pumpAndSettle();
      expect(find.text('den_s3cr3t_kq29xv'), findsOneWidget);
      await matchShot('settings_hub_app_secret_phone');
    });

    testWidgets('connecting an assistant: the address and the steps for each', (tester) async {
      final state = await connected(tester);
      await shootWith(
        tester,
        'settings_connect_guide_phone',
        const ConnectGuideScreen(address: 'https://den.example.com/mcp'),
        state: state,
        size: const Size(390, 3200),
        pushed: true,
      );
      for (final name in ['Claude', 'ChatGPT', 'Gemini', 'Grok', 'Siri', 'Alexa+']) {
        expect(find.text(name), findsOneWidget);
      }
    });

    testWidgets('make a token', (tester) async {
      final state = await demo(tester);
      await pumpScreen(tester, const CreateTokenScreen(), state: state, pushed: true);
      await tester.enterText(find.byType(TextField), 'Home Assistant');
      await tester.pumpAndSettle();
      await matchShot('settings_create_token_phone');
    });

    testWidgets('a token, shown once', (tester) async {
      final state = await demo(tester);
      await shootWith(
        tester,
        'settings_token_once_phone',
        const CreateTokenScreen(token: 'den_7Kq2mX9vB4nR8wT1pL6sY3hF0cJ5gD2a', label: 'Home Assistant'),
        state: state,
      );
    });

    testWidgets('Home Assistant', (tester) async {
      final state = await connected(tester);
      await shootWith(tester, 'settings_home_assistant_phone', const HomeAssistantScreen(), state: state, pushed: true);
    });
  });
}
