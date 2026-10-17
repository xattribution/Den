import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/net/den_network.dart';
import 'package:den_app/net/local_hub.dart';
import 'package:den_app/net/pairing.dart';
import 'package:den_net/den_net.dart' show SyncNode;
import 'package:den_app/state/app_state.dart';
import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';

/// Pairing that answers at once with fixed words, for screenshots of invites, approvals and joins.
class FakePairing extends PairingService {
  FakePairing({
    this.pending = const [],
    this.status,
    required this.now,
    this.found = const [],
    this.hubInfo,
    this.setup,
    this.link,
  });

  final List<PendingJoin> pending;
  final JoinStatus? status;
  final DateTime now;
  final List<FoundHub> found;
  final HubInfo? hubInfo;
  final HubSetupSession? setup;
  final BrowserLinkSession? link;

  @override
  Future<List<FoundHub>> findHubs() async => found;

  @override
  Future<HubInfo> hubStatus(String address) async =>
      hubInfo ?? (throw const PairingException("Couldn't reach a hub at that address."));

  @override
  HubSetupSession setUpHub(HubInfo hub, String code) => setup!;

  @override
  Future<BrowserLinkSession> linkThisBrowser({required String Function() deviceName}) async =>
      link ?? (throw const PairingException(LocalOnlyPairing.message));

  @override
  Future<String> answerBrowserLink(String code) async => 'Closet hub';

  @override
  Future<JoinTicket> joinWithQr(String uri, {required String deviceName, required DeviceKind kind}) async =>
      const JoinTicket(familyId: 'FAMILY', words: ['maple', 'river', 'candle']);

  @override
  Future<JoinTicket> joinWithCode(String words, {String? hubUrl, required String deviceName, required DeviceKind kind}) async =>
      const JoinTicket(familyId: 'FAMILY', words: ['maple', 'river', 'candle']);

  @override
  Stream<JoinStatus> get joinStatus => status == null ? const Stream.empty() : Stream.value(status!);

  @override
  Future<String> createInviteQr() async =>
      'den://join?f=7Q2KX4M9PA3TBV6W&fk=Zm91bmRlcg&d=8CQ3HPLA&k=aW52aXRlcg&s=c2VjcmV0c2VjcmV0MTI4&h=http://192.168.1.20:47733&x=1792170000000';

  @override
  Future<SpokenCode> createSpokenCode() async => SpokenCode(
        words: const ['maple', 'river', 'candle', 'tiger'],
        expires: now.add(const Duration(minutes: 9, seconds: 42)).millisecondsSinceEpoch,
      );

  @override
  Stream<List<PendingJoin>> get pendingJoins => Stream.value(pending);
}

/// Pumps [screen] the way `shoot` does, without comparing, so a test can act before the shot.
Future<void> pumpScreen(
  WidgetTester tester,
  Widget screen, {
  required AppState state,
  Size size = phone,
  bool night = false,
  PairingService? pairing,
}) async {
  await loadFonts();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final scale = state.wall ? DenType.wallScale : 1.0;
  Widget child = Scaffold(body: SafeArea(child: screen));
  if (pairing != null) child = PairingScope(service: pairing, child: child);
  await tester.pumpWidget(
    DenScope(
      state: state,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: denTheme(night ? DenColors.night : DenColors.day, typeScale: scale),
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Compares the current frame with `test/goldens/<name>.png`.
Future<void> matchShot(String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/$name.png'));

/// Pumps and compares in one step, with an optional pairing service in scope.
Future<void> shootWith(
  WidgetTester tester,
  String name,
  Widget screen, {
  required AppState state,
  Size size = phone,
  bool night = false,
  PairingService? pairing,
}) async {
  await pumpScreen(tester, screen, state: state, size: size, night: night, pairing: pairing);
  await matchShot(name);
}

/// The demo family's kids, oldest first by tier, and a parent.
Member kidOf(AppState state, {int index = 0}) => state.den.members.where((m) => m.isKid).elementAt(index);
Member parentOf(AppState state) => state.den.members.firstWhere((m) => m.isParent);

/// The demo family, built outside the test's fake clock: the engine's PBKDF2 for sign-ins
/// pauses on real timers, which never fire inside `testWidgets` without `runAsync`.
Future<AppState> demo(WidgetTester tester, {bool wall = false}) async => (await tester.runAsync(() => demoState(wall: wall)))!;

/// Runs engine work (writes, sign-in hashing) on the real clock.
Future<T> real<T>(WidgetTester tester, Future<T> Function() work) async => (await tester.runAsync(work)) as T;

/// A fresh engine with no family, for onboarding screens.
Future<AppState> empty(WidgetTester tester) async => (await tester.runAsync(emptyState))!;

/// A fresh engine with no family, for onboarding screens.
Future<AppState> emptyState() async {
  final den = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: () => demoNow.millisecondsSinceEpoch);
  return AppState(den);
}

/// The demo family as a new shared display on the kitchen wall sees it: joined, approved by
/// Alex's phone as a shared display, and synced the family space.
Future<AppState> kitchen(WidgetTester tester, {String layout = 'week', bool openCheckoff = false}) => real(tester, () async {
      final phone = await createDemoFamily(now: demoNow);
      final display = await Den.open(
        storage: MemoryStorage(),
        keys: await DeviceKeys.generate(),
        now: () => demoNow.millisecondsSinceEpoch,
      );
      await display.requestJoin(
        familyId: phone.familyId!,
        founderPubkey: phone.founderPubkey!,
        deviceName: 'Kitchen wall',
        kind: DeviceKind.display,
        mode: DeviceMode.shared,
      );
      await phone.ingest(display.changesSince(phone.versionVector));
      await phone.approveDevice(display.deviceId, mode: DeviceMode.shared);
      await phone.updateDevice(display.deviceId, {
        'display': {'layout': layout, 'openCheckoff': openCheckoff},
      });
      await display.ingest(phone.changesSince(display.versionVector, spaces: phone.spacesForDevice(display.deviceId)));
      return AppState(display, wall: true);
    });

/// The demo family as a little kid's own tablet sees it (Leo's), joined and approved for him.
Future<AppState> littleKidTablet(WidgetTester tester) => real(tester, () async {
      final phone = await createDemoFamily(now: demoNow);
      final leo = phone.members.firstWhere((m) => m.tier == Tier.little);
      final tablet = await Den.open(
        storage: MemoryStorage(),
        keys: await DeviceKeys.generate(),
        now: () => demoNow.millisecondsSinceEpoch,
      );
      await tablet.requestJoin(
        familyId: phone.familyId!,
        founderPubkey: phone.founderPubkey!,
        deviceName: "Leo's tablet",
        kind: DeviceKind.tablet,
        memberId: leo.id,
      );
      await phone.ingest(tablet.changesSince(phone.versionVector));
      await phone.approveDevice(tablet.deviceId, member: leo.id, mode: DeviceMode.personal);
      await tablet.ingest(phone.changesSince(tablet.versionVector, spaces: phone.spacesForDevice(tablet.deviceId)));
      return AppState(tablet);
    });

/// A fixed hub, for screenshots of adding one.
final HubInfo closetHub = HubInfo(
  base: Uri.parse('http://192.168.1.20:47733'),
  paired: false,
  device: 'H7Q2KX4M9PA3TBV6',
  name: 'Closet hub',
  stage: 'waiting_for_code',
);

/// A hub setup frozen at one stage.
class FakeHubSetup extends HubSetupSession {
  FakeHubSetup(this.stage, {this.error});
  @override
  final HubSetupStage stage;
  @override
  final String? error;
  @override
  HubInfo get hub => closetHub;
  @override
  List<String> get words => const ['lantern', 'meadow', 'copper'];
  @override
  Future<void> approve() async {}
  @override
  Future<void> cancel() async {}
}

/// A browser link code waiting for a phone.
class FakeBrowserLink extends BrowserLinkSession {
  FakeBrowserLink({required this.expires, this.stage = LinkStage.waiting});
  @override
  final int expires;
  @override
  final LinkStage stage;
  @override
  String get uri => 'den://link?hub=H7Q2KX4M9PA3TBV6&slot=c2xvdHNsb3RzbG90c2xvdA&u=http%3A%2F%2F192.168.1.20%3A47733';
  @override
  Uri get hub => Uri.parse('http://192.168.1.20:47733');
  @override
  String? get error => null;
  @override
  JoinTicket? get ticket => null;
  @override
  Future<void> cancel() async {}
}

/// An in-process hub frozen in one state, for Settings screenshots.
class FakeLocalHub extends LocalHub {
  FakeLocalHub({this.state = LocalHubState.off, this.connected = 0, this.error});
  @override
  final LocalHubState state;
  @override
  final int connected;
  @override
  final String? error;
  @override
  List<Uri> get addresses => state == LocalHubState.running ? [Uri.parse('http://192.168.1.20:47733')] : const [];
  @override
  SyncNode? get node => null;
  @override
  Future<void> start(Den den, {Uri? relay}) async {}
  @override
  Future<void> stop() async {}
}

/// The demo family with this device's network; with [hub], Alex's phone is the family's hub.
Future<AppState> networked(WidgetTester tester, {LocalHub? localHub, bool hub = false, List<Uri> hubs = const []}) =>
    real(tester, () async {
      final state = await demoState();
      if (hub) await state.den.setThisDeviceMode(DeviceMode.hub);
      final network = DenNetwork(state.den, localHub: localHub ?? FakeLocalHub(), hubs: hubs);
      return AppState(state.den, network: network);
    });
