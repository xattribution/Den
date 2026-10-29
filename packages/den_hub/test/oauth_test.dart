@Timeout(Duration(seconds: 90))
library;

import 'dart:convert';

import 'package:cryptography/dart.dart';
import 'package:den_core/den_core.dart';
import 'package:den_hub/src/edge.dart' show Limits;
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

  Future<String> register({String name = 'Claude'}) async {
    final reg = await f.call('POST', '/oauth/register', body: {
      'redirect_uris': [redirect],
      'client_name': name,
      'token_endpoint_auth_method': 'none',
    });
    expect(reg.status, 201);
    return reg.body['client_id'] as String;
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
    expect(page.body, contains('Settings &rarr; Advanced &rarr; AI and automations'));
    expect(page.body, contains('#F2F2F2'));
    final id = RegExp(r'var id = "([^"]+)"').firstMatch(page.body)!.group(1)!;
    return (id, page.body);
  }

  Future<Map<String, Object?>> status(String id) async =>
      (jsonDecode((await http.get(f.base.resolve('/oauth/authorize/status?request=$id'))).body) as Map).cast<String, Object?>();

  // What a parent's phone does in the Den app, signed with its own key.
  Future<Map<String, String>> signed(String method, String path, [List<int> body = const []]) => DeviceRequest.sign(
        keys: f.phone.keys,
        method: method,
        url: f.base.resolve(path),
        body: body,
        hub: f.hubDen.deviceId,
        actorId: f.phone.actor?.id,
      );

  Future<List<Map<String, Object?>>> waiting() async {
    const path = '/api/v1/connections/requests';
    final r = await f.call('GET', path, headers: await signed('GET', path));
    expect(r.status, 200);
    return [for (final x in r.body['requests'] as List) (x as Map).cast<String, Object?>()];
  }

  Future<ApiResult> decide(String request, String decision) async {
    final path = '/api/v1/connections/requests/$request';
    final body = jsonEncode({'decision': decision});
    return f.call('POST', path, body: body, headers: await signed('POST', path, utf8.encode(body)));
  }

  test('register, authorize with a parent letting it in and approving on a synced phone, exchange, use, refresh', () async {
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
    final changes = f.hubDen.changesSince(const {}).length;
    final (id, page) = await authorize(clientId, challenge);
    expect(page, contains('<strong>claude.ai</strong>'), reason: 'the page says where the app signs in, not only its name');
    final shown = RegExp(r'class="code">([A-Z0-9-]+)<').firstMatch(page)!.group(1)!;
    expect((await status(id))['state'], 'pending');
    expect(f.hubDen.changesSince(const {}).length, changes, reason: 'nothing reaches the family\'s log before a parent acts');
    expect(f.phone.connections.where((c) => c.client == clientId), isEmpty);

    expect((await f.call('GET', '/api/v1/connections/requests')).status, 401, reason: 'only a family device may look');
    final request = (await waiting()).firstWhere((r) => r['code'] == shown);
    expect(request['client_name'], 'Claude');
    expect(request['redirect_host'], 'claude.ai');
    expect(request['scopes'], ['read', 'lists']);
    final admitted = await decide(request['id'] as String, 'admit');
    expect(admitted.status, 200);
    final connection = admitted.body['connection'] as String;
    expect((await decide(request['id'] as String, 'admit')).body['connection'], connection, reason: 'admitting twice is the same');

    await eventually(() => f.phone.connections.any((c) => c.id == connection && c.status == ConnectionStatus.pending));
    final pending = f.phone.connections.firstWhere((c) => c.id == connection);
    expect(pending.label, 'Claude (claude.ai)');
    expect(pending.client, clientId);
    expect(pending.scopes, {Scope.read, Scope.lists});
    await f.phone.approveConnection(pending.id, scopes: {Scope.read, Scope.lists});

    Map<String, Object?> decided = {};
    await eventually(() async => (decided = await status(id))['state'] == 'approved');
    final back = Uri.parse(decided['redirect'] as String);
    expect(back.toString(), startsWith(redirect));
    expect(back.queryParameters['state'], 'xyz');
    final code = back.queryParameters['code']!;

    final logged = f.hubDen.changesSince(const {}).length;
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
    // The hourly token lives in the hub's own state, never in the family's log.
    expect(f.hubDen.connections.firstWhere((c) => c.id == pending.id).tokenHash, isNull);
    expect(f.hubDen.connections.firstWhere((c) => c.id == pending.id).expires, isNull);
    expect(f.hub.context.oauthStore.accessConnection(access, DateTime.now().millisecondsSinceEpoch), pending.id);

    final refreshed = await form('/oauth/token', {'grant_type': 'refresh_token', 'refresh_token': tokens['refresh_token'] as String, 'client_id': clientId});
    expect(refreshed['status'], 200);
    expect(refreshed['refresh_token'], isNot(tokens['refresh_token']));
    expect((await f.call('GET', '/api/v1/members', token: access)).status, 401, reason: 'the old access token stopped');
    expect((await f.call('GET', '/api/v1/members', token: refreshed['access_token'] as String)).status, 200);
    final reuse = await form('/oauth/token', {'grant_type': 'refresh_token', 'refresh_token': tokens['refresh_token'] as String, 'client_id': clientId});
    expect(reuse['error'], 'invalid_grant');
    expect((await f.call('GET', '/api/v1/members', token: refreshed['access_token'] as String)).status, 401,
        reason: 'reusing a refresh token ends the connection\'s tokens');
    expect(f.hubDen.changesSince(const {}).length, logged, reason: 'issuing and refreshing tokens writes nothing to the log');
  });

  test('a parent turning an app off ends its token at once', () async {
    final pending = await f.phone.requestOAuthConnection(label: 'Claude', client: 'c1', scopes: {Scope.read});
    await f.phone.approveConnection(pending, scopes: {Scope.read});
    await eventually(() => f.hubDen.connections.any((c) => c.id == pending && c.status == ConnectionStatus.active));
    const token = 'den_an-access-token-the-hub-issued';
    await f.hub.context.oauthStore.issueAccess(token,
        connection: pending, client: 'c1', expires: DateTime.now().millisecondsSinceEpoch + 3600000);
    expect((await f.call('GET', '/api/v1/members', token: token)).status, 200);
    await f.phone.revokeConnection(pending);
    await eventually(() => f.hubDen.connections.any((c) => c.id == pending && c.status == ConnectionStatus.revoked));
    expect((await f.call('GET', '/api/v1/members', token: token)).status, 401);
  });

  test('a token an older hub wrote into the log moves to the hub\'s state and keeps working', () async {
    final id = await f.hubDen.requestOAuthConnection(label: 'ChatGPT', client: 'c2', scopes: {Scope.read});
    await f.toPhone();
    await f.phone.approveConnection(id, scopes: {Scope.read});
    await f.toHub();
    const token = 'den_a-token-from-an-older-hub';
    await f.hubDen.setConnectionToken(id, hashToken(token), expires: DateTime.now().millisecondsSinceEpoch + 3600000);
    await f.hub.oauth.adoptLoggedTokens();
    final record = f.hubDen.connections.firstWhere((c) => c.id == id);
    expect(record.tokenHash, isNull, reason: 'gone from the log');
    expect(record.expires, isNull);
    expect((await f.call('GET', '/api/v1/members', token: token)).status, 200, reason: 'the app\'s token still works');
    final after = f.hubDen.changesSince(const {}).length;
    await f.hub.oauth.adoptLoggedTokens();
    expect(f.hubDen.changesSince(const {}).length, after, reason: 'once');
  });

  test('a parent declining sends the app back with access_denied', () async {
    final clientId = await register();
    final (id, _) = await authorize(clientId, 'c' * 43, state: 'nope');
    final request = (await waiting()).first;
    expect((await decide(request['id'] as String, 'decline')).status, 200);
    expect(f.hubDen.connections.where((c) => c.client == clientId), isEmpty, reason: 'declined before it reached the log');
    Map<String, Object?> decided = {};
    await eventually(() async => (decided = await status(id))['state'] == 'declined');
    final back = Uri.parse(decided['redirect'] as String);
    expect(back.queryParameters['error'], 'access_denied');
    expect(back.queryParameters['state'], 'nope');
    expect((await decide(request['id'] as String, 'admit')).status, 409);
  });

  test('requests nobody answers expire, and pending connections left in the log are turned down', () async {
    // Earlier hubs wrote a pending connection for every request; a stranger's is still there.
    final old = await f.phone.requestOAuthConnection(label: 'Home Assistant', client: 'made-up', scopes: {Scope.admin});
    await eventually(() => f.hubDen.connections.any((c) => c.id == old));
    final clientId = await register();
    final (id, _) = await authorize(clientId, 'd' * 43);
    final request = (await waiting()).first;
    final admitted = (await decide(request['id'] as String, 'admit')).body['connection'] as String;
    await f.hub.oauth.sweep(now: DateTime.now().millisecondsSinceEpoch + const Duration(minutes: 16).inMilliseconds);
    ConnectionStatus statusOf(String connection) => f.hubDen.connections.firstWhere((c) => c.id == connection).status;
    expect(statusOf(old), ConnectionStatus.revoked);
    expect(statusOf(admitted), ConnectionStatus.revoked, reason: 'admitted but never approved in time');
    expect((await waiting()).where((r) => r['id'] == request['id']), isEmpty);
    expect((await status(id))['state'], 'declined');
  });

  test('one address can only start so many sign-ins', () async {
    final clientId = await register();
    var limited = false;
    for (var i = 0; i <= Limits.oauthAuthorize.burst && !limited; i++) {
      final page = await http.get(f.base.replace(path: '/oauth/authorize', queryParameters: {
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirect,
        'code_challenge': 'e' * 43,
        'code_challenge_method': 'S256',
      }));
      if (page.statusCode == 429) {
        limited = true;
        expect(page.body, contains('Too many sign-in requests from here'));
      }
    }
    expect(limited, isTrue);
  });

  test('authorize refuses unknown clients, unregistered redirects and missing PKCE', () async {
    final unknown = await http.get(f.base.replace(path: '/oauth/authorize', queryParameters: {'client_id': 'nope', 'response_type': 'code'}));
    expect(unknown.statusCode, 400);
    expect(unknown.body, contains('This sign-in link doesn'));
    expect(unknown.headers['content-security-policy'], contains("script-src 'nonce-"));
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
