import 'package:den_app/features/advanced/screens/server_screen.dart';
import 'package:den_app/features/settings/screens/backups_screen.dart';
import 'package:den_app/features/settings/screens/settings_screen.dart';
import 'package:den_app/features/today/state/needs_you.dart';
import 'package:den_app/features/today/widgets/needs_you_card.dart';
import 'package:den_app/platform/sync/hub_client.dart';
import 'package:den_app/platform/sync/server_setup.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';

/// Oct 28, 2026, 3:17 AM in the test's time zone: last night's backup.
final int lastNight = DateTime(2026, 10, 28, 3, 17).millisecondsSinceEpoch;
final int morning = DateTime(2026, 10, 28, 9, 30).millisecondsSinceEpoch;

/// The server, as far as Settings goes: what it was sent, never a password said back.
class FakeServer implements ServerSource {
  FakeServer({this.problem, this.update, this.notHost = false});

  BackupProblem? problem;
  UpdateState? update;
  bool notHost;
  NasPlace? place;
  final sentTokens = <String>[];
  final sentPlaces = <NasPlace>[];
  int runs = 0;
  int updates = 0;

  BackupsState get _backups => BackupsState(
        lastAt: lastNight,
        lastSize: 2210000,
        problem: problem,
        place: place == null ? null : NasPlace.fromJson({...place!.toJson()..remove('password'), 'has_password': true}),
        placeLastAt: place == null || problem != null ? null : lastNight,
        opensWith: const ['Alex'],
      );

  ServerState get _server => ServerState(
        version: update?.current ?? 'v1.2.0',
        internet: const InternetState(available: true, token: true, connected: true),
        address: 'https://den.rivera.family',
        update: update,
      );

  void _check() {
    if (notHost) throw const HubException('Set up by whoever runs this server.', code: 'host_family_only');
  }

  @override
  Future<BackupsState> backups() async {
    _check();
    return _backups;
  }

  @override
  Future<BackupsState> backUpNow() async {
    runs++;
    problem = null;
    return _backups;
  }

  @override
  Future<List<FoundNas>> findNas() async => const [];

  @override
  Future<List<String>> shares(NasPlace place) async {
    if (place.password != 'nas-secret') throw const HubException('The NAS didn\'t accept that username and password.');
    return const ['backups', 'photos'];
  }

  @override
  Future<BackupsState> setPlace(NasPlace p) async {
    sentPlaces.add(p);
    place = p;
    return _backups;
  }

  @override
  Future<BackupsState> clearPlace() async {
    place = null;
    return _backups;
  }

  @override
  Future<ServerState> server() async {
    _check();
    return _server;
  }

  @override
  Future<ServerState> saveToken(String pasted) async {
    sentTokens.add(pasted);
    return _server;
  }

  @override
  Future<ServerState> updateNow() async {
    updates++;
    update = UpdateState(current: update!.current, available: update!.available, state: 'updating');
    return _server;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Backups', () {
    testWidgets('last night\'s backup, its size, whose words open it; Back up now', (tester) async {
      final state = await demo(tester);
      final server = FakeServer();
      await pumpScreen(tester, BackupsScreen(source: server, now: morning), state: state, pushed: true);
      expect(find.textContaining(RegExp(r'2\.1\sMB')), findsOneWidget);
      expect(find.textContaining('recovery words of Alex'), findsOneWidget);
      await tester.tap(findWords('Back up now'));
      await tester.pumpAndSettle();
      expect(server.runs, 1);
      await matchShot('settings_backups_phone');
    });

    testWidgets('a NAS that couldn\'t be reached is said plainly', (tester) async {
      final state = await demo(tester);
      final server = FakeServer(problem: BackupProblem(kind: 'unreachable', at: lastNight, place: true))
        ..place = const NasPlace(host: '192.168.1.40', name: 'Family NAS', share: 'backups', user: 'james');
      await pumpScreen(tester, BackupsScreen(source: server, now: morning), state: state, pushed: true);
      expect(find.textContaining('Couldn\'t reach Family NAS last night'), findsOneWidget);
      expect(state.backupProblem?.kind, 'unreachable');
      await matchShot('settings_backups_problem_phone');
    });

    testWidgets('Back up to a NAS: its address, its sign-in, a shared folder; the password goes to the server only', (tester) async {
      final state = await demo(tester);
      final server = FakeServer();
      await pumpScreen(tester, BackupsScreen(source: server, now: morning), state: state, pushed: true, size: const Size(390, 1000));
      await tester.tap(findWords('Back up to a NAS'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'nas.local');
      await tester.tap(findWords('Next'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'james');
      await tester.enterText(find.byType(TextField).at(1), 'nas-secret');
      await tester.tap(findWords('Connect'));
      await tester.pumpAndSettle();
      await matchShot('settings_backups_nas_share_phone');
      await tester.tap(findWords('Use this folder'));
      await tester.pumpAndSettle();
      final sent = server.sentPlaces.single;
      expect(sent.host, 'nas.local');
      expect(sent.share, 'backups');
      expect(sent.folder, 'Den backups');
      expect(sent.password, 'nas-secret');
      expect(findWords('Backups'), findsOneWidget, reason: 'back on Backups');
      expect(find.textContaining('nas-secret'), findsNothing);
      expect(findWords('Stop copying to the NAS'), findsOneWidget);
    });

    testWidgets('another family on the server sees nothing of it', (tester) async {
      final state = await demo(tester);
      await pumpScreen(tester, BackupsScreen(source: FakeServer(notHost: true)), state: state, pushed: true);
      expect(find.textContaining('Whoever runs your family\'s server'), findsOneWidget);
      expect(findWords('Back up now'), findsNothing);
    });
  });

  group('Server', () {
    testWidgets('Update available: Update now asks the server', (tester) async {
      final state = await demo(tester);
      final server = FakeServer(update: const UpdateState(current: 'v1.2.0', available: 'v1.3.0'));
      await pumpScreen(tester, ServerScreen(source: server), state: state, pushed: true);
      expect(findWords('Update available: v1.3.0'), findsOneWidget);
      await matchShot('settings_server_update_phone');
      await tester.tap(findWords('Update now'));
      await tester.pumpAndSettle();
      expect(server.updates, 1);
      expect(find.textContaining('Den restarts'), findsOneWidget);
    });

    testWidgets('no updater: no update row; a new tunnel token is sent and not kept on the page', (tester) async {
      final state = await demo(tester);
      final server = FakeServer();
      await pumpScreen(tester, ServerScreen(source: server), state: state, pushed: true);
      expect(find.textContaining('Update'), findsNothing);
      expect(findWords('Connected'), findsOneWidget);
      await tester.tap(findWords('Change the tunnel token'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'eyJhIjoiYSIsInQiOiJ0IiwicyI6InMifQ==');
      await tester.tap(findWords('Save token'));
      await tester.pumpAndSettle();
      expect(server.sentTokens.single, 'eyJhIjoiYSIsInQiOiJ0IiwicyI6InMifQ==');
      expect(find.textContaining('eyJhIjoiYSIs'), findsNothing);
    });
  });

  testWidgets('Settings: the Backups row for the server\'s own family, saying a failure plainly', (tester) async {
    final state = await demo(tester);
    final server = FakeServer(problem: BackupProblem(kind: 'unreachable', at: lastNight, place: true));
    await pumpScreen(tester, SettingsScreen(version: '1.0.0', server: server), state: state, pushed: true, size: const Size(390, 1400));
    await tester.pumpAndSettle();
    expect(findWords('Backups'), findsOneWidget);
    expect(find.textContaining('Couldn\'t reach the NAS'), findsOneWidget);
  });

  testWidgets('Needs you says a failed backup once; Got it puts it away for good', (tester) async {
    final state = await demo(tester);
    final now = state.den.now();
    final problem = BackupProblem(kind: 'unreachable', at: now - 6 * 3600000, place: true);
    state.backupProblem = problem;
    expect(needsYou(state, now: now).whereType<BackupNeed>(), hasLength(1));
    await pumpScreen(tester, NeedsYouSection(now: now), state: state, size: const Size(390, 1200));
    expect(find.textContaining('Couldn\'t reach the NAS'), findsOneWidget);
    state.markSeen(BackupNeed(problem).key);
    expect(needsYou(state, now: now).whereType<BackupNeed>(), isEmpty);
    state.backupProblem = BackupProblem(kind: 'no_words', at: now);
    expect(needsYou(state, now: now).whereType<BackupNeed>(), isEmpty, reason: 'the recovery words reminder says that');
  });
}
