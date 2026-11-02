import 'dart:io';

import 'package:den_hub/src/web.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// The web app's files (web.dart): compressed for a browser that takes gzip, as they are for one
/// that doesn't.
void main() {
  late Directory dir;
  late Handler handler;
  final code = 'console.log("den");\n' * 5000;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('den_web_');
    File('${dir.path}/index.html').writeAsStringSync('<html><body>${'Den ' * 2000}</body></html>');
    File('${dir.path}/main.dart.js').writeAsStringSync(code);
    File('${dir.path}/favicon.png').writeAsBytesSync(List.filled(4000, 7));
    handler = webAppHandler(dir.path)!;
  });
  tearDown(() => dir.delete(recursive: true));

  Future<Response> get(String path, {String? encoding}) async => handler(Request(
        'GET',
        Uri.parse('http://hub$path'),
        headers: {'accept-encoding': ?encoding},
      ));

  test('the app code is compressed for a browser that takes gzip', () async {
    final r = await get('/main.dart.js', encoding: 'gzip, deflate, br');
    expect(r.statusCode, 200);
    expect(r.headers['content-encoding'], 'gzip');
    expect(r.headers['vary'], 'accept-encoding');
    expect(r.headers['content-type'], startsWith('text/javascript'));
    final body = await r.read().expand((b) => b).toList();
    expect(body.length, lessThan(code.length ~/ 10));
    expect(String.fromCharCodes(gzip.decode(body)), code);
  });

  test('as it is for one that does not', () async {
    final r = await get('/main.dart.js');
    expect(r.headers['content-encoding'], isNull);
    expect(await r.readAsString(), code);
  });

  test('the page itself, and a route the app handles, are compressed too', () async {
    for (final path in ['/', '/join/maple-river']) {
      final r = await get(path, encoding: 'gzip');
      expect(r.statusCode, 200, reason: path);
      expect(r.headers['content-encoding'], 'gzip', reason: path);
      expect(String.fromCharCodes(gzip.decode(await r.read().expand((b) => b).toList())), startsWith('<html>'));
    }
  });

  test('a changed file is compressed again', () async {
    await get('/main.dart.js', encoding: 'gzip');
    final file = File('${dir.path}/main.dart.js')..writeAsStringSync('changed');
    file.setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
    final r = await get('/main.dart.js', encoding: 'gzip');
    expect(String.fromCharCodes(gzip.decode(await r.read().expand((b) => b).toList())), 'changed');
  });

  test('images stay as they are, and a missing file is still missing', () async {
    expect((await get('/favicon.png', encoding: 'gzip')).headers['content-encoding'], isNull);
    expect((await get('/nothing.js', encoding: 'gzip')).statusCode, 404);
  });
}
