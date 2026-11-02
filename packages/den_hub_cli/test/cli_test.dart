@Timeout(Duration(seconds: 120))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:den_hub/cli_support.dart' show HubState, restoreMarkerDoc;
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '../../den_sett_import/test/sett_fixture.dart';
import '../bin/src/cli.dart';
import '../bin/src/data_dir.dart';

/// Runs the CLI in-process, feeding [input] lines and capturing what it prints.
Future<(int, String, String)> run(List<String> args, {List<String> input = const [], Map<String, String> env = const {}}) async {
  final out = StringBuffer(), err = StringBuffer();
  final controller = StreamController<List<int>>();
  final code = runCli(args, io: CliIo(input: controller.stream, out: out, err: err, environment: env));
  for (final line in input) {
    controller.add(utf8.encode('$line\n'));
  }
  unawaited(controller.close());
  return (await code, out.toString(), err.toString());
}

void main() {
  late Directory tmp;
  late String dataPath;
  late Den phone;
  late String token;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('den_hub_cli');
    dataPath = '${tmp.path}${Platform.pathSeparator}data';
    phone = await createDemoFamily();
    final data = DataDir(dataPath);
    final hub = await data.open();
    await hub.requestJoin(
      familyId: phone.familyId!,
      founderPubkey: phone.founderPubkey!,
      deviceName: 'Closet hub',
      kind: DeviceKind.hub,
      mode: DeviceMode.hub,
    );
    await phone.ingest(hub.changesSince(const {}));
    await phone.approveDevice(hub.deviceId, mode: DeviceMode.hub);
    token = await phone.addTokenConnection(label: 'Laptop assistant', scopes: {Scope.read, Scope.lists});
    await hub.ingest(phone.changesSince(const {}));
    await hub.close();
  });

  tearDownAll(() => tmp.delete(recursive: true));

  test('keys.json is made once and reused', () async {
    final data = DataDir(dataPath);
    final first = await data.keys();
    final again = await DataDir(dataPath).keys();
    expect(again.pubkey, first.pubkey);
    expect(jsonDecode(data.keysFile.readAsStringSync()), contains('signingSeed'));
  });

  test('mcp over stdio, scoped by the token, from the data directory', () async {
    final (code, out, err) = await run(['mcp', '--token', token, '--data', dataPath, '--hub', 'http://127.0.0.1:9'], input: [
      jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-11-25'}}),
      jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
      jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call', 'params': {'name': 'add_items', 'arguments': {'list': 'Groceries', 'items': ['Cocoa']}}}),
      jsonEncode({'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call', 'params': {'name': 'create_event', 'arguments': {'title': 'x', 'start': '2026-11-01'}}}),
    ]);
    expect(code, 0, reason: err);
    final lines = [for (final l in const LineSplitter().convert(out)) jsonDecode(l) as Map];
    expect(lines, hasLength(3));
    expect(((lines[1]['result'] as Map)['isError']), isFalse);
    expect(((lines[2]['result'] as Map)['isError']), isTrue, reason: 'no calendar scope');
    final (bad, _, badErr) = await run(['mcp', '--token', 'den_nope', '--data', dataPath, '--hub', 'http://127.0.0.1:9']);
    expect(bad, 1);
    expect(badErr, contains('token'));
  });

  test('import-sett acts as the named parent through the hub device', () async {
    final db = '${tmp.path}${Platform.pathSeparator}coord.db';
    writeSettFixture(db);
    final (wrong, _, wrongErr) = await run(['import-sett', db, '--as', 'Leo', '--data', dataPath]);
    expect(wrong, 1);
    expect(wrongErr, contains('Parents: Alex, Priya'));
    final (code, out, err) = await run(['import-sett', db, '--as', 'alex', '--data', dataPath]);
    expect(code, 0, reason: err);
    expect(out, startsWith('Imported: '));
    final hub = await DataDir(dataPath).open();
    addTearDown(hub.close);
    expect(hub.members.map((m) => m.name), containsAll(['Sam', 'Mia']));
    final entry = hub.history(type: RecordType.member).first;
    expect(entry.actor, phone.members.firstWhere((m) => m.name == 'Alex').id);
    expect(entry.via, 'Sett import');
  });

  test('status, and a second process is kept out while one holds the directory', () async {
    final (code, out, _) = await run(['status', '--data', dataPath, '--port', '9']);
    expect(code, 0);
    expect(out, contains('Not running'));
    expect(out, contains('In a family'));
    final holder = DataDir(dataPath);
    await holder.lock();
    final (locked, _, err) = await run(['status', '--data', dataPath, '--port', '9']);
    await holder.unlock();
    expect(locked, 1);
    expect(err, contains('Another den_hub'));
  });

  test('status of a running public hub says what the hub tells it, never "null"', () async {
    final den = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    final hub = await DenHub.start(den, HubConfig(
      port: 0,
      host: InternetAddress.loopbackIPv4,
      mdns: false,
      name: 'Server hub',
      publicUrl: Uri.parse('https://den.example.com'),
    ));
    addTearDown(() async {
      await hub.stop();
      await den.close();
    });
    final (code, out, err) = await run(['status', '--data', dataPath, '--port', '${hub.port}']);
    expect(code, 0, reason: err);
    expect(out, isNot(contains('null')));
    expect(out, contains('Running: Server hub (${den.deviceId}), den_hub $hubVersion'));
    expect(out, contains('Setup: waiting_for_code'));
  });

  test("setup-link: the first parent's link and QR code, with the setup code to type if it can't be used", () async {
    final dir = await Directory.systemTemp.createTemp('den_hub_cli_setup');
    addTearDown(() => dir.delete(recursive: true));
    final den = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    final hub = await DenHub.start(den, HubConfig(
      port: 0,
      host: InternetAddress.loopbackIPv4,
      mdns: false,
      dataDir: dir.path,
      publicUrl: Uri.parse('https://den.example.com'),
      log: HubLog(level: LogLevel.error),
    ));
    addTearDown(() async {
      await hub.stop();
      await den.close();
    });
    final code = File('${dir.path}/hub/setup-code').readAsStringSync().trim();
    final (status, out, err) = await run(['setup-link', '--data', dir.path, '--port', '${hub.port}'],
        env: {'DEN_PUBLIC_URL': 'https://den.example.com'});
    expect(status, 0, reason: err);
    expect(out, contains('  https://den.example.com/setup/$code/${den.deviceId}'));
    expect(out, contains('If Den asks for the setup code, it is: $code'));
    expect(out, contains('▀'), reason: 'a QR code drawn in half blocks');
    // Without the hub's address, the code alone and how to get the link.
    final (_, plain, _) = await run(['setup-link', '--data', dir.path, '--port', '${hub.port}']);
    expect(plain, contains('Setup code: $code'));
    expect(plain, contains('--url'));
    // An address given on the command line wins.
    final (_, given, _) = await run(['setup-link', '--data', dir.path, '--port', '${hub.port}', '--url', 'https://den.smith.family']);
    expect(given, contains('https://den.smith.family/setup/$code/${den.deviceId}'));
    // --bare, for deploy/install.sh: the link alone on the first line, then the QR code.
    final (bareStatus, bare, _) =
        await run(['setup-link', '--data', dir.path, '--port', '${hub.port}', '--url', 'http://192.168.1.50:47733', '--bare']);
    expect(bareStatus, 0);
    expect(bare.split('\n').first, 'http://192.168.1.50:47733/setup/$code/${den.deviceId}');
    expect(bare, contains('▀'));
    expect(bare, isNot(contains('iPhone')));
    final (noUrl, _, _) = await run(['setup-link', '--data', dir.path, '--port', '${hub.port}', '--bare']);
    expect(noUrl, 1);
  });

  test('status of a hub the family removed says so, running or not', () async {
    final removedPath = '${tmp.path}${Platform.pathSeparator}removed';
    final hubDen = await DataDir(removedPath).open();
    await hubDen.requestJoin(
      familyId: phone.familyId!,
      founderPubkey: phone.founderPubkey!,
      deviceName: 'Old hub',
      kind: DeviceKind.hub,
      mode: DeviceMode.hub,
    );
    await phone.ingest(hubDen.changesSince(const {}));
    await phone.approveDevice(hubDen.deviceId, mode: DeviceMode.hub);
    await hubDen.ingest(phone.changesSince(const {}));
    await phone.revokeDevice(hubDen.deviceId);
    await hubDen.ingest(phone.changesSince(hubDen.versionVector));
    final notice = RegExp(r'This hub was removed from the family on [A-Z][a-z]{2} \d{1,2}; reset it to add it again\.');

    final logged = <String>[];
    final hub = await DenHub.start(hubDen, HubConfig(
      port: 0,
      host: InternetAddress.loopbackIPv4,
      mdns: false,
      log: HubLog(level: LogLevel.info, sink: logged.add),
    ));
    final (running, out, err) = await run(['status', '--data', removedPath, '--port', '${hub.port}']);
    await hub.stop();
    await hubDen.close();
    expect(running, 0, reason: err);
    expect(out, matches(notice));
    expect(out, isNot(contains('Setup:')));
    expect(logged.where((l) => l.contains('This hub was removed from the family on ')), hasLength(1),
        reason: 'it says so as it starts');
    expect(logged.where((l) => l.contains('Setup code')), isEmpty, reason: 'a setup code would get nowhere');

    final (stopped, out2, err2) = await run(['status', '--data', removedPath, '--port', '9']);
    expect(stopped, 0, reason: err2);
    expect(out2, contains('Not running'));
    expect(out2, matches(notice));
  });

  test('backup and restore round-trip under a passphrase', () async {
    final file = '${tmp.path}${Platform.pathSeparator}hub.denbackup';
    final env = {'DEN_PASS': 'correct horse battery'};
    File('$dataPath${Platform.pathSeparator}hub${Platform.pathSeparator}$signInFile')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"v": 1}');
    final (code, out, err) = await run(['backup', '--out', file, '--passphrase-env', 'DEN_PASS', '--data', dataPath], env: env);
    expect(code, 0, reason: err);
    expect(out, contains('Backed up'));
    expect(File(file).readAsBytesSync().sublist(0, 4), utf8.encode('DENB'));
    final target = '${tmp.path}${Platform.pathSeparator}restored';
    final (wrong, _, _) = await run(['restore', '--in', file, '--passphrase-env', 'DEN_PASS', '--data', target],
        env: {'DEN_PASS': 'not the passphrase'});
    expect(wrong, 1);
    final (ok, okOut, okErr) = await run(['restore', '--in', file, '--passphrase-env', 'DEN_PASS', '--data', target], env: env);
    expect(ok, 0, reason: okErr);
    expect(okOut, contains('open Den on a phone or tablet in the family'));
    // The keys and the hub's secrets come back owner-only, written that way from the start.
    if (!Platform.isWindows) {
      for (final name in ['keys.json', 'hub${Platform.pathSeparator}$signInFile']) {
        final restoredFile = File('$target${Platform.pathSeparator}$name');
        expect(restoredFile.statSync().mode & 0x1ff, 0x180, reason: name);
      }
    }
    expect(Directory(target).listSync(recursive: true).where((e) => e.path.endsWith('.restore.tmp')), isEmpty);
    // The restored hub writes nothing of its own until a device has synced with it, and says so.
    final marker = File('$target${Platform.pathSeparator}hub${Platform.pathSeparator}$restoreMarkerDoc.json');
    expect(marker.existsSync(), isTrue);
    expect(HubState(target).restored, isTrue);
    final (_, statusOut, _) = await run(['status', '--data', target, '--port', '9']);
    expect(statusOut, contains('Catching up after a restore'));
    final db = '${tmp.path}${Platform.pathSeparator}restore-coord.db';
    writeSettFixture(db);
    final (refused, _, refusedErr) = await run(['import-sett', db, '--as', 'Alex', '--data', target]);
    expect(refused, 1);
    expect(refusedErr, contains('Catching up after a restore'));
    final restored = await DataDir(target).open();
    addTearDown(restored.close);
    final original = await DataDir(dataPath).keys();
    expect(restored.keys.pubkey, original.pubkey);
    expect(restored.isApproved, isTrue);
    final (again, _, againErr) = await run(['restore', '--in', file, '--passphrase-env', 'DEN_PASS', '--data', target], env: env);
    expect(again, 1);
    expect(againErr, contains('--force'));
  });

  test('open-linking lets browsers ask a public hub for a link code for a while, and stays out of backups', () async {
    final (code, out, err) = await run(['open-linking', '--data', dataPath, '--minutes', '5']);
    expect(code, 0, reason: err);
    expect(out, contains('Link this browser'));
    final file = File('$dataPath${Platform.pathSeparator}hub${Platform.pathSeparator}link-open');
    final until = int.parse(file.readAsStringSync().trim());
    expect(until, greaterThan(DateTime.now().millisecondsSinceEpoch + 4 * 60000));
    expect((await run(['open-linking', '--data', dataPath, '--minutes', '600'])).$1, 64);
    expect((await DataDir(dataPath).readBackup()).keys, isNot(contains('hub/link-open')));
  });

  test('serve refuses a DEN_PEER_HUBS that names an address or http, before it opens anything', () async {
    for (final bad in ['http://den-smith.example.com', '10.0.0.5', 'den-smith.example.com localhost']) {
      final (code, _, err) = await run(['serve', '--data', dataPath, '--port', '0'], env: {'DEN_PEER_HUBS': bad});
      expect(code, 64, reason: bad);
      expect(err, startsWith('DEN_PEER_HUBS: '), reason: bad);
    }
  });

  test('settings the hub no longer reads are named once in the log, never their values, and change nothing', () async {
    const secret = 'GOCSPX-shh-not-for-logs';
    final env = {
      'DEN_LOG': 'warn',
      'DEN_GOOGLE_CLIENT_ID': '1234567890-den.apps.googleusercontent.com',
      'DEN_GOOGLE_CLIENT_SECRET': secret,
      'DEN_APPLE_KEY_FILE': '${tmp.path}/no-such-key.p8',
      'DEN_HOST_PUSH': 'den.example.com',
      'DEN_HA_URL': 'http://homeassistant.local:8123',
      'DEN_HA_TOKEN': 'ha-token-not-for-logs',
    };
    final err = StringBuffer();
    final host = await openHost(
      cliParser().commands['serve']!.parse(['--port', '0', '--host', '127.0.0.1', '--no-mdns']),
      DataDir(dataPath),
      0,
      CliIo(input: const Stream.empty(), out: StringBuffer(), err: err, environment: env),
    );
    addTearDown(host.stop);
    final log = err.toString();
    expect(log, contains('DEN_GOOGLE_CLIENT_ID, DEN_GOOGLE_CLIENT_SECRET, DEN_APPLE_KEY_FILE are no longer read'));
    expect(log, contains('Settings, Advanced, Sign in with Google or Apple'));
    expect(log, contains('DEN_HOST_PUSH is no longer read'));
    expect(log, contains('DEN_HA_URL, DEN_HA_TOKEN'));
    for (final value in [secret, 'ha-token-not-for-logs', '1234567890-den', 'homeassistant.local']) {
      expect(log, isNot(contains(value)), reason: 'a value is never echoed');
    }
    expect(host.signIn.providers, isNull, reason: 'sign-in is set up in the app, not from the environment');
    expect(host.tenants.single.config.hostPush, isTrue, reason: 'what DEN_HOST_PUSH=all did is the default');
    expect(DataDir.backupPath('hub/$signInFile'), isTrue, reason: 'what the app set up for signing in is in backups');
    expect(retiredSettings.keys, containsAll(['DEN_GOOGLE_CLIENT_ID', 'DEN_APPLE_KEY_FILE', 'DEN_HOST_PUSH', 'DEN_NOTIFY']));
    for (final retired in ['--google-client-id', '--host-push', '--ha-url']) {
      expect(cliParser().commands['serve']!.options.keys, isNot(contains(retired.substring(2))));
    }
  });

  test('recover: a link and four words for a parent, only once the family turned server help on', () async {
    final hubDir = DataDir(dataPath);
    await hubDir.lock();
    final den = await hubDir.open();
    final hub = await DenHub.start(den, HubConfig(
      port: 0,
      host: InternetAddress.loopbackIPv4,
      mdns: false,
      dataDir: dataPath,
      publicUrl: Uri.parse('https://den.example.com'),
      public: false,
      log: HubLog(level: LogLevel.error),
    ));
    try {
      final port = '${hub.port}';
      final (off, _, offErr) = await run(['recover', '--person', 'Alex', '--data', dataPath, '--port', port]);
      expect(off, 1);
      expect(offErr, contains('hasn\'t turned on server help'));
      expect(offErr, contains('Settings, Family, "Let the hub help us get back in"'));
      expect(offErr, contains('12 recovery words'));

      // Alex's phone asks the hub for its key and turns server help on.
      final url = hub.localUrl.resolve('/api/v1/recovery/key');
      final headers = await DeviceRequest.sign(
        keys: phone.keys,
        method: 'GET',
        url: url,
        body: const [],
        hub: den.deviceId,
        actorId: phone.actor!.id,
      );
      final key = (jsonDecode((await http.get(url, headers: headers)).body) as Map)['key'] as String;
      await phone.setServerRecoveryKey(key);
      await den.ingest(phone.changesSince(den.versionVector));

      final (code, out, err) = await run(['recover', '--person', 'Alex', '--data', dataPath, '--port', port]);
      expect(code, 0, reason: err);
      final link = RegExp(r'https://den\.example\.com/#/recover/([a-z]+)-([a-z]+)-([a-z]+)-([a-z]+)').firstMatch(out);
      expect(link, isNotNull, reason: out);
      expect(out, contains('  ${link!.group(1)} ${link.group(2)} ${link.group(3)} ${link.group(4)}'));
      expect(out, contains('30 minutes'));
      expect(out, contains('"I lost my phone"'));
      expect(out, contains("Alex's new phone was let in by the hub"));

      final (kid, _, kidErr) = await run(['recover', '--person', 'Maya', '--data', dataPath, '--port', port]);
      expect(kid, 1);
      expect(kidErr, contains('isn\'t a parent'));
      final (none, _, noneErr) = await run(['recover', '--person', 'Mallory', '--data', dataPath, '--port', port]);
      expect(none, 1);
      expect(noneErr, contains('Parents: Alex'));
      expect((await run(['recover', '--data', dataPath, '--port', port])).$1, 64);

      // The key is in backups; the command's secret and the codes, which last minutes, aren't.
      final files = (await hubDir.readBackup()).keys;
      expect(files, contains('hub/recovery.json'));
      expect(files, isNot(contains('hub/$recoveryCliFile')));
      expect(files, isNot(contains('hub/$recoveryTicketsDoc.json')));
    } finally {
      await hub.stop();
      await den.close();
      await hubDir.unlock();
    }

    // With no hub running, the command makes the code in the data directory.
    final (offline, offlineOut, offlineErr) =
        await run(['recover', '--person', 'Alex', '--data', dataPath, '--port', '9'], env: {'DEN_PUBLIC_URL': 'https://den.example.com'});
    expect(offline, 0, reason: offlineErr);
    expect(offlineOut, contains('https://den.example.com/#/recover/'));
  });

  test('a backup taken while the hub runs and writes is consistent, and holds notify.json', () async {
    final hubDir = DataDir(dataPath);
    await hubDir.lock();
    final den = await hubDir.open();
    File('$dataPath${Platform.pathSeparator}notify.json').writeAsStringSync('{"members": {"Alex": {"ntfy": "den-alex"}}}');
    final before = den.changesSince(const {}).length;
    var writing = true;
    Future<void> keepWriting() async {
      for (var n = 0; writing && n < 60; n++) {
        await den.addEvent(title: 'While backing up $n', start: 1792535400000 + n * 60000, end: 1792539000000 + n * 60000);
      }
    }

    final writer = keepWriting();
    final file = '${tmp.path}${Platform.pathSeparator}live.denbackup';
    final env = {'DEN_PASS': 'correct horse battery'};
    final (code, _, err) = await run(['backup', '--out', file, '--passphrase-env', 'DEN_PASS', '--data', dataPath], env: env);
    writing = false;
    await writer;
    final after = den.changesSince(const {}).length;
    await den.close();
    await hubDir.unlock();
    expect(code, 0, reason: err);
    expect(err, contains('running'), reason: 'it didn\'t need the running hub\'s lock');

    final target = '${tmp.path}${Platform.pathSeparator}live-restored';
    final (ok, out, okErr) = await run(['restore', '--in', file, '--passphrase-env', 'DEN_PASS', '--data', target], env: env);
    expect(ok, 0, reason: okErr);
    expect(out, contains('open Den on a phone or tablet'));
    expect(File('$target${Platform.pathSeparator}notify.json').readAsStringSync(), contains('den-alex'));
    final restored = await DataDir(target).open();
    final count = restored.changesSince(const {}).length;
    final approved = restored.isApproved;
    await restored.close();
    expect(count, inInclusiveRange(before, after));
    expect(approved, isTrue);

    // A restore never runs under a running hub, and --force leaves nothing of the old one.
    File('$target${Platform.pathSeparator}hub${Platform.pathSeparator}stale.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');
    final running = DataDir(target);
    await running.lock();
    final (busy, _, busyErr) = await run(['restore', '--in', file, '--passphrase-env', 'DEN_PASS', '--data', target, '--force'], env: env);
    await running.unlock();
    expect(busy, 1);
    expect(busyErr, contains('Stop it first'));
    final (forced, _, forcedErr) = await run(['restore', '--in', file, '--passphrase-env', 'DEN_PASS', '--data', target, '--force'], env: env);
    expect(forced, 0, reason: forcedErr);
    expect(File('$target${Platform.pathSeparator}hub${Platform.pathSeparator}stale.json').existsSync(), isFalse);
  });

  test('with no passphrase, a backup opens with a parent\'s recovery words, given or typed', () async {
    final alex = phone.members.firstWhere((m) => m.name == 'Alex');
    Future<void> setWords(String? key) async {
      await phone.setRecoveryKey(alex.id, key);
      final hub = await DataDir(dataPath).open();
      await hub.ingest(phone.changesSince(const {}));
      await hub.close();
    }

    await setWords(null);
    final noWords = '${tmp.path}${Platform.pathSeparator}nobody.denbackup';
    final (refused, _, refusedErr) = await run(['backup', '--out', noWords, '--data', dataPath]);
    expect(refused, 1, reason: 'nobody could open it');
    expect(refusedErr, contains('recovery words'));
    expect(File(noWords).existsSync(), isFalse);

    final words = RecoveryWords.generate();
    await setWords((await RecoveryWords.key(words)).publicKey);

    final file = '${tmp.path}${Platform.pathSeparator}words.denbackup';
    final (code, out, err) = await run(['backup', '--out', file, '--data', dataPath]);
    expect(code, 0, reason: err);
    expect(out, contains('recovery words of Alex'));
    final target = '${tmp.path}${Platform.pathSeparator}words-restored';
    final (wrong, _, wrongErr) = await run(['restore', '--in', file, '--words-env', 'W', '--data', target],
        env: {'W': RecoveryWords.generate().join(' ')});
    expect(wrong, 1);
    expect(wrongErr, contains("don't open this backup"));
    final (typed, typedOut, typedErr) = await run(['restore', '--in', file, '--data', target], input: [words.join(' ')]);
    expect(typed, 0, reason: typedErr);
    expect(typedOut, contains('Alex'));
    final restored = await DataDir(target).open();
    addTearDown(restored.close);
    expect(restored.isApproved, isTrue);
  });
}
