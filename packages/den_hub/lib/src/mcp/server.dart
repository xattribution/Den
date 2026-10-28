import 'dart:async';

import 'package:den_actions/den_actions.dart';
import 'package:den_capture/den_capture.dart' show CaptureReader;

import '../access.dart';
import '../config.dart';
import '../context.dart';
import '../log.dart';

/// MCP protocol versions this server speaks, newest first.
const List<String> mcpProtocolVersions = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];

/// JSON-RPC error codes.
abstract final class RpcError {
  /// Parse error.
  static const int parse = -32700;

  /// Invalid request.
  static const int invalidRequest = -32600;

  /// Method not found.
  static const int methodNotFound = -32601;

  /// Invalid params.
  static const int invalidParams = -32602;

  /// Internal error.
  static const int internal = -32603;
}

/// An MCP session (Streamable HTTP keeps these by `Mcp-Session-Id`).
class McpSession {
  /// Creates a session for [connectionId].
  McpSession(this.id, this.connectionId, this.protocolVersion);

  /// The session id.
  final String id;

  /// The connection that started it; other tokens can't use it.
  final String connectionId;

  /// The negotiated protocol version.
  final String protocolVersion;

  /// Last use (UTC ms).
  int lastUsed = DateTime.now().millisecondsSinceEpoch;
}

/// Den's MCP server: den_actions' specs over JSON-RPC 2.0, independent of transport. Every call
/// runs with the token's member acting, through one [ActionRunner]: a tool is listed and
/// callable only with the token's scope and when its member may use it (`can`), and the engine
/// still decides each change.
class McpServer {
  /// Creates the server over [hub]; [reader] supplies what reads text for `add_from_text`.
  McpServer(this.hub, {ActionRunner? runner, this.reader}) : runner = runner ?? standardRunner();

  /// Shared hub context.
  final HubContext hub;

  /// Runs the tools, and keeps their receipts and confirmation tokens.
  final ActionRunner runner;

  /// The family's capture reader, when the hub has one.
  final CaptureReader? Function()? reader;

  static const String _instructions =
      'Den is a family\'s shared calendar, chores with stars, lists and rewards. Start with get_today or '
      'list_members. People, lists, chores and events can be named instead of given by id; when a name '
      'is ambiguous the error lists the choices. Times without an offset are in the family\'s time zone. '
      'Every change returns a receipt; undo takes it back.';

  /// The version to answer an `initialize` asking for [requested].
  static String negotiate(Object? requested) =>
      requested is String && mcpProtocolVersions.contains(requested) ? requested : mcpProtocolVersions.first;

  /// The context one call from [access] runs in.
  ActionContext context(Access access) => ActionContext(
        hub.den,
        member: access.member,
        scopes: access.scopes,
        surface: Surface.mcp,
        caller: access.connection.id,
        readable: access.readable(hub.den),
        reader: reader?.call(),
        via: access.label,
      );

  /// The tools [access] may use, as `tools/list` shows them.
  List<ActionSpec> tools(Access access) => runner.available(context(access));

  /// Handles one JSON-RPC message from [access]; returns the response, or null for
  /// notifications and responses.
  Future<Map<String, Object?>?> handle(Object? message, Access access) async {
    if (message is! Map) return _error(null, RpcError.invalidRequest, 'Expected a JSON-RPC object');
    final id = message['id'];
    final method = message['method'];
    if (method is! String) {
      if (message.containsKey('result') || message.containsKey('error')) return null;
      return _error(id, RpcError.invalidRequest, 'Expected a method');
    }
    if (!message.containsKey('id')) return null;
    final params = message['params'];
    if (params != null && params is! Map) return _error(id, RpcError.invalidParams, 'params must be an object');
    final p = (params as Map?)?.cast<String, Object?>() ?? const {};
    try {
      switch (method) {
        case 'initialize':
          return _result(id, initializeResult(p['protocolVersion']));
        case 'ping':
          return _result(id, const {});
        case 'tools/list':
          return _result(id, {
            'tools': [for (final t in tools(access)) t.toolJson()],
          });
        case 'tools/call':
          return _result(id, await callTool(access, p['name'], p['arguments']));
        case 'resources/list':
          return _result(id, const {'resources': []});
        case 'prompts/list':
          return _result(id, const {'prompts': []});
        default:
          return _error(id, RpcError.methodNotFound, 'Den doesn\'t offer "$method"');
      }
    } on _RpcException catch (e) {
      return _error(id, e.code, e.message);
    } on Object catch (e, st) {
      hub.log.error('MCP $method failed: ${describeError(e, st)}');
      return _error(id, RpcError.internal, 'Something went wrong on the hub');
    }
  }

  /// The `initialize` result.
  Map<String, Object?> initializeResult(Object? requested) => {
        'protocolVersion': negotiate(requested),
        'capabilities': {
          'tools': {'listChanged': false},
        },
        'serverInfo': {'name': 'den-hub', 'title': 'Den', 'version': hubVersion},
        'instructions': _instructions,
      };

  /// Runs tool [name] with [arguments] for [access]. Old tool names still work.
  Future<Map<String, Object?>> callTool(Access access, Object? name, Object? arguments) async {
    final spec = name is String ? runner.spec(name) : null;
    if (name is! String || spec == null) throw _RpcException(RpcError.invalidParams, 'Den has no tool called "$name"');
    if (arguments != null && arguments is! Map) throw _RpcException(RpcError.invalidParams, 'arguments must be an object');
    final args = (arguments as Map?)?.cast<String, Object?>() ?? <String, Object?>{};
    final ActionResult result;
    if (!hub.ready) {
      result = runner.refusal(context(access), spec) ?? ActionResult.failed('This hub isn\'t part of a family yet.');
    } else {
      result = await hub.gate.run(access.member, access.label, () => runner.run(context(access), name, args));
    }
    return toolResult(result);
  }

  /// The `tools/call` result for [result]: one speakable text, and the same facts as JSON.
  static Map<String, Object?> toolResult(ActionResult result) => {
        'content': [
          {'type': 'text', 'text': result.text},
        ],
        'structuredContent': result.structured,
        'isError': result.isError,
      };

  static Map<String, Object?> _result(Object? id, Map<String, Object?> result) => {'jsonrpc': '2.0', 'id': id, 'result': result};

  static Map<String, Object?> _error(Object? id, int code, String message) => {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      };

  /// A JSON-RPC error response.
  static Map<String, Object?> errorResponse(Object? id, int code, String message) => _error(id, code, message);
}

class _RpcException implements Exception {
  _RpcException(this.code, this.message);
  final int code;
  final String message;
}
