import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'net_guard.dart';
import 'oauth_store.dart';

/// Why a client's metadata document can't be used; the message is for people.
class ClientMetadataProblem implements Exception {
  /// A problem explained by [message].
  const ClientMetadataProblem(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => 'ClientMetadataProblem: $message';
}

/// OAuth Client ID Metadata Documents (draft-ietf-oauth-client-id-metadata-document, which MCP
/// prefers to registration): a client whose `client_id` is an https URL publishes its name and
/// redirect addresses there, and the hub reads them instead of keeping a registration.
///
/// Documents are fetched through the hub's guarded client ([NetGuard]), so a `client_id` can't
/// make the hub reach its own network; without redirects, within [timeout] and [maxBytes]; and
/// kept for what the document's `Cache-Control` says, between [minCache] and [maxCache].
/// Only public clients (`token_endpoint_auth_method` `none`) are accepted: Den has no keys to
/// check a signed client assertion with.
class ClientMetadataDocuments {
  /// Reads documents with [client], the hub's guarded client.
  ClientMetadataDocuments(this.client, {this.now});

  /// Fetches documents.
  final http.Client client;

  /// The time (UTC ms), for tests.
  final int Function()? now;

  /// Largest document read.
  static const int maxBytes = 5 * 1024;

  /// How long a fetch may take (Claude allows ten seconds for a whole OAuth request).
  static const Duration timeout = Duration(seconds: 5);

  /// Shortest and longest a document is kept.
  static const Duration minCache = Duration(minutes: 5), maxCache = Duration(hours: 24);

  /// How long a document without caching headers is kept.
  static const Duration defaultCache = Duration(hours: 1);

  /// Most documents kept.
  static const int maxKept = 100;

  final Map<String, ({OAuthClient client, int until})> _kept = {};

  int _now() => now?.call() ?? DateTime.now().toUtc().millisecondsSinceEpoch;

  /// Whether [clientId] is a metadata document's URL: https, a host, a path other than `/`, no
  /// fragment, no user name or password, no `.` or `..` segments.
  static bool isDocumentUrl(String clientId) {
    if (!clientId.startsWith('https://')) return false;
    final u = Uri.tryParse(clientId);
    if (u == null || u.scheme != 'https' || u.host.isEmpty || u.userInfo.isNotEmpty || u.hasFragment) return false;
    if (u.path.isEmpty || u.path == '/') return false;
    return !u.pathSegments.any((s) => s == '.' || s == '..');
  }

  /// Whether the document at [clientId] is kept and fresh.
  bool isKept(String clientId) => (_kept[clientId]?.until ?? 0) > _now();

  /// The client [clientId] describes: kept, or fetched and checked. Throws
  /// [ClientMetadataProblem].
  Future<OAuthClient> resolve(String clientId) async {
    final kept = _kept[clientId];
    final now = _now();
    if (kept != null && kept.until > now) return kept.client;
    if (!isDocumentUrl(clientId)) throw const ClientMetadataProblem('The app\'s id isn\'t an https address with a path.');
    final fetched = await _fetch(Uri.parse(clientId));
    final parsed = parse(clientId, fetched.bytes);
    _kept.removeWhere((_, v) => v.until <= now);
    while (_kept.length >= maxKept) {
      _kept.remove(_kept.keys.first);
    }
    _kept[clientId] = (client: parsed, until: now + cacheFor(fetched.cacheControl).inMilliseconds);
    return parsed;
  }

  Future<({List<int> bytes, String? cacheControl})> _fetch(Uri url) async {
    final request = http.Request('GET', url)
      ..followRedirects = false
      ..headers['accept'] = 'application/json';
    try {
      final response = await client.send(request).timeout(timeout);
      if (response.statusCode != 200) {
        await response.stream.drain<void>();
        throw ClientMetadataProblem('The app\'s description answered ${response.statusCode}.');
      }
      final declared = response.contentLength;
      if (declared != null && declared > maxBytes) throw const ClientMetadataProblem('The app\'s description is too large.');
      final read = <int>[];
      await for (final chunk in response.stream.timeout(timeout)) {
        read.addAll(chunk);
        if (read.length > maxBytes) throw const ClientMetadataProblem('The app\'s description is too large.');
      }
      return (bytes: read, cacheControl: response.headers['cache-control']);
    } on ClientMetadataProblem {
      rethrow;
    } on BlockedAddress {
      throw const ClientMetadataProblem('The app\'s description is on a private network.');
    } on TimeoutException {
      throw const ClientMetadataProblem('The app\'s description took too long to load.');
    } on Object {
      throw const ClientMetadataProblem('The hub couldn\'t load the app\'s description.');
    }
  }

  /// How long to keep a document sent with [cacheControl].
  static Duration cacheFor(String? cacheControl) {
    if (cacheControl == null) return defaultCache;
    final directives = cacheControl.toLowerCase().split(',').map((d) => d.trim());
    if (directives.any((d) => d == 'no-store' || d == 'no-cache')) return minCache;
    for (final d in directives) {
      if (d.startsWith('max-age=')) {
        final seconds = int.tryParse(d.substring(8));
        if (seconds == null) break;
        final age = Duration(seconds: seconds);
        if (age < minCache) return minCache;
        if (age > maxCache) return maxCache;
        return age;
      }
    }
    return defaultCache;
  }

  /// The client described by [bytes], fetched from [clientId]. Throws [ClientMetadataProblem]
  /// when it isn't a JSON object, names another `client_id`, has no name or redirect addresses,
  /// lists an address Den won't send anyone to, or wants client authentication Den can't check.
  static OAuthClient parse(String clientId, List<int> bytes) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const ClientMetadataProblem('The app\'s description isn\'t JSON.');
    }
    if (json is! Map) throw const ClientMetadataProblem('The app\'s description isn\'t a JSON object.');
    if (json['client_id'] != clientId) throw const ClientMetadataProblem('The app\'s description names a different app.');
    final name = json['client_name'];
    if (name is! String || name.trim().isEmpty) throw const ClientMetadataProblem('The app\'s description has no name.');
    final uris = json['redirect_uris'];
    if (uris is! List || uris.isEmpty || uris.length > 10 || uris.any((u) => u is! String || u.length > 2000 || !redirectAllowed(u))) {
      throw const ClientMetadataProblem('The app\'s description lists addresses Den won\'t send anyone back to.');
    }
    final method = json['token_endpoint_auth_method'] ?? 'none';
    if (method != 'none') {
      throw const ClientMetadataProblem('Den signs in apps that use no client secret (token_endpoint_auth_method none).');
    }
    final trimmed = name.trim();
    return OAuthClient(
      id: clientId,
      name: trimmed.length > 60 ? trimmed.substring(0, 60) : trimmed,
      redirectUris: uris.cast<String>(),
      authMethod: 'none',
      created: 0,
      kind: OAuthClientKind.document,
    );
  }
}

/// Whether Den may send someone back to [uri] after sign-in: an https address, a loopback
/// `http` one (for apps on the person's computer), or an app's own scheme; never `javascript:`
/// and the like, and never with a fragment.
bool redirectAllowed(String uri) {
  final u = Uri.tryParse(uri);
  if (u == null || !u.hasScheme || u.fragment.isNotEmpty) return false;
  if (u.scheme == 'https') return u.host.isNotEmpty;
  if (u.scheme == 'http') return loopbackHosts.contains(u.host);
  return !const {'javascript', 'data', 'file', 'vbscript', 'blob', 'http', 'ws', 'wss', 'ftp'}.contains(u.scheme);
}

/// Hosts that mean "this computer".
const Set<String> loopbackHosts = {'localhost', '127.0.0.1', '[::1]', '::1'};

/// Whether redirect address [given] matches [registered]: exactly, or for a loopback `http`
/// address, on any port (RFC 8252 section 7.3: an app on the person's computer listens on
/// whatever port is free).
bool redirectMatches(String registered, String given) {
  if (registered == given) return true;
  final a = Uri.tryParse(registered);
  final b = Uri.tryParse(given);
  if (a == null || b == null || a.scheme != 'http' || b.scheme != 'http') return false;
  if (!loopbackHosts.contains(a.host) || a.host != b.host) return false;
  return a.path == b.path && a.query == b.query && !b.hasFragment && b.userInfo.isEmpty;
}
