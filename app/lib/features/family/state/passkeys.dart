import '../../../app/app_state.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/sync/den_network.dart';
import '../../../platform/sync/hub_api.dart';
import '../../../platform/sync/hub_client.dart';

/// Where this device's passkeys are kept: the family's hub. Tests put fakes here, as for
/// `Pairing.service`.
abstract final class PasskeyHub {
  /// Whether [app]'s family has a hub this device can reach to keep a passkey.
  static bool Function(AppState app) reachable = (app) {
    final network = app.network;
    return network != null && (network.isHub || network.hubDevice != null);
  };

  /// The hub's passkeys, for [app]'s device; only when [reachable].
  static PasskeySource Function(AppState app) source = (app) => HubPasskeySource(app.network!);
}

/// The hub's options for making a passkey on this device: what the page arms before the tap.
class PasskeyOptions {
  const PasskeyOptions({required this.options, required this.expires, this.existing = 0});

  /// What `navigator.credentials.create` takes, as the hub wrote it (base64url bytes).
  final Map<String, Object?> options;

  /// UTC milliseconds when its challenge runs out.
  final int expires;

  /// How many passkeys this person has already, on any device.
  final int existing;

  /// The RP ID the hub named: the page must be at this host.
  String? get rpId => options['rp'] is Map ? (options['rp']! as Map)['id'] as String? : null;
}

/// One of the person's passkeys, as the hub keeps it.
class PasskeySummary {
  const PasskeySummary({required this.id, this.madeOn, this.made, this.used});

  final String id;

  /// The device it was made on ("Alex's iPhone").
  final String? madeOn;

  /// UTC milliseconds.
  final int? made;
  final int? used;

  static PasskeySummary? fromJson(Object? json) {
    if (json is! Map || json['id'] is! String) return null;
    return PasskeySummary(
      id: json['id']! as String,
      madeOn: json['made_on'] as String?,
      made: (json['made_ms'] as num?)?.toInt(),
      used: (json['used_ms'] as num?)?.toInt(),
    );
  }
}

/// A person's passkeys at the family's hub (docs/hub-api.md, "Getting back in with a passkey"),
/// asked by their own device; a fake in tests.
abstract interface class PasskeySource {
  /// Options with a fresh challenge for making one here.
  Future<PasskeyOptions> creationOptions();

  /// Keeps [credential] (the browser's answer to `create`) as this person's passkey.
  Future<PasskeySummary> register(Map<String, Object?> credential);

  /// This person's passkeys.
  Future<List<PasskeySummary>> mine();

  /// Removes one of theirs.
  Future<void> remove(String id);
}

/// [PasskeySource] through the family's hub, signed by this device, at the address the page is
/// at: a passkey belongs to it.
class HubPasskeySource implements PasskeySource {
  HubPasskeySource(DenNetwork network) : _api = HubApi(network);

  final HubApi _api;

  /// The page's own address on the web; the hub's on the apps (which make none yet).
  static Uri? get _here {
    if (!Capabilities.web) return null;
    final base = Uri.base;
    return Uri(scheme: base.scheme, host: base.host, port: base.hasPort ? base.port : null);
  }

  @override
  Future<PasskeyOptions> creationOptions() async {
    final json = await _api.send('POST', '/api/v1/passkeys/options', body: const {}, at: _here, missing: 'Update the family\'s hub first.');
    final options = json['options'];
    if (options is! Map) throw const HubException("The hub's answer was missing something. Try again.");
    return PasskeyOptions(
      options: Map<String, Object?>.from(options),
      expires: (json['expires_ms'] as num?)?.toInt() ?? 0,
      existing: (json['existing'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<PasskeySummary> register(Map<String, Object?> credential) async {
    final json = await _api.send('POST', '/api/v1/passkeys', body: {'credential': credential}, at: _here);
    return PasskeySummary.fromJson(json) ?? (throw const HubException("The hub's answer was missing something. Try again."));
  }

  @override
  Future<List<PasskeySummary>> mine() async {
    final json = await _api.send('GET', '/api/v1/passkeys', at: _here, missing: 'none');
    return [
      if (json['passkeys'] case final List<Object?> list)
        for (final p in list) ?PasskeySummary.fromJson(p),
    ];
  }

  @override
  Future<void> remove(String id) => _api.send('DELETE', '/api/v1/passkeys/${Uri.encodeComponent(id)}', at: _here);
}
