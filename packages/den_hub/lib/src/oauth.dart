import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:cryptography/dart.dart';
import 'package:den_core/den_core.dart';
import 'package:shelf/shelf.dart';

import 'access.dart' show defaultScopes;
import 'context.dart';
import 'device_auth.dart';
import 'edge.dart';
import 'http_util.dart';
import 'hub.dart' show HubService;
import 'mcp/http.dart' show corsHeaders, originAllowed;
import 'oauth_cimd.dart';
import 'oauth_page.dart';
import 'oauth_store.dart';
import 'setup.dart' show setupAlphabet;

const List<String> _scopeNames = ['read', 'calendar', 'chores', 'lists', 'points', 'admin'];

/// One sign-in request from an OAuth client, held by the hub (never in the family's log) until
/// a parent admits it.
class _Pending {
  _Pending({
    required this.ref,
    required this.code,
    required this.client,
    required this.host,
    required this.redirectUri,
    required this.challenge,
    required this.state,
    required this.scopes,
    required this.created,
    this.resource,
  });

  /// The id the parent's app knows it by (not the secret the waiting browser polls with).
  final String ref;

  /// Shown on the sign-in page and in the parent's app, so the parent approves the request
  /// they started.
  final String code;
  final OAuthClient client;

  /// Where the client's sign-in returns to: the one thing about the client it can't make up.
  final String host;
  final String redirectUri;
  final String challenge;
  final String? state;
  final List<String> scopes;
  final int created;

  /// The `resource` the client asked for (RFC 8707), if it named one.
  final String? resource;

  /// The pending `connection` written once a parent admitted the request.
  String? connection;
  bool declined = false;
  String? authCode;
  int? codeIssued;
  bool used = false;

  Set<Scope> get scopeSet => {for (final s in Scope.values) if (scopes.contains(s.name)) s};
}

/// OAuth 2.1 for remote MCP clients: metadata, three ways for a client to be known (a client ID
/// metadata document at an https `client_id`, which MCP prefers; dynamic registration; or a
/// client a parent created for an assistant that can do neither, such as Alexa+),
/// authorization approved by a parent in the Den app, and tokens with PKCE and refresh-token
/// rotation. Access tokens live only as hashes in the connection record. A `resource` a client
/// names (RFC 8707) must be this hub's MCP endpoint or the hub itself, and every answer to the
/// client's browser names the hub as its issuer (`iss`, RFC 9207).
///
/// A sign-in request needs no credentials, so the hub keeps it to itself: nothing reaches the
/// family's log until a parent's own device admits it (`GET` and `POST
/// /api/v1/connections/requests`), which writes a `pending` connection the parent then approves
/// as before. Requests expire on a timer after [approvalWindow], are limited per client and in
/// number, and show the parent the client's redirect host and a code to match, never its
/// self-chosen name alone.
class OAuthServer implements HubService {
  /// Creates the server for [hub]; [auth] checks the parent's signed requests.
  OAuthServer(this.hub, this.auth)
      : store = OAuthStore(hub.state),
        documents = ClientMetadataDocuments(hub.fetch, now: hub.now);

  /// Shared hub context.
  final HubContext hub;

  /// Checks requests signed by the family's devices.
  final DeviceAuth auth;

  /// Clients and refresh tokens.
  final OAuthStore store;

  /// Clients known by their metadata documents.
  final ClientMetadataDocuments documents;

  final Map<String, _Pending> _requests = {};
  final Random _random = Random.secure();
  Timer? _sweeper;

  /// How long a parent has to approve.
  static const Duration approvalWindow = Duration(minutes: 15);

  /// Most sign-in requests waiting at once.
  static const int maxWaiting = 20;

  /// Registered clients that never connected are forgotten after this.
  static const Duration unusedClients = Duration(days: 1);

  @override
  String get name => 'OAuth sign-in requests';

  @override
  Future<void> start() async {
    _sweeper = Timer.periodic(const Duration(minutes: 1), (_) => unawaited(sweep()));
    await sweep();
  }

  @override
  Future<void> stop() async {
    _sweeper?.cancel();
    _sweeper = null;
  }

  Uri _base(Request r) => hub.base(r);

  Response _json(Request r, Object body, {int status = 200}) => jsonResponse(body, status: status, headers: corsHeaders(r));

  bool _expired(_Pending p, int now) => now - p.created > approvalWindow.inMilliseconds;

  /// Closes requests nobody answered in [approvalWindow] (keeping them one more window so the
  /// waiting page hears why), turns down pending connections in the log that no open request
  /// needs (one a parent admitted and never approved, and the ones earlier hubs wrote for every
  /// request), and forgets registrations that never connected. Runs every minute; [now] is for
  /// tests. Writes nothing while the hub is catching up after a restore.
  Future<void> sweep({int? now}) async {
    final at = now ?? hub.now();
    _requests.removeWhere((_, p) => at - p.created > 2 * approvalWindow.inMilliseconds);
    for (final p in _requests.values) {
      if (_expired(p, at) && p.authCode == null) p.declined = true;
    }
    if (!hub.ready || hub.catchingUp) return;
    final live = {
      for (final p in _requests.values)
        if (p.connection != null && !p.declined && !_expired(p, at)) p.connection!,
    };
    final keep = <String>{
      for (final p in _requests.values) p.client.id,
      ...store.clientsWithTokens,
    };
    var turnedDown = 0;
    await hub.gate.asHub(() async {
      for (final c in hub.den.connections) {
        final client = c.client;
        if (client != null && c.status == ConnectionStatus.active) keep.add(client);
        if (c.kind != ConnectionKind.oauth || c.status != ConnectionStatus.pending || live.contains(c.id)) continue;
        if (at - c.rec.created.millis < approvalWindow.inMilliseconds) continue;
        await hub.den.revokeConnection(c.id);
        turnedDown++;
      }
    });
    if (turnedDown > 0) hub.log.info('Turned down $turnedDown app request${turnedDown == 1 ? '' : 's'} nobody approved in time');
    await store.pruneClients(before: at ~/ 1000 - unusedClients.inSeconds, keep: keep);
  }

  /// `/.well-known/oauth-protected-resource` and `/.well-known/oauth-protected-resource/mcp`.
  Response resourceMetadata(Request r) => _json(r, {
        'resource': urlOf(_base(r), '/mcp'),
        'authorization_servers': [urlOf(_base(r), '')],
        'scopes_supported': _scopeNames,
        'bearer_methods_supported': ['header'],
        'resource_name': 'Den',
      });

  /// Whether [resource], a client's RFC 8707 `resource`, names this hub: its MCP endpoint (what
  /// the resource metadata says, and what Claude sends) or the hub itself (what ChatGPT sends),
  /// compared without case in the scheme and host and without a trailing slash.
  bool resourceOk(Request r, String resource) {
    final canonical = _canonical(resource);
    if (canonical == null) return false;
    final base = _base(r);
    return canonical == _canonical(urlOf(base, '/mcp')) || canonical == _canonical(urlOf(base, ''));
  }

  static String? _canonical(String uri) {
    final u = Uri.tryParse(uri.trim());
    if (u == null || !u.hasScheme || u.host.isEmpty || u.hasFragment) return null;
    var path = u.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    final port = u.hasPort ? ':${u.port}' : '';
    return '${u.scheme.toLowerCase()}://${u.host.toLowerCase()}$port$path${u.hasQuery ? '?${u.query}' : ''}';
  }

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
      'client_id_metadata_document_supported': true,
      'authorization_response_iss_parameter_supported': true,
    });
  }

  /// Where a redirect URI returns to, as a parent should read it: its host, or its scheme for an
  /// app's own (`myapp:`).
  static String _hostOf(String uri) {
    final u = Uri.parse(uri);
    return u.host.isNotEmpty ? u.host : '${u.scheme}:';
  }

  Response _registerError(Request r, String error, String description, {int status = 400}) =>
      _json(r, {'error': error, 'error_description': description}, status: status);

  /// `POST /oauth/register` (RFC 7591).
  Future<Response> register(Request r) async {
    if (!originAllowed(r, hub)) return _registerError(r, 'invalid_request', 'Origin not allowed');
    if (!hub.limits.allow('oauth-register', hub.clientOf(r), Limits.oauthRegister)) {
      return _registerError(r, 'invalid_request', 'Too many registrations from here. Try again later.', status: 429);
    }
    final Map<String, Object?> body;
    try {
      body = await readJsonObject(r, required: true);
    } on ApiError {
      return _registerError(r, 'invalid_client_metadata', 'The body must be a JSON object');
    }
    final uris = body['redirect_uris'];
    if (uris is! List || uris.isEmpty || uris.length > 10 || uris.any((u) => u is! String || u.length > 2000 || !redirectAllowed(u))) {
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

  String _nonce() => base64Url.encode(List.generate(16, (_) => _random.nextInt(256))).replaceAll('=', '');

  Response _page(String Function(String nonce) build, {int status = 200}) {
    final nonce = _nonce();
    return Response(
      status,
      body: build(nonce),
      headers: {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
        'x-frame-options': 'DENY',
        'content-security-policy': oauthPagePolicy(nonce),
      },
    );
  }

  Response _fail(String message, {int status = 400}) =>
      _page((nonce) => oauthErrorPage(message, nonce: nonce, webDir: hub.config.webDir), status: status);

  Response _waiting(String id, _Pending p, String status) => _page((nonce) => authorizePage(
        client: p.client.name,
        host: p.host,
        code: p.code,
        scopes: p.scopes,
        requestId: id,
        status: status,
        nonce: nonce,
        webDir: hub.config.webDir,
        loopback: _loopback(p.redirectUri),
        describedAt: _documentHost(p.client),
      ));

  /// Whether [redirect] returns to the person's own computer, where any program could be
  /// listening: the page and the parent's app say so.
  static bool _loopback(String redirect) {
    final u = Uri.tryParse(redirect);
    return u != null && u.scheme == 'http' && loopbackHosts.contains(u.host);
  }

  /// For a client known by its metadata document, the host that published it.
  static String? _documentHost(OAuthClient client) =>
      client.kind == OAuthClientKind.document ? Uri.tryParse(client.id)?.host : null;

  /// The client [id] names: a metadata document's (fetched, or kept from before), or one the
  /// hub registered or a parent created. Null when there is none; throws
  /// [ClientMetadataProblem] for a document that can't be used.
  Future<OAuthClient?> _client(Request r, String id) async {
    if (!ClientMetadataDocuments.isDocumentUrl(id)) return store.client(id);
    if (!documents.isKept(id) && !hub.limits.allow('oauth-document', hub.clientOf(r), Limits.oauthRegister)) {
      throw const ClientMetadataProblem('Too many sign-in requests from here. Wait a few minutes, then start again.');
    }
    return documents.resolve(id);
  }

  static String _withQuery(String uri, Map<String, String?> params) {
    final u = Uri.parse(uri);
    return u.replace(queryParameters: {...u.queryParameters, for (final e in params.entries) if (e.value != null) e.key: e.value!}).toString();
  }

  String _userCode() {
    final c = List.generate(8, (_) => setupAlphabet[_random.nextInt(setupAlphabet.length)]).join();
    return '${c.substring(0, 4)}-${c.substring(4)}';
  }

  /// `GET /oauth/authorize`: starts a request (held by the hub until a parent admits it) or,
  /// with `request=`, shows it again or finishes it.
  Future<Response> authorize(Request r) async {
    final q = r.url.queryParameters;
    final existing = q['request'];
    if (existing != null) {
      final pending = _requests[existing];
      if (pending == null) return _fail('This sign-in request has expired. Start again from the app.');
      final decided = await _decision(pending, _base(r));
      if (decided.redirect != null) return Response.found(decided.redirect!);
      return _waiting(existing, pending, decided.message);
    }
    if (!hub.ready) return _fail('This hub isn\'t part of a family yet.');
    final OAuthClient? client;
    try {
      client = await _client(r, q['client_id'] ?? '');
    } on ClientMetadataProblem catch (e) {
      return _fail(e.message);
    }
    if (client == null) return _fail('The app asking to connect isn\'t registered with this hub.');
    final redirect = q['redirect_uri'] ?? (client.redirectUris.length == 1 ? client.redirectUris.single : null);
    if (redirect == null || !client.redirectUris.any((u) => redirectMatches(u, redirect))) {
      return _fail('The app gave an address this hub doesn\'t know.');
    }
    String back(String error, String description) =>
        _withQuery(redirect, {'error': error, 'error_description': description, 'state': q['state'], 'iss': urlOf(_base(r), '')});
    if (q['response_type'] != 'code') return Response.found(back('unsupported_response_type', 'Only the code flow is supported'));
    final resource = q['resource'];
    if (resource != null && !resourceOk(r, resource)) {
      return Response.found(back('invalid_target', 'This hub only issues tokens for ${urlOf(_base(r), '/mcp')}'));
    }
    final challenge = q['code_challenge'];
    if (challenge == null || challenge.length < 43 || challenge.length > 128 || q['code_challenge_method'] != 'S256') {
      return Response.found(back('invalid_request', 'PKCE with S256 is required'));
    }
    final asked = (q['scope'] ?? '').split(RegExp(r'[\s+]+')).where((s) => s.isNotEmpty).toSet();
    final scopes = asked.isEmpty
        ? defaultScopes
        : {for (final s in Scope.values) if (asked.contains(s.name)) s};
    if (scopes.isEmpty) return Response.found(back('invalid_scope', 'Den\'s scopes are ${_scopeNames.join(' ')}'));
    if (!hub.limits.allow('oauth-authorize', hub.clientOf(r), Limits.oauthAuthorize)) {
      return _fail('Too many sign-in requests from here. Wait a few minutes, then start again from the app.', status: 429);
    }
    final now = hub.now();
    _requests.removeWhere((_, p) => now - p.created > 2 * approvalWindow.inMilliseconds);
    final waiting = _requests.values.where((p) => !p.declined && p.authCode == null && !_expired(p, now)).length;
    if (waiting >= maxWaiting) return _fail('Too many apps are waiting for approval. Try again later.', status: 429);
    final id = store.secret(18).substring(4);
    final pending = _requests[id] = _Pending(
      ref: store.secret(12).substring(4),
      code: _userCode(),
      client: client,
      host: _hostOf(redirect),
      redirectUri: redirect,
      challenge: challenge,
      state: q['state'],
      scopes: [for (final s in Scope.values) if (scopes.contains(s)) s.name],
      created: now,
      resource: resource,
    );
    hub.log.info('An app asked to connect; a parent can approve it in the Den app');
    return _waiting(id, pending, 'Waiting for a parent to approve it.');
  }

  Future<({String state, String message, String? redirect})> _decision(_Pending p, Uri base) =>
      hub.gate.asHub(() async {
        final issuer = urlOf(base, '');
        final id = p.connection;
        final c = id == null ? null : hub.den.connections.firstWhereOrNull((x) => x.id == id);
        if (c != null && c.status == ConnectionStatus.active) {
          if (p.authCode == null) {
            p.authCode = store.secret(24).substring(4);
            p.codeIssued = hub.now();
          }
          return (
            state: 'approved',
            message: 'Approved. Taking you back.',
            redirect: _withQuery(p.redirectUri, {'code': p.authCode, 'state': p.state, 'iss': issuer}),
          );
        }
        final expired = _expired(p, hub.now());
        final gone = id != null && (c == null || c.status == ConnectionStatus.revoked);
        if (p.declined || gone || expired) {
          // Left for the sweep while the hub is catching up after a restore.
          if (c != null && c.status == ConnectionStatus.pending && !hub.catchingUp) await hub.den.revokeConnection(c.id);
          return (
            state: 'declined',
            message: expired && !p.declined && !gone ? 'Nobody approved it in time.' : 'A parent said no.',
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

  Map<String, Object?> _requestJson(_Pending p) => {
        'id': p.ref,
        'code': p.code,
        'client_name': p.client.name,
        'redirect_host': p.host,
        'redirect_loopback': _loopback(p.redirectUri),
        'client_kind': p.client.kind.name,
        'client_document_host': ?_documentHost(p.client),
        'scopes': p.scopes,
        'connection': p.connection,
        'requested': DateTime.fromMillisecondsSinceEpoch(p.created, isUtc: true).toIso8601String(),
        'requested_ms': p.created,
        'expires': DateTime.fromMillisecondsSinceEpoch(p.created + approvalWindow.inMilliseconds, isUtc: true).toIso8601String(),
        'expires_ms': p.created + approvalWindow.inMilliseconds,
      };

  /// `GET /api/v1/connections/requests`, signed by a parent's own device: the sign-in requests
  /// waiting for a parent, newest first.
  Future<Response> requests(Request r) async {
    await auth.parent(r, message: 'Only a parent\'s own phone can see apps asking to connect.');
    final now = hub.now();
    final open = _requests.values.where((p) => !p.declined && p.authCode == null && !_expired(p, now)).toList()
      ..sort((a, b) => b.created.compareTo(a.created));
    return jsonResponse({'requests': [for (final p in open) _requestJson(p)]});
  }

  /// `POST /api/v1/connections/requests/{id}` `{"decision": "admit" | "decline"}`, signed by a
  /// parent's own device. Admitting writes the `pending` connection (labelled with the client's
  /// name and redirect host) that the parent's app then approves with `approveConnection`, as
  /// for any connection; it answers `{"connection": id, "request": {...}}` and is idempotent.
  /// Declining sends the app back with `access_denied`.
  Future<Response> decide(Request r, String ref) async {
    final signed = await auth.withBody(r, limit: 4096);
    final c = DeviceAuth.parentOf(signed.check, message: 'Only a parent\'s own phone can let an app connect.');
    hub.requireCaughtUp();
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(signed.body));
    } on FormatException {
      throw ApiError.invalid('The body must be a JSON object.');
    }
    final decision = json is Map ? json['decision'] : null;
    if (decision != 'admit' && decision != 'decline') {
      throw ApiError.invalid('"decision" must be admit or decline.', field: 'decision');
    }
    final now = hub.now();
    final p = _requests.values.firstWhereOrNull((x) => x.ref == ref);
    if (p == null || _expired(p, now)) throw ApiError.notFound(type: 'request', message: 'That request has expired.');
    if (p.declined) throw ApiError(409, 'declined', 'A parent already said no to that request.');
    if (decision == 'decline') {
      p.declined = true;
      final id = p.connection;
      if (id != null) {
        await hub.gate.asHub(() async {
          final held = hub.den.connections.firstWhereOrNull((x) => x.id == id);
          if (held != null && held.status == ConnectionStatus.pending) await hub.den.revokeConnection(id);
        });
      }
      hub.log.info('${c.actor!.name} turned down an app asking to connect');
      return jsonResponse({'ok': true});
    }
    p.connection ??= await hub.gate.asHub(
      () => hub.den.requestOAuthConnection(label: _label(p), client: p.client.id, scopes: p.scopeSet),
    );
    hub.log.info('${c.actor!.name} is approving an app asking to connect');
    return jsonResponse({'connection': p.connection, 'request': _requestJson(p)});
  }

  /// The connection's label: the client's name and, unless the name already says it, where it
  /// signs in, so the app list never shows a made-up name alone.
  static String _label(_Pending p) {
    final name = p.client.name;
    final label = name.toLowerCase().contains(p.host.toLowerCase()) ? name : '$name (${p.host})';
    return label.length > 120 ? label.substring(0, 120) : label;
  }

  Map<String, Object?> _staticJson(OAuthClient c) => {
        'client_id': c.id,
        'name': c.name,
        'redirect_uris': c.redirectUris,
        'created': DateTime.fromMillisecondsSinceEpoch(c.created * 1000, isUtc: true).toIso8601String(),
      };

  /// `GET /api/v1/connections/clients`, signed by a parent's own device: the apps parents set
  /// up to sign in with (never their secrets).
  Future<Response> clients(Request r) async {
    await auth.parent(r, message: 'Only a parent\'s own phone can see the apps parents set up.');
    return jsonResponse({'clients': [for (final c in store.staticClients) _staticJson(c)]});
  }

  /// `POST /api/v1/connections/clients` `{"name": "Alexa", "redirect_uris": [...]}`, signed by a
  /// parent's own device: sets up a client for an assistant that can't register itself or
  /// publish a metadata document (Alexa+ takes a client id and secret). It answers the
  /// `client_secret`, shown this once, with the addresses to enter beside it. Signing in with it
  /// still needs a parent's approval in the Den app, as for any app.
  Future<Response> createClient(Request r) async {
    final signed = await auth.withBody(r, limit: 16 * 1024);
    final c = DeviceAuth.parentOf(signed.check, message: 'Only a parent\'s own phone can set up an app.');
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(signed.body));
    } on FormatException {
      throw ApiError.invalid('The body must be a JSON object.');
    }
    if (json is! Map) throw ApiError.invalid('The body must be a JSON object.');
    final name = json['name'];
    if (name is! String || name.trim().isEmpty || name.trim().length > 60) {
      throw ApiError.invalid('"name" must be the app\'s name, up to 60 characters.', field: 'name');
    }
    final uris = json['redirect_uris'];
    if (uris is! List || uris.isEmpty || uris.length > 10 || uris.any((u) => u is! String || u.length > 2000 || !redirectAllowed(u))) {
      throw ApiError.invalid('"redirect_uris" must list the https addresses the app gave you.', field: 'redirect_uris');
    }
    if (store.staticClients.length >= maxStaticClients) {
      throw ApiError(409, 'too_many', 'This hub already has $maxStaticClients apps set up by parents. Remove one first.');
    }
    final secret = store.secret();
    final client = OAuthClient(
      id: store.secret(16).substring(4),
      name: name.trim(),
      redirectUris: uris.cast<String>(),
      authMethod: 'client_secret_basic',
      secretHash: hashToken(secret),
      created: hub.now() ~/ 1000,
      kind: OAuthClientKind.static,
    );
    await store.addClient(client);
    hub.log.info('${c.actor!.name} set up an app to sign in with');
    final base = _base(r);
    return jsonResponse({
      ..._staticJson(client),
      'client_secret': secret,
      'authorization_endpoint': urlOf(base, '/oauth/authorize'),
      'token_endpoint': urlOf(base, '/oauth/token'),
      'token_endpoint_auth_methods': ['client_secret_basic', 'client_secret_post'],
      'resource': urlOf(base, '/mcp'),
      'scopes': [for (final s in Scope.values) if (defaultScopes.contains(s)) s.name],
    }, status: 201);
  }

  /// `DELETE /api/v1/connections/clients/{id}`, signed by a parent's own device: removes an app
  /// parents set up. Its refresh tokens stop working and the hub ends the connections it made.
  Future<Response> deleteClient(Request r, String id) async {
    final c = await auth.parent(r, message: 'Only a parent\'s own phone can remove an app.');
    hub.requireCaughtUp();
    final client = store.client(id);
    if (client == null || client.kind != OAuthClientKind.static) {
      throw ApiError.notFound(type: 'client', message: 'There\'s no app with that id.');
    }
    await store.removeClient(id);
    final ended = await hub.gate.asHub(() async {
      var n = 0;
      for (final x in hub.den.connections) {
        if (x.client != id || x.status == ConnectionStatus.revoked) continue;
        await hub.den.revokeConnection(x.id);
        n++;
      }
      return n;
    });
    hub.log.info('${c.actor!.name} removed an app parents set up');
    return jsonResponse({'ok': true, 'connections_ended': ended});
  }

  /// Most apps parents set up.
  static const int maxStaticClients = 20;

  Response _tokenError(Request r, String error, String description, {int status = 400}) => jsonResponse(
        {'error': error, 'error_description': description},
        status: status,
        headers: {...corsHeaders(r), 'pragma': 'no-cache'},
      );

  Response _badClient(Request r, String error, String description, {int status = 400}) {
    hub.failed(r);
    return _tokenError(r, error, description, status: status);
  }

  /// `POST /oauth/token`: authorization_code (with PKCE) and refresh_token (rotating). While the
  /// hub catches up after a restore it issues nothing: `503` with `Retry-After`, which leaves
  /// the code or refresh token the client holds unused.
  Future<Response> token(Request r) async {
    final key = hub.clientOf(r);
    if (hub.limits.exhausted('failures', key, Limits.failures) || !hub.limits.allow('oauth-token', key, Limits.oauthToken)) {
      return _tokenError(r, 'invalid_request', 'Too many requests from here. Try again later.', status: 429);
    }
    if (hub.catchingUp) {
      return jsonResponse(
        {'error': 'temporarily_unavailable', 'error_description': ApiError.catchingUp().message},
        status: 503,
        headers: {...corsHeaders(r), 'pragma': 'no-cache', 'retry-after': '${ApiError.catchUpRetry}'},
      );
    }
    final text = utf8.decode(await readBodyBytes(r), allowMalformed: true);
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
        return _badClient(r, 'invalid_client', 'Malformed client credentials', status: 401);
      }
    }
    // A client known by its metadata document is public: the code or refresh token it brings
    // must have been issued to that same address, which the checks below hold it to.
    final client = clientId == null
        ? null
        : ClientMetadataDocuments.isDocumentUrl(clientId)
            ? OAuthClient(id: clientId, name: '', redirectUris: const [], authMethod: 'none', created: 0, kind: OAuthClientKind.document)
            : store.client(clientId);
    if (client == null) return _badClient(r, 'invalid_client', 'Unknown client', status: 401);
    if (client.secretHash != null && (secret == null || hashToken(secret) != client.secretHash)) {
      return _badClient(r, 'invalid_client', 'Wrong client secret', status: 401);
    }
    final resource = form['resource'];
    if (resource != null && !resourceOk(r, resource)) {
      return _tokenError(r, 'invalid_target', 'This hub only issues tokens for ${urlOf(_base(r), '/mcp')}');
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
    final entry = _requests.entries.firstWhereOrNull((e) => e.value.authCode != null && e.value.authCode == code);
    final p = entry?.value;
    if (p == null || p.used || p.client.id != client.id) return _badClient(r, 'invalid_grant', 'Unknown or used code');
    if (hub.now() - (p.codeIssued ?? 0) > const Duration(minutes: 10).inMilliseconds) {
      return _tokenError(r, 'invalid_grant', 'The code expired');
    }
    if (form['redirect_uri'] != null && form['redirect_uri'] != p.redirectUri) {
      return _badClient(r, 'invalid_grant', 'redirect_uri doesn\'t match');
    }
    final resource = form['resource'];
    if (resource != null && p.resource != null && _canonical(resource) != _canonical(p.resource!)) {
      return _tokenError(r, 'invalid_target', 'resource doesn\'t match the one the app asked for');
    }
    final verifier = form['code_verifier'] ?? '';
    final digest = b64e(const DartSha256().hashSync(utf8.encode(verifier)).bytes);
    if (verifier.length < 43 || digest != p.challenge) return _badClient(r, 'invalid_grant', 'PKCE verification failed');
    p.used = true;
    _requests.remove(entry!.key);
    return _issue(r, client, p.connection!);
  }

  Future<Response> _refresh(Request r, OAuthClient client, String token) async {
    final reused = store.usedBy(token);
    if (reused != null) {
      await store.revokeConnection(reused);
      await _setTokenHash(reused, hashToken(store.secret()));
      hub.log.warn('A used refresh token came back; ended that connection\'s tokens');
      return _badClient(r, 'invalid_grant', 'That refresh token was already used');
    }
    final grant = store.refresh(token);
    if (grant == null || grant.client != client.id || grant.expires <= hub.now()) {
      return _badClient(r, 'invalid_grant', 'Unknown or expired refresh token');
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
