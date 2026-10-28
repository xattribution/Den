import 'dart:convert';
import 'dart:io';

import 'package:cryptography/dart.dart';
import 'package:mime/mime.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_static/shelf_static.dart';

/// A file name that carries a content hash (`main.dart.3f2a9c1b.js`, `chunk-5e0c1d2f.js`): a new
/// build has new names, so such files may be kept a year.
final RegExp _hashedName = RegExp(r'[.\-_][0-9a-fA-F]{8,}\.[A-Za-z0-9]+$');

final RegExp _inlineScript = RegExp(r'<script\b(?![^>]*\bsrc\s*=)[^>]*>([\s\S]*?)</script\s*>', caseSensitive: false);

final MimeTypeResolver _types = MimeTypeResolver()
  ..addExtension('wasm', 'application/wasm')
  ..addExtension('mjs', 'text/javascript')
  ..addExtension('webmanifest', 'application/manifest+json');

/// The `Cache-Control` for the web app file at [path]: a year (immutable) for files whose names
/// carry a content hash, else `no-cache`, so `index.html`, `flutter_bootstrap.js`, the service
/// worker, `manifest.json` and Flutter's other fixed names are checked with the hub on every
/// load (a `304` when nothing changed) and a new build reaches every phone at once.
String cacheControlFor(String path) =>
    _hashedName.hasMatch(path.split('/').last) ? 'public, max-age=31536000, immutable' : 'no-cache';

/// The CSP hashes (`'sha256-…'`) of the inline scripts in [html], so a page's own inline
/// scripts run and no other inline script does.
List<String> inlineScriptHashes(String html) => [
      for (final m in _inlineScript.allMatches(html))
        if (m[1]!.trim().isNotEmpty) "'sha256-${base64.encode(const DartSha256().hashSync(utf8.encode(m[1]!)).bytes)}'",
    ];

/// The web app's Content-Security-Policy. Everything comes from the hub itself and nothing from
/// a CDN; WebAssembly may compile (CanvasKit); inline scripts run only by [scriptHashes];
/// styles may be inline (Flutter sets them on its elements); the app may connect to the hub
/// and to [connect] (its `ws:` or `wss:` origin, for sync); images and media may be `data:`
/// or `blob:` (photos being shared); and no other site may frame it.
String webAppPolicy({required String connect, List<String> scriptHashes = const []}) => [
      "default-src 'self'",
      ["script-src 'self' 'wasm-unsafe-eval'", ...scriptHashes].join(' '),
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: blob:",
      "font-src 'self' data:",
      "connect-src 'self' $connect",
      "media-src 'self' data: blob:",
      "worker-src 'self' blob:",
      "manifest-src 'self'",
      "object-src 'none'",
      "base-uri 'self'",
      "form-action 'self'",
      "frame-ancestors 'none'",
    ].join('; ');

/// Serves a static web build from [directory] with single-page-app fallback: a `GET` for a path
/// with no file extension that isn't a file answers with `index.html`. Every answer carries
/// [cacheControlFor]'s caching and, with [policy], the Content-Security-Policy it gives for the
/// request and `index.html`'s inline script hashes. Null when the directory doesn't exist.
Handler? webAppHandler(String? directory, {String Function(Request request, List<String> scriptHashes)? policy}) {
  if (directory == null || !Directory(directory).existsSync()) return null;
  final files = createStaticHandler(directory, defaultDocument: 'index.html', contentTypeResolver: _types);
  final index = File('$directory${Platform.pathSeparator}index.html');
  DateTime? stamp;
  var hashes = const <String>[];
  List<String> scripts() {
    try {
      final modified = index.lastModifiedSync();
      if (modified != stamp) {
        hashes = inlineScriptHashes(index.readAsStringSync());
        stamp = modified;
      }
    } on FileSystemException {
      hashes = const [];
    }
    return hashes;
  }

  Response finish(Request request, Response response) {
    final html = (response.headers['content-type'] ?? '').startsWith('text/html');
    return response.change(headers: {
      'cache-control': html ? 'no-cache' : cacheControlFor(request.url.path),
      if (policy != null) 'content-security-policy': policy(request, scripts()),
    });
  }

  return (Request request) async {
    var response = await files(request);
    if (response.statusCode == 404 && (request.method == 'GET' || request.method == 'HEAD')) {
      final last = request.url.pathSegments.isEmpty ? '' : request.url.pathSegments.last;
      if (!last.contains('.') && index.existsSync()) {
        response = Response.ok(
          request.method == 'HEAD' ? null : index.openRead(),
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      }
    }
    return finish(request, response);
  };
}
