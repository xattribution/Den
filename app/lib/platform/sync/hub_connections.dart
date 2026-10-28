import 'package:http/http.dart' as http;

import 'den_network.dart';
import 'hub_api.dart';

/// An app signing in to the hub (claude.ai, ChatGPT) that waits for a parent to let it in.
class ConnectionRequest {
  const ConnectionRequest({
    required this.id,
    required this.code,
    required this.clientName,
    required this.redirectHost,
    required this.scopes,
    required this.expires,
    this.connection,
  });

  factory ConnectionRequest.fromJson(Map<String, Object?> json) => ConnectionRequest(
        id: json['id'] as String? ?? '',
        code: json['code'] as String? ?? '',
        clientName: json['client_name'] as String? ?? 'An app',
        redirectHost: json['redirect_host'] as String? ?? '',
        scopes: [
          if (json['scopes'] case final List<Object?> scopes)
            for (final s in scopes)
              if (s is String) s,
        ],
        expires: (json['expires_ms'] as num?)?.toInt() ?? 0,
        connection: json['connection'] as String?,
      );

  final String id;

  /// The code the person signing in sees on their screen (`K7QP-M4XD`).
  final String code;

  /// The name the app registered with: anything it likes.
  final String clientName;

  /// Where its sign-in returns (`claude.ai`), which it can't make up.
  final String redirectHost;
  final List<String> scopes;

  /// UTC milliseconds.
  final int expires;

  /// The pending connection the hub wrote once a parent let it in.
  final String? connection;
}

/// The hub's waiting sign-ins (`/api/v1/connections/requests`), for a parent's own device.
class HubConnections {
  HubConnections(this.network, {http.Client? client}) : _api = HubApi(network, client: client);

  final DenNetwork network;
  final HubApi _api;

  static const _old = "The family's hub doesn't hold sign-ins for a parent yet. Update the hub, then try again.";

  /// The requests waiting, newest first.
  Future<List<ConnectionRequest>> requests() async {
    final json = await _api.send('GET', '/api/v1/connections/requests', missing: _old);
    return [
      if (json['requests'] case final List<Object?> list)
        for (final r in list)
          if (r is Map) ConnectionRequest.fromJson(r.cast<String, Object?>()),
    ];
  }

  /// Lets [request] in: the hub writes a pending connection for a parent to approve. Answers its
  /// id.
  Future<String?> admit(ConnectionRequest request) async {
    final json = await _api.send('POST', '/api/v1/connections/requests/${request.id}', body: {'decision': 'admit'});
    return json['connection'] as String?;
  }

  /// Turns [request] away; the app is told no.
  Future<void> decline(ConnectionRequest request) async {
    await _api.send('POST', '/api/v1/connections/requests/${request.id}', body: {'decision': 'decline'});
  }
}
