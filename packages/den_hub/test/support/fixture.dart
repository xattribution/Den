import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:http/http.dart' as http;

/// A hub joined to the demo family (the Carters), with Alex's phone as the parent device.
class HubFixture {
  HubFixture._(this.phone, this.hubDen, this.hub);

  /// Alex's phone, which founded the family.
  final Den phone;

  /// The hub's engine.
  final Den hubDen;

  /// The running hub.
  final DenHub hub;

  /// The hub's base URL.
  Uri get base => hub.localUrl;

  /// Starts a hub over a fresh demo family. [configure] adjusts the configuration.
  static Future<HubFixture> start({HubConfig Function(HubConfig base)? configure, String? dataDir}) async {
    final phone = await createDemoFamily();
    final hubDen = await approvedHub(phone);
    var config = HubConfig(
      port: 0,
      host: InternetAddress.loopbackIPv4,
      mdns: false,
      dataDir: dataDir,
      log: HubLog(level: LogLevel.warn, sink: (line) => stderr.writeln('[hub] $line')),
    );
    if (configure != null) config = configure(config);
    final hub = await DenHub.start(hubDen, config);
    return HubFixture._(phone, hubDen, hub);
  }

  /// A hub-mode device approved by [phone], holding everything the phone holds.
  static Future<Den> approvedHub(Den phone, {String name = 'Kitchen hub'}) async {
    final hub = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    await hub.requestJoin(
      familyId: phone.familyId!,
      founderPubkey: phone.founderPubkey!,
      deviceName: name,
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
    return hub;
  }

  /// Member id by name.
  String id(String name) => phone.members.firstWhere((m) => m.name == name).id;

  /// Sends the hub what the phone has that it lacks.
  Future<void> toHub() => hubDen.ingest(phone.changesSince(hubDen.versionVector));

  /// Sends the phone what the hub has that it lacks.
  Future<void> toPhone() => phone.ingest(hubDen.changesSince(phone.versionVector));

  /// A token made on the phone and synced to the hub.
  Future<String> token({Set<Scope> scopes = const {Scope.read}, String? member, String label = 'Test', int? expires}) async {
    final token = await phone.addTokenConnection(label: label, scopes: scopes, member: member, expires: expires);
    await toHub();
    return token;
  }

  /// Calls the hub and decodes the JSON answer.
  Future<ApiResult> call(String method, String path, {String? token, Object? body, Map<String, String>? headers}) =>
      apiCall(base, method, path, token: token, body: body, headers: headers);

  /// Stops the hub and closes the engines.
  Future<void> stop() async {
    await hub.stop();
    await hubDen.close();
    await phone.close();
  }
}

/// Calls a hub at [base] and decodes the JSON answer.
Future<ApiResult> apiCall(Uri base, String method, String path,
    {String? token, Object? body, Map<String, String>? headers}) async {
  final request = http.Request(method, base.resolve(path));
  if (token != null) request.headers['authorization'] = 'Bearer $token';
  if (headers != null) request.headers.addAll(headers);
  if (body != null) {
    request.headers['content-type'] = 'application/json';
    request.body = body is String ? body : jsonEncode(body);
  }
  final response = await http.Response.fromStream(await request.send());
  Object? json;
  try {
    json = response.body.isEmpty ? null : jsonDecode(response.body);
  } on FormatException {
    json = null;
  }
  return ApiResult(response.statusCode, json, response.headers, response.body);
}

/// One HTTP answer.
class ApiResult {
  ApiResult(this.status, this.json, this.headers, this.text);
  final int status;
  final Object? json;
  final Map<String, String> headers;
  final String text;

  Map<String, Object?> get body => (json as Map).cast<String, Object?>();
  Map<String, Object?> get error => (body['error'] as Map).cast<String, Object?>();

  @override
  String toString() => 'ApiResult($status $text)';
}

/// Waits until [condition] holds.
Future<void> eventually(FutureOr<bool> Function() condition, {Duration timeout = const Duration(seconds: 15)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
