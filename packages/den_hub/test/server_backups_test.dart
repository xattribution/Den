@Timeout(Duration(seconds: 180))
library;

import 'dart:convert';
import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';

import 'support/server_fixture.dart';
import 'support/test.dart';

/// The server's own backups and settings from a parent's phone (backups.dart, server_api.dart):
/// nightly to the disk, sealed to the recovery words; a NAS set up and tested from the phone,
/// its password kept owner-only and never said back; a failure said plainly; "Update now".
void main() {
  late Directory tmp;
  late List<String> words;
  late Den phone;
  late ServerFixture s;
  late int clock;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('den_server_');
    clock = DateTime.utc(2026, 10, 28, 9, 17).millisecondsSinceEpoch; // 4:17 AM in Chicago
    words = RecoveryWords.generate();
    final dir = '${tmp.path}/data';
    final (p, hub) = await familyAt(dir, words: words);
    phone = p;
    s = await ServerFixture.start(dir, hub,
        publicUrl: Uri.parse('https://den.rivera.test'), updater: FileUpdater('$dir/hub'), clock: () => clock);
  });

  tearDown(() async {
    await s.stop();
    await phone.close();
    await tmp.delete(recursive: true);
  });

  test('Back up now: on the server\'s disk, opened by Alex\'s recovery words alone', () async {
    final run = await s.signed(phone, 'POST', '/api/v1/hub/backups/run');
    expect(run.status, 200, reason: run.text);
    expect((run.body['last'] as Map)['at'], clock);
    expect((run.body['last'] as Map)['size'], greaterThan(100));
    expect(run.body['opens_with'], ['Alex']);
    expect(run.body['problem'], isNull);
    final file = File('${s.dir}/backups/${backupName(clock)}');
    expect(file.existsSync(), isTrue);
    if (!Platform.isWindows) expect(file.statSync().mode & 0x1ff, 0x180);
    final files = backupFilesOf(await openBackup(await file.readAsBytes(), words: words));
    expect(files.keys, containsAll(['keys.json', 'log/meta.json']));
    expect(files.keys.where((k) => k.contains(backupSettingsFile) || k.contains(tunnelTokenFile)), isEmpty,
        reason: 'what is the server\'s stays out');
  });

  test('the disk keeps the newest 14', () async {
    for (var i = 0; i < 16; i++) {
      clock += const Duration(days: 1).inMilliseconds;
      await s.host.backups.runNow();
    }
    expect(s.host.backups.onDisk(), hasLength(defaultBackupKeep));
    expect(s.host.backups.onDisk().first.name, backupName(clock));
  });

  test('the nightly run waits for the night in the family\'s time zone (Chicago)', () async {
    final b = s.host.backups;
    expect(b.due(), isFalse, reason: 'just started');
    clock = DateTime.utc(2026, 10, 29, 6, 17).millisecondsSinceEpoch; // 1:17 AM in Chicago, 21 hours on
    expect(b.due(), isFalse);
    clock = DateTime.utc(2026, 10, 29, 7, 17).millisecondsSinceEpoch; // 2:17 AM
    expect(b.due(), isTrue);
    await b.tick();
    expect(b.status.attemptAt, clock);
    expect(b.due(), isFalse, reason: 'done for tonight');
    clock += const Duration(hours: 31).inMilliseconds; // a missed night: 30 hours is enough
    expect(b.due(), isTrue);
  });

  test('a NAS: found, its shares listed, tested, saved; the password kept owner-only and never said back', () async {
    final found = await s.signed(phone, 'POST', '/api/v1/hub/backups/find');
    expect(found.body['found'], [
      {'name': 'Family NAS', 'host': '192.168.1.40'},
    ]);
    const nas = {'kind': 'nas', 'host': '192.168.1.40', 'name': 'Family NAS', 'user': 'james', 'password': 'nas-secret'};
    final shares = await s.signed(phone, 'POST', '/api/v1/hub/backups/shares', body: {'place': nas});
    expect(shares.body['shares'], ['backups', 'photos']);
    final missing = await s.signed(phone, 'PUT', '/api/v1/hub/backups/place', body: {
      'place': {...nas, 'share': 'nope'},
    });
    expect(missing.status, 422);
    expect((missing.error['details'] as Map)['problem'], 'missing');
    final wrong = await s.signed(phone, 'PUT', '/api/v1/hub/backups/place', body: {
      'place': {...nas, 'share': 'backups', 'password': 'wrong'},
    });
    expect((wrong.error['details'] as Map)['problem'], 'login');
    expect(s.host.backups.place, isNull, reason: 'nothing saved until it works');

    final saved = await s.signed(phone, 'PUT', '/api/v1/hub/backups/place', body: {
      'place': {...nas, 'share': 'backups'},
    });
    expect(saved.status, 200, reason: saved.text);
    expect(saved.text, isNot(contains('nas-secret')));
    expect((saved.body['place'] as Map)['has_password'], isTrue);
    expect((saved.body['place'] as Map)['share'], 'backups');
    expect(s.rclone.calls.map((c) => c.args.first), containsAll(['mkdir', 'rcat', 'deletefile']));
    expect(s.rclone.files.keys.where((k) => k.contains('.den-check')), isEmpty, reason: 'the test file is gone again');
    final settings = File('${s.dir}/hub/$backupSettingsFile');
    expect(settings.readAsStringSync(), contains('nas-secret'));
    if (!Platform.isWindows) expect(settings.statSync().mode & 0x1ff, 0x180);
    expect((await s.signed(phone, 'GET', '/api/v1/hub/backups')).text, isNot(contains('nas-secret')));
    expect(s.logged.where((l) => l.contains('nas-secret')), isEmpty);
    expect(s.rclone.calls.every((c) => !c.args.contains('nas-secret')), isTrue);

    // A change of folder needs no password again.
    final folder = await s.signed(phone, 'PUT', '/api/v1/hub/backups/place', body: {
      'place': {'kind': 'nas', 'host': '192.168.1.40', 'user': 'james', 'share': 'backups', 'folder': 'Rivera'},
    });
    expect(folder.status, 200, reason: folder.text);
    expect(s.host.backups.place?.password, 'nas-secret');

    final run = await s.signed(phone, 'POST', '/api/v1/hub/backups/run');
    expect((run.body['place'] as Map)['last_at'], clock);
    expect(s.rclone.files.keys, contains('backups/Rivera/${backupName(clock)}'));
  });

  test('a NAS that can\'t be reached: the disk copy is there, and the problem says so', () async {
    s.host.backups.setPlace(const BackupPlace(kind: 'nas', host: '192.168.1.40', share: 'backups', user: 'james', password: 'nas-secret'));
    s.rclone.failWith = 'couldn\'t connect SMB: dial tcp 192.168.1.40:445: i/o timeout';
    final run = await s.signed(phone, 'POST', '/api/v1/hub/backups/run');
    expect((run.body['last'] as Map)['at'], clock, reason: 'on the disk all the same');
    expect(run.body['problem'], {'kind': 'unreachable', 'at': clock, 'place': true});
    s.rclone.failWith = null;
    clock += 60000;
    final next = await s.signed(phone, 'POST', '/api/v1/hub/backups/run');
    expect(next.body['problem'], isNull, reason: 'it clears once one works');
  });

  test('nobody with recovery words: no backup, and the problem says why', () async {
    final alex = phone.members.firstWhere((m) => m.name == 'Alex');
    await phone.setRecoveryKey(alex.id, null);
    await s.own.den.ingest(phone.changesSince(s.own.den.versionVector));
    final run = await s.signed(phone, 'POST', '/api/v1/hub/backups/run');
    expect((run.body['problem'] as Map)['kind'], 'no_words');
    expect(run.body['opens_with'], isEmpty);
    expect(s.host.backups.onDisk(), isEmpty);
  });

  test('only a parent of the server\'s own family on their own phone', () async {
    for (final (name, mode) in [('Maya', DeviceMode.personal), (null, DeviceMode.shared)]) {
      final d = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
      addTearDown(d.close);
      final member = name == null ? null : phone.members.firstWhere((m) => m.name == name).id;
      await d.requestJoin(
        familyId: phone.familyId!,
        founderPubkey: phone.founderPubkey!,
        deviceName: '${name ?? 'Kitchen'} device',
        kind: mode == DeviceMode.shared ? DeviceKind.display : DeviceKind.phone,
        mode: mode,
        memberId: member,
      );
      await phone.ingest(d.changesSince(const {}));
      await phone.approveDevice(d.deviceId, member: member, mode: mode);
      await d.ingest(phone.changesSince(d.versionVector, spaces: phone.spacesForDevice(d.deviceId)), through: phone.completeVector);
      await s.own.den.ingest(phone.changesSince(s.own.den.versionVector));
      final get = await s.signed(d, 'GET', '/api/v1/hub/backups');
      expect(get.status, 403, reason: '${name ?? 'a shared screen'}: ${get.text}');
      final put = await s.signed(d, 'PUT', '/api/v1/hub/server/internet', body: {'token': fakeTunnelToken()});
      expect(put.status, 403);
    }
    expect(s.connector.tokens, isEmpty);
  });

  test('a new tunnel token from Settings goes to the connector and is never said back', () async {
    final token = fakeTunnelToken(secret: 'bmV3LXNlY3JldC1uZXctc2VjcmV0LW5ldy1zZWNyZXQ');
    final put = await s.signed(phone, 'PUT', '/api/v1/hub/server/internet', body: {'token': token});
    expect(put.status, 202, reason: put.text);
    expect(s.connector.tokens, [token]);
    expect(put.text, isNot(contains(token)));
    expect(s.logged.where((l) => l.contains(token)), isEmpty);
  });

  test('Update now: shown only when the updater says something newer, and asked through its file', () async {
    final before = await s.signed(phone, 'GET', '/api/v1/hub/server');
    expect(before.body.containsKey('update'), isFalse, reason: 'no updater files: no update row');
    expect(before.body['address'], 'https://den.rivera.test');
    final status = File('${s.dir}/hub/update.json')..createSync(recursive: true);
    status.writeAsStringSync(jsonEncode({'current': 'v1.2.0', 'available': 'v1.3.0', 'checked': '2026-10-28T03:17:00Z', 'state': 'available'}));
    final now = await s.signed(phone, 'GET', '/api/v1/hub/server');
    expect(now.body['version'], 'v1.2.0');
    expect(now.body['update'], {'current': 'v1.2.0', 'available': 'v1.3.0', 'checked': '2026-10-28T03:17:00Z', 'state': 'idle'});
    final asked = await s.signed(phone, 'POST', '/api/v1/hub/server/update');
    expect(asked.status, 202, reason: asked.text);
    expect(File('${s.dir}/hub/update-request').readAsStringSync(), contains('Alex'));
    expect((asked.body['update'] as Map)['state'], 'updating');
    status.writeAsStringSync(jsonEncode({'current': 'v1.3.0', 'available': 'v1.3.0', 'state': 'updated'}));
    File('${s.dir}/hub/update-request').deleteSync();
    final done = await s.signed(phone, 'POST', '/api/v1/hub/server/update');
    expect(done.status, 409);
    expect(((await s.signed(phone, 'GET', '/api/v1/hub/server')).body['update'] as Map).containsKey('available'), isFalse);
  });
}
