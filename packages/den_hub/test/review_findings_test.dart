@Timeout(Duration(seconds: 180))
library;

import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:http/http.dart' as http;

import 'support/browser.dart';
import 'support/fake_idp.dart';
import 'support/fixture.dart';
import 'support/test.dart';

/// The security review's proofs for PR #41, ported with their assertions turned around: each
/// test showed a finding, and now shows it fixed. (F3 is in den_core's account_test, F5 in the
/// app's, F7 in oidc_test.)

/// The hub's fetch client, with discovery taking [delay] (a real provider over the internet).
class _SlowDiscovery extends http.BaseClient {
  _SlowDiscovery(this.inner, this.delay);
  final http.Client inner;
  final Duration delay;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/openid-configuration')) await Future<void>.delayed(delay);
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}

void main() {
  final public = Uri.parse('https://den.test');

  HubConfig configFor(HubConfig base, FakeIdp google, {http.Client? fetch, List<IpNetwork> proxies = const []}) => HubConfig(
        port: 0,
        host: InternetAddress.loopbackIPv4,
        mdns: false,
        log: base.log,
        publicUrl: public,
        trustedProxies: proxies,
        fetchClient: fetch ?? fakeProviderGuard().client(),
        signIn: SignInProviders(
            google: OidcProvider.google(clientId: google.clientId, clientSecret: google.clientSecret, issuer: google.issuerUri)),
      );

  Future<Map<String, Object?>> binding(HubFixture f) async {
    final started = await signedCall(f.base, f.phone, 'POST', '/api/v1/account/bindings', hub: f.hubDen.deviceId, body: {'provider': 'google'});
    expect(started.status, 201);
    return (started.json! as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> poll(HubFixture f, Map<String, Object?> b) async =>
      ((await signedCall(f.base, f.phone, 'GET', '/api/v1/account/bindings/${b['id']}', hub: f.hubDen.deviceId)).json! as Map)
          .cast<String, Object?>();

  late FakeIdp google;
  setUp(() async => google = await FakeIdp.start());
  tearDown(() => google.stop());

  test('F1: a start link used twice while discovery is in flight binds neither person', () async {
    final f = await HubFixture.start(
        configure: (base) => configFor(base, google, fetch: _SlowDiscovery(fakeProviderGuard().client(), const Duration(milliseconds: 300))));
    addTearDown(f.stop);
    final b = await binding(f);
    final ticket = Uri.parse(b['start_url'] as String).queryParameters['bind']!;
    final parent = Browser(f.base), attacker = Browser(f.base);
    Future<Answer> press(Browser who) =>
        who.go('POST', '/auth/oidc/google/start', form: 'bind=$ticket', headers: {'origin': 'https://den.test'});
    final opened = await Future.wait([press(parent), press(attacker)]);
    // One got a sign-in; the other spoiled the binding.
    expect(opened.map((a) => a.status).toList()..sort(), [302, 400]);
    final won = opened[0].status == 302 ? (parent, opened[0]) : (attacker, opened[1]);
    final at = Uri.parse(won.$2.location!);
    final code = google.signIn(at, sub: 'mallory-sub', email: 'mallory@example.net');
    await won.$1.go('GET', '/auth/oidc/google/callback?code=$code&state=${at.queryParameters['state']}');
    final result = await poll(f, b);
    expect(result['state'], 'failed');
    expect(result.containsKey('account'), isFalse, reason: 'the phone is handed nobody\'s account');
  });

  test('F2: a few addresses can\'t fill the sign-ins in flight; nobody is turned away, and bindings are never pushed out', () async {
    final f = await HubFixture.start(configure: (base) => configFor(base, google, proxies: [IpNetwork.parse('127.0.0.1/32')]));
    addTearDown(f.stop);
    f.hub.accounts.maxFlows = 20;
    // A binding under way first, then a flood from many addresses.
    final b = await binding(f);
    final parent = Browser(f.base);
    final mine = await parent.confirm(b['start_url'] as String);
    expect(mine.status, 302);
    final stranger = Browser(f.base);
    for (var i = 0; i < 120; i++) {
      final a = await stranger.go('GET', '/auth/oidc/google/start', headers: {'x-forwarded-for': '198.51.100.${i ~/ 6}'});
      expect(a.status, 302, reason: '$i');
    }
    expect(f.hub.accounts.flowCount, lessThanOrEqualTo(20));
    // Someone new still gets a sign-in, and finishes it.
    final someone = Browser(f.base);
    final hers = await someone.go('GET', '/auth/oidc/google/start', headers: {'x-forwarded-for': '203.0.113.9'});
    expect(hers.status, 302);
    // The binding's sign-in survived the flood.
    final at = Uri.parse(mine.location!);
    final back = await parent.go('GET', '/auth/oidc/google/callback?code=${google.signIn(at, sub: 'alex-sub')}&state=${at.queryParameters['state']}');
    expect(back.status, 200, reason: back.body);
    expect((await poll(f, b))['state'], 'done');
  });

  test('F2: one client keeps only its last few sign-ins in flight', () async {
    final f = await HubFixture.start(configure: (base) => configFor(base, google));
    addTearDown(f.stop);
    final b = Browser(f.base);
    final first = await b.go('GET', '/auth/oidc/google/start');
    final flow = b.cookies[HubAccounts.flowCookie]!;
    for (var i = 0; i < HubAccounts.maxFlowsPerClient; i++) {
      await Browser(f.base).go('GET', '/auth/oidc/google/start');
    }
    expect(f.hub.accounts.flowCount, HubAccounts.maxFlowsPerClient);
    final at = Uri.parse(first.location!);
    final late = Browser(f.base)..cookies[HubAccounts.flowCookie] = flow;
    final back = await late.go('GET', '/auth/oidc/google/callback?code=${google.signIn(at, sub: 'x')}&state=${at.queryParameters['state']}');
    expect(back.status, 400, reason: 'its oldest made room');
  });

  test('F4: a parent made a kid keeps a binding that signs in as nobody, and their session ends', () async {
    final f = await HubFixture.start(configure: (base) => configFor(base, google));
    addTearDown(f.stop);
    final alex = f.id('Alex');
    final b = await binding(f);
    await Browser(f.base).signIn(google, sub: 'alex-sub', start: b['start_url'] as String);
    await f.phone.setAccount(alex, AccountRef.fromJson((await poll(f, b))['account'])!);
    await f.toHub();
    final before = Browser(f.base);
    expect((await before.signIn(google, sub: 'alex-sub')).status, 200);
    expect((await before.go('GET', '/api/v1/me')).status, 200);

    await f.phone.updateMember(alex, {'role': Role.kid.name});
    await f.toHub();
    expect(f.hubDen.member(alex)!.account, isNotNull, reason: 'dormant: it stays, and does nothing');
    expect((await before.go('GET', '/api/v1/me')).status, 401);
    final after = Browser(f.base);
    expect((await after.signIn(google, sub: 'alex-sub')).status, 403);
    expect((await after.go('GET', '/api/v1/me')).status, 401);
  });
}
