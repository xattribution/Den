import 'dart:convert';
import 'dart:io';

import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';
import 'package:http/http.dart' as http;

import 'fixture.dart';

/// One family on a test host: its founder's phone, its hub's engine and its hub, at its own
/// address.
class HostedFamily {
  HostedFamily(this.hostname, this.phone, this.hubDen, this.hub);

  /// The family's address (`den-a.test`); requests name it in `Host`.
  final String hostname;

  /// The founder's phone (Alex, in the demo family).
  final Den phone;

  /// The hub's engine.
  final Den hubDen;

  /// The family's hub on the host.
  final DenHub hub;

  /// Member id by name.
  String id(String name) => phone.members.firstWhere((m) => m.name == name).id;

  /// Sends the hub what the phone has that it lacks.
  Future<void> toHub() => hubDen.ingest(phone.changesSince(hubDen.versionVector));

  /// A token made on the phone and synced to the hub.
  Future<String> token({Set<Scope> scopes = const {Scope.read}}) async {
    final token = await phone.addTokenConnection(label: 'Test', scopes: scopes);
    await toHub();
    return token;
  }
}

/// A Den host on loopback with a family at each of [hostnames], each a fresh demo family (the
/// Carters, each with its own keys and family id).
class HostFixture {
  HostFixture._(this.host, this.families);

  /// The host.
  final DenHost host;

  /// The families by address.
  final Map<String, HostedFamily> families;

  /// The host's loopback address.
  Uri get base => host.localUrl;

  /// The family at [hostname].
  HostedFamily operator [](String hostname) => families[hostname]!;

  static HubLog _log() => HubLog(level: LogLevel.warn, sink: (line) => stderr.writeln('[host] $line'));

  /// Starts a host with a family at each of [hostnames]. [configure] adjusts the host's
  /// configuration, [hub] each family's.
  static Future<HostFixture> start({
    List<String> hostnames = const ['den-a.test', 'den-b.test'],
    HostConfig Function(HostConfig base)? configure,
    HubConfig Function(String hostname, HubConfig base)? hub,
  }) async {
    var config = HostConfig(port: 0, host: InternetAddress.loopbackIPv4, log: _log());
    if (configure != null) config = configure(config);
    final host = await DenHost.start(config);
    final families = <String, HostedFamily>{};
    for (final name in hostnames) {
      families[name] = await addFamily(host, name, configure: hub == null ? null : (c) => hub(name, c));
    }
    return HostFixture._(host, families);
  }

  /// Adds a fresh demo family at [hostname] to [host].
  static Future<HostedFamily> addFamily(DenHost host, String hostname, {HubConfig Function(HubConfig)? configure}) async {
    final phone = await createDemoFamily();
    final hubDen = await HubFixture.approvedHub(phone);
    var config = HubConfig(mdns: false, publicUrl: Uri.parse('https://$hostname'), log: _log().labeled(hostname));
    if (configure != null) config = configure(config);
    final hub = await host.add(hubDen, config);
    return HostedFamily(hostname, phone, hubDen, hub);
  }

  /// Calls the host as if at [hostname] (null: at its loopback address, which is no family's).
  Future<ApiResult> call(String method, String path,
      {String? hostname, String? token, Object? body, Map<String, String>? headers}) {
    return apiCall(base, method, path, token: token, body: body, headers: {...?headers, 'host': ?hostname});
  }

  /// A request signed by [den]'s device for the hub [hub], made at [hostname]. Without
  /// [sendHub] it leaves out `X-Den-Hub`, as an older app does.
  Future<ApiResult> signed(Den den, String method, String path,
      {required String hub, String? hostname, Object? body, bool sendHub = true}) async {
    final bytes = body == null ? <int>[] : utf8.encode(jsonEncode(body));
    final headers = await DeviceRequest.sign(
      keys: den.keys,
      method: method,
      url: base.resolve(path),
      body: bytes,
      hub: hub,
      actorId: den.actor?.id,
    );
    if (!sendHub) headers.remove(DeviceRequest.hubHeader);
    return call(method, path, hostname: hostname, body: body, headers: headers);
  }

  /// A raw GET at [hostname], for answers that aren't JSON (calendars, streams).
  Future<http.StreamedResponse> open(String path, {String? hostname}) {
    final request = http.Request('GET', base.resolve(path));
    if (hostname != null) request.headers['host'] = hostname;
    return http.Client().send(request);
  }

  /// Stops the host and closes every engine.
  Future<void> stop() async {
    await host.stop();
    for (final f in families.values) {
      await f.hubDen.close();
      await f.phone.close();
    }
  }
}
