@Timeout(Duration(seconds: 240))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:den_hub/cli_support.dart' show restoreMarkerDoc;
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '../bin/src/cli.dart';
import '../bin/src/data_dir.dart';

Future<(int, String, String)> run(List<String> args, {Map<String, String> env = const {}}) async {
  final out = StringBuffer(), err = StringBuffer();
  final code = await runCli(args, io: CliIo(input: const Stream.empty(), out: out, err: err, environment: env));
  return (code, out.toString(), err.toString());
}

/// `den_hub serve` over [path], in this process, until the test stops it.
Future<DenHost> serveAt(String path, {List<String> args = const []}) => openHost(
      cliParser().commands['serve']!.parse(['--port', '0', '--host', '127.0.0.1', '--no-mdns', ...args]),
      DataDir(path),
      0,
      CliIo(input: const Stream.empty(), out: StringBuffer(), err: StringBuffer(), environment: const {'DEN_LOG': 'error', 'DEN_HOST_RETRY': '1'}),
    );

/// A hub in its own data directory at [path], approved into [phone]'s family with the space keys
/// it holds: a family's own container, before it moves.
Future<String> ownHub(String path, Den phone) async {
  final hub = await DataDir(path).open();
  await hub.requestJoin(
    familyId: phone.familyId!,
    founderPubkey: phone.founderPubkey!,
    deviceName: 'Smith hub',
    kind: DeviceKind.hub,
    mode: DeviceMode.hub,
  );
  await phone.ingest(hub.changesSince(const {}));
  await phone.approveDevice(hub.deviceId, mode: DeviceMode.hub);
  await hub.ingest(phone.changesSince(const {}));
  for (final space in phone.spacesForDevice(hub.deviceId)) {
    final key = await phone.spaceKey(space);
    if (key != null) await hub.setSpaceKey(space, key);
  }
  final id = hub.deviceId;
  await hub.close();
  return id;
}

/// [phone] syncs with the hub [hubId] at [host], over `/ws` at its loopback address (the hello
/// names the family, which is all the host needs); returns once both sides are live.
Future<SyncNode> syncWith(Den phone, DenHost host, String hubId) async {
  final node = SyncNode(phone);
  final peer = await node.connect(await connectWebSocket(host.localUrl.replace(scheme: 'ws', path: '/ws')), expectDevice: hubId);
  await peer.live;
  return node;
}

/// [hours] from now, UTC ms.
int _soon(int hours) => DateTime.now().toUtc().add(Duration(hours: hours)).millisecondsSinceEpoch;

Future<void> eventually(FutureOr<bool> Function() condition, {Duration timeout = const Duration(seconds: 20)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  late Directory tmp;

  setUp(() async => tmp = await Directory.systemTemp.createTemp('den_host_cli'));
  tearDown(() => tmp.delete(recursive: true));

  String at(String name) => '${tmp.path}${Platform.pathSeparator}$name';

  test('add-family: the running host serves a new family at once, and every --family command reaches it', () async {
    final host = await serveAt(at('host'));
    final port = '${host.port}';
    final args = ['--data', at('host'), '--port', port];
    try {
      final (code, out, err) = await run(['add-family', '--hostname', 'den-smith.test', ...args]);
      expect(code, 0, reason: err);
      final link = RegExp(r'https://den-smith\.test/setup/([A-Z0-9]{4}-[A-Z0-9]{4})/([A-Za-z0-9]+)').firstMatch(out);
      expect(link, isNotNull, reason: out);
      expect(out, contains('▀'), reason: 'the QR code');
      final smith = host.tenants.singleWhere((t) => t.config.publicUrl?.host == 'den-smith.test');
      expect(link![1], smith.setupCode);
      expect(link[2], smith.den.deviceId);
      final log = HostState(at('host')).find('den-smith.test')!;
      expect(File('${at('host')}/logs/${log.id}/keys.json').existsSync(), isTrue);

      final (_, again, _) = await run(['setup-link', '--family', 'den-smith.test', ...args]);
      expect(again, contains(link[0]!), reason: 'the same link again');
      final (_, code2, _) = await run(['setup-code', '--family', 'den-smith.test', ...args]);
      expect(code2.trim(), smith.setupCode);
      final (_, status, _) = await run(['status', '--family', 'den-smith.test', ...args]);
      expect(status, contains('Setup: waiting_for_code'));
      expect(status, contains(smith.den.deviceId));
      final (_, list, _) = await run(['families', ...args]);
      expect(list, contains('https://den-smith.test'));

      final (dup, _, dupErr) = await run(['add-family', '--hostname', 'den-smith.test', ...args]);
      expect(dup, 1);
      expect(dupErr, contains('den-smith.test'));
      final (bad, _, badErr) = await run(['add-family', '--hostname', '10.0.0.5', ...args]);
      expect(bad, 64, reason: badErr);

      final (removed, _, removeErr) = await run(['remove-family', '--family', 'den-smith.test', ...args]);
      expect(removed, 0, reason: removeErr);
      expect(host.tenants.where((t) => t.config.publicUrl?.host == 'den-smith.test'), isEmpty);
      final (gone, _, goneErr) = await run(['status', '--family', 'den-smith.test', ...args]);
      expect(gone, 1);
      expect(goneErr, contains('no family at den-smith.test'));
      final (back, backOut, backErr) = await run(['add-family', '--hostname', 'den-smith.test', ...args]);
      expect(back, 0, reason: backErr);
      final returned = host.tenants.singleWhere((t) => t.config.publicUrl?.host == 'den-smith.test');
      expect(returned.den.deviceId, smith.den.deviceId, reason: 'the same hub, brought back: $backOut');
    } finally {
      await host.stop();
    }
    final (offline, out, err) = await run(['add-family', '--hostname', 'den-jones.test', '--data', at('host'), '--port', '9']);
    expect(offline, 0, reason: err);
    expect(out, contains('from its next start'));
    final later = await serveAt(at('host'));
    expect(later.tenants.map((t) => t.config.publicUrl?.host), containsAll(['den-smith.test', 'den-jones.test']));
    await later.stop();
  });

  test('adopt: a hub that ran on its own moves onto the host, keeps its device id, and its phone keeps syncing', () async {
    final phone = await createDemoFamily();
    addTearDown(phone.close);
    final hubId = await ownHub(at('smith'), phone);

    // The Smiths' own hub, as their container ran it: the phone syncs an event to it.
    final own = await serveAt(at('smith'), args: ['--public-url', 'https://den-smith.test']);
    var node = await syncWith(phone, own, hubId);
    await phone.addEvent(title: 'Before the move', start: _soon(1), end: _soon(2));
    final ownHubDen = own.tenants.single.den;
    await eventually(() => ownHubDen.events.any((e) => e.title == 'Before the move'));
    await node.close();
    // Running, it can't be adopted.
    final (busy, _, busyErr) = await run(['adopt', at('smith'), '--hostname', 'den-smith.test', '--data', at('host'), '--port', '9']);
    expect(busy, 1);
    expect(busyErr, contains('Stop it first'));
    await own.stop();

    final host = await serveAt(at('host'));
    final args = ['--data', at('host'), '--port', '${host.port}'];
    try {
      final (dry, dryOut, dryErr) = await run(['adopt', at('smith'), '--hostname', 'den-smith.test', '--dry-run', ...args]);
      expect(dry, 0, reason: dryErr);
      expect(dryOut, contains('Would adopt'));
      expect(dryOut, contains(hubId));
      expect(dryOut, contains('Nothing changed'));
      expect(Directory('${at('host')}/logs').existsSync(), isFalse);
      expect(host.tenants, hasLength(1));

      final (code, out, err) = await run(['adopt', at('smith'), '--hostname', 'den-smith.test', ...args]);
      expect(code, 0, reason: err);
      expect(out, contains('The host serves den-smith.test now'));
      final smith = host.tenants.singleWhere((t) => t.config.publicUrl?.host == 'den-smith.test');
      expect(smith.den.deviceId, hubId, reason: 'its keys came with it');
      expect(smith.den.events.map((e) => e.title), contains('Before the move'));
      expect(smith.ready, isTrue);
      expect(File('${at('smith')}/hub/$restoreMarkerDoc.json').existsSync(), isTrue,
          reason: 'the old hub, started by mistake, waits for a phone before writing');

      // The phone, unchanged, syncs with the same hub on the host: no pairing again.
      node = await syncWith(phone, host, hubId);
      await phone.addEvent(title: 'After the move', start: _soon(2), end: _soon(3));
      await eventually(() => smith.den.events.any((e) => e.title == 'After the move'));
      await node.close();
      final (_, status, _) = await run(['status', '--family', 'den-smith.test', ...args]);
      expect(status, contains('In a family and serving'));

      final (twice, _, twiceErr) = await run(['adopt', at('smith'), '--hostname', 'den-other.test', ...args]);
      expect(twice, 1);
      expect(twiceErr, contains('serves that hub already'));
    } finally {
      await host.stop();
    }
    // And from the next start too.
    final again = await serveAt(at('host'));
    expect(again.tenants.singleWhere((t) => t.config.publicUrl?.host == 'den-smith.test').den.deviceId, hubId);
    await again.stop();
  });

  test('a family on the host backs up alone, and restores alone (onto a new server too)', () async {
    final phone = await createDemoFamily();
    addTearDown(phone.close);
    final hubId = await ownHub(at('smith'), phone);
    final (adopted, _, adoptErr) = await run(['adopt', at('smith'), '--hostname', 'den-smith.test', '--data', at('host'), '--port', '9']);
    expect(adopted, 0, reason: adoptErr);
    final env = {'DEN_BACKUP_PASSPHRASE': 'correct horse battery'};
    final file = at('smith.denbackup');
    final host = await serveAt(at('host'));
    try {
      final (code, out, err) = await run(
          ['backup', '--family', 'den-smith.test', '--data', at('host'), '--out', file, '--passphrase-env', 'DEN_BACKUP_PASSPHRASE'],
          env: env);
      expect(code, 0, reason: err);
      expect(out, contains('Backed up'));
      final (refused, _, refusedErr) = await run(
          ['restore', '--family', 'den-smith.test', '--data', at('host'), '--in', file, '--passphrase-env', 'DEN_BACKUP_PASSPHRASE', '--force'],
          env: env);
      expect(refused, 1, reason: 'the host holds every family: stop it first');
      expect(refusedErr, contains('Stop it first'));
    } finally {
      await host.stop();
    }
    // A new server: restore the Smiths alone into a fresh host's directory.
    final (restored, out, err) = await run(
        ['restore', '--family', 'den-smith.test', '--data', at('new'), '--in', file, '--passphrase-env', 'DEN_BACKUP_PASSPHRASE'],
        env: env);
    expect(restored, 0, reason: err);
    final log = HostState(at('new')).find('den-smith.test')!;
    expect(out, contains('${at('new')}/logs/${log.id}'));
    expect(File('${at('new')}/logs/${log.id}/hub/$restoreMarkerDoc.json').existsSync(), isTrue);
    expect(File('${at('new')}/keys.json').existsSync(), isFalse, reason: 'the first family is untouched');
    final fresh = await serveAt(at('new'));
    final smith = fresh.tenants.singleWhere((t) => t.config.publicUrl?.host == 'den-smith.test');
    expect(smith.den.deviceId, hubId);
    expect(smith.catchingUp, isTrue);
    await fresh.stop();
    final backup = backupFilesOf(await openBackup(await File(file).readAsBytes(), passphrase: env.values.single));
    expect(backup.keys, isNot(contains(startsWith('host/'))), reason: "one family's files only");
  });

  test('adopt: never the host\'s own directories, by any path, nor a hub it has or had; run again, it is done', () async {
    final phone = await createDemoFamily();
    addTearDown(phone.close);
    await ownHub(at('smith'), phone);
    final args = ['--data', at('host'), '--port', '9'];
    // A copy an adopt left halfway, which host.json doesn't list: moved aside, never deleted.
    Directory('${at('host')}/logs').createSync(recursive: true);
    await Process.run('cp', ['-r', at('smith'), '${at('host')}/logs/halfway']);
    final (adopted, adoptOut, adoptErr) = await run(['adopt', at('smith'), '--hostname', 'den-smith.test', ...args]);
    expect(adopted, 0, reason: adoptErr);
    expect(adoptOut, contains('Moved an unfinished copy'));
    expect(Directory('${at('host')}/logs/halfway').existsSync(), isFalse);
    final aside = Directory('${at('host')}/logs-aside').listSync();
    expect(aside, hasLength(1));
    expect(File('${aside.single.path}/keys.json').existsSync(), isTrue, reason: 'kept whole');
    final log = HostState(at('host')).find('den-smith.test')!;
    final inside = '${at('host')}/logs/${log.id}';

    // The same hub again at its address: done already, nothing changes.
    final (again, againOut, againErr) = await run(['adopt', at('smith'), '--hostname', 'den-smith.test', ...args]);
    expect(again, 0, reason: againErr);
    expect(againOut, contains('already'));
    expect(HostState(at('host')).all, hasLength(1));
    // The same hub at another address, or a family's own directory by any path.
    final (elsewhere, _, elsewhereErr) = await run(['adopt', at('smith'), '--hostname', 'den-other.test', ...args]);
    expect(elsewhere, 1);
    expect(elsewhereErr, contains('serves that hub already'));
    Link(at('alias')).createSync(inside);
    for (final path in [inside, '${at('smith')}/../host/logs/${log.id}', at('alias'), at('host')]) {
      final (code, _, err) = await run(['adopt', path, '--hostname', 'den-new.test', ...args]);
      expect(code, 1, reason: path);
      expect(err, anyOf(contains("own data directory"), contains('serves that hub already')), reason: path);
    }
    // Taken off, its directory stays, and is never adopted again: add-family brings it back.
    final (removed, _, removeErr) = await run(['remove-family', '--family', 'den-smith.test', ...args]);
    expect(removed, 0, reason: removeErr);
    final copy = at('copy');
    await Process.run('cp', ['-r', inside, copy]);
    final (twice, _, twiceErr) = await run(['adopt', copy, '--hostname', 'den-new.test', ...args]);
    expect(twice, 1);
    expect(twiceErr, contains('taken off'));
    // And remove-family --delete-data deletes what a family taken off left.
    final (deleted, deletedOut, deletedErr) = await run(['remove-family', '--family', 'den-smith.test', '--delete-data', ...args]);
    expect(deleted, 0, reason: deletedErr);
    expect(deletedOut, contains('deleted'));
    expect(Directory(inside).existsSync(), isFalse);
    expect(HostState(at('host')).all, isEmpty);
  });

  test("a family that doesn't open: its address answers 503, the host is up and says why, it is tried again, and its address stays its own", () async {
    final phone = await createDemoFamily();
    addTearDown(phone.close);
    await ownHub(at('smith'), phone);
    final (adopted, _, adoptErr) = await run(['adopt', at('smith'), '--hostname', 'den-smith.test', '--data', at('host'), '--port', '9']);
    expect(adopted, 0, reason: adoptErr);
    final log = HostState(at('host')).find('den-smith.test')!;
    // A backup holding its lock while the host starts.
    final busy = DataDir(at('host')).log(log.id);
    await busy.lock();
    final host = await serveAt(at('host'));
    final args = ['--data', at('host'), '--port', '${host.port}'];
    try {
      expect(host.tenants, hasLength(1));
      final status = await http.get(host.localUrl.resolve('/api/v1/hub/status'), headers: {'host': 'den-smith.test'});
      expect(status.statusCode, 503);
      expect(status.headers['retry-after'], isNotNull);
      final health = await http.get(host.localUrl.resolve('/health'));
      expect(health.statusCode, 200, reason: "every family had its try: one that won't open doesn't hold up --wait");
      expect(jsonDecode(health.body), containsPair('waiting', 1));
      final (_, statusOut, _) = await run(['status', '--family', 'den-smith.test', ...args]);
      expect(statusOut, contains("isn't open: Another den_hub is using"));
      final (_, list, _) = await run(['families', ...args]);
      expect(list, contains('https://den-smith.test  id ${log.id}  not open: Another den_hub is using'));
      final (taken, _, takenErr) = await run(['add-family', '--hostname', 'den-smith.test', ...args]);
      expect(taken, 1);
      expect(takenErr, contains("address on this host already"));
      await busy.unlock();
      await eventually(() => host.tenants.length == 2);
      expect((await http.get(host.localUrl.resolve('/api/v1/hub/status'), headers: {'host': 'den-smith.test'})).statusCode, 200);
      expect((await http.get(host.localUrl.resolve('/health'))).statusCode, 200);
    } finally {
      await host.stop();
    }
  });

  test('a family taken off an address more than once comes back by its id; a backup goes back to its own family only', () async {
    final state = HostState(at('host'));
    for (final id in ['old1', 'old2']) {
      await DataDir(at('host')).log(id).keys();
      state.put(HostedLog(id: id, publicUrl: Uri.parse('https://den-smith.test'), added: 1, removed: true));
    }
    await DataDir(at('host')).keys();
    final args = ['--data', at('host'), '--port', '9'];
    final (ambiguous, _, err) = await run(['add-family', '--hostname', 'den-smith.test', ...args]);
    expect(ambiguous, 1);
    expect(err, contains('--id'));
    final (chosen, _, chosenErr) = await run(['add-family', '--hostname', 'den-smith.test', '--id', 'old2', ...args]);
    expect(chosen, 0, reason: chosenErr);
    expect(HostState(at('host')).find('den-smith.test')!.id, 'old2');

    // old2's backup can't be restored over the first family, whose own hub is elsewhere.
    final env = {'DEN_BACKUP_PASSPHRASE': 'correct horse battery'};
    final file = at('old2.denbackup');
    final (backedUp, _, backupErr) = await run(
        ['backup', '--family', 'den-smith.test', '--data', at('host'), '--out', file, '--passphrase-env', 'DEN_BACKUP_PASSPHRASE'],
        env: env);
    expect(backedUp, 0, reason: backupErr);
    final (wrong, _, wrongErr) = await run(
        ['restore', '--data', at('host'), '--in', file, '--passphrase-env', 'DEN_BACKUP_PASSPHRASE', '--force'],
        env: env);
    expect(wrong, 1);
    expect(wrongErr, contains('den-smith.test'));
    final (right, _, rightErr) = await run(
        ['restore', '--family', 'den-smith.test', '--data', at('host'), '--in', file, '--passphrase-env', 'DEN_BACKUP_PASSPHRASE', '--force'],
        env: env);
    expect(right, 0, reason: rightErr);
  });

  test('remove-family --delete-data: by its id for a family still on the host, in the running host; its address is free again', () async {
    final host = await serveAt(at('host'));
    final args = ['--data', at('host'), '--port', '${host.port}'];
    try {
      final (added, _, addErr) = await run(['add-family', '--hostname', 'den-smith.test', ...args]);
      expect(added, 0, reason: addErr);
      final log = HostState(at('host')).find('den-smith.test')!;
      final dir = Directory('${at('host')}/logs/${log.id}');
      final (_, list, _) = await run(['families', ...args]);
      expect(list, contains('https://den-smith.test  id ${log.id}  setup:'));

      // By its address, a family still on the host is never deleted; nor by another's id.
      final (refused, _, refusedErr) = await run(['remove-family', '--family', 'den-smith.test', '--delete-data', ...args]);
      expect(refused, 1);
      expect(refusedErr, contains('--id ${log.id}'));
      final (wrong, _, wrongErr) = await run(['remove-family', '--family', 'den-other.test', '--id', log.id, '--delete-data', ...args]);
      expect(wrong, 1, reason: wrongErr);
      expect(host.tenants, hasLength(2));
      expect(dir.existsSync(), isTrue);

      // By its id: the host lets it go and deletes it, so its record is gone from the running
      // host and host.json alike.
      final (deleted, out, err) = await run(['remove-family', '--family', 'den-smith.test', '--id', log.id, '--delete-data', ...args]);
      expect(deleted, 0, reason: err);
      expect(out, contains('deleted'));
      expect(dir.existsSync(), isFalse);
      expect(HostState(at('host')).all, isEmpty);
      expect(host.tenants, hasLength(1));
      // Its old address is never the first family's.
      expect((await http.get(host.localUrl.resolve('/api/v1/hub/status'), headers: {'host': 'den-smith.test'})).statusCode, 404);

      final (again, againOut, againErr) = await run(['add-family', '--hostname', 'den-smith.test', ...args]);
      expect(again, 0, reason: againErr);
      expect(againOut, contains('https://den-smith.test/setup/'), reason: 'a new family at the freed address');
    } finally {
      await host.stop();
    }
    final later = await serveAt(at('host'));
    expect(later.tenants.map((t) => t.config.publicUrl?.host), contains('den-smith.test'));
    await later.stop();
  });
}
