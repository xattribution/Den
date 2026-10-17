import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:cryptography/dart.dart';
import 'package:den_core/den_core.dart';
import 'package:shelf/shelf.dart';

import 'context.dart';
import 'http_util.dart';
import 'mcp/http.dart' show corsHeaders, originAllowed;
import 'oauth_page.dart';
import 'oauth_store.dart';

const List<String> _scopeNames = ['read', 'calendar', 'chores', 'lists', 'points', 'admin'];
const Set<Scope> _defaultScopes = {Scope.read, Scope.calendar, Scope.chores, Scope.lists, Scope.points};

class _Pending {
  _Pending(this.client, this.redirectUri, this.challenge, this.state, this.scopes, this.connection, this.created);
  final OAuthClient client;
  final String redirectUri;
  final String challenge;
  final String? state;
  final List<String> scopes;
  final String connection;
  final int created;
  String? code;
  int? codeIssued;
  bool used = false;
}

/// OAuth 2.1 for remote MCP clients: metadata, dynamic registration, authorization (approved
/// by a parent in the Den app, arriving as a synced change), and tokens with PKCE and
/// refresh-token rotation. Access tokens live only as hashes in the connection record.
class OAuthServer {
  /// Creates the server for [hub].
  OAuthServer(this.hub) : store = OAuthStore(hub.state);

  /// Shared hub context.
  final HubContext hub;

  /// Clients and refresh tokens.
  final OAuthStore store;

  final Map<String, _Pending> _requests = {};

  /// How long a parent has to approve.
  static const Duration approvalWindow = Duration(minutes: 15);

  Uri _base(Request r) => requestBase(r, hub.config.publicUrl);

  Response _json(Request r, Object body, {int status = 200}) => jsonResponse(body, status: status, headers: corsHeaders(r));

  /// `/.well-known/oauth-protected-resource`.
  Response resourceMetadata(Request r) => _json(r, {
        'resource': urlOf(_base(r), '/mcp'),
        'authorization_servers': [urlOf(_base(r), '')],
        'scopes_supported': _scopeNames,
        'bearer_methods_supported': ['header'],
        'resource_name': 'Den',
      });

  /// `/.well-known/oauth-authorization-server`.
  Response serverMetadata(Request r) {
    final base = _base(r);
    return _json(r, {
      'issuer': urlOf(base, ''),
      'authorization_endpoint': urlOf(base, '/oauth/authorize'),
      'token_endpoint': urlOf(base, '/oauth/token'),
      'registration_endpoint': urlOf(base, '/oauth/register'),
      'response_types_supported': ['code'],
      'grant_types_supported': ['authorization_code', 'refresh_token'],
      'code_challenge_methods_supported': ['S256'],
      'token_endpoint_auth_methods_supported': ['none', 'client_secret_post', 'client_secret_basic'],
      'scopes_supported': _scopeNames,
    });
  }

  static bool _redirectOk(String uri) {
    final u = Uri.tryParse(uri);
    if (u == null || !u.hasScheme || u.fragment.isNotEmpty) return false;
    if (u.scheme == 'https') return u.host.isNotEmpty;
    if (u.scheme == 'http') return const {'localhost', '127.0.0.1', '[::1]', '::1'}.contains(u.host);
    return !const {'javascript', 'data', 'file', 'vbscript', 'blob'}.contains(u.scheme);
  }

  Response _registerError(Request r, String error, String description) =>
      _json(r, {'error': error, 'error_description': description}, status: 400);

  /// `POST /oauth/register` (RFC 7591).
  Future<Response> register(Request r) async {
    if (!originAllowed(r, hub)) return _registerError(r, 'invalid_request', 'Origin not allowed');
    final Map<String, Object?> body;
    try {
      body = await readJsonObject(r, required: true);
    } on ApiError {
      return _registerError(r, 'invalid_client_metadata', 'The body must be a JSON object');
    }
    final uris = body['redirect_uris'];
    if (uris is! List || uris.isEmpty || uris.length > 10 || uris.any((u) => u is! String || !_redirectOk(u))) {
      return _registerError(r, 'invalid_redirect_uri', 'redirect_uris must list https (or loopback http) addresses');
    }
    final method = body['token_endpoint_auth_method'] as String? ?? 'client_secret_basic';
    if (!const {'none', 'client_secret_post', 'client_secret_basic'}.contains(method)) {
      return _registerError(r, 'invalid_client_metadata', 'Unsupported token_endpoint_auth_method');
    }
    if (store.clientCount >= 500) return _registerError(r, 'invalid_request', 'Too many registered clients');
    final rawName = body['client_name'];
    final name = rawName is String && rawName.trim().isNotEmpty
        ? (rawName.trim().length > 60 ? rawName.trim().substring(0, 60) : rawName.trim())
        : 'An AI assistant';
    final secret = method == 'none' ? null : store.secret();
    final client = OAuthClient(
      id: store.secret(16).substring(4),
      name: name,
      redirectUris: uris.cast<String>(),
      authMethod: method,
      secretHash: secret == null ? null : hashToken(secret),
      created: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    await store.addClient(client);
    return _json(r, {
      'client_id': client.id,
      'client_secret': ?secret,
      'client_id_issued_at': client.created,
      if (secret != null) 'client_secret_expires_at': 0,
      'client_name': client.name,
      'redirect_uris': client.redirectUris,
      'token_endpoint_auth_method': method,
      'grant_types': ['authorization_code', 'refresh_token'],
      'response_types': ['code'],
    }, status: 201);
  }

  Response _page(String body, {int status = 200}) => Response(
        status,
        body: body,
        headers: {'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store', 'x-frame-options': 'DENY'},
      );

  Response _fail(String message) => _page(oauthErrorPage(message, webDir: hub.config.webDir), status: 400);

  static String _withQuery(String uri, Map<String, String?> params) {
    final u = Uri.parse(uri);
    return u.replace(queryParameters: {...u.queryParameters, for (final e in params.entries) if (e.value != null) e.key: e.value!}).toString();
  }

  /// `GET /oauth/authorize`: starts a request (creating a pending connection) or, with
  /// `request=`, shows it again or finishes it.
  Future<Response> authorize(Request r) async {
    final q = r.url.queryParameters;
    final existing = q['request'];
    if (existing != null) {
      final pending = _requests[existing];
      if (pending == null) return _fail('This sign-in request has expired. Start again from the app.');
      final decided = await _decision(pending, _base(r));
      if (decided.redirect != null) return Response.found(decided.redirect!);
      return _page(authorizePage(client: pending.client.name, scopes: pending.scopes, requestId: existing, status: decided.message, webDir: hub.config.webDir));
    }
    if (!hub.ready) return _fail('This hub isn\'t part of a family yet.');
    final client = store.client(q['client_id'] ?? '');
    if (client == null) return _fail('The app asking to connect isn\'t registered with this hub.');
    final redirect = q['redirect_uri'] ?? (client.redirectUris.length == 1 ? client.redirectUris.single : null);
    if (redirect == null || !client.redirectUris.contains(redirect)) return _fail('The app gave an address this hub doesn\'t know.');
    String back(String error, String description) =>
        _withQuery(redirect, {'error': error, 'error_description': description, 'state': q['state'], 'iss': urlOf(_base(r), '')});
    if (q['response_type'] != 'code') return Response.found(back('unsupported_response_type', 'Only the code flow is supported'));
    final challenge = q['code_challenge'];
    if (challenge == null || challenge.length < 43 || challenge.length > 128 || q['code_challenge_method'] != 'S256') {
      return Response.found(back('invalid_request', 'PKCE with S256 is required'));
    }
    final asked = (q['scope'] ?? '').split(RegExp(r'[\s+]+')).where((s) => s.isNotEmpty).toSet();
    final scopes = asked.isEmpty
        ? _defaultScopes
        : {for (final s in Scope.values) if (asked.contains(s.name)) s};
    if (scopes.isEmpty) return Response.found(back('invalid_scope', 'Den\'s scopes are ${_scopeNames.join(' ')}'));
    final now = hub.now();
    _requests.removeWhere((_, p) => now - p.created > 2 * approvalWindow.inMilliseconds);
    if (_requests.length >= 50) return _fail('Too many apps are waiting for approval. Try again later.');
    final connection = await hub.gate.asHub(
      () => hub.den.requestOAuthConnection(label: client.name, client: client.id, scopes: scopes),
    );
    final id = store.secret(18).substring(4);
    final pending = _requests[id] = _Pending(client, redirect, challenge, q['state'],
        [for (final s in Scope.values) if (scopes.contains(s)) s.name], connection, now);
    hub.log.info('An app asked to connect; waiting for a parent to approve it');
    return _page(authorizePage(
      client: client.name,
      scopes: pending.scopes,
      requestId: id,
      status: 'Waiting for a parent to approve it.',
      webDir: hub.config.webDir,
    ));
  }

  Future<({String state, String message, String? redirect})> _decision(_Pending p, Uri base) =>
      hub.gate.asHub(() async {
        final issuer = urlOf(base, '');
        final c = hub.den.connections.firstWhereOrNull((x) => x.id == p.connection);
        if (c != null && c.status == ConnectionStatus.active) {
          if (p.code == null) {
            p.code = store.secret(24).substring(4);
            p.codeIssued = hub.now();
          }
          return (
            state: 'approved',
            message: 'Approved. Taking you back.',
            redirect: _withQuery(p.redirectUri, {'code': p.code, 'state': p.state, 'iss': issuer}),
          );
        }
        final expired = hub.now() - p.created > approvalWindow.inMilliseconds;
        if (c == null || c.status == ConnectionStatus.revoked || expired) {
          if (c != null && c.status == ConnectionStatus.pending) await hub.den.revokeConnection(c.id);
          return (
            state: 'declined',
            message: expired ? 'Nobody approved it in time.' : 'A parent said no.',
            redirect: _withQuery(p.redirectUri, {'error': 'access_denied', 'state': p.state, 'iss': issuer}),
          );
        }
        return (state: 'pending', message: 'Waiting for a parent to approve it.', redirect: null);
      });

  /// `GET /oauth/authorize/status?request=`: what the waiting page polls.
  Future<Response> status(Request r) async {
    final pending = _requests[r.url.queryParameters['request'] ?? ''];
    if (pending == null) return jsonResponse({'state': 'expired', 'message': 'This sign-in request has expired.'});
    final d = await _decision(pending, _base(r));
    return jsonResponse({'state': d.state, 'message': d.message, 'redirect': ?d.redirect});
  }

  Response _tokenError(Request r, String error, String description, {int status = 400}) => jsonResponse(
        {'error': error, 'error_description': description},
        status: status,
        headers: {...corsHeaders(r), 'pragma': 'no-cache'},
      );

  /// `POST /oauth/token`: authorization_code (with PKCE) and refresh_token (rotating).
  Future<Response> token(Request r) async {
    final text = utf8.decode(await readBodyBytes(r));
    final Map<String, String> form;
    try {
      form = (r.mimeType == 'application/json')
          ? (jsonDecode(text) as Map).map((k, v) => MapEntry('$k', '$v'))
          : Uri.splitQueryString(text);
    } on Object {
      return _tokenError(r, 'invalid_request', 'Malformed body');
    }
    var clientId = form['client_id'];
    var secret = form['client_secret'];
    final basic = r.headers['authorization'];
    if (basic != null && basic.toLowerCase().startsWith('basic ')) {
      try {
        final pair = utf8.decode(base64.decode(basic.substring(6).trim()));
        final colon = pair.indexOf(':');
        clientId = Uri.decodeQueryComponent(pair.substring(0, colon));
        secret = Uri.decodeQueryComponent(pair.substring(colon + 1));
      } on Object {
        return _tokenError(r, 'invalid_client', 'Malformed client credentials', status: 401);
      }
    }
    final client = clientId == null ? null : store.client(clientId);
    if (client == null) return _tokenError(r, 'invalid_client', 'Unknown client', status: 401);
    if (client.secretHash != null && (secret == null || hashToken(secret) != client.secretHash)) {
      return _tokenError(r, 'invalid_client', 'Wrong client secret', status: 401);
    }
    switch (form['grant_type']) {
      case 'authorization_code':
        return _exchangeCode(r, client, form);
      case 'refresh_token':
        return _refresh(r, client, form['refresh_token'] ?? '');
      default:
        return _tokenError(r, 'unsupported_grant_type', 'Use authorization_code or refresh_token');
    }
  }

  Future<Response> _exchangeCode(Request r, OAuthClient client, Map<String, String> form) async {
    final code = form['code'];
    final entry = _requests.entries.firstWhereOrNull((e) => e.value.code != null && e.value.code == code);
    final p = entry?.value;
    if (p == null || p.used || p.client.id != client.id) return _tokenError(r, 'invalid_grant', 'Unknown or used code');
    if (hub.now() - (p.codeIssued ?? 0) > const Duration(minutes: 10).inMilliseconds) {
      return _tokenError(r, 'invalid_grant', 'The code expired');
    }
    if (form['redirect_uri'] != null && form['redirect_uri'] != p.redirectUri) {
      return _tokenError(r, 'invalid_grant', 'redirect_uri doesn\'t match');
    }
    final verifier = form['code_verifier'] ?? '';
    final digest = b64e(const DartSha256().hashSync(utf8.encode(verifier)).bytes);
    if (verifier.length < 43 || digest != p.challenge) return _tokenError(r, 'invalid_grant', 'PKCE verification failed');
    p.used = true;
    _requests.remove(entry!.key);
    return _issue(r, client, p.connection);
  }

  Future<Response> _refresh(Request r, OAuthClient client, String token) async {
    final reused = store.usedBy(token);
    if (reused != null) {
      await store.revokeConnection(reused);
      await _setTokenHash(reused, hashToken(store.secret()));
      hub.log.warn('A used refresh token came back; ended that connection\'s tokens');
      return _tokenError(r, 'invalid_grant', 'That refresh token was already used');
    }
    final grant = store.refresh(token);
    if (grant == null || grant.client != client.id || grant.expires <= hub.now()) {
      return _tokenError(r, 'invalid_grant', 'Unknown or expired refresh token');
    }
    await store.retire(token, grant.connection);
    return _issue(r, client, grant.connection);
  }

  Future<bool> _setTokenHash(String connection, String hash, {int? expires}) => hub.gate.asHub(() async {
        final c = hub.den.connections.firstWhereOrNull((x) => x.id == connection);
        if (c == null || c.status != ConnectionStatus.active) return false;
        await hub.den.setConnectionToken(connection, hash, expires: expires);
        return true;
      });

  Future<Response> _issue(Request r, OAuthClient client, String connection) async {
    final access = store.secret();
    final lifetime = hub.config.accessTokenLifetime;
    final ok = await _setTokenHash(connection, hashToken(access), expires: hub.now() + lifetime.inMilliseconds);
    if (!ok) return _tokenError(r, 'invalid_grant', 'This app\'s access was turned off in the Den app');
    store.prune(hub.now());
    final refresh = await store.issueRefresh(
      RefreshGrant(connection, client.id, hub.now() + hub.config.refreshTokenLifetime.inMilliseconds),
    );
    final scopes = await hub.gate.asHub(() => hub.den.connections.firstWhereOrNull((x) => x.id == connection)?.scopes ?? const <Scope>{});
    return jsonResponse({
      'access_token': access,
      'token_type': 'Bearer',
      'expires_in': lifetime.inSeconds,
      'refresh_token': refresh,
      'scope': [for (final s in Scope.values) if (scopes.contains(s)) s.name].join(' '),
    }, headers: {...corsHeaders(r), 'pragma': 'no-cache'});
  }
}
