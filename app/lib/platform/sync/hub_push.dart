import 'package:http/http.dart' as http;

import '../web/web_app.dart';
import 'den_network.dart';
import 'hub_api.dart';
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
  HubPushClient(this.network, {http.Client? client}) : _api = HubApi(network, client: client);

  final DenNetwork network;
  final HubApi _api;

  Future<HubPushStatus> status() => _send('GET', '/api/v1/push');

  /// Hands the hub this browser's subscription.
  Future<HubPushStatus> subscribe(WebPushSubscription subscription) =>
      _send('PUT', '/api/v1/push', body: subscription.toJson());

  Future<HubPushStatus> unsubscribe() => _send('DELETE', '/api/v1/push');

  /// One notification to this device, to see that reminders arrive.
  Future<void> test() async => _send('POST', '/api/v1/push/test');

  Future<HubPushStatus> _send(String method, String path, {Map<String, Object?>? body}) async {
    if (network.hubDevice == null && !network.isHub) {
      throw const HubException('This family has no hub yet, and reminders come from the hub.');
    }
    final json = await _api.send(
      method,
      path,
      body: body,
      missing: "The family's hub can't send reminders to browsers yet. Update the hub, then try again.",
    );
    return HubPushStatus(key: json['key'] as String? ?? '', subscribed: json['subscribed'] == true);
  }
}
