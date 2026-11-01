@Timeout(Duration(seconds: 180))
library;

import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'support/fixture.dart';
import 'support/server_fixture.dart';
import 'support/test.dart';

/// The server's first boot in a browser (first_boot.dart): only the setup code's holder connects
/// it to Cloudflare and restores a family; the token is kept owner-only and never said back.
void main() {
  late Directory tmp;

  setUp(() async => tmp = await Directory.systemTemp.createTemp('den_first_boot_'));
  tearDown(() => tmp.delete(recursive: true));

  Future<ServerFixture> fresh({String name = 'new', String? passphrase}) async {
    final dir = '${tmp.path}/$name';
    return ServerFixture.start(dir, await openDataDir(dir), backupPassphrase: passphrase);
  }

  test('only the setup code opens the first-boot pages, and the status says they are there', () async {
    final s = await fresh();
    addTearDown(s.stop);
    final status = await apiCall(s.base, 'GET', '/api/v1/hub/status');
    expect(status.body['first_boot'], {'next': 'start'});

    final none = await apiCall(s.base, 'GET', '/api/v1/hub/first-boot');
    expect(none.status, 403);
    final wrong = await s.withCode('GET', '/api/v1/hub/first-boot', code: 'AAAA-AAAA');
    expect(wrong.status, 403);
    expect((wrong.error['details'] as Map)['tries_left'], setupTries - 1);
    final put = await s.withCode('PUT', '/api/v1/hub/first-boot/internet', code: 'AAAA-AAAA', body: {'token': fakeTunnelToken()});
    expect(put.status, 403);
    expect(s.connector.tokens, isEmpty, reason: 'nothing was saved without the code');

    final ok = await s.withCode('GET', '/api/v1/hub/first-boot');
    expect(ok.status, 200, reason: ok.text);
    expect((ok.body['internet'] as Map)['available'], isTrue);
    expect(ok.body['setup_link'], contains('/#/setup/${s.own.setupCode}/${s.own.den.deviceId}'));
  });

  test('the tunnel token goes to the connector, is never said back, and the address comes from the tunnel', () async {
    final s = await fresh();
    addTearDown(s.stop);
    final token = fakeTunnelToken();
    final bad = await s.withCode('PUT', '/api/v1/hub/first-boot/internet', body: {'token': 'not a token'});
    expect(bad.status, 400);
    // Pasted with the command Cloudflare shows around it.
    final put = await s.withCode('PUT', '/api/v1/hub/first-boot/internet', body: {'token': 'sudo cloudflared service install $token'});
    expect(put.status, 202, reason: put.text);
    expect(s.connector.tokens, [token]);
    expect(put.text, isNot(contains(token)));
    expect((put.body['internet'] as Map)['token'], isTrue);
    expect((put.body['internet'] as Map)['connected'], isFalse);
    expect(put.body['address'], isNull);

    s.connector
      ..connected = true
      ..hostnames = ['den.rivera.test'];
    final now = await s.withCode('GET', '/api/v1/hub/first-boot');
    expect((now.body['internet'] as Map)['connected'], isTrue);
    expect(now.body['address'], 'https://den.rivera.test');
    expect(now.body['setup_link'], startsWith('https://den.rivera.test/#/setup/'));
    expect(s.own.config.publicUrl, Uri.parse('https://den.rivera.test'));
    expect(File('${s.dir}/hub/$addressFile').readAsStringSync().trim(), 'https://den.rivera.test');
    expect(now.text, isNot(contains(token)));
    expect(s.logged.where((l) => l.contains(token) || l.contains('c2VjcmV0')), isEmpty, reason: 'never in the log');
  });

  test('without a tunnel saying it, the address is asked for', () async {
    final s = await fresh();
    addTearDown(s.stop);
    final bad = await s.withCode('PUT', '/api/v1/hub/first-boot/address', body: {'address': 'not an address'});
    expect(bad.status, 400);
    final ok = await s.withCode('PUT', '/api/v1/hub/first-boot/address', body: {'address': 'Den.Rivera.test/'});
    expect(ok.status, 200);
    expect(ok.body['address'], 'https://den.rivera.test');
    final chosen = await s.withCode('POST', '/api/v1/hub/first-boot/choice', body: {'choice': 'family'});
    expect(chosen.status, 200);
    expect((await apiCall(s.base, 'GET', '/api/v1/hub/status')).body['first_boot'], {'next': 'family'});
  });

  test('the real connector keeps the token owner-only and reads the address from cloudflared', () async {
    final dir = '${tmp.path}/cf';
    final metrics = await shelf_io.serve((Request r) {
      if (r.url.path == 'ready') return Response.ok('{"status":200,"readyConnections":4}');
      if (r.url.path == 'config') {
        return Response.ok('{"version":3,"config":{"ingress":[{"hostname":"den.rivera.test","service":"http://localhost:47733"},'
            '{"service":"http_status:404"}],"warp-routing":{"enabled":false}}}');
      }
      return Response.notFound('');
    }, InternetAddress.loopbackIPv4, 0);
    addTearDown(() => metrics.close(force: true));
    final c = CloudflaredConnector(dataDir: dir, available: true, metrics: Uri.parse('http://127.0.0.1:${metrics.port}'));
    expect((await c.state()).token, isFalse);
    await c.setToken(fakeTunnelToken());
    final file = File('$dir/hub/$tunnelTokenFile');
    expect(file.readAsStringSync(), fakeTunnelToken());
    if (!Platform.isWindows) expect(file.statSync().mode & 0x1ff, 0x180);
    final state = await c.state();
    expect(state.connected, isTrue);
    expect(state.hostnames, ['den.rivera.test']);
    // The connector's own status file, while fresh, says more: what is wrong, in plain words.
    File('$dir/hub/tunnel-status.json').writeAsStringSync(
        '{"state":"error","hostname":"den.rivera.test","message":"Cloudflare didn\'t accept the tunnel token.",'
        '"updated":"${DateTime.now().toUtc().toIso8601String()}"}');
    final said = await c.state();
    expect(said.connected, isFalse);
    expect(said.message, contains('tunnel token'));
    File('$dir/hub/tunnel-status.json').writeAsStringSync('{"state":"error","updated":"2026-01-01T00:00:00Z"}');
    expect((await c.state()).connected, isTrue, reason: 'a stale status file gives way to the metrics');
    await c.clearToken();
    expect(file.existsSync(), isFalse);
    expect(tunnelTokenOf('--token ${fakeTunnelToken()}'), fakeTunnelToken());
    expect(tunnelTokenOf('eyJhIjoiYSJ9'), isNull, reason: 'JSON, but no tunnel in it');
  });

  test('once the family exists the first-boot pages are closed', () async {
    final dir = '${tmp.path}/ready';
    final (phone, hub) = await familyAt(dir);
    addTearDown(phone.close);
    final s = await ServerFixture.start(dir, hub);
    addTearDown(s.stop);
    final answer = await apiCall(s.base, 'GET', '/api/v1/hub/first-boot', headers: {HubSetup.codeHeader: 'ABCD-EFGH'});
    expect(answer.status, 409);
    expect(answer.error['code'], 'already_set_up');
    final put = await apiCall(s.base, 'PUT', '/api/v1/hub/first-boot/internet',
        headers: {HubSetup.codeHeader: 'ABCD-EFGH'}, body: {'token': fakeTunnelToken()});
    expect(put.status, 409);
    expect(s.connector.tokens, isEmpty);
  });

  group('restoring a backup on a fresh server', () {
    late List<String> words;
    late Den phone;
    late String oldHub;
    late List<int> sealed;

    setUp(() async {
      words = RecoveryWords.generate();
      final dir = '${tmp.path}/old';
      final (p, hub) = await familyAt(dir, words: words);
      phone = p;
      oldHub = hub.deviceId;
      await hub.addEvent(title: 'Soccer', start: 1792535400000, end: 1792539000000);
      final files = await readBackupFiles(dir);
      await hub.close();
      final about = await backupAbout(files);
      sealed = await sealBackup(backupPlaintext(files), to: about.to, madeAt: 1761621420000, familyName: about.familyName);
    });
    tearDown(() => phone.close());

    Future<http.Response> upload(ServerFixture s, List<int> bytes, {String? code}) => http.post(
          s.base.resolve('/api/v1/hub/first-boot/upload'),
          headers: {HubSetup.codeHeader: code ?? s.own.setupCode!, 'content-type': 'application/octet-stream'},
          body: bytes,
        );

    test('a file from the browser, opened with Alex\'s recovery words: the family is back, catching up', () async {
      final s = await fresh();
      addTearDown(s.stop);
      await s.withCode('PUT', '/api/v1/hub/first-boot/internet', body: {'token': fakeTunnelToken()});
      final wrongCode = await upload(s, sealed, code: 'AAAA-AAAA');
      expect(wrongCode.statusCode, 403);
      final up = await upload(s, sealed);
      expect(up.statusCode, 200, reason: up.body);
      expect(up.body, contains('"names":["Alex"]'));

      final wrong = await s.withCode('POST', '/api/v1/hub/first-boot/restore', body: {'from': 'upload', 'words': RecoveryWords.generate().join(' ')});
      expect(wrong.status, 422);
      expect(wrong.error['message'], contains('Alex'));
      expect(s.own.ready, isFalse, reason: 'nothing changed');

      final ok = await s.withCode('POST', '/api/v1/hub/first-boot/restore', body: {'from': 'upload', 'words': words.join(' ')});
      expect(ok.status, 200, reason: ok.text);
      expect(ok.body['family_name'], phone.family!.name);
      final restored = s.own;
      expect(restored.den.deviceId, oldHub, reason: 'the same hub, so the phones know it');
      expect(restored.ready, isTrue);
      expect(restored.catchingUp, isTrue, reason: 'it waits for a phone to sync before it writes');
      expect(restored.den.events.map((e) => e.title), contains('Soccer'));
      expect(File('${s.dir}/hub/$tunnelTokenFile').existsSync(), isFalse, reason: 'the fake connector keeps none');
      expect(File('${s.dir}/restore-upload.denbackup').existsSync(), isFalse);
      final again = await s.withCode('GET', '/api/v1/hub/first-boot', body: null, code: 'ABCD-EFGH');
      expect(again.status, 409, reason: 'the pages are closed now');
      expect((await apiCall(s.base, 'GET', '/api/v1/hub/status')).body['paired'], isTrue);
    });

    test('from the NAS, newest first; the NAS stays the place backups go', () async {
      final s = await fresh();
      addTearDown(s.stop);
      s.rclone.files['backups/Den backups/den-2026-10-27-0317.denbackup'] = [1, 2, 3];
      s.rclone.files['backups/Den backups/den-2026-10-28-0317.denbackup'] = sealed;
      const place = {'kind': 'nas', 'host': '192.168.1.40', 'share': 'backups', 'user': 'james', 'password': 'nas-secret'};
      final found = await s.withCode('POST', '/api/v1/hub/first-boot/nas/find', body: <String, Object?>{});
      expect(found.body['found'], [
        {'name': 'Family NAS', 'host': '192.168.1.40'},
      ]);
      final shares = await s.withCode('POST', '/api/v1/hub/first-boot/nas/shares', body: {'place': place});
      expect(shares.body['shares'], ['backups', 'photos']);
      final wrongPassword = await s.withCode('POST', '/api/v1/hub/first-boot/nas/shares', body: {
        'place': {...place, 'password': 'nope'},
      });
      expect(wrongPassword.status, 422);
      expect((wrongPassword.error['details'] as Map)['problem'], 'login');
      final list = await s.withCode('POST', '/api/v1/hub/first-boot/backups', body: {'place': place});
      expect([for (final b in list.body['backups'] as List) (b as Map)['name']],
          ['den-2026-10-28-0317.denbackup', 'den-2026-10-27-0317.denbackup']);
      final ok = await s.withCode('POST', '/api/v1/hub/first-boot/restore', body: {'from': 'nas', 'place': place, 'words': words.join(' ')});
      expect(ok.status, 200, reason: ok.text);
      expect(s.own.den.deviceId, oldHub);
      expect(s.host.backups.place?.share, 'backups');
      expect(s.rclone.calls.every((c) => !c.args.contains('nas-secret')), isTrue, reason: 'never on a command line');
    });

    test('an older backup sealed with a passphrase opens with it', () async {
      final s = await fresh(passphrase: 'from the old .env');
      addTearDown(s.stop);
      final files = await readBackupFiles('${tmp.path}/old');
      final old = await encryptBackup(backupPlaintext(files), 'from the old .env',
          params: const BackupParams(memoryKiB: 1024, iterations: 1, parallelism: 1));
      final up = await upload(s, old);
      expect(up.body, contains('"version":1'));
      final ok = await s.withCode('POST', '/api/v1/hub/first-boot/restore', body: {'from': 'upload'});
      expect(ok.status, 200, reason: ok.text);
      expect(s.own.den.deviceId, oldHub);
    });
  });
}
