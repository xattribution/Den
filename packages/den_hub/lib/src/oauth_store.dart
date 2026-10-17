import 'dart:math';

import 'package:den_core/den_core.dart';

import 'state.dart';

/// A client registered with `/oauth/register`.
class OAuthClient {
  /// Creates a client record.
  OAuthClient({
    required this.id,
    required this.name,
    required this.redirectUris,
    required this.authMethod,
    this.secretHash,
    required this.created,
  });

  /// Reads a stored client.
  factory OAuthClient.fromJson(String id, Map<String, Object?> json) => OAuthClient(
        id: id,
        name: json['name'] as String? ?? 'An app',
        redirectUris: [...((json['redirect_uris'] as List?) ?? const []).whereType<String>()],
        authMethod: json['auth'] as String? ?? 'none',
        secretHash: json['secret'] as String?,
        created: json['created'] as int? ?? 0,
      );

  /// `client_id`.
  final String id;

  /// `client_name`, shown to parents.
  final String name;

  /// Registered redirect URIs, matched exactly.
  final List<String> redirectUris;

  /// `none`, `client_secret_post` or `client_secret_basic`.
  final String authMethod;

  /// SHA-256 of the client secret, for confidential clients.
  final String? secretHash;

  /// Registration time (seconds).
  final int created;

  /// For storage.
  Map<String, Object?> toJson() => {
        'name': name,
        'redirect_uris': redirectUris,
        'auth': authMethod,
        'secret': ?secretHash,
        'created': created,
      };
}

/// A refresh token's record; the token itself is stored only as a hash.
class RefreshGrant {
  /// Creates a record.
  RefreshGrant(this.connection, this.client, this.expires);

  /// Reads a stored record.
  factory RefreshGrant.fromJson(Map<String, Object?> json) =>
      RefreshGrant(json['connection'] as String, json['client'] as String, json['expires'] as int);

  /// The connection it refreshes.
  final String connection;

  /// The client it was issued to.
  final String client;

  /// When it stops working (UTC ms).
  final int expires;

  /// For storage.
  Map<String, Object?> toJson() => {'connection': connection, 'client': client, 'expires': expires};
}

/// OAuth clients and refresh-token hashes, kept in the hub's state (`oauth.json`).
class OAuthStore {
  /// Opens the store in [state].
  OAuthStore(this.state);

  /// Where it is kept.
  final HubState state;

  final Random _random = Random.secure();

  Map<String, Object?> get _doc => state.read('oauth');

  Map<String, Object?> _section(String name) {
    final raw = _doc[name];
    if (raw is Map<String, Object?>) return raw;
    final fresh = <String, Object?>{...?(raw as Map?)?.cast<String, Object?>()};
    _doc[name] = fresh;
    return fresh;
  }

  /// A random secret: `den_` and [bytes] random bytes in base64url.
  String secret([int bytes = 32]) => 'den_${b64e(List.generate(bytes, (_) => _random.nextInt(256)))}';

  /// The client with [id], or null.
  OAuthClient? client(String id) {
    final raw = _section('clients')[id];
    return raw is Map ? OAuthClient.fromJson(id, raw.cast<String, Object?>()) : null;
  }

  /// Number of registered clients.
  int get clientCount => _section('clients').length;

  /// Stores [client].
  Future<void> addClient(OAuthClient client) {
    _section('clients')[client.id] = client.toJson();
    return state.save('oauth');
  }

  /// The grant for refresh token [token], or null.
  RefreshGrant? refresh(String token) {
    final raw = _section('refresh')[hashToken(token)];
    return raw is Map ? RefreshGrant.fromJson(raw.cast<String, Object?>()) : null;
  }

  /// The connection a refresh token that was already used belonged to, or null.
  String? usedBy(String token) => _section('used')[hashToken(token)] as String?;

  /// Stores a new refresh token for [grant] and returns it.
  Future<String> issueRefresh(RefreshGrant grant) {
    final token = secret();
    _section('refresh')[hashToken(token)] = grant.toJson();
    return state.save('oauth').then((_) => token);
  }

  /// Retires [token] after use, remembering it to catch reuse.
  Future<void> retire(String token, String connection) {
    final hash = hashToken(token);
    _section('refresh').remove(hash);
    final used = _section('used');
    used[hash] = connection;
    while (used.length > 2000) {
      used.remove(used.keys.first);
    }
    return state.save('oauth');
  }

  /// Drops every refresh token of [connection].
  Future<void> revokeConnection(String connection) {
    _section('refresh').removeWhere((_, v) => v is Map && v['connection'] == connection);
    return state.save('oauth');
  }

  /// Drops expired refresh tokens.
  void prune(int now) => _section('refresh').removeWhere((_, v) => v is! Map || (v['expires'] as int? ?? 0) <= now);
}
