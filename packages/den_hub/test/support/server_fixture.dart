import 'dart:convert';
import 'dart:io';

import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:den_core/storage_io.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';

import 'fixture.dart';

/// rclone, faked: a NAS whose shares and files are in [files] (`share/folder/name` to bytes), and
/// every run in [calls] with the environment it got.
class FakeRclone implements Rclone {
  /// The NAS's shares.
  final Set<String> shares = {'backups', 'photos'};

  /// What is on the NAS: path (without `den:`) to bytes.
  final Map<String, List<int>> files = {};

  /// Every run: its arguments and environment.
  final List<({List<String> args, Map<String, String> env})> calls = [];

  /// When set, every run that reaches the NAS fails with this complaint.
  String? failWith;

  /// The password the NAS takes (obscured as `obscured:<password>`).
  String password = 'nas-secret';

  @override
  Future<RcloneResult> run(List<String> args, {Map<String, String> env = const {}, List<int>? stdin, Duration? timeout}) async {
    calls.add((args: args, env: env));
    if (args.first == 'obscure') return RcloneResult(0, 'obscured:${utf8.decode(stdin ?? const [])}\n', '');
    if (failWith != null) return RcloneResult(1, '', failWith!);
    if (env['RCLONE_CONFIG_DEN_PASS'] != 'obscured:$password') {
      return const RcloneResult(1, '', 'couldn\'t connect SMB: response error: The attempted logon is invalid. STATUS_LOGON_FAILURE');
    }
    String strip(String p) => p.startsWith('den:') ? p.substring(4) : p;
    switch (args.first) {
      case 'lsjson':
        final where = strip(args.firstWhere((a) => a.startsWith('den:')));
        if (where.isEmpty) return RcloneResult(0, jsonEncode([for (final s in shares) {'Name': s, 'IsDir': true}]), '');
        final prefix = '$where/';
        return RcloneResult(0, jsonEncode([
          for (final e in files.entries)
            if (e.key.startsWith(prefix) && !e.key.substring(prefix.length).contains('/'))
              {'Name': e.key.substring(prefix.length), 'Size': e.value.length, 'ModTime': '2026-10-28T03:17:00Z'},
        ]), '');
      case 'mkdir':
        final share = strip(args[1]).split('/').first;
        if (!shares.contains(share)) return const RcloneResult(1, '', 'couldn\'t connect SMB: STATUS_BAD_NETWORK_NAME');
        return const RcloneResult(0, '', '');
      case 'rcat':
        files[strip(args[1])] = stdin ?? const [];
        return const RcloneResult(0, '', '');
      case 'deletefile':
        files.remove(strip(args[1]));
        return const RcloneResult(0, '', '');
      case 'copyto':
        if (args[1].startsWith('den:')) {
          final bytes = files[strip(args[1])];
          if (bytes == null) return const RcloneResult(3, '', 'object not found');
          File(args[2]).writeAsBytesSync(bytes);
        } else {
          files[strip(args[2])] = File(args[1]).readAsBytesSync();
        }
        return const RcloneResult(0, '', '');
    }
    return const RcloneResult(1, '', 'unknown command');
  }
}

/// A Cloudflare connector, faked: what it was given, and how it says the tunnel stands.
class FakeConnector implements TunnelConnector {
  /// The tokens it was given, in order.
  final List<String> tokens = [];

  /// Whether it says the tunnel is connected.
  bool connected = false;

  /// The addresses it says Cloudflare sends here.
  List<String> hostnames = const [];

  @override
  bool get available => true;

  @override
  bool get hasToken => tokens.isNotEmpty;

  @override
  Future<void> setToken(String token) async => tokens.add(token);

  @override
  Future<void> clearToken() async => tokens.clear();

  @override
  Future<CloudflareStatus> state() async =>
      CloudflareStatus(token: hasToken, connected: hasToken && connected, hostnames: hasToken && connected ? hostnames : const []);
}

/// NASes on the network, faked.
class FakeFinder implements NasFinder {
  @override
  Future<List<FoundNas>> find({Duration wait = const Duration(seconds: 3)}) async =>
      const [FoundNas(name: 'Family NAS', host: '192.168.1.40')];
}

/// A tunnel token as Cloudflare makes them: base64 JSON with the account, tunnel and secret.
String fakeTunnelToken({String secret = 'c2VjcmV0LXNlY3JldC1zZWNyZXQtc2VjcmV0'}) =>
    base64.encode(utf8.encode(jsonEncode({'a': 'account-tag-1234', 't': '6ff42ae2-765d-4adf-8112-31c55c1551ef', 's': secret})));

/// Opens the hub in the data directory [dir] as `den_hub serve` does: its keys (made on first
/// use) and its log.
Future<Den> openDataDir(String dir) async {
  final keysFile = File('$dir/keys.json');
  final DeviceKeys keys;
  if (keysFile.existsSync()) {
    keys = await DeviceKeys.fromJson((jsonDecode(keysFile.readAsStringSync()) as Map).cast<String, Object?>());
  } else {
    keys = await DeviceKeys.generate();
    keysFile.parent.createSync(recursive: true);
    keysFile.writeAsStringSync(jsonEncode(await keys.toJson()));
  }
  return Den.open(storage: FileStorage('$dir/log'), keys: keys);
}

/// A demo family's phone and its approved hub, kept in the data directory [dir], with Alex's
/// recovery words set to [words] (when given).
Future<(Den phone, Den hub)> familyAt(String dir, {List<String>? words}) async {
  final phone = await createDemoFamily();
  if (words != null) {
    final alex = phone.members.firstWhere((m) => m.name == 'Alex');
    await phone.setRecoveryKey(alex.id, (await RecoveryWords.key(words)).publicKey);
  }
  final hub = await openDataDir(dir);
  await hub.requestJoin(
    familyId: phone.familyId!,
    founderPubkey: phone.founderPubkey!,
    deviceName: 'Closet hub',
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
  return (phone, hub);
}

/// A server as `den_hub serve` runs it: a host over the data directory [dir] with its own
/// family's hub in it, a fake connector, rclone and NAS finder, and a restore that opens the
/// directory again.
class ServerFixture {
  ServerFixture._(this.dir, this.host, this.connector, this.rclone, this.logged);

  /// The data directory.
  final String dir;

  /// The host.
  final DenHost host;

  /// The connector.
  final FakeConnector connector;

  /// rclone.
  final FakeRclone rclone;

  /// Every line the server logged.
  final List<String> logged;

  /// The server's loopback address.
  Uri get base => host.localUrl;

  /// The server's own family's hub now.
  DenHub get own => host.ownFamily!;

  /// Starts the server over [dir], whose hub [den] is (opened by [openDataDir]); [publicUrl] as
  /// `DEN_PUBLIC_URL` would give it.
  static Future<ServerFixture> start(String dir, Den den,
      {Uri? publicUrl, String? backupPassphrase, ServerUpdater? updater, int Function()? clock}) async {
    final logged = <String>[];
    final log = HubLog(level: LogLevel.debug, sink: logged.add);
    final connector = FakeConnector();
    final rclone = FakeRclone();
    HubConfig configFor() {
      final saved = File('$dir/hub/$addressFile');
      final address = publicUrl ?? (saved.existsSync() ? Uri.parse(saved.readAsStringSync().trim()) : null);
      return HubConfig(port: 0, host: InternetAddress.loopbackIPv4, dataDir: dir, mdns: false, log: log, publicUrl: address);
    }

    final host = await DenHost.start(HostConfig(
      port: 0,
      host: InternetAddress.loopbackIPv4,
      dataDir: dir,
      log: log,
      single: true,
      connector: connector,
      rclone: rclone,
      nasFinder: FakeFinder(),
      backupPassphrase: backupPassphrase,
      updater: updater,
      clock: clock,
      reopenOwn: () async {
        final again = await openDataDir(dir);
        return (den: again, config: configFor(), close: again.close);
      },
    ));
    await host.add(den, configFor(), onClosed: den.close);
    return ServerFixture._(dir, host, connector, rclone, logged);
  }

  /// A request with the setup code [code] (null: the server's own). From the home network the
  /// code isn't needed; [outside] sends it through a tunnel, with the door pass the setup link
  /// gives, where the code is what counts.
  Future<ApiResult> withCode(String method, String path, {Object? body, String? code, bool outside = false}) async =>
      apiCall(base, method, path, body: body, headers: {
        HubSetup.codeHeader: code ?? own.setupCode ?? '',
        if (outside) ...await outsideHeaders(),
      });

  /// The headers of a browser outside the home that opened this server's setup link.
  Future<Map<String, String>> outsideHeaders() async =>
      {...fromTunnel, 'cookie': await doorPass(base, '/setup/${own.setupCode}/${own.den.deviceId}')};

  /// A request [den] signs for the server's own family's hub.
  Future<ApiResult> signed(Den den, String method, String path, {Object? body}) async {
    final bytes = body == null ? <int>[] : utf8.encode(jsonEncode(body));
    final headers = await DeviceRequest.sign(
      keys: den.keys,
      method: method,
      url: base.resolve(path),
      body: bytes,
      hub: own.den.deviceId,
      actorId: den.actor?.id,
    );
    return apiCall(base, method, path, body: body, headers: headers);
  }

  /// Stops the server.
  Future<void> stop() => host.stop();
}
