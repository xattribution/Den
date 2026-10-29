import 'package:http/http.dart' as http;

import '../web/web_app.dart';
import 'den_network.dart';
import 'hub_api.dart';
import 'hub_client.dart';

/// Where the hub stands on this device's reminders.
class HubPushStatus {
  const HubPushStatus({required this.key, required this.subscribed, this.hostKey, this.withHost = false});

  /// The hub's VAPID public key, base64url: what the browser subscribes with.
  final String key;

  /// Whether the hub sends this device reminders.
  final bool subscribed;

  /// The key every family on this Den host that shares one hands out (`host_key`), when this
  /// family does: one subscription made with it reaches each of them.
  final String? hostKey;

  /// Whether this device's subscription was made with [hostKey].
  final bool withHost;
}

/// This device's reminders from the hub through Web Push (`/api/v1/push`), every request signed
/// with this device's key for whoever is acting on it.
class HubPushClient {
  HubPushClient(this.network, {http.Client? client}) : _api = HubApi(network, client: client);

  final DenNetwork network;
  final HubApi _api;

  Future<HubPushStatus> status() => _send('GET', '/api/v1/push');

  /// Hands the hub this browser's subscription, made with [key] when it isn't the family's own
  /// (the host's key several families share).
  Future<HubPushStatus> subscribe(WebPushSubscription subscription, {String? key}) =>
      _send('PUT', '/api/v1/push', body: {...subscription.toJson(), 'key': ?key});

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
    return HubPushStatus(
      key: json['key'] as String? ?? '',
      subscribed: json['subscribed'] == true,
      hostKey: json['host_key'] as String?,
      withHost: json['with'] == 'host',
    );
  }

  void close() => _api.close();
}

/// One family's line to its hub's push endpoints, with its name for what the screen says.
class PushFamily {
  const PushFamily(this.name, this.client);

  final String name;
  final HubPushClient client;
}

/// Reminders for a browser holding several families at one address (FAMILY-LINKS-PLAN §3.5): a
/// browser holds one subscription, bound to one key. When every family says the host shares its
/// key with them ([HubPushStatus.hostKey]), one subscription made with it is registered with
/// each family; otherwise the subscription is the first family's own, and the others can't
/// reach this browser until whoever runs the server turns that on ([unreached]).
class PushPlan {
  const PushPlan({required this.key, required this.shared, required this.reached, this.unreached = const [], this.on = false});

  /// What the browser subscribes with.
  final String key;

  /// [key] is the host's, shared by every family in [reached].
  final bool shared;

  /// The families one subscription reaches, the first (the one Settings is for) first.
  final List<PushFamily> reached;

  /// Families whose hub doesn't share the host's key (or wasn't reachable).
  final List<String> unreached;

  /// Every family in [reached] has this device's subscription, made with [key].
  final bool on;

  /// Asks each of [families] (the one Settings is for first) where it stands, and decides.
  /// Throws [HubException] when the first family's hub can't be asked.
  static Future<PushPlan> look(List<PushFamily> families) async {
    final first = families.first;
    final statuses = <PushFamily, HubPushStatus>{first: await first.client.status()};
    final unreached = <String>[];
    for (final f in families.skip(1)) {
      try {
        statuses[f] = await f.client.status();
      } on HubException {
        unreached.add(f.name);
      }
    }
    final asked = [for (final f in families) if (statuses.containsKey(f)) f];
    final host = statuses[first]!.hostKey;
    final sharing = host != null && asked.length > 1 && asked.every((f) => statuses[f]!.hostKey == host);
    if (asked.length > 1 && sharing) {
      return PushPlan(
        key: host,
        shared: true,
        reached: asked,
        unreached: unreached,
        on: asked.every((f) => statuses[f]!.subscribed && statuses[f]!.withHost),
      );
    }
    final own = statuses[first]!;
    return PushPlan(
      key: own.key,
      shared: false,
      reached: [first],
      unreached: [...unreached, for (final f in asked.skip(1)) f.name],
      on: own.subscribed && !own.withHost,
    );
  }

  /// Registers [subscription] with every family it reaches.
  Future<void> register(WebPushSubscription subscription) async {
    for (final f in reached) {
      await f.client.subscribe(subscription, key: shared ? key : null);
    }
  }
}
