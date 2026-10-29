import 'package:den_app/platform/sync/den_network.dart';
import 'package:den_app/platform/sync/hub_client.dart';
import 'package:den_app/platform/sync/local_hub.dart';
import 'package:den_app/platform/sync/pairing.dart';
import 'package:den_app/features/advanced/screens/add_hub_screen.dart';
import 'package:den_app/features/advanced/screens/hub_screen.dart';
import 'package:den_app/features/family/family.dart' show TrustActions;
import 'package:den_app/features/advanced/screens/nearby_device_screen.dart';
import 'package:den_app/features/advanced/screens/link_browser_screen.dart';
import 'package:den_app/features/onboarding/screens/link_this_browser_screen.dart';
import 'package:den_app/features/onboarding/screens/welcome_screen.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final found = [
    FoundHub(name: 'Closet hub', base: Uri.parse('http://192.168.1.20:47733')),
    FoundHub(name: 'Basement NAS', base: Uri.parse('http://192.168.1.31:47733'), familyId: 'SOMEONEELSE'),
  ];

  testWidgets('Add a device offers hubs and browsers', (tester) async {
    final state = await demo(tester);
    await shootWith(
      tester,
      'settings_hub_phone',
      const HubScreen(),
      state: state,
      pairing: FakePairing(now: demoNow),
    );
  });

  testWidgets('A device in the same room: a code to scan, or four words', (tester) async {
    final state = await demo(tester);
    await shootWith(
      tester,
      'settings_nearby_device_phone',
      NearbyDeviceScreen(now: () => demoNow),
      state: state,
      size: const Size(390, 1100),
      pairing: FakePairing(now: demoNow),
      pushed: true,
    );
    expect(find.text('maple river candle tiger'), findsOneWidget);
  });

  testWidgets('A device in the same room, without a hub or relay, says so', (tester) async {
    final state = await demo(tester);
    await pumpScreen(tester, const NearbyDeviceScreen(), state: state);
    expect(findWords(LocalOnlyPairing.message), findsOneWidget);
  });

  testWidgets('Add a hub, phone', (tester) async {
    final state = await demo(tester);
    final pairing = FakePairing(now: demoNow, found: found);
    await pumpScreen(tester, const AddHubScreen(), state: state, pairing: pairing);
    await tester.tap(find.text('Closet hub'));
    await tester.enterText(find.widgetWithText(TextField, 'ABCD-EFGH'), 'K7MP-Q2XR');
    await tester.pumpAndSettle();
    await matchShot('family_add_hub_phone');
  });

  testWidgets('Add a hub, tablet, night', (tester) async {
    final state = await demo(tester);
    await shootWith(
      tester,
      'family_add_hub_tablet_night',
      const AddHubScreen(),
      state: state,
      size: tablet,
      night: true,
      pairing: FakePairing(now: demoNow, found: found),
    );
  });

  testWidgets('Add a hub, words to approve', (tester) async {
    final state = await demo(tester);
    await shootWith(
      tester,
      'family_add_hub_confirm_phone',
      AddHubScreen(session: FakeHubSetup(HubSetupStage.confirm)),
      state: state,
      pairing: FakePairing(now: demoNow),
    );
  });

  testWidgets('Add a hub, words differ', (tester) async {
    final state = await demo(tester);
    await shootWith(
      tester,
      'family_add_hub_words_differ_phone',
      AddHubScreen(session: FakeHubSetup(HubSetupStage.confirm, hubWords: const ['harbor', 'violet', 'pencil'])),
      state: state,
      pairing: FakePairing(now: demoNow),
    );
    final approve = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Approve Closet hub'));
    expect(approve.onPressed, isNull, reason: "a hub whose words differ can't be approved");
  });

  testWidgets("Add a hub, words the hub didn't report", (tester) async {
    final state = await demo(tester);
    await pumpScreen(
      tester,
      AddHubScreen(session: FakeHubSetup(HubSetupStage.confirm, hubWords: const [])),
      state: state,
      pairing: FakePairing(now: demoNow),
    );
    expect(find.textContaining("didn't report its words"), findsOneWidget);
    final approve = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Approve Closet hub'));
    expect(approve.onPressed, isNotNull);
  });

  testWidgets('Add a hub, wrong code', (tester) async {
    final state = await demo(tester);
    await shootWith(
      tester,
      'family_add_hub_failed_phone',
      AddHubScreen(
        session: FakeHubSetup(
          HubSetupStage.failed,
          error: "That setup code isn't right. Check it in the hub's log: 4 more tries, then the hub makes you wait a minute.",
        ),
      ),
      state: state,
      pairing: FakePairing(now: demoNow),
    );
  });

  testWidgets('Add a hub, done, night', (tester) async {
    final state = await demo(tester);
    await shootWith(
      tester,
      'family_add_hub_done_phone_night',
      AddHubScreen(session: FakeHubSetup(HubSetupStage.done)),
      state: state,
      night: true,
      pairing: FakePairing(now: demoNow),
    );
  });

  testWidgets('Link a browser, paste the code', (tester) async {
    final state = await demo(tester);
    await shootWith(
      tester,
      'family_link_browser_phone',
      const LinkBrowserScreen(scan: false),
      state: state,
      pairing: FakePairing(now: demoNow),
    );
  });

  testWidgets('Link a browser, approve it', (tester) async {
    final state = await demo(tester);
    await shootWith(
      tester,
      'family_link_browser_approve_phone',
      const LinkBrowserScreen(scan: false, linkedTo: 'Closet hub'),
      state: state,
      pairing: FakePairing(
        now: demoNow,
        pending: const [PendingJoin(deviceId: 'BROWSER1', deviceName: 'Kitchen laptop', kind: DeviceKind.browser)],
      ),
    );
  });

  testWidgets('Welcome in a browser leads with linking', (tester) async {
    final state = await empty(tester);
    await shootWith(tester, 'onboarding_welcome_browser_tablet', const WelcomeScreen(browser: true), state: state, size: tablet);
  });

  testWidgets('Link this browser', (tester) async {
    final state = await empty(tester);
    final link = FakeBrowserLink(expires: demoNow.add(const Duration(minutes: 9, seconds: 12)).millisecondsSinceEpoch);
    await shootWith(
      tester,
      'onboarding_link_browser_tablet',
      LinkThisBrowserScreen(now: () => demoNow),
      state: state,
      size: tablet,
      pairing: FakePairing(now: demoNow, link: link),
    );
  });

  testWidgets('Link this browser, phone, night', (tester) async {
    final state = await empty(tester);
    final link = FakeBrowserLink(expires: demoNow.add(const Duration(minutes: 9, seconds: 12)).millisecondsSinceEpoch);
    await shootWith(
      tester,
      'onboarding_link_browser_phone_night',
      LinkThisBrowserScreen(now: () => demoNow),
      state: state,
      night: true,
      pairing: FakePairing(now: demoNow, link: link),
    );
  });

  testWidgets('Settings, This device with sync, hub address and relay', (tester) async {
    final state = await networked(tester, hubs: [Uri.parse('ws://192.168.1.20:47733/ws')]);
    await pumpScreen(tester, const HubScreen(), state: state);
    await tester.drag(find.byType(ListView).first, const Offset(0, -260));
    await tester.pumpAndSettle();
    await matchShot('settings_sync_phone');
  });

  testWidgets('Settings, this computer keeps the family online', (tester) async {
    final state = await networked(
      tester,
      hub: true,
      localHub: FakeLocalHub(state: LocalHubState.running, connected: 3),
    );
    expect(state.den.actor?.name, 'Alex');
    await shootWith(tester, 'settings_hub_running_tablet', const HubScreen(), state: state, size: tablet);
  });

  testWidgets('Settings, the hub could not start, night', (tester) async {
    final state = await networked(
      tester,
      hub: true,
      localHub: FakeLocalHub(
        state: LocalHubState.failed,
        error: 'Port 47733 is already in use, maybe by another Den hub on this computer. Stop that one, then turn this on again.',
      ),
    );
    await pumpScreen(tester, const HubScreen(), state: state, night: true);
    await tester.drag(find.byType(ListView).first, const Offset(0, -260));
    await tester.pumpAndSettle();
    await matchShot('settings_hub_failed_phone_night');
  });

  testWidgets('Hub and sync lists the hubs after a reset, newest in use first, and removes the old one', (tester) async {
    final r = await replacedHub(tester);
    final den = r.state.den;
    expect(r.state.network!.hubDevices.map((d) => d.id), [r.newHub, r.oldHub]);
    expect(r.state.network!.hubDevice!.id, r.newHub, reason: 'not name order: both are "Den hub"');
    await pumpScreen(tester, const HubScreen(), state: r.state, size: const Size(390, 1240));
    expect(find.text('Hubs'), findsOneWidget);
    // (The clock's "AM" follows a narrow no-break space.)
    expect(find.textContaining(RegExp(r'^Last seen today at 7:56\sAM · Added Oct 16$')), findsOneWidget);
    expect(find.text('Last seen Oct 2 · Added Sep 18'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Remove').last);
    await tester.pumpAndSettle();
    expect(find.textContaining("devices stop looking for it"), findsOneWidget);
    await matchShot('settings_hubs_remove_phone');
    await tester.runAsync(() async {
      await tester.tap(find.text('Remove Den hub'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pumpAndSettle();
    expect(den.device(r.oldHub)!.revoked, isTrue);
    expect(den.device(r.newHub)!.revoked, isFalse);
    expect(find.text('The hub'), findsOneWidget, reason: 'one hub left');
  });

  testWidgets("Hubs are removed only on a parent's own personal device, not on a hub", (tester) async {
    final r = await replacedHub(tester);
    final den = r.state.den;
    // Alex's computer keeping the family online is a hub, though Alex owns it.
    await tester.runAsync(() => den.setThisDeviceMode(DeviceMode.hub));
    await pumpScreen(tester, const HubScreen(), state: r.state, size: const Size(390, 1240));
    expect(find.text('Hubs'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Remove'), findsNothing);
    expect(() => TrustActions(den).removeHub(r.oldHub), throwsA(isA<PermissionDenied>()));
    expect(den.device(r.oldHub)!.revoked, isFalse);
  });

  testWidgets('Adding a hub where an older one answered offers to remove the old one', (tester) async {
    final r = await replacedHub(tester);
    final den = r.state.den;
    final network = r.state.network!;
    expect(network.hubsAt(Uri.parse('http://192.168.1.20:47733'), except: r.newHub).map((d) => d.id), [r.oldHub]);
    expect(network.hubsAt(Uri.parse('http://192.168.1.31:47733'), except: r.newHub), isEmpty, reason: 'another address');
    await pumpScreen(
      tester,
      AddHubScreen(session: FakeHubSetup(HubSetupStage.done), replaces: [den.device(r.oldHub)!]),
      state: r.state,
      pairing: FakePairing(now: demoNow),
    );
    expect(find.textContaining(RegExp(r'^The Den hub added Sep 18\sused this address before')), findsOneWidget);
    await matchShot('family_add_hub_replaces_phone');
    await tester.runAsync(() async {
      await tester.tap(find.text('Remove the old hub'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pumpAndSettle();
    expect(den.device(r.oldHub)!.revoked, isTrue);
    expect(find.text('Removed the old Den hub.'), findsOneWidget);
  });

  test('Which hub a phone tries first, and where it saw each', () {
    final seen = HubSighting.decode(HubSighting.encode({
      'H1': HubSighting(5, Uri.parse('wss://den.example.com:443/ws')),
      'H2': const HubSighting(7, null),
    }));
    expect(seen['H1']!.at, 5);
    expect(seen['H1']!.address.toString(), 'wss://den.example.com:443/ws');
    expect(seen['H2']!.address, isNull);
    expect(HubSighting.decode('not json'), isEmpty);
  });

  test('Hub addresses as people type them', () {
    expect(HubClient.baseFor('192.168.1.20').toString(), 'http://192.168.1.20:47733');
    expect(HubClient.baseFor('den-hub.local:8080').toString(), 'http://den-hub.local:8080');
    expect(HubClient.baseFor('https://den.example.com').toString(), 'https://den.example.com');
    expect(HubClient.baseFor('  '), isNull);
    final link = LinkCode.parse('den://link?hub=H1&slot=S1&u=http%3A%2F%2F192.168.1.20%3A47733');
    expect(link?.hubDevice, 'H1');
    expect(link?.base.toString(), 'http://192.168.1.20:47733');
    expect(LinkCode.parse('den://join?f=x'), isNull);
  });
}
