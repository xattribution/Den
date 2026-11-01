import '../../../platform/sync/den_network.dart';
import '../../../platform/sync/hub_api.dart';
import '../../../platform/sync/hub_client.dart';

/// Where one provider stands on the hub: on or off, who turned it on and when, and the
/// addresses to register with it. Never what it was set up with: the hub doesn't say.
class ProviderSetup {
  const ProviderSetup({required this.on, this.setAt, this.setBy, this.redirects = const [], this.domains = const []});

  factory ProviderSetup.fromJson(Object? json, {required String redirectsKey}) {
    final m = json is Map ? json : const {};
    List<String> list(Object? v) => [if (v is List) for (final s in v) if (s is String) s];
    final at = m['set_at'];
    return ProviderSetup(
      on: m['on'] == true,
      setAt: at is int && at > 0 ? DateTime.fromMillisecondsSinceEpoch(at) : null,
      setBy: m['set_by'] as String?,
      redirects: list(m[redirectsKey]),
      domains: list(m['domains']),
    );
  }

  final bool on;
  final DateTime? setAt;

  /// The parent who turned it on, by name.
  final String? setBy;

  /// Where the provider sends people back, one for each family on the server (Google's
  /// "Authorized redirect URIs", Apple's "Return URLs").
  final List<String> redirects;

  /// Apple's "Domains and subdomains": each family's address.
  final List<String> domains;
}

/// What the hub says about signing in with Google and Apple.
class SignInSetupStatus {
  const SignInSetupStatus({required this.google, required this.apple, required this.https, this.withoutHttps = const []});

  factory SignInSetupStatus.fromJson(Map<String, Object?> json) => SignInSetupStatus(
        google: ProviderSetup.fromJson(json['google'], redirectsKey: 'redirect_urls'),
        apple: ProviderSetup.fromJson(json['apple'], redirectsKey: 'return_urls'),
        https: json['https'] != false,
        withoutHttps: [if (json['without_https'] case final List<Object?> l) for (final s in l) if (s is String) s],
      );

  final ProviderSetup google;
  final ProviderSetup apple;

  /// Whether any family on the server has an https address, which signing in needs.
  final bool https;

  /// Families on the server without one, by address.
  final List<String> withoutHttps;
}

/// Setting up signing in with Google and Apple on the family's hub (docs/hub-api.md, "Setting up
/// signing in with Google and Apple"): the hub, or a fake in tests. Every call throws
/// [HubException]; its code is `host_family_only` when this family isn't the one whose server
/// it is.
abstract interface class SignInSetupSource {
  Future<SignInSetupStatus> status();

  /// Turns Google on with the client from Google's console, or changes it.
  Future<SignInSetupStatus> turnOnGoogle({required String clientId, required String clientSecret});

  /// Turns Apple on, or changes it: [key] is the `.p8` file's text.
  Future<SignInSetupStatus> turnOnApple({required String servicesId, required String teamId, required String keyId, required String key});

  /// Turns `google` or `apple` off.
  Future<SignInSetupStatus> turnOff(String provider);
}

/// [SignInSetupSource] through the family's hub, signed by this phone.
class HubSignInSetupSource implements SignInSetupSource {
  HubSignInSetupSource(DenNetwork network) : _api = HubApi(network);

  final HubApi _api;

  static const String _path = '/api/v1/hub/sign-in';
  static const String _old = 'Your family\'s hub is too old to set this up. Update it first.';

  @override
  Future<SignInSetupStatus> status() async => SignInSetupStatus.fromJson(await _api.send('GET', _path, missing: _old));

  @override
  Future<SignInSetupStatus> turnOnGoogle({required String clientId, required String clientSecret}) async => SignInSetupStatus.fromJson(
      await _api.send('PUT', '$_path/google', body: {'client_id': clientId, 'client_secret': clientSecret}, missing: _old));

  @override
  Future<SignInSetupStatus> turnOnApple(
          {required String servicesId, required String teamId, required String keyId, required String key}) async =>
      SignInSetupStatus.fromJson(await _api.send('PUT', '$_path/apple',
          body: {'services_id': servicesId, 'team_id': teamId, 'key_id': keyId, 'key': key}, missing: _old));

  @override
  Future<SignInSetupStatus> turnOff(String provider) async =>
      SignInSetupStatus.fromJson(await _api.send('DELETE', '$_path/$provider', missing: _old));
}
