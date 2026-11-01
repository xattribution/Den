@Timeout(Duration(seconds: 180))
library;

// Real networking over localhost: a kitchen screen opened at the family's hub shows a code, a
// parent types it on her own phone, approves it there, and the screen joins as a shared display
// nobody owns. Plain `test`s (no widget binding), so sockets and timers are real.
import 'package:den_app/platform/sync/den_network.dart';
import 'package:den_app/platform/sync/local_hub.dart';
import 'package:den_app/platform/sync/net_pairing.dart';
import 'package:den_app/platform/sync/pairing.dart';
import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart' show ScreenCode;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

Future<void> until(bool Function() done, {Duration timeout = const Duration(seconds: 40), String? what}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for ${what ?? 'a condition'}');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<Den> freshDen() async => Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());

LocalHub noHub() => LocalHub.create(port: 0, mdns: false);

void main() {
  setUpAll(tzdata.initializeTimeZones);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// A family whose hub runs on a free port, with Sam's phone syncing with it.
  Future<(Den hubDen, DenHub hub, Den phone, NetPairing pairing)> family() async {
    final hubDen = await freshDen();
    final hub = await DenHub.start(hubDen, HubConfig(port: 0, mdns: false, log: HubLog.silent(), name: 'Closet hub'));
    addTearDown(hub.stop);
    final phone = await freshDen();
    await phone.createFamily(
      familyName: 'The Testers',
      timezone: 'America/Chicago',
      yourName: 'Sam',
      marker: Marker.sky,
      animal: Animal.cat,
      deviceName: "Sam's phone",
      deviceKind: DeviceKind.phone,
    );
    final network = DenNetwork(phone, localHub: noHub());
    addTearDown(network.dispose);
    final pairing = NetPairing(network);
    final info = await pairing.hubStatus('127.0.0.1:${hub.port}');
    final setup = pairing.setUpHub(info, hub.setupCode!);
    await until(() => setup.stage == HubSetupStage.confirm || setup.stage == HubSetupStage.failed, what: 'the hub to ask');
    await setup.approve();
    await until(() => hub.ready, what: 'the hub to be ready');
    await until(() => network.status.state.name == 'live', what: 'the phone to sync with the hub');
    return (hubDen, hub, phone, pairing);
  }

  /// A tablet opened at the hub's address, with no family yet.
  Future<(Den, NetPairing)> tablet(DenHub hub) async {
    final den = await freshDen();
    final network = DenNetwork(den, localHub: noHub());
    addTearDown(network.dispose);
    return (den, NetPairing(network, servedBy: Uri.parse('http://127.0.0.1:${hub.port}/')));
  }

  test('A kitchen screen joins with the code it shows, typed on a parent\'s phone', () async {
    final (hubDen, hub, phone, pairing) = await family();
    final (screen, screenPairing) = await tablet(hub);

    final session = await screenPairing.showScreenCode(deviceName: 'Kitchen iPad', kind: DeviceKind.tablet);
    addTearDown(session.dispose);
    expect(session.stage, ScreenStage.waiting);
    expect(session.code, hasLength(8));
    expect(session.link, 'http://127.0.0.1:${hub.port}/#/add-screen/${session.code}');
    expect(screen.hasFamily, isFalse, reason: 'nothing is written on the screen before a parent adds it');

    // Typed the way people type it: lower case, with a space.
    final typed = ScreenCode.format(session.code).replaceAll('-', ' ').toLowerCase();
    final ask = await pairing.findScreen(typed);
    expect(ask.name, 'Kitchen iPad');
    expect(ask.device, screen.deviceId);
    expect(phone.device(screen.deviceId), isNull, reason: 'finding the screen writes nothing');

    await pairing.addScreen(ask, name: 'Kitchen');
    final added = phone.device(screen.deviceId)!;
    expect(added.approved, isTrue);
    expect(added.mode, DeviceMode.shared);
    expect(added.member, isNull);
    expect(added.name, 'Kitchen');
    expect(added.rec.fields['approvedBy'], phone.owner!.id, reason: 'approved and signed on the parent\'s own phone');

    await until(() => screen.isApproved, what: 'the screen to be let in');
    await until(() => session.stage == ScreenStage.approved, what: 'the screen to move on');
    expect(screen.thisDevice!.mode, DeviceMode.shared);
    expect(screen.thisDevice!.member, isNull);
    expect(screen.family!.name, 'The Testers');
    expect(hubDen.device(screen.deviceId)!.approved, isTrue);
    await until(() => hub.screens.waiting == 0, what: 'the hub to forget the code');

    // Used once.
    await expectLater(pairing.findScreen(session.code), throwsA(isA<PairingException>()));
  });

  test('A wrong code finds nothing and writes nothing', () async {
    final (_, hub, phone, pairing) = await family();
    final (_, screenPairing) = await tablet(hub);
    final session = await screenPairing.showScreenCode(deviceName: 'Kitchen iPad', kind: DeviceKind.tablet);
    addTearDown(session.dispose);
    final before = phone.devices.length;
    final wrong = session.code == 'K7QM3RXA' ? 'K7QM3RXB' : 'K7QM3RXA';
    await expectLater(
      pairing.findScreen(wrong),
      throwsA(isA<PairingException>().having((e) => e.message, 'message', contains("That code isn't right"))),
    );
    await expectLater(
      pairing.findScreen('K7QM'),
      throwsA(isA<PairingException>().having((e) => e.message, 'message', contains('8 letters and numbers'))),
    );
    expect(phone.devices.length, before);
    expect(session.stage, ScreenStage.waiting, reason: 'the real code still works');
  });
}
