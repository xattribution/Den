import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:den_core/den_core.dart';
import 'package:shelf/shelf.dart';

import '../access.dart';
import '../context.dart';
import '../edge.dart';
import '../feed.dart';
import '../http_util.dart';
import 'server.dart';
import 'subscriptions.dart';

/// Origins allowed to call `/mcp` and the OAuth endpoints from a browser by default.
const List<String> defaultAllowedOrigins = ['https://claude.ai', 'https://claude.com'];

/// Whether a browser [request]'s `Origin` may reach the hub. Requests without one (servers,
/// scripts) pass. A same-origin request passes only for hosts a DNS-rebinding page can't
/// claim: IP literals, `localhost`, `.local` and `.localhost` names, this machine's name, and
/// the configured public URL; other origins must be listed.
bool originAllowed(Request request, HubContext hub) {
  final origin = request.headers['origin'];
  if (origin == null || origin.isEmpty) return true;
  if (origin == 'null') return false;
  final allowed = {...defaultAllowedOrigins, ...hub.config.allowedOrigins};
  final public = hub.config.publicUrl;
  if (public != null) allowed.add(public.replace(path: '').origin);
  if (allowed.contains(origin)) return true;
  final Uri parsed;
  try {
    parsed = Uri.parse(origin);
  } on FormatException {
    return false;
  }
  final hosts = {
    request.headers['host'],
    if (viaTrustedProxy(request, hub.config.trustedProxies)) requestBase(request, null, trusted: hub.config.trustedProxies).authority,
  };
  if (!hosts.contains('${parsed.host}${parsed.hasPort ? ':${parsed.port}' : ''}')) return false;
  final name = parsed.host.toLowerCase();
  if (InternetAddress.tryParse(name.replaceAll(RegExp(r'^\[|\]$'), '')) != null) return true;
  return name == 'localhost' ||
      name.endsWith('.local') ||
      name.endsWith('.localhost') ||
      name == Platform.localHostname.toLowerCase();
}

/// CORS headers for an allowed browser origin.
Map<String, String> corsHeaders(Request request) {
  final origin = request.headers['origin'];
  if (origin == null) return const {};
  return {
    'access-control-allow-origin': origin,
    'access-control-allow-methods': 'GET, POST, DELETE, OPTIONS',
    'access-control-allow-headers':
        'authorization, content-type, accept, mcp-session-id, mcp-protocol-version, mcp-method, mcp-name, last-event-id',
    'access-control-expose-headers': 'mcp-session-id, www-authenticate',
    'access-control-max-age': '600',
    'vary': 'origin',
  };
}

/// The headers a Streamable HTTP client sends with [message] (2026-07-28): `MCP-Protocol-Version`
/// from its `_meta`, `Mcp-Method`, and `Mcp-Name` for the requests that name a tool, resource or
/// prompt, in the Base64 form when the name isn't plain ASCII. Empty for anything else.
Map<String, String> mcpRequestHeaders(Object? message) {
  if (message is! Map) return const {};
  final method = message['method'];
  final params = message['params'];
  final meta = params is Map ? params['_meta'] : null;
  final version = meta is Map ? meta[McpMeta.protocolVersion] : null;
  if (method is! String || version is! String) return const {};
  final name = params is Map ? params[method == 'resources/read' ? 'uri' : 'name'] : null;
  return {
    'mcp-protocol-version': version,
    'mcp-method': method,
    if (_named.contains(method) && name is String) 'mcp-name': encodeMcpHeader(name),
  };
}

const Set<String> _named = {'tools/call', 'resources/read', 'prompts/get'};

final RegExp _plainHeader = RegExp(r'^[\x21-\x7e]([\x20-\x7e]*[\x21-\x7e])?$');

/// [value] as a header carries it: as it is when it is plain ASCII without leading or trailing
/// space, else `=?base64?...?=`.
String encodeMcpHeader(String value) {
  final sentinel = value.startsWith('=?base64?') && value.endsWith('?=');
  if (_plainHeader.hasMatch(value) && !sentinel) return value;
  return '=?base64?${base64.encode(utf8.encode(value))}?=';
}

/// A header [value] decoded from its Base64 form when it has one; null when it is malformed.
String? decodeMcpHeader(String value) {
  if (!RegExp(r'^[\x20-\x7e\t]*$').hasMatch(value)) return null;
  if (value.startsWith('=?base64?') && value.endsWith('?=') && value.length >= 11) {
    try {
      return utf8.decode(base64.decode(value.substring(9, value.length - 2)));
    } on FormatException {
      return null;
    }
  }
  return value;
}

/// MCP Streamable HTTP at `/mcp`, for both eras, with bearer tokens (API tokens or OAuth access
/// tokens) and Origin checks:
///
/// - 2026-07-28: every request stands alone. Its `MCP-Protocol-Version`, `Mcp-Method` and
///   `Mcp-Name` headers must match its body (`400`, `-32020` otherwise), a method Den doesn't
///   have is `404`, a notification is `202`, and `subscriptions/listen` holds a stream open.
///   Session headers are ignored.
/// - Earlier versions: `initialize` opens a session, kept by `Mcp-Session-Id` and ended with
///   `DELETE`; JSON responses; batches.
class McpHttp {
  /// Creates the transport for [server]; [feed] tells subscriptions what changed.
  McpHttp(this.hub, this.server, ChangeFeed feed) : listen = McpListen(hub, server, feed);

  /// Shared hub context.
  final HubContext hub;

  /// The protocol handler.
  final McpServer server;

  /// Open `subscriptions/listen` streams.
  final McpListen listen;

  final Map<String, McpSession> _sessions = {};
  final Random _random = Random.secure();

  /// Most sessions kept.
  static const int maxSessions = 1000;

  /// Idle sessions are forgotten after this.
  static const Duration idle = Duration(hours: 24);

  Response _rpcError(int status, int code, String message, Request request, {Object? id, Map<String, String> headers = const {}}) =>
      jsonResponse(McpServer.errorResponse(id, code, message), status: status, headers: {...corsHeaders(request), ...headers});

  /// The `WWW-Authenticate` challenge pointing OAuth clients at the resource metadata, with the
  /// scopes Den asks for by default (an assistant gets everything but `admin` unless a parent
  /// chooses otherwise).
  String challenge(Request request, {bool invalid = false}) {
    final base = hub.base(request);
    return 'Bearer resource_metadata="${urlOf(base, '/.well-known/oauth-protected-resource/mcp')}", '
        'scope="${defaultScopeNames.join(' ')}"'
        '${invalid ? ', error="invalid_token"' : ''}';
  }

  /// The caller's access, or null without a working token. A token that doesn't work counts
  /// against the client's failed tries (`429` past them); no token at all is how OAuth clients
  /// discover the hub, so it doesn't.
  Access? _auth(Request request) {
    if (!hub.ready) throw ApiError.notReady();
    hub.checkFailures(request);
    final token = bearerToken(request.headers['authorization']);
    final access = hub.access(token);
    if (access == null && token != null) hub.failed(request);
    return access;
  }

  Response _unauthorized(Request request) {
    final hasToken = bearerToken(request.headers['authorization']) != null;
    return jsonResponse(
      {
        'error': {'code': 'unauthorized', 'message': 'This needs a token, or approval in the Den app.'},
      },
      status: 401,
      headers: {'www-authenticate': challenge(request, invalid: hasToken), ...corsHeaders(request)},
    );
  }

  /// `OPTIONS /mcp`.
  Response options(Request request) => originAllowed(request, hub)
      ? Response(204, headers: corsHeaders(request))
      : _rpcError(403, RpcError.invalidRequest, 'Origin not allowed', request);

  /// `GET /mcp`: no server-initiated stream (2026-07-28 uses `subscriptions/listen`).
  Response get(Request request) => Response(405, headers: {'allow': 'POST, DELETE', ...corsHeaders(request)});

  /// `DELETE /mcp`: ends a session (protocol versions before 2026-07-28).
  Response delete(Request request) {
    if (!originAllowed(request, hub)) return _rpcError(403, RpcError.invalidRequest, 'Origin not allowed', request);
    final access = _auth(request);
    if (access == null) return _unauthorized(request);
    final id = request.headers['mcp-session-id'];
    final session = id == null ? null : _sessions[id];
    if (session == null || session.connectionId != access.connection.id) {
      return _rpcError(404, RpcError.invalidRequest, 'Session not found', request);
    }
    _sessions.remove(id);
    return Response(204, headers: corsHeaders(request));
  }

  /// `POST /mcp`.
  Future<Response> post(Request request) async {
    if (!originAllowed(request, hub)) return _rpcError(403, RpcError.invalidRequest, 'Origin not allowed', request);
    final access = _auth(request);
    if (access == null) return _unauthorized(request);
    final Object? body;
    try {
      body = jsonDecode(utf8.decode(await readBodyBytes(request)));
    } on FormatException {
      return _rpcError(400, RpcError.parse, 'Parse error', request);
    }
    // After a restore the hub writes nothing until a device of the family has synced with it.
    if (hub.catchingUp && (body is List ? body.any(server.writes) : server.writes(body))) {
      final error = ApiError.catchingUp();
      return _rpcError(503, RpcError.internal, error.message, request,
          id: body is Map ? body['id'] : null, headers: error.headers);
    }
    if (body is Map && body['method'] != 'initialize' && _modern(body, request)) {
      return _modernPost(request, access, body.cast<String, Object?>());
    }
    if (body is List && body.any((m) => m is Map && _modern(m, request))) {
      return _rpcError(400, RpcError.invalidRequest, 'Send one message per request at 2026-07-28', request);
    }
    return _legacyPost(request, access, body);
  }

  /// Whether [message] is a 2026-07-28 request: its `_meta` names a version, or the
  /// `MCP-Protocol-Version` header names a version with no `initialize`.
  static bool _modern(Map<dynamic, dynamic> message, Request request) {
    final params = message['params'];
    final meta = params is Map ? params['_meta'] : null;
    if (meta is Map && meta.containsKey(McpMeta.protocolVersion)) return true;
    return modernProtocolVersions.contains(request.headers['mcp-protocol-version']);
  }

  Future<Response> _modernPost(Request request, Access access, Map<String, Object?> message) async {
    final id = message['id'];
    final method = message['method'];
    if (method is! String) return _rpcError(400, RpcError.invalidRequest, 'Expected a method', request, id: id);
    final rawParams = message['params'];
    if (rawParams != null && rawParams is! Map) return _rpcError(400, RpcError.invalidParams, 'params must be an object', request, id: id);
    final params = (rawParams as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
    // A notification is accepted and has no answer; 2026-07-28 defines none from the client
    // over HTTP, nor headers for one.
    if (!message.containsKey('id')) return Response(202, headers: corsHeaders(request));
    final meta = params['_meta'];
    final version = meta is Map ? meta[McpMeta.protocolVersion] : null;
    if (version == null) {
      return _rpcError(400, RpcError.invalidParams,
          'A 2026-07-28 request carries ${McpMeta.protocolVersion} and ${McpMeta.clientCapabilities} in params._meta', request,
          id: id);
    }
    String? mismatch;
    final header = request.headers['mcp-protocol-version'];
    final named = method == 'resources/read' ? params['uri'] : params['name'];
    final nameHeader = request.headers['mcp-name'];
    final decodedName = nameHeader == null ? null : decodeMcpHeader(nameHeader);
    if (header == null) {
      mismatch = 'The MCP-Protocol-Version header is missing';
    } else if (header != version) {
      mismatch = 'Header mismatch: MCP-Protocol-Version $header does not match $version in _meta';
    } else if (request.headers['mcp-method'] != method) {
      mismatch = request.headers['mcp-method'] == null
          ? 'The Mcp-Method header is missing'
          : 'Header mismatch: Mcp-Method does not match the method in the body';
    } else if (_named.contains(method)) {
      if (nameHeader == null) {
        mismatch = 'The Mcp-Name header is missing';
      } else if (decodedName == null) {
        mismatch = 'The Mcp-Name header has characters a header can\'t carry';
      } else if (named is! String || decodedName != named) {
        mismatch = 'Header mismatch: Mcp-Name does not match the body';
      }
    }
    if (mismatch != null) return _rpcError(400, RpcError.headerMismatch, mismatch, request, id: id);
    if (method == 'subscriptions/listen') {
      final (checked, problem) = McpServer.requestMeta(id, params);
      if (problem != null) return jsonResponse(problem.body, status: problem.status, headers: corsHeaders(request));
      if (checked != null) {
        return listen.open(request, access, bearerToken(request.headers['authorization'])!, id, params, corsHeaders(request));
      }
    }
    final reply = await server.respond(message, access);
    if (reply == null) return Response(202, headers: corsHeaders(request));
    return jsonResponse(reply.body, status: reply.status, headers: corsHeaders(request));
  }

  Future<Response> _legacyPost(Request request, Access access, Object? body) async {
    final version = request.headers['mcp-protocol-version'];
    if (version != null && !mcpProtocolVersions.contains(version)) {
      return _rpcError(400, RpcError.invalidRequest, 'Unsupported MCP-Protocol-Version: $version', request);
    }
    final messages = body is List ? body : [body];
    if (messages.isEmpty) return _rpcError(400, RpcError.invalidRequest, 'Empty batch', request);
    final initializing = messages.any((m) => m is Map && m['method'] == 'initialize');
    final headers = {...corsHeaders(request)};
    if (initializing) {
      if (messages.length != 1) return _rpcError(400, RpcError.invalidRequest, 'initialize must be sent alone', request);
      final m = messages.single as Map;
      final params = m['params'];
      final session = _open(access, McpServer.negotiate(params is Map ? params['protocolVersion'] : null));
      headers['mcp-session-id'] = session.id;
    } else {
      final id = request.headers['mcp-session-id'];
      if (id == null) {
        return _rpcError(400, -32000, 'Bad Request: an Mcp-Session-Id header is required', request);
      }
      final session = _sessions[id];
      if (session == null || session.connectionId != access.connection.id) {
        return _rpcError(404, -32001, 'Session not found', request);
      }
      session.lastUsed = DateTime.now().millisecondsSinceEpoch;
    }
    final responses = <Map<String, Object?>>[];
    for (final m in messages) {
      final r = await server.handle(m, access);
      if (r != null) responses.add(r);
    }
    if (responses.isEmpty) return Response(202, headers: headers);
    return jsonResponse(body is List ? responses : responses.single, headers: headers);
  }

  McpSession _open(Access access, String version) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _sessions.removeWhere((_, s) => now - s.lastUsed > idle.inMilliseconds);
    while (_sessions.length >= maxSessions) {
      _sessions.remove(_sessions.keys.first);
    }
    final id = b64e(List.generate(18, (_) => _random.nextInt(256)));
    return _sessions[id] = McpSession(id, access.connection.id, version);
  }

  /// Ends every subscription, telling each client it ended on purpose.
  Future<void> shutdown() => listen.shutdown();
}
