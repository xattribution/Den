import 'package:den_app/features/onboarding/screens/first_boot_screen.dart';
import 'package:den_app/features/onboarding/screens/start_family_screen.dart';
import 'package:den_app/platform/sync/hub_client.dart';
import 'package:den_app/platform/sync/server_setup.dart';
import 'package:den_net/den_net.dart' show RecoveryWords;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';

/// A fresh server's first-boot pages, as the server would answer them: what it was sent, and
/// a tunnel that connects once told to.
class FakeFirstBoot implements FirstBootSource {
  FakeFirstBoot({this.address, this.connects = true, this.saysAddress = true, this.onDisk = const []});

  String? address;
  bool token = false;
  bool connected = false;
  bool connects;
  bool saysAddress;
  bool made = false;
  bool chose = false;
  final List<BackupItem> onDisk;
  final tokens = <String>[];
  final restores = <Map<String, Object?>>[];
  HubException? refuseRestore;
  BackupFileInfo uploaded = const BackupFileInfo(familyName: 'The Riveras', names: ['Alex', 'Priya'], madeAt: 1792036620000);

  FirstBootState get _state => FirstBootState(
        internet: InternetState(available: true, token: token, connected: connected),
        address: address,
        setupLink: '${address ?? 'http://192.168.1.50:47733'}/#/setup/3JKN-BEKA/3uhgitwjccsopjlo',
      );

  @override
  Future<FirstBootState> state() async {
    if (token && connects) {
      connected = true;
      if (saysAddress) address ??= 'https://den.rivera.family';
    }
    return _state;
  }

  @override
  Future<FirstBootState> saveToken(String pasted) async {
    if (!pasted.contains('eyJ')) throw const HubException('That isn\'t a tunnel token. Copy the long one Cloudflare shows for the tunnel (it starts with eyJ).');
    tokens.add(pasted);
    token = true;
    return _state;
  }

  @override
  Future<FirstBootState> saveAddress(String a) async {
    address = 'https://${a.trim()}';
    return _state;
  }

  @override
  Future<void> chooseFamily() async => chose = true;

  @override
  Future<List<FoundNas>> findNas() async => const [];

  @override
  Future<List<String>> shares(NasPlace place) async {
    if (place.password != 'nas-secret') throw const HubException('The NAS didn\'t accept that username and password.');
    return const ['backups', 'photos'];
  }

  @override
  Future<List<BackupItem>> backups({NasPlace? place}) async => place == null
      ? onDisk
      : const [
          BackupItem(name: 'den-2026-10-28-0817.denbackup', size: 2210000, at: 1792138620000),
          BackupItem(name: 'den-2026-10-27-0817.denbackup', size: 2200000, at: 1792052220000),
        ];

  @override
  Future<BackupFileInfo> upload(List<int> bytes) async => uploaded;

  @override
  Future<String?> restore({required String from, String? name, NasPlace? place, String? words, String? passphrase}) async {
    restores.add({'from': from, 'name': name, 'place': place?.toJson(), 'words': words, 'passphrase': passphrase});
    if (refuseRestore != null) throw refuseRestore!;
    return 'The Riveras';
  }

  @override
  Future<bool> paired() async => made;
}

const Size laptop = Size(1280, 800);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final opened = <Uri>[];
  Widget screen(FakeFirstBoot hub, {FirstBootStep? at, VoidCallback? here}) => FirstBootScreen(
        source: hub,
        onMakeHere: here ?? () {},
        poll: const Duration(milliseconds: 100),
        initial: at,
        open: (u) async {
          opened.add(u);
          return true;
        },
        pickFile: () async => (name: 'den-2026-10-28-0817.denbackup', bytes: const [1, 2, 3]),
      );

  Future<void> pump(WidgetTester tester, FakeFirstBoot hub, {FirstBootStep? at, Size size = phone}) async {
    final state = await empty(tester);
    await pumpScreen(tester, screen(hub, at: at), state: state, size: size);
  }

  testWidgets('paste the token: it connects, the address comes from the tunnel, and the token is gone from the page', (tester) async {
    final hub = FakeFirstBoot();
    await pump(tester, hub);
    expect(findWords('Connect Den to the internet'), findsOneWidget);
    expect(findWords('Paste your Cloudflare tunnel token.'), findsOneWidget);
    await tester.tap(findWords('How do I get one?'));
    expect(opened.last.toString(), 'https://github.com/xattribution/Den#cloudflare');

    await tester.enterText(find.byType(TextField), 'not one');
    await tester.tap(findWords('Connect'));
    await tester.pumpAndSettle();
    expect(find.textContaining('it starts with eyJ'), findsOneWidget);

    const token = 'eyJhIjoiYWNjb3VudCIsInQiOiJ0dW5uZWwiLCJzIjoic2VjcmV0In0=';
    await tester.enterText(find.byType(TextField), 'cloudflared service install $token');
    await tester.tap(findWords('Connect'));
    await tester.pump();
    expect(hub.tokens.single, contains(token));
    expect(findWords('Connecting'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(findWords('Connected'), findsOneWidget);
    expect(find.text('den.rivera.family'), findsOneWidget);
    expect(find.textContaining(token), findsNothing);
    await tester.tap(findWords('Next'));
    await tester.pumpAndSettle();
    expect(findWords('Make your family'), findsOneWidget);
  });

  testWidgets('a tunnel that doesn\'t say its address: asked for', (tester) async {
    final hub = FakeFirstBoot(saysAddress: false)..token = true;
    await pump(tester, hub);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 110));
    }
    await tester.pumpAndSettle();
    expect(findWords('Your family\'s address'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'den.rivera.family');
    await tester.tap(findWords('Save'));
    await tester.pumpAndSettle();
    expect(find.text('den.rivera.family'), findsOneWidget);
  });

  testWidgets('skip: only at home; make your family with a QR code, and the page moves on once the phone made it', (tester) async {
    final hub = FakeFirstBoot();
    await pump(tester, hub);
    await tester.tap(findWords('Skip — only at home for now'));
    await tester.pumpAndSettle();
    await tester.tap(findWords('Make your family'));
    await tester.pumpAndSettle();
    expect(hub.chose, isTrue);
    expect(findWords('Finish on your phone'), findsOneWidget);
    hub.made = true;
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(findWords('You\'re all set'), findsOneWidget);
  });

  testWidgets('restore a file from this device with the recovery words', (tester) async {
    final hub = FakeFirstBoot(address: 'https://den.rivera.family')..token = true;
    await pump(tester, hub, at: FirstBootStep.choose);
    await tester.tap(findWords('Restore from a backup'));
    await tester.pumpAndSettle();
    await tester.tap(findWords('A file on this device'));
    await tester.pumpAndSettle();
    expect(findWords('Your recovery words'), findsOneWidget);
    expect(find.textContaining('Alex or Priya'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'maple river');
    await tester.tap(findWords('Restore'));
    await tester.pumpAndSettle();
    expect(findWords('Type all 12 words. 2 so far.'), findsOneWidget);
    expect(hub.restores, isEmpty);

    final words = RecoveryWords.generate();
    hub.refuseRestore = const HubException('Those words don\'t open this backup. It opens with the recovery words of Alex or Priya.');
    await tester.enterText(find.byType(TextField), words.join(' '));
    await tester.tap(findWords('Restore'));
    await tester.pumpAndSettle();
    expect(find.textContaining('don\'t open this backup'), findsOneWidget);
    hub.refuseRestore = null;
    await tester.tap(findWords('Restore'));
    await tester.pumpAndSettle();
    expect(hub.restores.last, containsPair('from', 'upload'));
    expect(hub.restores.last['words'], words.join(' '));
    expect(findWords('Your family is back'), findsOneWidget);
    expect(find.textContaining('find it by themselves'), findsOneWidget);
  });

  testWidgets('restore from the NAS: typed address, sign in, a shared folder, the newest backup', (tester) async {
    final hub = FakeFirstBoot();
    await pump(tester, hub, at: FirstBootStep.restoreFrom);
    await tester.tap(findWords('On your NAS'));
    await tester.pumpAndSettle();
    expect(findWords('Type your NAS\'s name or address.'), findsOneWidget, reason: 'none answered on the network');
    await tester.enterText(find.byType(TextField), '192.168.1.40');
    await tester.tap(findWords('Next'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'james');
    await tester.enterText(fields.at(1), 'wrong');
    await tester.tap(findWords('Connect'));
    await tester.pumpAndSettle();
    expect(find.textContaining('didn\'t accept'), findsOneWidget);
    await tester.enterText(fields.at(1), 'nas-secret');
    await tester.tap(findWords('Connect'));
    await tester.pumpAndSettle();
    expect(findWords('backups'), findsOneWidget);
    await tester.tap(findWords('Find backups'));
    await tester.pumpAndSettle();
    expect(findWords('Pick a backup'), findsOneWidget);
    await tester.tap(findWords('Next'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), RecoveryWords.generate().join(' '));
    await tester.tap(findWords('Restore'));
    await tester.pumpAndSettle();
    final sent = hub.restores.single;
    expect(sent['from'], 'nas');
    expect(sent['name'], 'den-2026-10-28-0817.denbackup', reason: 'the newest, picked for her');
    expect((sent['place']! as Map)['share'], 'backups');
  });

  testWidgets('the setup link on a fresh server shows the first boot first; "on this device" goes to the family form',
      (tester) async {
    final state = await empty(tester);
    final hub = FakeFirstBoot();
    await pumpScreen(
      tester,
      StatefulBuilder(builder: (context, _) {
        return StartFamilyScreen(
          initialTimeZone: 'America/Chicago',
          setupCode: '3JKN-BEKA',
          hubDevice: '3uhgitwjccsopjlo',
          browser: false,
          firstBoot: hub,
        );
      }),
      state: state,
    );
    expect(findWords('Connect Den to the internet'), findsOneWidget);
    await tester.tap(findWords('Skip — only at home for now'));
    await tester.pumpAndSettle();
    await tester.tap(findWords('Make your family'));
    await tester.pumpAndSettle();
    await tester.tap(findWords('Make it on this device instead'));
    await tester.pumpAndSettle();
    expect(findWords('Create family'), findsOneWidget);
  });

  group('shots', () {
    for (final (name, size) in [('phone', phone), ('laptop', laptop)]) {
      testWidgets('internet, $name', (tester) async {
        await pump(tester, FakeFirstBoot(), size: size);
        await matchShot('first_boot_internet_$name');
      });
      testWidgets('connected, $name', (tester) async {
        await pump(tester, FakeFirstBoot(address: 'https://den.rivera.family')..token = true, at: FirstBootStep.connected, size: size);
        await matchShot('first_boot_connected_$name');
      });
      testWidgets('choose, $name', (tester) async {
        await pump(tester, FakeFirstBoot(address: 'https://den.rivera.family')..token = true, at: FirstBootStep.choose, size: size);
        await matchShot('first_boot_choose_$name');
      });
      testWidgets('finish on your phone, $name', (tester) async {
        await pump(tester, FakeFirstBoot(address: 'https://den.rivera.family')..token = true, at: FirstBootStep.family, size: size);
        await matchShot('first_boot_family_$name');
      });
      testWidgets('restore from, $name', (tester) async {
        await pump(tester, FakeFirstBoot(onDisk: const [BackupItem(name: 'den-2026-10-28-0817.denbackup', size: 2210000, at: 1792138620000)]),
            at: FirstBootStep.restoreFrom, size: size);
        await matchShot('first_boot_restore_from_$name');
      });
      testWidgets('recovery words, $name', (tester) async {
        final hub = FakeFirstBoot();
        await pump(tester, hub, at: FirstBootStep.restoreFrom, size: size);
        await tester.tap(findWords('A file on this device'));
        await tester.pumpAndSettle();
        await matchShot('first_boot_words_$name');
      });
    }
    testWidgets('the address asked for, phone', (tester) async {
      await pump(tester, FakeFirstBoot()..token = true, at: FirstBootStep.address);
      await matchShot('first_boot_address_phone');
    });
    testWidgets('the NAS\'s sign-in, phone', (tester) async {
      await pump(tester, FakeFirstBoot(), at: FirstBootStep.nas);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'nas.local');
      await tester.tap(findWords('Next'));
      await tester.pumpAndSettle();
      await matchShot('first_boot_nas_sign_in_phone');
    });
    testWidgets('restored, phone', (tester) async {
      await pump(tester, FakeFirstBoot(address: 'https://den.rivera.family')..token = true, at: FirstBootStep.restored);
      await matchShot('first_boot_restored_phone');
    });
  });
}
