import 'dart:convert';

import 'package:den_net/den_net.dart';
import 'package:http/http.dart' as http;

import '../web/web_app.dart';
import 'den_network.dart';
import 'hub_client.dart';

/// Where the hub stands on this device's reminders.
class HubPushStatus {
  const HubPushStatus({required this.key, required this.subscribed});

  /// The hub's VAPID public key, base64url: what the browser subscribes with.
  final String key;

  /// Whether the hub sends this device reminders.
  final bool subscribed;
}

/// This device's reminders from the hub through Web Push (`/api/v1/push`), every request signed
/// with this device's key for whoever is acting on it.
class HubPushClient {
  HubPushClient(this.network, {http.Client? client}) : _http = client ?? http.Client();

  final DenNetwork network;
  final http.Client _http;

  Future<HubPushStatus> status() => _send('GET', '/api/v1/push');

  /// Hands the hub this browser's subscription.
  Future<HubPushStatus> subscribe(WebPushSubscription subscription) =>
      _send('PUT', '/api/v1/push', body: subscription.toJson());

  Future<HubPushStatus> unsubscribe() => _send('DELETE', '/api/v1/push');

  /// One notification to this device, to see that reminders arrive.
  Future<void> test() async => _send('POST', '/api/v1/push/test');

  Future<HubPushStatus> _send(String method, String path, {Map<String, Object?>? body}) async {
    final den = network.den;
    final hub = network.hubDevice?.id;
    if (hub == null) throw const HubException("This family has no hub yet, and reminders come from the hub.");
    final bases = await network.hubBases();
    if (bases.isEmpty) throw const HubException("Den doesn't know the hub's address yet.");
    final bytes = body == null ? const <int>[] : utf8.encode(jsonEncode(body));
    HubException? last;
    for (final base in bases) {
      final url = base.replace(path: path);
      final headers = await DeviceRequest.sign(
        keys: den.keys,
        method: method,
        url: url,
        body: bytes,
        hub: hub,
        actorId: den.actor?.id,
      );
      final request = http.Request(method, url)..headers.addAll(headers);
      if (body != null) {
        request.headers['content-type'] = 'application/json';
        request.bodyBytes = bytes;
      }
      final http.Response response;
      try {
        response = await http.Response.fromStream(await _http.send(request)).timeout(const Duration(seconds: 15));
      } on Object {
        last = HubException("Couldn't reach the hub at ${base.host}. Check the connection, then try again.");
        continue;
      }
      Map<String, Object?> json;
      try {
        json = Map<String, Object?>.from(jsonDecode(response.body) as Map);
      } on Object {
        json = const {};
      }
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return HubPushStatus(key: json['key'] as String? ?? '', subscribed: json['subscribed'] == true);
      }
      final error = json['error'] is Map ? Map<String, Object?>.from(json['error']! as Map) : const <String, Object?>{};
      throw HubException(
        response.statusCode == 404 && error['code'] == 'not_found' && path == '/api/v1/push'
            ? "The family's hub can't send reminders to browsers yet. Update the hub, then try again."
            : error['message'] as String? ?? 'The hub refused that (${response.statusCode}).',
        code: error['code'] as String?,
      );
    }
    throw last ?? const HubException("Couldn't reach the hub.");
  }
}
