import '../../../platform/sync/den_network.dart';
import '../../../platform/sync/hub_api.dart';

/// An app a parent set up on the hub to sign in with (Alexa+, which can't register itself).
class HubApp {
  const HubApp({required this.id, required this.name, required this.redirects, this.secret, this.extra = const {}});

  factory HubApp.fromJson(Map<String, Object?> json) => HubApp(
        id: json['client_id'] as String? ?? '',
        name: json['name'] as String? ?? 'An app',
        redirects: [
          if (json['redirect_uris'] case final List<Object?> uris)
            for (final u in uris)
              if (u is String) u,
        ],
        secret: json['client_secret'] as String?,
        extra: {
          for (final key in const ['authorization_endpoint', 'token_endpoint', 'resource'])
            if (json[key] is String) key: json[key]! as String,
        },
      );

  final String id;
  final String name;
  final List<String> redirects;

  /// Shown once, right after it's set up.
  final String? secret;

  /// The addresses to enter beside the id and secret, right after it's set up.
  final Map<String, String> extra;
}

/// Where the apps a parent set up come from: the hub, or a fake in tests.
abstract interface class HubAppsSource {
  Future<List<HubApp>> list();
  Future<HubApp> create(String name, List<String> redirects);
  Future<void> remove(String id);
}

/// The hub's apps parents set up (`/api/v1/connections/clients`), from a parent's own device.
class HubApps implements HubAppsSource {
  HubApps(DenNetwork network) : _api = HubApi(network);

  final HubApi _api;

  static const _old = "The family's hub can't set up apps yet. Update the hub, then try again.";

  @override
  Future<List<HubApp>> list() async {
    final json = await _api.send('GET', '/api/v1/connections/clients', missing: _old);
    return [
      if (json['clients'] case final List<Object?> list)
        for (final c in list)
          if (c is Map) HubApp.fromJson(c.cast<String, Object?>()),
    ];
  }

  /// Sets up [name] to return to [redirects]; the answer holds the secret, shown this once.
  @override
  Future<HubApp> create(String name, List<String> redirects) async => HubApp.fromJson(
        await _api.send('POST', '/api/v1/connections/clients', body: {'name': name, 'redirect_uris': redirects}, missing: _old),
      );

  /// Removes [id]; the connections it made end too.
  @override
  Future<void> remove(String id) => _api.send('DELETE', '/api/v1/connections/clients/$id');
}
