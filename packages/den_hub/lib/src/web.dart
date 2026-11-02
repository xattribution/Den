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

/// The web app's files worth compressing: the app's code, CanvasKit, fonts and text.
const Set<String> _compressible = {'js', 'mjs', 'wasm', 'json', 'css', 'html', 'ttf', 'otf', 'svg', 'txt', 'map', 'webmanifest'};

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

  // Each compressed file once, while it stays the same: the app's code and CanvasKit are about
  // 15 MB as they are and about 4 MB compressed, which is what a phone on a slow VPN waits for.
  final gzipped = <String, ({DateTime modified, List<int> bytes})>{};
  Response compressed(Request request, Response response) {
    if (response.statusCode != 200 || request.method != 'GET') return response;
    if (response.headers['content-encoding'] != null) return response;
    final accepts = (request.headers['accept-encoding'] ?? '').split(',').map((e) => e.trim());
    if (!accepts.any((e) => e == 'gzip' || e == '*' || e.startsWith('gzip;') && !e.endsWith('q=0'))) return response;
    final segments = request.url.pathSegments.where((s) => s.isNotEmpty).toList();
    final last = segments.isEmpty ? '' : segments.last;
    final dot = last.lastIndexOf('.');
    final File file;
    if (dot < 0) {
      file = index;
    } else {
      if (!_compressible.contains(last.substring(dot + 1).toLowerCase())) return response;
      file = File([directory, ...segments].join(Platform.pathSeparator));
    }
    try {
      final modified = file.lastModifiedSync();
      var kept = gzipped[file.path];
      if (kept == null || kept.modified != modified) {
        kept = (modified: modified, bytes: gzip.encode(file.readAsBytesSync()));
        gzipped[file.path] = kept;
      }
      final headers = {
        for (final h in response.headers.entries)
          if (h.key != 'content-length' && h.key != 'accept-ranges') h.key: h.value,
        'content-encoding': 'gzip',
        'vary': 'accept-encoding',
      };
      return Response.ok(kept.bytes, headers: headers);
    } on FileSystemException {
      return response;
    }
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
    return finish(request, compressed(request, response));
  };
}
