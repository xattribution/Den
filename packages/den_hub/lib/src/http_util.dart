import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';

/// Largest request body the API reads.
const int maxBodyBytes = 256 * 1024;

/// An error answered with the API's error body (docs/hub-api.md, "Errors").
class ApiError implements Exception {
  /// Creates an error.
  ApiError(this.status, this.code, this.message, {this.details, this.headers = const {}});

  /// `400 invalid_input`, naming [field] when one field is at fault.
  factory ApiError.invalid(String message, {String? field}) =>
      ApiError(400, 'invalid_input', message, details: field == null ? null : {'field': field});

  /// `401 unauthorized`.
  factory ApiError.unauthorized([String message = 'This needs a valid token from the Den app.']) =>
      ApiError(401, 'unauthorized', message, headers: const {'www-authenticate': 'Bearer'});

  /// `403 insufficient_scope`.
  factory ApiError.scope(String scope) => ApiError(
        403,
        'insufficient_scope',
        'This token doesn\'t have the "$scope" scope.',
        details: {'scope': scope},
      );

  /// `403 permission_denied`.
  factory ApiError.denied(String message) => ApiError(403, 'permission_denied', message);

  /// `404 not_found`, naming the record when one was asked for.
  factory ApiError.notFound({String? type, String? id, String? message}) => ApiError(
        404,
        'not_found',
        message ?? (type == null ? 'There\'s nothing here.' : 'There\'s no such $type.'),
        details: type == null ? null : {'type': type, 'id': ?id},
      );

  /// `409 read_only`.
  factory ApiError.readOnly() => ApiError(
        409,
        'read_only',
        'This event comes from a subscribed calendar. Change it there.',
      );

  /// `503 not_ready`.
  factory ApiError.notReady() => ApiError(
        503,
        'not_ready',
        'This hub isn\'t part of a family yet, or is still starting.',
      );

  /// HTTP status.
  final int status;

  /// Stable machine-readable code.
  final String code;

  /// Written for people.
  final String message;

  /// Extra structured data.
  final Map<String, Object?>? details;

  /// Extra response headers.
  final Map<String, String> headers;

  /// The response for this error.
  Response toResponse() => jsonResponse(
        {
          'error': {'code': code, 'message': message, 'details': ?details},
        },
        status: status,
        headers: headers,
      );

  @override
  String toString() => 'ApiError($status $code)';
}

/// A JSON response with the API's content type.
Response jsonResponse(Object? body, {int status = 200, Map<String, String> headers = const {}}) => Response(
      status,
      body: utf8.encode(jsonEncode(body)),
      headers: {'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...headers},
    );

/// Reads the request body, refusing more than [limit] bytes with `413 too_large`.
Future<Uint8List> readBodyBytes(Request request, {int limit = maxBodyBytes}) async {
  final declared = request.contentLength;
  if (declared != null && declared > limit) throw ApiError(413, 'too_large', 'That request is too large.');
  final out = BytesBuilder(copy: false);
  await for (final chunk in request.read()) {
    out.add(chunk);
    if (out.length > limit) throw ApiError(413, 'too_large', 'That request is too large.');
  }
  return out.takeBytes();
}

/// Reads a JSON object body. An empty body is an empty object unless [required].
Future<Map<String, Object?>> readJsonObject(Request request, {bool required = false}) async {
  final bytes = await readBodyBytes(request);
  if (bytes.isEmpty) {
    if (required) throw ApiError.invalid('This needs a JSON body.');
    return {};
  }
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    throw ApiError.invalid('The body isn\'t valid JSON.');
  }
  if (json is! Map) throw ApiError.invalid('The body must be a JSON object.');
  return json.cast<String, Object?>();
}

/// One route: a method and a path pattern whose `<name>` segments capture.
class Route {
  /// Creates a route.
  Route(this.method, this.pattern, this.handler) : _segments = _split(pattern);

  /// HTTP method.
  final String method;

  /// Path pattern such as `/api/v1/events/<id>`.
  final String pattern;

  /// Answers a matched request.
  final FutureOr<Response> Function(Request request, Map<String, String> params) handler;

  final List<String> _segments;

  static List<String> _split(String path) => path.split('/').where((s) => s.isNotEmpty).toList();

  /// The captured parameters when [path] matches, else null.
  Map<String, String>? match(List<String> path) {
    if (path.length != _segments.length) return null;
    final params = <String, String>{};
    for (var i = 0; i < path.length; i++) {
      final s = _segments[i];
      if (s.startsWith('<') && s.endsWith('>')) {
        params[s.substring(1, s.length - 1)] = path[i];
      } else if (s != path[i]) {
        return null;
      }
    }
    return params;
  }
}

/// Matches requests to [Route]s: `404` for no path, `405` with `Allow` for a known path with
/// another method.
class Routes {
  final List<Route> _routes = [];

  /// Adds a route.
  void add(String method, String pattern, FutureOr<Response> Function(Request, Map<String, String>) handler) =>
      _routes.add(Route(method, pattern, handler));

  /// The handler for [request] with its parameters, or null when no path matches. Throws
  /// `405 method_not_allowed` for a known path and the wrong method.
  (Route, Map<String, String>)? find(Request request) {
    final path = request.url.pathSegments.where((s) => s.isNotEmpty).toList();
    final allowed = <String>{};
    for (final r in _routes) {
      final params = r.match(path);
      if (params == null) continue;
      if (r.method == request.method || (r.method == 'GET' && request.method == 'HEAD')) return (r, params);
      allowed.add(r.method);
    }
    if (allowed.isEmpty) return null;
    throw ApiError(
      405,
      'method_not_allowed',
      'That path doesn\'t take ${request.method}.',
      headers: {'allow': (allowed.toList()..sort()).join(', ')},
    );
  }
}

/// A query parameter as an int within bounds, or [fallback] when absent.
int queryInt(Request request, String name, int fallback, {int? min, int? max}) {
  final raw = request.url.queryParameters[name];
  if (raw == null || raw.isEmpty) return fallback;
  final value = int.tryParse(raw.trim());
  if (value == null || (min != null && value < min) || (max != null && value > max)) {
    throw ApiError.invalid('"$name" must be a whole number${min != null && max != null ? ' from $min to $max' : ''}.',
        field: name);
  }
  return value;
}

/// A query parameter as a bool (`true`/`false`, `1`/`0`).
bool queryBool(Request request, String name, bool fallback) {
  final raw = request.url.queryParameters[name]?.trim().toLowerCase();
  if (raw == null || raw.isEmpty) return fallback;
  if (raw == 'true' || raw == '1') return true;
  if (raw == 'false' || raw == '0') return false;
  throw ApiError.invalid('"$name" must be true or false.', field: name);
}

/// The public base URL a request came to: `https://den.example.com`, honoring a proxy's
/// forwarded scheme and host.
Uri requestBase(Request request, Uri? configured) {
  if (configured != null) return configured.replace(path: '', query: null, fragment: null);
  final proto = request.headers['x-forwarded-proto']?.split(',').first.trim();
  final host = request.headers['x-forwarded-host']?.split(',').first.trim() ?? request.headers['host'];
  final scheme = (proto == 'https' || proto == 'http') ? proto! : request.requestedUri.scheme;
  if (host == null || host.isEmpty) {
    return Uri(scheme: scheme, host: request.requestedUri.host, port: request.requestedUri.port);
  }
  return Uri.parse('$scheme://$host');
}

/// [base] and [path] joined as a string without a trailing slash.
String urlOf(Uri base, String path) {
  final text = base.toString();
  return '${text.endsWith('/') ? text.substring(0, text.length - 1) : text}$path';
}
