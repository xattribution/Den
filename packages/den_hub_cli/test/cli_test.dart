@Timeout(Duration(seconds: 120))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
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
    final (code, out, err) = await run(['backup', '--out', file, '--passphrase-env', 'DEN_PASS', '--data', dataPath], env: env);
    expect(code, 0, reason: err);
    expect(out, contains('Backed up'));
    expect(File(file).readAsBytesSync().sublist(0, 4), utf8.encode('DENB'));
    final target = '${tmp.path}${Platform.pathSeparator}restored';
    final (wrong, _, _) = await run(['restore', '--in', file, '--passphrase-env', 'DEN_PASS', '--data', target],
        env: {'DEN_PASS': 'not the passphrase'});
    expect(wrong, 1);
    final (ok, _, okErr) = await run(['restore', '--in', file, '--passphrase-env', 'DEN_PASS', '--data', target], env: env);
    expect(ok, 0, reason: okErr);
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
    expect(out, contains('let the family'));
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
}
