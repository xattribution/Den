import 'dart:convert';

import 'package:den_actions/den_actions.dart';
import 'package:den_capture/den_capture.dart' show CaptureReader;

import '../access.dart';
import '../config.dart';
import '../context.dart';
import '../http_util.dart' show ApiError;
import '../log.dart';
import 'prompts.dart';
import 'resources.dart';

/// MCP protocol versions served without a session: every request names its version and its
/// client's capabilities in `params._meta`.
const List<String> modernProtocolVersions = ['2026-07-28'];

/// MCP protocol versions that open a session with `initialize`.
const List<String> legacyProtocolVersions = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];

/// Every MCP protocol version this server speaks, newest first.
const List<String> mcpProtocolVersions = [...modernProtocolVersions, ...legacyProtocolVersions];

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

  /// Resource not found, before 2026-07-28 (which uses [invalidParams]).
  static const int resourceNotFound = -32002;

  /// HTTP headers don't match the body (2026-07-28).
  static const int headerMismatch = -32020;

  /// The request needs a client capability the client didn't declare (2026-07-28).
  static const int missingCapability = -32021;

  /// The server doesn't speak the requested protocol version (2026-07-28).
  static const int unsupportedVersion = -32022;
}

/// The `_meta` keys MCP reserves.
abstract final class McpMeta {
  /// The request's protocol version.
  static const String protocolVersion = 'io.modelcontextprotocol/protocolVersion';

  /// The client's name and version.
  static const String clientInfo = 'io.modelcontextprotocol/clientInfo';

  /// What the client can do, for this request.
  static const String clientCapabilities = 'io.modelcontextprotocol/clientCapabilities';

  /// The server's name and version, on results.
  static const String serverInfo = 'io.modelcontextprotocol/serverInfo';

  /// The `subscriptions/listen` request a notification belongs to.
  static const String subscriptionId = 'io.modelcontextprotocol/subscriptionId';
}

/// An MCP session (Streamable HTTP keeps these by `Mcp-Session-Id`, for protocol versions
/// before 2026-07-28).
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

/// What a 2026-07-28 request says about itself in `params._meta`.
class McpRequestMeta {
  /// Metadata naming [version] and [capabilities].
  const McpRequestMeta(this.version, this.capabilities);

  /// The protocol version of this request.
  final String version;

  /// What the client can do for this request.
  final Map<String, Object?> capabilities;

  /// Whether the client can ask its person to fill a form (elicitation in form mode).
  bool get elicitsForms {
    final e = capabilities['elicitation'];
    return e is Map && (e.isEmpty || e.containsKey('form'));
  }
}

/// One answer: the JSON-RPC response, the HTTP status Streamable HTTP sends it with, and the
/// notifications that go before it on the same stream.
class McpReply {
  /// A reply carrying [body].
  const McpReply(this.body, {this.status = 200, this.notifications = const []});

  /// The JSON-RPC response.
  final Map<String, Object?> body;

  /// The HTTP status for it.
  final int status;

  /// Notifications sent first (on a stream).
  final List<Map<String, Object?>> notifications;
}

/// Den's MCP server: den_actions' specs over JSON-RPC 2.0, independent of transport, with the
/// family's day, lists and people as resources and a few ready-made prompts. Every call runs
/// with the token's member acting, through one [ActionRunner]: a tool is listed and callable
/// only with the token's scope and when its member may use it (`can`), and the engine still
/// decides each change.
///
/// It speaks both eras of MCP. A request whose `params._meta` names its protocol version
/// (2026-07-28) is served on its own, with no session; `initialize` starts a session for the
/// earlier versions, which the transport keeps.
class McpServer {
  /// Creates the server over [hub]; [reader] supplies what reads text for `add_from_text`.
  McpServer(this.hub, {ActionRunner? runner, this.reader}) : runner = runner ?? standardRunner();

  /// Shared hub context.
  final HubContext hub;

  /// Runs the tools, and keeps their receipts and confirmation tokens.
  final ActionRunner runner;

  /// The family's capture reader, when the hub has one.
  final CaptureReader? Function()? reader;

  /// How long a client may keep `tools/list`, `prompts/list` and `resources/list`.
  static const int listTtlMs = 5 * 60 * 1000;

  /// How long a client may keep `server/discover`.
  static const int discoverTtlMs = 60 * 60 * 1000;

  static const String _instructions =
      'Den is a family\'s shared calendar, chores with stars, lists and rewards. Start with get_overview or '
      'get_family, or read the den://today resource. People, lists, chores and events can be named instead of '
      'given by id; when a name is ambiguous the error lists the choices. Times without an offset are in the '
      'family\'s time zone. Every change returns a receipt; undo takes it back. Some changes need the person to '
      'say yes first: ask them, then call the tool again as it says.';

  /// The server's name and version, as results carry them.
  static const Map<String, Object?> serverInfo = {'name': 'den-hub', 'title': 'Den', 'version': hubVersion};

  /// The version to answer an `initialize` asking for [requested]: the same one when Den
  /// speaks it, else the newest version with sessions.
  static String negotiate(Object? requested) =>
      requested is String && legacyProtocolVersions.contains(requested) ? requested : legacyProtocolVersions.first;

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
        viewZone: access.timezone,
      );

  /// The tools [access] may use, as `tools/list` shows them.
  List<ActionSpec> tools(Access access) => runner.available(context(access));

  Set<String> _toolNames(Access access) => {for (final t in tools(access)) t.mcpName};

  /// The resources [access] may read.
  List<McpResource> resources(Access access) {
    final names = _toolNames(access);
    return [for (final r in denResources) if (names.contains(r.action)) r];
  }

  /// The resource templates [access] may read.
  List<McpResourceTemplate> resourceTemplates(Access access) {
    final names = _toolNames(access);
    return [for (final t in denResourceTemplates) if (names.contains(t.action)) t];
  }

  /// The prompts [access] may use.
  List<McpPrompt> prompts(Access access) {
    final names = _toolNames(access);
    return [for (final p in denPrompts) if (p.needs.every(names.contains)) p];
  }

  /// Whether [access] may read the resource at [uri].
  bool canRead(Access access, String uri) {
    final target = resourceAction(uri);
    return target != null && _toolNames(access).contains(target.action);
  }

  /// The metadata of a 2026-07-28 request, null for a request from an earlier version (which
  /// carries none), or the error reply for metadata that is malformed or names a version Den
  /// doesn't speak.
  static (McpRequestMeta?, McpReply?) requestMeta(Object? id, Map<String, Object?> params) {
    final meta = params['_meta'];
    if (meta is! Map || !meta.containsKey(McpMeta.protocolVersion)) return (null, null);
    final version = meta[McpMeta.protocolVersion];
    if (version is! String || version.isEmpty) {
      return (null, _fail(id, RpcError.invalidParams, '${McpMeta.protocolVersion} must be a version string', 400));
    }
    if (!mcpProtocolVersions.contains(version)) {
      return (
        null,
        McpReply(
          _errorBody(id, RpcError.unsupportedVersion, 'Unsupported protocol version',
              data: {'supported': mcpProtocolVersions, 'requested': version}),
          status: 400,
        ),
      );
    }
    final capabilities = meta[McpMeta.clientCapabilities];
    if (capabilities is! Map) {
      return (null, _fail(id, RpcError.invalidParams, '${McpMeta.clientCapabilities} is required in _meta', 400));
    }
    return (McpRequestMeta(version, capabilities.cast<String, Object?>()), null);
  }

  /// Handles one JSON-RPC message from [access]; returns the response, or null for
  /// notifications and responses.
  Future<Map<String, Object?>?> handle(Object? message, Access access) async => (await respond(message, access))?.body;

  /// [handle], with the HTTP status for the response and any notifications that go first.
  Future<McpReply?> respond(Object? message, Access access) async {
    if (message is! Map) return _fail(null, RpcError.invalidRequest, 'Expected a JSON-RPC object', 400);
    final id = message['id'];
    final method = message['method'];
    if (method is! String) {
      if (message.containsKey('result') || message.containsKey('error')) return null;
      return _fail(id, RpcError.invalidRequest, 'Expected a method', 400);
    }
    final params = message['params'];
    if (params != null && params is! Map) {
      return message.containsKey('id') ? _fail(id, RpcError.invalidParams, 'params must be an object', 400) : null;
    }
    final p = (params as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
    final checked = method == 'initialize' ? null : requestMeta(id, p);
    final meta = checked?.$1;
    final problem = checked?.$2;
    if (!message.containsKey('id')) return null;
    if (problem != null) return problem;
    if (method == 'subscriptions/listen' && meta != null) {
      // Over stdio, where requests are handled one at a time, a subscription is acknowledged
      // with nothing to send and ended at once; Streamable HTTP keeps it open ([McpListen]).
      return McpReply(
        _resultBody(id, _modern({
          '_meta': {McpMeta.subscriptionId: id},
        })),
        notifications: [acknowledgement(id, const {})],
      );
    }
    try {
      final result = await _dispatch(method, p, access, meta);
      if (result == null) {
        return _fail(id, RpcError.methodNotFound, 'Den doesn\'t offer "$method"', meta == null ? 200 : 404);
      }
      return McpReply(_resultBody(id, meta == null ? result : _modern(result)));
    } on McpError catch (e) {
      final code = meta == null && e.code == RpcError.invalidParams && e.resource ? RpcError.resourceNotFound : e.code;
      return _fail(id, code, e.message, 200);
    } on Object catch (e, st) {
      hub.log.error('MCP $method failed: ${describeError(e, st)}');
      return _fail(id, RpcError.internal, 'Something went wrong on the hub', 200);
    }
  }

  /// [result] as 2026-07-28 shapes it: a `resultType`, and the server's name in `_meta`.
  static Map<String, Object?> _modern(Map<String, Object?> result) => {
        'resultType': 'complete',
        ...result,
        '_meta': {...?(result['_meta'] as Map?)?.cast<String, Object?>(), McpMeta.serverInfo: serverInfo},
      };

  Future<Map<String, Object?>?> _dispatch(String method, Map<String, Object?> p, Access access, McpRequestMeta? meta) async {
    // 2026-07-28 results say how long a client may keep them, and whether they are the same for
    // everyone ("public") or for this token only ("private").
    Map<String, Object?> cached(Map<String, Object?> body, int ttl, String scope) =>
        meta != null ? {...body, 'ttlMs': ttl, 'cacheScope': scope} : body;
    switch (method) {
      case 'initialize':
        return initializeResult(p['protocolVersion']);
      case 'server/discover':
        return cached(discoverResult(), discoverTtlMs, 'public');
      case 'ping':
        return const {};
      case 'tools/list':
        return cached({
          'tools': [for (final t in tools(access)) t.toolJson()],
        }, listTtlMs, 'private');
      case 'tools/call':
        return callTool(access, p['name'], p['arguments'], meta: meta, params: p);
      case 'resources/list':
        return cached({
          'resources': [for (final r in resources(access)) r.toJson()],
        }, listTtlMs, 'private');
      case 'resources/templates/list':
        return cached({
          'resourceTemplates': [for (final t in resourceTemplates(access)) t.toJson()],
        }, listTtlMs, 'private');
      case 'resources/read':
        return cached(await readResource(access, p['uri']), 0, 'private');
      case 'prompts/list':
        return cached({
          'prompts': [for (final x in prompts(access)) x.toJson()],
        }, listTtlMs, 'private');
      case 'prompts/get':
        return getPrompt(access, p['name'], p['arguments']);
      default:
        return null;
    }
  }

  /// The `initialize` result (protocol versions before 2026-07-28).
  Map<String, Object?> initializeResult(Object? requested) => {
        'protocolVersion': negotiate(requested),
        'capabilities': {
          'tools': {'listChanged': false},
          'resources': {'subscribe': false, 'listChanged': false},
          'prompts': {'listChanged': false},
        },
        'serverInfo': serverInfo,
        'instructions': _instructions,
      };

  /// The `server/discover` result (2026-07-28).
  Map<String, Object?> discoverResult() => {
        'supportedVersions': mcpProtocolVersions,
        'capabilities': {
          'tools': <String, Object?>{},
          'resources': {'subscribe': true},
          'prompts': <String, Object?>{},
        },
        'instructions': _instructions,
      };

  /// The `notifications/subscriptions/acknowledged` for subscription [id], honoring [filter].
  static Map<String, Object?> acknowledgement(Object? id, Map<String, Object?> filter) => {
        'jsonrpc': '2.0',
        'method': 'notifications/subscriptions/acknowledged',
        'params': {
          '_meta': {McpMeta.subscriptionId: id},
          'notifications': filter,
        },
      };

  /// Whether [message] is a `tools/call` that would write (a tool that changes something, not
  /// asked for a preview): what waits while the hub catches up after a restore.
  bool writes(Object? message) {
    if (message is! Map || message['method'] != 'tools/call') return false;
    final params = message['params'];
    if (params is! Map) return false;
    final name = params['name'];
    final spec = name is String ? runner.spec(name) : null;
    if (spec == null || spec.readOnly) return false;
    final args = params['arguments'];
    return !(args is Map && args['preview'] == true);
  }

  /// Runs tool [name] with [arguments] for [access]. Old tool names still work.
  ///
  /// A change that needs a yes first (Den's `confirm` two-step) asks through the client when the
  /// 2026-07-28 request [meta] says it can show a form: an `input_required` result with one
  /// yes-or-no question, whose `requestState` is the runner's confirmation token (kept on the
  /// hub, bound to this connection, this tool and this exact input, good for ten minutes and
  /// once). The client's retry with the person's answer runs it, or says nothing changed.
  /// Other clients get the question as the tool's result and call again with `confirm`.
  Future<Map<String, Object?>> callTool(Access access, Object? name, Object? arguments,
      {McpRequestMeta? meta, Map<String, Object?> params = const {}}) async {
    final spec = name is String ? runner.spec(name) : null;
    if (name is! String || spec == null) throw McpError(RpcError.invalidParams, 'Den has no tool called "$name"');
    if (arguments != null && arguments is! Map) throw McpError(RpcError.invalidParams, 'arguments must be an object');
    final args = Map<String, Object?>.of((arguments as Map?)?.cast<String, Object?>() ?? const {});
    final asks = meta != null && meta.elicitsForms;
    if (asks) {
      final state = params['requestState'];
      if (state is String && state.isNotEmpty) {
        final answer = _answer(params['inputResponses']);
        if (answer == false) {
          return toolResult(ActionResult.failed('Nothing changed: the person said no.', code: 'declined'));
        }
        if (answer == true) args['confirm'] = state;
      }
    }
    final ActionResult result;
    if (!hub.ready) {
      result = runner.refusal(context(access), spec) ?? ActionResult.failed('This hub isn\'t part of a family yet.');
    } else if (hub.catchingUp && !spec.readOnly && args['preview'] != true) {
      // Over HTTP this is a 503 before it gets here (McpHttp); over stdio, the tool says so.
      result = ActionResult.failed(ApiError.catchingUp().message, code: 'catching_up');
    } else {
      result = await hub.gate.run(access.member, access.label, () => runner.run(context(access), name, args));
    }
    if (asks && result.status == ActionStatus.needsConfirmation) return _inputRequired(result);
    return toolResult(result);
  }

  /// The person's answer in `inputResponses`: true for yes, false for no, null for none.
  static bool? _answer(Object? responses) {
    if (responses is! Map) return null;
    final r = responses['confirm'];
    if (r is! Map) return null;
    final action = r['action'];
    if (action == 'decline' || action == 'cancel') return false;
    if (action != 'accept') return null;
    final content = r['content'];
    return content is Map && content['confirm'] == true;
  }

  static Map<String, Object?> _inputRequired(ActionResult result) {
    final confirm = (result.data['confirm'] as Map).cast<String, Object?>();
    final question = confirm['question'] as String;
    return {
      'resultType': 'input_required',
      'inputRequests': {
        'confirm': {
          'method': 'elicitation/create',
          'params': {
            'mode': 'form',
            'message': question,
            'requestedSchema': {
              'type': 'object',
              'properties': {
                'confirm': {'type': 'boolean', 'title': 'Do it', 'description': question, 'default': false},
              },
              'required': ['confirm'],
            },
          },
        },
      },
      'requestState': confirm['token'],
    };
  }

  /// The `tools/call` result for [result]: one speakable text, and the same facts as JSON. A
  /// change's receipt is in the text too, so a client that reads only text can undo exactly it.
  static Map<String, Object?> toolResult(ActionResult result) {
    final receipt = result.receipt;
    final text = receipt == null || !receipt.undoable ? result.text : '${result.text}\n[receipt ${receipt.id}: undo takes this back]';
    return {
      'content': [
        {'type': 'text', 'text': text},
      ],
      'structuredContent': result.structured,
      'isError': result.isError,
    };
  }

  /// Runs read action [action] with [args] for [access], as its member.
  Future<ActionResult> read(Access access, String action, Map<String, Object?> args) async {
    if (!hub.ready) return ActionResult.failed('This hub isn\'t part of a family yet.');
    return hub.gate.run(access.member, access.label, () => runner.run(context(access), action, args));
  }

  /// The `resources/read` result for [uri].
  Future<Map<String, Object?>> readResource(Access access, Object? uri) async {
    if (uri is! String || uri.isEmpty) throw McpError(RpcError.invalidParams, 'uri is required');
    final target = resourceAction(uri);
    if (target == null || !_toolNames(access).contains(target.action)) {
      throw McpError(RpcError.invalidParams, 'Den has no resource at $uri', resource: true);
    }
    final result = await read(access, target.action, target.args);
    if (result.isError) throw McpError(RpcError.invalidParams, result.text, resource: true);
    return {
      'contents': [
        {'uri': uri, 'mimeType': 'application/json', 'text': jsonEncode(result.structured)},
      ],
    };
  }

  /// The `prompts/get` result for prompt [name] with [arguments].
  Map<String, Object?> getPrompt(Access access, Object? name, Object? arguments) {
    final prompt = prompts(access).where((p) => p.name == name).firstOrNull;
    if (prompt == null) throw McpError(RpcError.invalidParams, 'Den has no prompt called "$name"');
    if (arguments != null && arguments is! Map) throw McpError(RpcError.invalidParams, 'arguments must be an object');
    final raw = (arguments as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
    final given = <String, String>{};
    for (final a in prompt.arguments) {
      final v = raw[a.name];
      if (v is String && v.trim().isNotEmpty) {
        final t = v.trim();
        given[a.name] = t.length > 4000 ? t.substring(0, 4000) : t;
      }
    }
    for (final a in prompt.arguments) {
      if (a.required && !given.containsKey(a.name)) throw McpError(RpcError.invalidParams, '"${a.name}" is required');
    }
    return {
      'description': prompt.description,
      'messages': [
        {
          'role': 'user',
          'content': {'type': 'text', 'text': prompt.build(given)},
        },
      ],
    };
  }

  static Map<String, Object?> _resultBody(Object? id, Map<String, Object?> result) => {'jsonrpc': '2.0', 'id': id, 'result': result};

  static Map<String, Object?> _errorBody(Object? id, int code, String message, {Object? data}) => {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message, 'data': ?data},
      };

  static McpReply _fail(Object? id, int code, String message, int status) => McpReply(_errorBody(id, code, message), status: status);

  /// A JSON-RPC error response.
  static Map<String, Object?> errorResponse(Object? id, int code, String message, {Object? data}) =>
      _errorBody(id, code, message, data: data);
}

/// A JSON-RPC error a method answers with.
class McpError implements Exception {
  /// An error with [code] and [message]; [resource] marks a resource that doesn't exist.
  McpError(this.code, this.message, {this.resource = false});

  /// The JSON-RPC code.
  final int code;

  /// Why.
  final String message;

  /// Whether it is about a resource that doesn't exist (`-32002` before 2026-07-28).
  final bool resource;
}
