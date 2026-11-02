@Timeout(Duration(seconds: 90))
library;

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/dart.dart';
import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fixture.dart';
import 'support/test.dart';

/// What each assistant platform needs from the hub's OAuth: client ID metadata documents
/// (Claude, ChatGPT), `resource` checks, `iss`, and clients a parent sets up (Alexa+).
void main() {
  late HubFixture f;
  final documents = <String, Map<String, Object?>>{};
  final fetched = <String>[];
  final web = http.Client();

  setUpAll(() async {
    f = await HubFixture.start(
      configure: (c) => HubConfig(
        port: 0,
        host: InternetAddress.loopbackIPv4,
        mdns: false,
        log: c.log,
        // Serves client metadata documents from made-up https addresses.
        fetchClient: MockClient((r) async {
          fetched.add(r.url.toString());
          final doc = documents[r.url.toString()];
          if (doc == null) return http.Response('not here', 404);
          return http.Response(jsonEncode(doc), 200, headers: {'content-type': 'application/json', 'cache-control': 'max-age=600'});
        }),
      ),
    );
  });
  tearDownAll(() async {
    web.close();
    await f.stop();
  });

  final verifier = 'v' * 20 + base64Url.encode(List.generate(32, (i) => i)).replaceAll('=', '');
  final challenge = base64Url.encode(const DartSha256().hashSync(utf8.encode(verifier)).bytes).replaceAll('=', '');

  Future<Map<String, String>> signed(String method, String path, [List<int> body = const []]) => DeviceRequest.sign(
        keys: f.phone.keys,
        method: method,
        url: f.base.resolve(path),
        body: body,
        hub: f.hubDen.deviceId,
        actorId: f.phone.actor?.id,
      );

  Future<http.Response> authorize(Map<String, String> query) async =>
      http.Response.fromStream(await web.send(http.Request('GET', f.base.replace(path: '/oauth/authorize', queryParameters: {
        'response_type': 'code',
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': 'st',
        ...query,
      }))
        ..followRedirects = false));

  Future<Map<String, Object?>> token(Map<String, String> fields, {Map<String, String> headers = const {}}) async {
    final r = await web.post(f.base.resolve('/oauth/token'), headers: headers, body: fields);
    return {'status': r.statusCode, ...(jsonDecode(r.body) as Map).cast<String, Object?>()};
  }

  /// Lets the sign-in on [page] in as a parent does: admits it from their phone, then approves
  /// the connection there. Returns the request as the parent's app saw it, and where the
  /// browser goes back to.
  Future<(Map<String, Object?>, Uri)> approve(String page) async {
    final id = RegExp(r'var id = "([^"]+)"').firstMatch(page)!.group(1)!;
    final code = RegExp(r'class="code">([A-Z0-9-]+)<').firstMatch(page)!.group(1)!;
    const path = '/api/v1/connections/requests';
    final list = await f.call('GET', path, headers: await signed('GET', path));
    final request = [for (final r in list.body['requests'] as List) (r as Map).cast<String, Object?>()].firstWhere((r) => r['code'] == code);
    final decidePath = '$path/${request['id']}';
    final body = jsonEncode({'decision': 'admit'});
    final admitted = await f.call('POST', decidePath, body: body, headers: await signed('POST', decidePath, utf8.encode(body)));
    expect(admitted.status, 200, reason: admitted.text);
    await f.toPhone();
    await f.phone.approveConnection(admitted.body['connection'] as String, scopes: {Scope.read, Scope.lists});
    await f.toHub();
    final status = jsonDecode((await web.get(f.base.resolve('/oauth/authorize/status?request=$id'))).body) as Map;
    expect(status['state'], 'approved');
    return (request, Uri.parse(status['redirect'] as String));
  }

  test('the metadata says Den reads client documents and names itself as issuer', () async {
    final meta = await f.call('GET', '/.well-known/oauth-authorization-server');
    expect(meta.body['client_id_metadata_document_supported'], isTrue);
    expect(meta.body['authorization_response_iss_parameter_supported'], isTrue);
    expect(meta.body['token_endpoint_auth_methods_supported'], contains('none'));
    expect(meta.body['registration_endpoint'], '${f.base}/oauth/register', reason: 'registration still works');
    final resource = await f.call('GET', '/.well-known/oauth-protected-resource/mcp');
    expect(resource.body['resource'], '${f.base}/mcp');
  });

  test('an app known by its metadata document signs in on any loopback port, and refreshes', () async {
    const id = 'https://app.example/oauth/client.json';
    documents[id] = {
      'client_id': id,
      'client_name': 'Claude Code',
      'redirect_uris': ['http://localhost/callback', 'http://127.0.0.1/callback'],
      'grant_types': ['authorization_code', 'refresh_token'],
      'response_types': ['code'],
      'token_endpoint_auth_method': 'none',
    };
    const back = 'http://localhost:43123/callback';
    final page = await authorize({'client_id': id, 'redirect_uri': back, 'scope': 'read lists', 'resource': '${f.base}/mcp'});
    expect(page.statusCode, 200, reason: page.body);
    expect(page.body, contains('Approve Claude Code in the Den app'));
    expect(page.body, contains('a program on this computer'));
    expect(page.body, contains('app.example'));
    expect(fetched, [id]);

    final (request, redirect) = await approve(page.body);
    expect(request['client_kind'], 'document');
    expect(request['client_document_host'], 'app.example');
    expect(request['redirect_loopback'], isTrue);
    expect(request['redirect_host'], 'localhost');
    expect(redirect.toString(), startsWith(back));
    expect(redirect.queryParameters['iss'], f.base.toString());
    expect(redirect.queryParameters['state'], 'st');

    final tokens = await token({
      'grant_type': 'authorization_code',
      'code': redirect.queryParameters['code']!,
      'redirect_uri': back,
      'client_id': id,
      'code_verifier': verifier,
      'resource': '${f.base}/mcp',
    });
    expect(tokens['status'], 200, reason: '$tokens');
    final access = tokens['access_token'] as String;
    final body = {
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/list',
      'params': {
        '_meta': {McpMeta.protocolVersion: '2026-07-28', McpMeta.clientCapabilities: <String, Object?>{}},
      },
    };
    final listed = await f.call('POST', '/mcp', token: access, body: body, headers: mcpRequestHeaders(body));
    expect(listed.status, 200, reason: listed.text);

    final elsewhere = await token({
      'grant_type': 'refresh_token',
      'refresh_token': tokens['refresh_token'] as String,
      'client_id': id,
      'resource': 'https://other.example/mcp',
    });
    expect(elsewhere['status'], 400);
    expect(elsewhere['error'], 'invalid_target');
    final refreshed = await token({
      'grant_type': 'refresh_token',
      'refresh_token': tokens['refresh_token'] as String,
      'client_id': id,
      'resource': '${f.base}',
    });
    expect(refreshed['status'], 200, reason: 'the hub itself names this resource too (ChatGPT sends the origin)');
    final other = await token({
      'grant_type': 'refresh_token',
      'refresh_token': refreshed['refresh_token'] as String,
      'client_id': 'https://evil.example/client.json',
    });
    expect(other['error'], 'invalid_grant', reason: 'a refresh token works only for the address it was issued to');
  });

  test('documents Den can\'t use are refused before anyone is asked', () async {
    Future<String> refused(String id, Map<String, Object?>? doc, {String redirect = 'https://chat.example/callback'}) async {
      if (doc != null) documents[id] = doc;
      final page = await authorize({'client_id': id, 'redirect_uri': redirect});
      expect(page.statusCode, 400, reason: id);
      return page.body;
    }

    Map<String, Object?> doc(String id, {Object? redirects, Object? method, String? named}) => {
          'client_id': named ?? id,
          'client_name': 'Chat',
          'redirect_uris': redirects ?? ['https://chat.example/callback'],
          'token_endpoint_auth_method': ?method,
        };

    expect(await refused('https://chat.example/a.json', doc('https://chat.example/a.json', named: 'https://chat.example/b.json')),
        contains('names a different app'));
    expect(await refused('https://chat.example/c.json', doc('https://chat.example/c.json', method: 'client_secret_basic')),
        contains('no client secret'));
    expect(await refused('https://chat.example/d.json', doc('https://chat.example/d.json', redirects: ['javascript:alert(1)'])),
        contains('won'));
    expect(await refused('https://chat.example/e.json', doc('https://chat.example/e.json'), redirect: 'https://evil.example/cb'),
        contains('address this hub doesn'));
    expect(await refused('https://chat.example/missing.json', null), contains('answered 404'));
    expect(await refused('http://chat.example/plain.json', null), contains('registered'),
        reason: 'only https addresses are documents');
    expect(f.hubDen.connections.where((c) => (c.client ?? '').startsWith('https://chat.example')), isEmpty);
  });

  test('a resource has to name this hub', () async {
    final reg = await f.call('POST', '/oauth/register', body: {
      'redirect_uris': ['https://claude.ai/api/mcp/auth_callback'],
      'client_name': 'Claude',
      'token_endpoint_auth_method': 'none',
    });
    final clientId = reg.body['client_id'] as String;
    final elsewhere = await authorize({
      'client_id': clientId,
      'redirect_uri': 'https://claude.ai/api/mcp/auth_callback',
      'resource': 'https://evil.example/mcp',
    });
    expect(elsewhere.statusCode, 302);
    final location = Uri.parse(elsewhere.headers['location']!);
    expect(location.queryParameters['error'], 'invalid_target');
    expect(location.queryParameters['iss'], f.base.toString());
    final slash = await authorize({
      'client_id': clientId,
      'redirect_uri': 'https://claude.ai/api/mcp/auth_callback',
      'resource': '${f.base}/',
    });
    expect(slash.statusCode, 200, reason: 'the hub with a trailing slash is still the hub');
  });

  test('a parent sets up a client for an assistant that can\'t register (Alexa+)', () async {
    const path = '/api/v1/connections/clients';
    const alexa = 'https://alexa.amazon.com/api/skill/link/M3IHEJ1OZMSGZ3';
    final body = jsonEncode({
      'name': 'Alexa',
      'redirect_uris': [alexa],
    });
    expect((await f.call('POST', path, body: body)).status, 401, reason: 'only a family device may');
    final created = await f.call('POST', path, body: body, headers: await signed('POST', path, utf8.encode(body)));
    expect(created.status, 201, reason: created.text);
    final clientId = created.body['client_id'] as String;
    final secret = created.body['client_secret'] as String;
    expect(created.body['authorization_endpoint'], '${f.base}/oauth/authorize');
    expect(created.body['token_endpoint'], '${f.base}/oauth/token');
    expect(created.body['resource'], '${f.base}/mcp');
    expect(created.body['scopes'], ['read', 'calendar', 'chores', 'lists', 'points']);

    final listed = await f.call('GET', path, headers: await signed('GET', path));
    final shown = [for (final c in listed.body['clients'] as List) (c as Map).cast<String, Object?>()];
    expect(shown.map((c) => c['client_id']), [clientId]);
    expect(shown.single.containsKey('client_secret'), isFalse);

    await f.hub.oauth.sweep(now: DateTime.now().millisecondsSinceEpoch + const Duration(days: 3).inMilliseconds);
    expect(f.hub.oauth.store.client(clientId), isNotNull, reason: 'a client a parent set up isn\'t pruned');

    final page = await authorize({'client_id': clientId, 'redirect_uri': alexa, 'scope': 'read lists'});
    expect(page.statusCode, 200, reason: page.body);
    final (request, redirect) = await approve(page.body);
    expect(request['client_kind'], 'static');
    expect(redirect.toString(), startsWith(alexa));
    final code = redirect.queryParameters['code']!;

    final noSecret = await token({
      'grant_type': 'authorization_code', 'code': code, 'redirect_uri': alexa, 'client_id': clientId, 'code_verifier': verifier,
    });
    expect(noSecret['error'], 'invalid_client');
    final basic = 'Basic ${base64.encode(utf8.encode('${Uri.encodeQueryComponent(clientId)}:${Uri.encodeQueryComponent(secret)}'))}';
    final tokens = await token({
      'grant_type': 'authorization_code', 'code': code, 'redirect_uri': alexa, 'code_verifier': verifier,
    }, headers: {'authorization': basic});
    expect(tokens['status'], 200, reason: '$tokens');
    expect(tokens['refresh_token'], isA<String>(), reason: 'Alexa needs a refresh token with every access token');
    final refreshed = await token({'grant_type': 'refresh_token', 'refresh_token': tokens['refresh_token'] as String},
        headers: {'authorization': basic});
    expect(refreshed['status'], 200, reason: 'Alexa refreshes without a resource');
    expect(refreshed['refresh_token'], isA<String>());

    final connection = f.hubDen.connections.firstWhere((c) => c.client == clientId);
    final removePath = '$path/$clientId';
    final removed = await f.call('DELETE', removePath, headers: await signed('DELETE', removePath));
    expect(removed.status, 200, reason: removed.text);
    expect(removed.body['connections_ended'], 1);
    expect(f.hubDen.connections.firstWhere((c) => c.id == connection.id).status, ConnectionStatus.revoked);
    final after = await token({'grant_type': 'refresh_token', 'refresh_token': refreshed['refresh_token'] as String},
        headers: {'authorization': basic});
    expect(after['error'], 'invalid_client');
  });
}
