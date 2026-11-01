@Timeout(Duration(seconds: 180))
library;

import 'dart:convert';
import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_hub/src/edge.dart' show Limits;

import 'support/browser.dart';
import 'support/fake_idp.dart';
import 'support/fixture.dart';
import 'support/host_fixture.dart';
import 'support/oidc_keys.dart';
import 'support/sign_in.dart';
import 'support/test.dart';

/// Setting up signing in with Google and Apple from a parent's phone (sign_in_setup.dart): who
/// may, what is kept where, what answers say, and that it takes effect at once.
void main() {
  const googleId = '1234567890-denhubtest.apps.googleusercontent.com';
  const googleSecret = 'GOCSPX-not-for-anyone-else';
  final public = Uri.parse('https://den.test');

  late FakeIdp google;
  late FakeIdp apple;
  final logged = <String>[];

  setUp(() async {
    logged.clear();
    google = await FakeIdp.start(clientId: googleId, clientSecret: googleSecret);
    apple = await FakeIdp.start(apple: true, clientId: 'family.den.signin');
  });

  tearDown(() async {
    await google.stop();
    await apple.stop();
  });

  HubConfig configFor(HubConfig base, {Uri? url, String? dataDir}) => HubConfig(
        port: 0,
        host: InternetAddress.loopbackIPv4,
        mdns: false,
        dataDir: dataDir,
        log: HubLog(level: LogLevel.debug, sink: logged.add),
        publicUrl: url ?? public,
        fetchClient: fakeProviderGuard().client(),
        signInIssuers: issuersOf(google: google, apple: apple),
      );

  Future<Answer> signed(HubFixture f, Den den, String method, String path, {Object? body}) =>
      signedCall(f.base, den, method, path, hub: f.hubDen.deviceId, body: body);

  Map<String, Object?> googleBody({String id = googleId, String secret = googleSecret}) => {'client_id': id, 'client_secret': secret};
  Map<String, Object?> appleBody({String key = appleP8}) =>
      {'services_id': apple.clientId, 'team_id': apple.teamId, 'key_id': apple.keyId, 'key': key};

  /// Everything that must never come back or reach the log.
  final secrets = [googleId, googleSecret, 'MIGHAgEAMBMGByqGSM49', 'TEAM123456', 'KEY7654321', 'family.den.signin'];

  void neverSays(String text) {
    for (final s in secrets) {
      expect(text, isNot(contains(s)), reason: 'says $s');
    }
  }

  /// A personal device approved by [f]'s phone for [name], or a shared display, or [name]'s
  /// device in hub mode.
  Future<Den> device(HubFixture f, String? name, {DeviceMode mode = DeviceMode.personal}) async {
    final d = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    final member = name == null ? null : f.id(name);
    await d.requestJoin(
      familyId: f.phone.familyId!,
      founderPubkey: f.phone.founderPubkey!,
      deviceName: '${name ?? 'Kitchen'} device',
      kind: mode == DeviceMode.shared ? DeviceKind.display : DeviceKind.phone,
      mode: mode,
      memberId: member,
    );
    await f.phone.ingest(d.changesSince(const {}));
    await f.phone.approveDevice(d.deviceId, member: member, mode: mode);
    await d.ingest(f.phone.changesSince(d.versionVector, spaces: f.phone.spacesForDevice(d.deviceId)), through: f.phone.completeVector);
    await f.toHub();
    addTearDown(d.close);
    return d;
  }

  group('one family', () {
    late HubFixture f;
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('den_sign_in_setup');
      f = await HubFixture.start(dataDir: dir.path, configure: (base) => configFor(base, dataDir: dir.path));
    });

    tearDown(() async {
      await f.stop();
      await dir.delete(recursive: true);
    });

    test('off until a parent turns it on from their phone; then it signs in at once, with no restart', () async {
      expect((await Browser(f.base).go('GET', '/auth/oidc/google/start')).status, 404);
      final before = await signed(f, f.phone, 'GET', '/api/v1/hub/sign-in');
      expect(before.status, 200, reason: before.body);
      final json = before.json! as Map;
      expect(json['google'], {'on': false, 'redirect_urls': ['https://den.test/auth/oidc/google/callback']});
      expect((json['apple'] as Map)['domains'], ['den.test']);
      expect((json['apple'] as Map)['return_urls'], ['https://den.test/auth/oidc/apple/callback']);
      expect(json['https'], isTrue);

      final changes = f.hubDen.changesSince(const {}).length;
      final on = await signed(f, f.phone, 'PUT', '/api/v1/hub/sign-in/google', body: googleBody());
      expect(on.status, 200, reason: on.body);
      expect(((on.json! as Map)['google'] as Map)['on'], isTrue);
      expect(((on.json! as Map)['google'] as Map)['set_by'], 'Alex');
      expect(google.discoveryFetches, greaterThan(0));

      final start = await Browser(f.base).go('GET', '/auth/oidc/google/start');
      expect(start.status, 302, reason: 'on at once');
      expect(start.location, startsWith('${google.issuer}/authorize'));
      expect(Uri.parse(start.location!).queryParameters['client_id'], googleId);
      expect(f.hub.accounts.enabled, isTrue);
      expect(f.hubDen.changesSince(const {}).length, changes, reason: 'nothing of it goes into the family\'s log');

      final off = await signed(f, f.phone, 'DELETE', '/api/v1/hub/sign-in/google');
      expect(off.status, 200);
      expect(((off.json! as Map)['google'] as Map)['on'], isFalse);
      expect((await Browser(f.base).go('GET', '/auth/oidc/google/start')).status, 404, reason: 'off at once');
    });

    test('kept owner-only in the hub\'s own data, in no answer and no log line, and read again after a restart', () async {
      final answers = [
        await signed(f, f.phone, 'PUT', '/api/v1/hub/sign-in/google', body: googleBody()),
        await signed(f, f.phone, 'PUT', '/api/v1/hub/sign-in/apple', body: appleBody()),
        await signed(f, f.phone, 'GET', '/api/v1/hub/sign-in'),
      ];
      for (final a in answers) {
        expect(a.status, 200, reason: a.body);
        neverSays(a.body);
        expect(a.header('cache-control'), 'no-store');
      }
      neverSays(logged.join('\n'));
      expect(logged.any((l) => l.contains('Alex turned on signing in with Google')), isTrue);

      final file = File('${dir.path}/hub/$signInFile');
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), contains(googleSecret), reason: 'what the hub needs is there');
      expect(File('${file.path}.tmp').existsSync(), isFalse);
      if (!Platform.isWindows) {
        expect(file.statSync().mode & 0x1ff, 0x180, reason: '0600');
        expect(file.parent.statSync().mode & 0x1ff, 0x1c0, reason: '0700');
      }

      await f.hub.stop();
      final again = await DenHub.start(f.hubDen, f.hub.config);
      addTearDown(again.stop);
      expect(again.accounts.providers!.all.map((p) => p.id), [googleProvider, appleProvider]);
      expect((await Browser(again.localUrl).go('GET', '/auth/oidc/apple/start')).status, 302);
    });

    test('only a parent, on their own personal phone', () async {
      final maya = await device(f, 'Maya');
      final kitchen = await device(f, null, mode: DeviceMode.shared);
      final tablet = await device(f, 'Alex', mode: DeviceMode.hub);
      final priya = await device(f, 'Priya');
      for (final (who, den) in [('a kid', maya), ('a shared screen', kitchen), ('a parent\'s hub-mode tablet', tablet)]) {
        for (final (method, body) in [('GET', null), ('PUT', googleBody()), ('DELETE', null)]) {
          final a = await signed(f, den, method, method == 'GET' ? '/api/v1/hub/sign-in' : '/api/v1/hub/sign-in/google', body: body);
          expect(a.status, 403, reason: '$who $method: ${a.body}');
          neverSays(a.body);
        }
      }
      expect(f.hub.host.signIn.isOn(googleProvider), isFalse);
      final unsigned = await Browser(f.base).go('GET', '/api/v1/hub/sign-in');
      expect(unsigned.status, 401);
      final token = await f.token(scopes: {Scope.read, Scope.admin});
      expect((await f.call('PUT', '/api/v1/hub/sign-in/google', token: token, body: googleBody())).status, 401);
      expect(f.hub.host.signIn.isOn(googleProvider), isFalse);

      final ok = await signed(f, priya, 'PUT', '/api/v1/hub/sign-in/google', body: googleBody());
      expect(ok.status, 200, reason: 'the other parent may, from her own phone');
      expect(((ok.json! as Map)['google'] as Map)['set_by'], 'Priya');
      expect((await signed(f, maya, 'DELETE', '/api/v1/hub/sign-in/google')).status, 403);
      expect(f.hub.host.signIn.isOn(googleProvider), isTrue);
    });

    test('what a parent pasted is checked with Google and Apple first, and nothing is kept until it holds', () async {
      Future<Answer> put(String provider, Map<String, Object?> body) => signed(f, f.phone, 'PUT', '/api/v1/hub/sign-in/$provider', body: body);
      Map<String, Object?> error(Answer a) => ((a.json! as Map)['error'] as Map).cast<String, Object?>();

      final swapped = await put('google', googleBody(id: googleSecret, secret: googleId));
      expect(swapped.status, 400);
      expect(error(swapped)['field'], 'client_id');
      expect(error(swapped)['message'], contains('client secret'));
      final typo = await put('google', googleBody(id: 'den-client.apps.example'));
      expect(error(typo)['message'], contains('apps.googleusercontent.com'));

      final calls = google.tokenCalls;
      final wrong = await put('google', googleBody(secret: 'GOCSPX-someone-elses'));
      expect(wrong.status, 400, reason: wrong.body);
      expect(error(wrong)['message'], contains('doesn\'t know that client ID and secret'));
      expect(google.tokenCalls, calls + 1, reason: 'Google was asked');
      neverSays(wrong.body);

      google.webClient = false;
      final desktop = await put('google', googleBody());
      expect(error(desktop)['message'], contains('Web application'));
      google.webClient = true;

      google.discovery = {'issuer': 'https://somewhere.else'};
      final unreachable = await put('google', googleBody());
      expect(unreachable.status, 502);
      expect(error(unreachable)['code'], 'provider_unreachable');
      expect(f.hub.host.signIn.isOn(googleProvider), isFalse, reason: 'nothing was kept');
      expect(File('${dir.path}/hub/$signInFile').existsSync(), isFalse);

      final notKey = await put('apple', appleBody(key: 'not a key'));
      expect(notKey.status, 400);
      expect(error(notKey)['field'], 'key');
      final team = await put('apple', {...appleBody(), 'team_id': 'abc'});
      expect(error(team)['field'], 'team_id');
      final otherKey = await put('apple', appleBody(key: otherP8));
      expect(otherKey.status, 400, reason: 'Apple refused the client secret it signs');
      expect(error(otherKey)['message'], contains('Apple didn\'t take'));
      expect(f.hub.host.signIn.isOn(appleProvider), isFalse);
      final lower = await put('apple', {...appleBody(), 'team_id': apple.teamId.toLowerCase()});
      expect(lower.status, 200, reason: lower.body);
      expect((await signed(f, f.phone, 'PUT', '/api/v1/hub/sign-in/facebook', body: googleBody())).status, 404);
    });

    test('each try asks the provider, so tries are limited', () async {
      for (var i = 0; i < Limits.signInSetup.burst; i++) {
        expect((await signed(f, f.phone, 'PUT', '/api/v1/hub/sign-in/google', body: googleBody(secret: 'GOCSPX-wrong-$i'))).status, 400);
      }
      final limited = await signed(f, f.phone, 'PUT', '/api/v1/hub/sign-in/google', body: googleBody());
      expect(limited.status, 429);
      expect(f.hub.host.signIn.isOn(googleProvider), isFalse);
    });
  });

  test('a hub without an https address says so and turns nothing on', () async {
    final f = await HubFixture.start(configure: (base) => configFor(base, url: Uri.parse('http://den.local:47733')));
    addTearDown(f.stop);
    final status = await signed(f, f.phone, 'GET', '/api/v1/hub/sign-in');
    expect((status.json! as Map)['https'], isFalse);
    expect((status.json! as Map)['without_https'], ['den.local']);
    expect(((status.json! as Map)['google'] as Map)['redirect_urls'], isEmpty);
    final on = await signed(f, f.phone, 'PUT', '/api/v1/hub/sign-in/google', body: googleBody());
    expect(on.status, 409);
    expect(f.hub.host.signIn.isOn(googleProvider), isFalse);
  });

  group('one host, two families', () {
    late HostFixture host;

    setUp(() async {
      host = await HostFixture.start(
        configure: (c) => HostConfig(
          port: c.port,
          host: c.host,
          log: HubLog(level: LogLevel.debug, sink: logged.add),
          fetchClient: fakeProviderGuard().client(),
          signInIssuers: issuersOf(google: google, apple: apple),
        ),
      );
    });

    tearDown(() => host.stop());

    Future<Answer> at(String name, Den den, String method, String path, {Object? body}) =>
        signedCall(host.base, den, method, path, hub: host[name].hubDen.deviceId, body: body, hostname: name);

    test("only the host's own family sets it up; the other family's parents can't see or change it", () async {
      final a = host['den-a.test'], b = host['den-b.test'];
      expect(host.host.ownFamily, same(a.hub));
      for (final (method, path, body) in [
        ('GET', '/api/v1/hub/sign-in', null),
        ('PUT', '/api/v1/hub/sign-in/google', googleBody()),
        ('DELETE', '/api/v1/hub/sign-in/google', null),
      ]) {
        final answer = await at('den-b.test', b.phone, method, path, body: body);
        expect(answer.status, 403, reason: '$method: ${answer.body}');
        expect(((answer.json! as Map)['error'] as Map)['code'], 'host_family_only');
        expect(answer.body, isNot(contains('den-a.test')), reason: 'it learns nothing of the other families');
      }
      expect(host.host.signIn.isOn(googleProvider), isFalse);
      // Signed for the host family's hub by the other family's phone: that hub doesn't know it.
      final crossed = await signedCall(host.base, b.phone, 'PUT', '/api/v1/hub/sign-in/google',
          hub: a.hubDen.deviceId, body: googleBody(), hostname: 'den-a.test');
      expect(crossed.status, 401);

      final status = await at('den-a.test', a.phone, 'GET', '/api/v1/hub/sign-in');
      expect(status.status, 200, reason: status.body);
      expect(((status.json! as Map)['google'] as Map)['redirect_urls'],
          ['https://den-a.test/auth/oidc/google/callback', 'https://den-b.test/auth/oidc/google/callback'],
          reason: 'every family\'s address, the host\'s own first');
      expect(((status.json! as Map)['apple'] as Map)['domains'], ['den-a.test', 'den-b.test']);

      expect((await at('den-a.test', a.phone, 'PUT', '/api/v1/hub/sign-in/google', body: googleBody())).status, 200);
      for (final name in ['den-a.test', 'den-b.test']) {
        final start = await Browser(host.base, hostname: name).go('GET', '/auth/oidc/google/start');
        expect(start.status, 302, reason: '$name signs in at once');
        expect(Uri.parse(start.location!).queryParameters['redirect_uri'], 'https://$name/auth/oidc/google/callback');
      }
      neverSays(logged.join('\n'));
    });

    test('a family the host adds later is listed too', () async {
      final a = host['den-a.test'];
      await HostFixture.addFamily(host.host, 'den-c.test');
      final status = await at('den-a.test', a.phone, 'GET', '/api/v1/hub/sign-in');
      expect(((status.json! as Map)['google'] as Map)['redirect_urls'], contains('https://den-c.test/auth/oidc/google/callback'));
    });
  });

  test('settings that can\'t be read leave sign-in off and say so, never what they hold', () async {
    final dir = await Directory.systemTemp.createTemp('den_sign_in_broken');
    addTearDown(() => dir.delete(recursive: true));
    Directory('${dir.path}/hub').createSync(recursive: true);
    File('${dir.path}/hub/$signInFile').writeAsStringSync(jsonEncode({
      'google': {'client_id': googleId},
      'apple': {'services_id': 'family.den.signin', 'team_id': 'TEAM123456', 'key_id': 'KEY7654321', 'key': 'nope'},
    }));
    final f = await HubFixture.start(dataDir: dir.path, configure: (base) => configFor(base, dataDir: dir.path));
    addTearDown(f.stop);
    expect(f.hub.accounts.providers, isNull);
    expect(logged.where((l) => l.contains('can\'t be read')), hasLength(2));
    neverSays(logged.join('\n'));
  });
}
