import 'dart:convert';
import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';

import 'fake_idp.dart';

/// One answer, every header kept as sent (`Set-Cookie` more than once among them).
class Answer {
  Answer(this.status, this.headers, this.body, this.elapsed);
  final int status;
  final Map<String, List<String>> headers;
  final String body;
  final Duration elapsed;

  String? header(String name) => headers[name]?.join(', ');
  List<String> get setCookies => headers['set-cookie'] ?? const [];
  String? get location => header('location');

  /// The `Set-Cookie` for [name], or null.
  String? cookieLine(String name) => setCookies.where((c) => c.startsWith('$name=')).firstOrNull;

  Object? get json => jsonDecode(body);

  @override
  String toString() => 'Answer($status ${body.length > 300 ? body.substring(0, 300) : body})';
}

/// A browser, as far as the hub can tell: it keeps the hub's cookies (sending them back as a
/// browser would, `SameSite=Lax` and all) and follows nothing on its own. Requests go to the hub
/// at [base] (loopback) as if at [hostname].
class Browser {
  Browser(this.base, {this.hostname});

  /// Where the hub listens.
  final Uri base;

  /// The address it is asked at (`Host`), or null for loopback's.
  final String? hostname;

  /// The cookies it holds for the hub.
  final Map<String, String> cookies = {};

  /// Sends [method] [path] (a path, or a full `https://` address of the hub's, whose path is
  /// used). [crossSitePost] leaves the cookies out, as a browser does for a `SameSite=Lax`
  /// cookie on a form another site posts.
  Future<Answer> go(String method, String path, {Map<String, String> headers = const {}, String? form, bool crossSitePost = false}) async {
    final target = path.startsWith('https://') ? Uri.parse(path) : null;
    final url = base.resolve(target == null ? path : '${target.path}${target.hasQuery ? '?${target.query}' : ''}');
    final client = HttpClient();
    final watch = Stopwatch()..start();
    try {
      final request = await client.openUrl(method, url);
      request.followRedirects = false;
      if (hostname != null) request.headers.set(HttpHeaders.hostHeader, hostname!);
      if (cookies.isNotEmpty && !crossSitePost) {
        request.headers.set(HttpHeaders.cookieHeader, [for (final e in cookies.entries) '${e.key}=${e.value}'].join('; '));
      }
      headers.forEach(request.headers.set);
      if (form != null) {
        request.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
        request.write(form);
      }
      final response = await request.close();
      final body = await utf8.decodeStream(response);
      final all = <String, List<String>>{};
      response.headers.forEach((name, values) => all[name] = values);
      for (final line in all['set-cookie'] ?? const <String>[]) {
        final pair = line.split(';').first;
        final eq = pair.indexOf('=');
        final name = pair.substring(0, eq), value = pair.substring(eq + 1);
        if (value.isEmpty || line.contains('Max-Age=0')) {
          cookies.remove(name);
        } else {
          cookies[name] = value;
        }
      }
      return Answer(response.statusCode, all, body, watch.elapsed);
    } finally {
      client.close(force: true);
    }
  }

  /// Signs in at [idp] as [sub]: opens [start] (the hub's start link, `/auth/oidc/<p>/start`
  /// by default), signs in at the provider, and comes back as the provider sends the browser
  /// back (Google: a redirect; Apple: a form it posts, from its own origin). Returns the hub's
  /// last answer. [authorize] changes the authorization request the browser takes to the
  /// provider; [back] the query it brings back.
  Future<Answer> signIn(
    FakeIdp idp, {
    required String sub,
    String? start,
    String email = 'alex@example.com',
    bool verified = true,
    Map<String, Object?> extra = const {},
    Uri Function(Uri authorize)? authorize,
    Map<String, String> Function(Map<String, String> query)? back,
  }) async {
    final provider = idp.apple ? 'apple' : 'google';
    final started = await go('GET', start ?? '/auth/oidc/$provider/start');
    if (started.status != 302) return started;
    final at = Uri.parse(started.location!);
    final code = idp.signIn(authorize == null ? at : authorize(at), sub: sub, email: email, verified: verified, extra: extra);
    var query = {'code': code, 'state': at.queryParameters['state']!};
    if (back != null) query = back(query);
    if (!idp.apple) return go('GET', '/auth/oidc/google/callback?${Uri(queryParameters: query).query}');
    final posted = await go('POST', '/auth/oidc/apple/callback',
        form: Uri(queryParameters: query).query, headers: {'origin': idp.origin}, crossSitePost: true);
    if (posted.status != 303) return posted;
    return go('GET', posted.location!);
  }
}

/// A request signed by [den]'s device (as whoever acts on it) for the hub [hub], made at [base]
/// as if at [hostname].
Future<Answer> signedCall(Uri base, Den den, String method, String path, {required String hub, Object? body, String? hostname}) async {
  final bytes = body == null ? <int>[] : utf8.encode(jsonEncode(body));
  final headers = await DeviceRequest.sign(keys: den.keys, method: method, url: base.resolve(path), body: bytes, hub: hub, actorId: den.actor?.id);
  final client = HttpClient();
  final watch = Stopwatch()..start();
  try {
    final request = await client.openUrl(method, base.resolve(path));
    if (hostname != null) request.headers.set(HttpHeaders.hostHeader, hostname);
    headers.forEach(request.headers.set);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.add(bytes);
    }
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    final all = <String, List<String>>{};
    response.headers.forEach((name, values) => all[name] = values);
    return Answer(response.statusCode, all, text, watch.elapsed);
  } finally {
    client.close(force: true);
  }
}
