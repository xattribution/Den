/// Reaching the internet through a Cloudflare tunnel, from a token a parent pastes: the hub keeps
/// the token and a connector (cloudflared, which the server's image runs beside the hub) takes it
/// from there. The hub only ever talks to the connector through [TunnelConnector], so how the
/// image runs it can change without the hub changing.
///
/// [CloudflaredConnector], the contract with the install's packaging (docs/install-technical.md):
///
/// - cloudflared runs in a container of its own beside the hub's (never on the hub's loopback,
///   where every request from the internet would look like this machine itself), on the compose
///   network the hub trusts as its proxy (`DEN_TRUSTED_PROXIES`).
/// - The hub writes the token to `<data>/hub/tunnel-token`, owner-only (written to a temporary
///   file made 0600 first, then renamed into place), and removes the file to stop the tunnel.
///   The connector polls the file every few seconds and restarts cloudflared when it changes. The
///   token is in no backup, no answer and no log.
/// - The connector writes `<data>/hub/tunnel-status.json`: `{state: waiting | starting |
///   connected | error, hostname, service, connections, message, since, updated}`, stale once
///   `updated` is more than 30 seconds old. Its `message` says what is wrong in plain words.
/// - cloudflared's metrics server is at `DEN_CONNECTOR_METRICS` (`http://tunnel:20241`).
///   `GET /ready` answers 200 once the tunnel has a connection to Cloudflare; `GET /config` holds
///   the configuration Cloudflare sent, whose `ingress` rules name the family's address (a
///   remotely managed tunnel's public hostname), so nobody has to type it. Asked when the status
///   file is missing or stale.
/// - `DEN_CONNECTOR=cloudflared` says a connector is there at all; without it (a dev build, a
///   setup with its own front door) the first-boot pages don't ask for a token.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../backup/backup_files.dart' show tunnelTokenFile;
import '../host_state.dart' show HostState;

/// How the tunnel stands.
class CloudflareStatus {
  /// The state.
  const CloudflareStatus({required this.token, this.connected = false, this.hostnames = const [], this.reachable = true, this.message});

  /// What is wrong, in plain words, when the connector says (a token Cloudflare didn't take, a
  /// public hostname that points elsewhere).
  final String? message;

  /// Whether a token is saved.
  final bool token;

  /// Whether the tunnel has a connection to Cloudflare.
  final bool connected;

  /// The public addresses Cloudflare sends to this server, from the tunnel's configuration.
  final List<String> hostnames;

  /// Whether the connector answered at all (false: it isn't running, or is starting).
  final bool reachable;
}

/// The Cloudflare tunnel's connector, as the hub sees it.
abstract interface class TunnelConnector {
  /// Whether this server has a connector at all.
  bool get available;

  /// Whether a token is saved.
  bool get hasToken;

  /// Saves [token] (already checked by [tunnelTokenOf]) and has the connector use it.
  Future<void> setToken(String token);

  /// Forgets the token: the tunnel stops.
  Future<void> clearToken();

  /// How the tunnel stands now.
  Future<CloudflareStatus> state();
}

/// The token in what a parent pasted: the token itself (`eyJ...`), or the whole command
/// Cloudflare shows (`cloudflared service install eyJ...`, `--token eyJ...`). Null when it holds
/// none: a tunnel token is base64 JSON naming the account (`a`), the tunnel (`t`) and its secret
/// (`s`).
String? tunnelTokenOf(String pasted) {
  final candidates = [for (final m in RegExp(r'eyJ[A-Za-z0-9+/_-]+=*').allMatches(pasted)) m.group(0)!]
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final c in candidates) {
    try {
      final json = jsonDecode(utf8.decode(base64.decode(base64.normalize(c.replaceAll('-', '+').replaceAll('_', '/')))));
      if (json is Map && json['a'] is String && json['t'] is String && json['s'] is String) return c;
    } on FormatException {
      continue;
    }
  }
  return null;
}

/// The tunnel id in [token] ([tunnelTokenOf]'s), for the log: never the secret.
String? tunnelIdOf(String token) {
  try {
    final json = jsonDecode(utf8.decode(base64.decode(base64.normalize(token.replaceAll('-', '+').replaceAll('_', '/')))));
    return json is Map && json['t'] is String ? json['t'] as String : null;
  } on FormatException {
    return null;
  }
}

/// [TunnelConnector] for cloudflared beside the hub (see the library's comment).
class CloudflaredConnector implements TunnelConnector {
  /// The connector for the data directory [dataDir], whose metrics server is at [metrics].
  CloudflaredConnector({required this.dataDir, required this.available, Uri? metrics, http.Client? client})
      : metrics = metrics ?? Uri.parse('http://tunnel:20241'),
        _client = client ?? http.Client();

  /// The server's data directory (the host's own family's).
  final String dataDir;

  /// cloudflared's metrics server.
  final Uri metrics;

  @override
  final bool available;

  final http.Client _client;

  File get _file => File([dataDir, 'hub', tunnelTokenFile].join(Platform.pathSeparator));
  File get _statusFile => File([dataDir, 'hub', 'tunnel-status.json'].join(Platform.pathSeparator));

  /// The connector's own status file, while it is fresh (written in the last 30 seconds).
  CloudflareStatus? _fromStatusFile() {
    try {
      final file = _statusFile;
      if (!file.existsSync()) return null;
      final j = jsonDecode(file.readAsStringSync());
      if (j is! Map) return null;
      final updated = j['updated'];
      final at = updated is int
          ? (updated < 100000000000 ? updated * 1000 : updated)
          : updated is String
              ? DateTime.tryParse(updated)?.millisecondsSinceEpoch
              : null;
      if (at == null || DateTime.now().millisecondsSinceEpoch - at > 30000) return null;
      final hostname = j['hostname'];
      final message = j['message'];
      return CloudflareStatus(
        token: true,
        connected: j['state'] == 'connected',
        hostnames: [if (hostname is String && hostname.isNotEmpty) hostname.toLowerCase()],
        message: j['state'] == 'error' && message is String && message.isNotEmpty ? message : null,
      );
    } on Object {
      return null;
    }
  }

  @override
  bool get hasToken => _file.existsSync() && _file.lengthSync() > 0;

  @override
  Future<void> setToken(String token) async {
    final file = _file;
    HostState.ownerOnlyDir(file.parent);
    final temp = File('${file.path}.tmp');
    if (temp.existsSync()) temp.deleteSync();
    temp.createSync(exclusive: true);
    HostState.ownerOnlyFile(temp.path);
    temp.writeAsStringSync(token, flush: true);
    temp.renameSync(file.path);
  }

  @override
  Future<void> clearToken() async {
    if (_file.existsSync()) _file.deleteSync();
  }

  @override
  Future<CloudflareStatus> state() async {
    final token = hasToken;
    if (!token) return const CloudflareStatus(token: false);
    final said = _fromStatusFile();
    if (said != null) return said;
    var connected = false;
    try {
      final ready = await _client.get(metrics.replace(path: '/ready')).timeout(const Duration(seconds: 3));
      connected = ready.statusCode == 200;
    } on Object {
      return const CloudflareStatus(token: true, reachable: false);
    }
    var hostnames = const <String>[];
    try {
      final config = await _client.get(metrics.replace(path: '/config')).timeout(const Duration(seconds: 3));
      if (config.statusCode == 200) hostnames = ingressHostnames(config.body);
    } on Object {
      // The address is asked for instead.
    }
    return CloudflareStatus(token: true, connected: connected, hostnames: hostnames);
  }
}

/// The public hostnames in cloudflared's `/config` answer ([body]): `{version, config: {ingress:
/// [{hostname, service}, ...]}}`. The catch-all rule at the end has no hostname.
List<String> ingressHostnames(String body) {
  try {
    final json = jsonDecode(body);
    final config = json is Map ? json['config'] : null;
    final ingress = config is Map ? config['ingress'] : null;
    if (ingress is! List) return const [];
    return [
      for (final rule in ingress)
        if (rule is Map && rule['hostname'] is String && (rule['hostname'] as String).isNotEmpty && !(rule['hostname'] as String).contains('*'))
          (rule['hostname'] as String).toLowerCase(),
    ];
  } on FormatException {
    return const [];
  }
}
