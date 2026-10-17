import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_static/shelf_static.dart';

/// Serves a static web build from [directory] with single-page-app fallback: a `GET` for a path
/// with no file extension that isn't a file answers with `index.html`. Null when the directory
/// doesn't exist.
Handler? webAppHandler(String? directory) {
  if (directory == null || !Directory(directory).existsSync()) return null;
  final files = createStaticHandler(directory, defaultDocument: 'index.html');
  final index = File('$directory${Platform.pathSeparator}index.html');
  return (Request request) async {
    final response = await files(request);
    if (response.statusCode != 404 || (request.method != 'GET' && request.method != 'HEAD')) return response;
    final last = request.url.pathSegments.isEmpty ? '' : request.url.pathSegments.last;
    if (last.contains('.') || !index.existsSync()) return response;
    return Response.ok(
      request.method == 'HEAD' ? null : index.openRead(),
      headers: {'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-cache'},
    );
  };
}
