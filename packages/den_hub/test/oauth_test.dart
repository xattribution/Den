@Timeout(Duration(seconds: 90))
library;

import 'dart:convert';

import 'package:cryptography/dart.dart';
import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:http/http.dart' as http;
import 'support/test.dart';

import 'support/fixture.dart';

void main() {
  late HubFixture f;
  late SyncNode phoneNode;
  late SyncClient phoneClient;
  const redirect = 'https://claude.ai/api/mcp/auth_callback';

  setUpAll(() async {
    f = await HubFixture.start();
    phoneNode = SyncNode(f.phone);
    phoneClient = SyncClient(
      node: phoneNode,
      endpoints: [Uri.parse('ws://127.0.0.1:${f.hub.port}/ws')],
      expectDevice: f.hubDen.deviceId,
    )..start();
    await phoneClient.whenLive();
  });

  tearDownAll(() async {
    await phoneClient.stop();
    await phoneNode.close();
    await f.stop();
  });

  Future<Map<String, Object?>> form(String path, Map<String, String> fields) async {
    final r = await http.post(f.base.resolve(path), body: fields);
    return {'status': r.statusCode, ...(jsonDecode(r.body) as Map).cast<String, Object?>()};
  }

  Future<(String, String)> authorize(String clientId, String challenge, {String state = 'xyz'}) async {
    final url = f.base.replace(path: '/oauth/authorize', queryParameters: {
      'response_type': 'code',
      'client_id': clientId,
      'redirect_uri': redirect,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'state': state,
      'scope': 'read lists',
      'resource': '${f.base}/mcp',
    });
    final page = await http.get(url);
    expect(page.statusCode, 200);
    expect(page.headers['content-type'], startsWith('text/html'));
    expect(page.body, contains('Approve Claude in the Den app'));
    expect(page.body, contains('Settings &rarr; AI and automations'));
    expect(page.body, contains('#FBFAF7'));
    final id = RegExp(r'var id = "([^"]+)"').firstMatch(page.body)!.group(1)!;
    return (id, page.body);
  }

  Future<Map<String, Object?>> status(String id) async =>
      (jsonDecode((await http.get(f.base.resolve('/oauth/authorize/status?request=$id'))).body) as Map).cast<String, Object?>();

  test('register, authorize with a parent approving on a synced phone, exchange, use, refresh', () async {
    final meta = await f.call('GET', '/.well-known/oauth-authorization-server');
    expect(meta.body['code_challenge_methods_supported'], ['S256']);
    expect(meta.body['token_endpoint'], '${f.base}/oauth/token');
    final resource = await f.call('GET', '/.well-known/oauth-protected-resource');
    expect(resource.body['resource'], '${f.base}/mcp');
    expect(resource.body['authorization_servers'], ['${f.base}']);

    final reg = await f.call('POST', '/oauth/register', body: {
      'redirect_uris': [redirect],
      'client_name': 'Claude',
      'token_endpoint_auth_method': 'none',
    });
    expect(reg.status, 201);
    final clientId = reg.body['client_id'] as String;
    expect(reg.body.containsKey('client_secret'), isFalse);
    expect((await f.call('POST', '/oauth/register', body: {'redirect_uris': ['http://evil.example/cb']})).status, 400);

    final verifier = 'v' * 20 + base64Url.encode(List.generate(32, (i) => i)).replaceAll('=', '');
    final challenge = base64Url.encode(const DartSha256().hashSync(utf8.encode(verifier)).bytes).replaceAll('=', '');
    final (id, _) = await authorize(clientId, challenge);
    expect((await status(id))['state'], 'pending');

    await eventually(() => f.phone.connections.any((c) => c.client == clientId && c.status == ConnectionStatus.pending));
    final pending = f.phone.connections.firstWhere((c) => c.client == clientId);
    expect(pending.label, 'Claude');
    expect(pending.scopes, {Scope.read, Scope.lists});
    await f.phone.approveConnection(pending.id, scopes: {Scope.read, Scope.lists});

    Map<String, Object?> decided = {};
    await eventually(() async => (decided = await status(id))['state'] == 'approved');
    final back = Uri.parse(decided['redirect'] as String);
    expect(back.toString(), startsWith(redirect));
    expect(back.queryParameters['state'], 'xyz');
    final code = back.queryParameters['code']!;

    final wrong = await form('/oauth/token', {
      'grant_type': 'authorization_code', 'code': code, 'redirect_uri': redirect, 'client_id': clientId, 'code_verifier': 'x' * 50,
    });
    expect(wrong['error'], 'invalid_grant');
    final tokens = await form('/oauth/token', {
      'grant_type': 'authorization_code', 'code': code, 'redirect_uri': redirect, 'client_id': clientId, 'code_verifier': verifier,
    });
    expect(tokens['status'], 200);
    expect(tokens['token_type'], 'Bearer');
    expect(tokens['scope'], 'read lists');
    final access = tokens['access_token'] as String;
    final again = await form('/oauth/token', {
      'grant_type': 'authorization_code', 'code': code, 'redirect_uri': redirect, 'client_id': clientId, 'code_verifier': verifier,
    });
    expect(again['error'], 'invalid_grant', reason: 'codes work once');

    final init = await f.call('POST', '/mcp', token: access, body: {
      'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18'},
    });
    expect(init.status, 200);
    expect(f.hubDen.connections.firstWhere((c) => c.id == pending.id).tokenHash, hashToken(access));
    expect(f.hubDen.connections.firstWhere((c) => c.id == pending.id).expires, isNotNull);

    final refreshed = await form('/oauth/token', {'grant_type': 'refresh_token', 'refresh_token': tokens['refresh_token'] as String, 'client_id': clientId});
    expect(refreshed['status'], 200);
    expect(refreshed['refresh_token'], isNot(tokens['refresh_token']));
    expect((await f.call('GET', '/api/v1/members', token: access)).status, 401, reason: 'the old access token stopped');
    expect((await f.call('GET', '/api/v1/members', token: refreshed['access_token'] as String)).status, 200);
    final reuse = await form('/oauth/token', {'grant_type': 'refresh_token', 'refresh_token': tokens['refresh_token'] as String, 'client_id': clientId});
    expect(reuse['error'], 'invalid_grant');
    expect((await f.call('GET', '/api/v1/members', token: refreshed['access_token'] as String)).status, 401,
        reason: 'reusing a refresh token ends the connection\'s tokens');
  });

  test('a parent declining sends the app back with access_denied', () async {
    final reg = await f.call('POST', '/oauth/register', body: {'redirect_uris': [redirect], 'client_name': 'Claude', 'token_endpoint_auth_method': 'none'});
    final clientId = reg.body['client_id'] as String;
    final (id, _) = await authorize(clientId, 'c' * 43, state: 'nope');
    await eventually(() => f.phone.connections.any((c) => c.client == clientId));
    await f.phone.revokeConnection(f.phone.connections.firstWhere((c) => c.client == clientId).id);
    Map<String, Object?> decided = {};
    await eventually(() async => (decided = await status(id))['state'] == 'declined');
    final back = Uri.parse(decided['redirect'] as String);
    expect(back.queryParameters['error'], 'access_denied');
    expect(back.queryParameters['state'], 'nope');
  });

  test('authorize refuses unknown clients, unregistered redirects and missing PKCE', () async {
    final unknown = await http.get(f.base.replace(path: '/oauth/authorize', queryParameters: {'client_id': 'nope', 'response_type': 'code'}));
    expect(unknown.statusCode, 400);
    expect(unknown.body, contains('This sign-in link doesn'));
    final reg = await f.call('POST', '/oauth/register', body: {'redirect_uris': [redirect], 'client_name': 'Claude'});
    expect(reg.body['client_secret'], isA<String>());
    final clientId = reg.body['client_id'] as String;
    final noPkce = await http.Client().send(http.Request('GET', f.base.replace(path: '/oauth/authorize', queryParameters: {
      'client_id': clientId, 'response_type': 'code', 'redirect_uri': redirect, 'state': 's',
    }))..followRedirects = false);
    expect(noPkce.statusCode, 302);
    expect(Uri.parse(noPkce.headers['location']!).queryParameters['error'], 'invalid_request');
    final secretless = await form('/oauth/token', {'grant_type': 'refresh_token', 'refresh_token': 'x', 'client_id': clientId});
    expect(secretless['error'], 'invalid_client');
  });
}
