import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:den_core/den_core.dart';
import 'package:shelf/shelf.dart';

import '../access.dart';
import '../context.dart';
import '../http_util.dart';
import 'server.dart';

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
  final host = request.headers['host'];
  if (host == null || '${parsed.host}${parsed.hasPort ? ':${parsed.port}' : ''}' != host) return false;
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
    'access-control-allow-headers': 'authorization, content-type, mcp-session-id, mcp-protocol-version, last-event-id',
    'access-control-expose-headers': 'mcp-session-id, www-authenticate',
    'access-control-max-age': '600',
    'vary': 'origin',
  };
}

/// MCP Streamable HTTP at `/mcp`: JSON responses, sessions by `Mcp-Session-Id`, bearer tokens
/// (API tokens or OAuth access tokens), Origin checks.
class McpHttp {
  /// Creates the transport for [server].
  McpHttp(this.hub, this.server);

  /// Shared hub context.
  final HubContext hub;

  /// The protocol handler.
  final McpServer server;

  final Map<String, McpSession> _sessions = {};
  final Random _random = Random.secure();

  /// Most sessions kept.
  static const int maxSessions = 1000;

  /// Idle sessions are forgotten after this.
  static const Duration idle = Duration(hours: 24);

  Response _rpcError(int status, int code, String message, Request request, {Map<String, String> headers = const {}}) =>
      jsonResponse(McpServer.errorResponse(null, code, message), status: status, headers: {...corsHeaders(request), ...headers});

  /// The `WWW-Authenticate` challenge pointing OAuth clients at the resource metadata.
  String challenge(Request request, {bool invalid = false}) {
    final base = requestBase(request, hub.config.publicUrl);
    return 'Bearer resource_metadata="${urlOf(base, '/.well-known/oauth-protected-resource')}"'
        '${invalid ? ', error="invalid_token"' : ''}';
  }

  Access? _auth(Request request) {
    if (!hub.ready) throw ApiError.notReady();
    return accessForToken(hub.den, bearerToken(request.headers['authorization']));
  }

  /// `OPTIONS /mcp`.
  Response options(Request request) => originAllowed(request, hub)
      ? Response(204, headers: corsHeaders(request))
      : _rpcError(403, RpcError.invalidRequest, 'Origin not allowed', request);

  /// `GET /mcp`: no server-initiated stream.
  Response get(Request request) => Response(405, headers: {'allow': 'POST, DELETE', ...corsHeaders(request)});

  /// `DELETE /mcp`: ends a session.
  Response delete(Request request) {
    if (!originAllowed(request, hub)) return _rpcError(403, RpcError.invalidRequest, 'Origin not allowed', request);
    final access = _auth(request);
    if (access == null) return Response(401, headers: {'www-authenticate': challenge(request), ...corsHeaders(request)});
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
    if (access == null) {
      final hasToken = bearerToken(request.headers['authorization']) != null;
      return jsonResponse(
        {
          'error': {'code': 'unauthorized', 'message': 'This needs a token, or approval in the Den app.'},
        },
        status: 401,
        headers: {'www-authenticate': challenge(request, invalid: hasToken), ...corsHeaders(request)},
      );
    }
    final version = request.headers['mcp-protocol-version'];
    if (version != null && !mcpProtocolVersions.contains(version)) {
      return _rpcError(400, RpcError.invalidRequest, 'Unsupported MCP-Protocol-Version: $version', request);
    }
    final Object? body;
    try {
      body = jsonDecode(utf8.decode(await readBodyBytes(request)));
    } on FormatException {
      return _rpcError(400, RpcError.parse, 'Parse error', request);
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
}
