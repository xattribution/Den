@Timeout(Duration(seconds: 120))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';
import 'support/host_fixture.dart';
import 'support/passkey.dart';

const _origin = 'https://den.example.com';

/// Passkeys: a family member's own device makes one, and signing in with it lets that person's
/// new device ask in under the family's trust rules, never anyone else.
void main() {
  group('the hub', () {
    late Directory dir;
    late HubFixture f;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('den-passkeys');
      f = await HubFixture.start(dataDir: dir.path, configure: (c) => _at(c, Uri.parse(_origin)));
    });

    tearDown(() async {
      await f.stop();
      await dir.delete(recursive: true);
    });

    Future<ApiResult> signed(Den den, String method, String path, {Object? body}) async {
      final bytes = body == null ? <int>[] : utf8.encode(jsonEncode(body));
      final headers = await DeviceRequest.sign(
        keys: den.keys,
        method: method,
        url: f.base.resolve(path),
        body: bytes,
        hub: f.hubDen.deviceId,
        actorId: den.actor?.id,
      );
      return f.call(method, path, body: body, headers: headers);
    }

    /// [den]'s person makes [key] on it: the options, then the browser's answer.
    Future<ApiResult> make(Den den, FakePasskey key, {String origin = _origin, bool uv = true}) async {
      final options = await signed(den, 'POST', '/api/v1/passkeys/options', body: const <String, Object?>{});
      expect(options.status, 200, reason: options.text);
      final o = (options.body['options']! as Map).cast<String, Object?>();
      return signed(den, 'POST', '/api/v1/passkeys', body: {'credential': key.register(o, origin: origin, uv: uv)});
    }

    Future<Map<String, Object?>> signInOptions() async {
      final r = await f.call('POST', '/api/v1/passkeys/sign-in/options');
      expect(r.status, 200, reason: r.text);
      return (r.body['options']! as Map).cast<String, Object?>();
    }

    Future<ApiResult> signIn(FakePasskey key, String pubkey, {Map<String, Object?>? options, bool uv = true, String origin = _origin}) async {
      final o = options ?? await signInOptions();
      return f.call('POST', '/api/v1/passkeys/sign-in', body: {'credential': key.assert_(o, origin: origin, uv: uv), 'pubkey': pubkey});
    }

    test('a person\'s own phone makes a passkey for the family\'s own address; nothing to configure', () async {
      final options = await signed(f.phone, 'POST', '/api/v1/passkeys/options', body: const <String, Object?>{});
      expect(options.status, 200, reason: options.text);
      final o = options.body['options']! as Map;
      expect(o['rp'], {'id': 'den.example.com', 'name': 'Den'});
      expect((o['user']! as Map)['displayName'], 'Alex');
      expect((o['user']! as Map)['name'], 'Alex (${f.phone.family!.name})');
      expect((o['user']! as Map)['id'], isNot(f.id('Alex')), reason: 'the handle is random, never the member id');
      expect(o['attestation'], 'none');
      expect(o['authenticatorSelection'], containsPair('userVerification', 'required'));
      expect(o['authenticatorSelection'], containsPair('residentKey', 'required'));
      expect([for (final p in o['pubKeyCredParams']! as List) (p as Map)['alg']], [-7, -257]);
      expect(options.body['existing'], 0);

      final key = FakePasskey.make();
      final made = await signed(f.phone, 'POST', '/api/v1/passkeys',
          body: {'credential': key.register((o).cast<String, Object?>(), origin: _origin)});
      expect(made.status, 201, reason: made.text);
      expect(made.body['id'], key.credentialId);
      expect(made.body['made_on'], "Alex's phone");

      final list = await signed(f.phone, 'GET', '/api/v1/passkeys');
      expect([for (final p in list.body['passkeys']! as List) (p as Map)['id']], [key.credentialId]);
      final again = await signed(f.phone, 'POST', '/api/v1/passkeys/options', body: const <String, Object?>{});
      expect(again.body['existing'], 1);
      expect((again.body['options']! as Map)['excludeCredentials'], [
        {'type': 'public-key', 'id': key.credentialId},
      ], reason: 'a phone that holds it already says so instead of making another');

      final file = File('${dir.path}/hub/$passkeysDoc.json');
      expect(file.readAsStringSync(), contains(key.credentialId));
      if (!Platform.isWindows) expect(file.statSync().mode & 0x3f, 0, reason: 'nobody but the hub\'s user reads it');
      final backup = await readBackupFiles(dir.path);
      expect(backup.keys, contains('hub/$passkeysDoc.json'), reason: 'backups keep passkeys');
      expect(jsonEncode([for (final c in f.hubDen.changesSince(const {})) c.toJson()]), isNot(contains(key.credentialId)),
          reason: 'never in the family\'s log');
    });

    test('making one needs the person\'s own device, a challenge it asked for, and Face ID', () async {
      expect((await f.call('POST', '/api/v1/passkeys/options', body: const <String, Object?>{})).status, 401);
      final screen = await _device(f, 'Kitchen', DeviceMode.shared);
      expect((await signed(screen, 'POST', '/api/v1/passkeys/options', body: const <String, Object?>{})).status, 403);

      expect((await make(f.phone, FakePasskey.make(), uv: false)).status, 400, reason: 'the person must be verified');
      expect((await make(f.phone, FakePasskey.make(), origin: 'https://evil.example')).status, 400);

      // A challenge Maya's phone asked for isn't Alex's to use.
      final maya = await _device(f, 'Maya phone', DeviceMode.personal, member: f.id('Maya'));
      final mine = await signed(maya, 'POST', '/api/v1/passkeys/options', body: const <String, Object?>{});
      final o = (mine.body['options']! as Map).cast<String, Object?>();
      final stolen = await signed(f.phone, 'POST', '/api/v1/passkeys', body: {'credential': FakePasskey.make().register(o, origin: _origin)});
      expect(stolen.status, 400);
      // Used once: Maya can't use it after the refusal either.
      final again = await signed(maya, 'POST', '/api/v1/passkeys', body: {'credential': FakePasskey.make().register(o, origin: _origin)});
      expect(again.status, 400);

      // Another algorithm, or a point off the curve.
      final options = await signed(f.phone, 'POST', '/api/v1/passkeys/options', body: const <String, Object?>{});
      final ed = FakePasskey.make().register((options.body['options']! as Map).cast<String, Object?>(),
          origin: _origin, cose: {1: 1, 3: -8, -1: 6, -2: Uint8List(32)});
      expect((await signed(f.phone, 'POST', '/api/v1/passkeys', body: {'credential': ed})).status, 400);
    });

    test("a parent signs back in at once while the hub may help; every device sees how", () async {
      final key = FakePasskey.make();
      expect((await make(f.phone, key)).status, 201);
      // "Let the hub help us get back in".
      final hubKey = await signed(f.phone, 'GET', '/api/v1/recovery/key');
      await f.phone.setServerRecoveryKey(hubKey.body['key']! as String);
      await f.toHub();

      final phone = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
      addTearDown(phone.close);
      final r = await signIn(key, phone.keys.pubkey);
      expect(r.status, 200, reason: r.text);
      expect(r.body['member'], f.id('Alex'));
      expect(r.body['member_name'], 'Alex');
      expect(r.body['lets_in'], isTrue);
      final proof = RecoveryProof.parse(r.body['proof'])!;
      expect(proof.kind, RecoveryKind.hub);

      final node = SyncNode(phone);
      addTearDown(node.close);
      final attempt = await node.joinWithRecoveryProof(
        await connectWebSocket(f.base.replace(scheme: 'ws', path: '/ws')),
        await Invite.parse(r.body['invite']! as String),
        proof,
        deviceName: "Alex's new iPhone",
        kind: DeviceKind.phone,
      );
      await attempt.completed;
      expect(phone.isApproved, isTrue);
      expect(phone.owner?.name, 'Alex');
      expect(recoveryOf(f.hubDen.device(phone.deviceId)!)?.kind, RecoveryKind.hub);

      // The passkey now belongs to the new phone: removing the old one keeps it working.
      await f.toPhone();
      final old = f.phone.deviceId;
      expect((await signed(f.phone, 'GET', '/api/v1/passkeys')).body['passkeys'], hasLength(1));
      await phone.revokeDevice(old);
      await f.hubDen.ingest(phone.changesSince(f.hubDen.versionVector));
      final later = await signIn(key, (await DeviceKeys.generate()).pubkey);
      expect(later.status, 200, reason: 'the old phone going doesn\'t take the passkey with it: ${later.text}');
    });

    test('anyone else, and a parent while the hub may not help, asks in; a parent lets them in with one tap', () async {
      final maya = await _device(f, 'Maya phone', DeviceMode.personal, member: f.id('Maya'));
      final mayas = FakePasskey.make();
      expect((await make(maya, mayas)).status, 201);
      final alexs = FakePasskey.make();
      expect((await make(f.phone, alexs)).status, 201);

      final asAlex = await signIn(alexs, (await DeviceKeys.generate()).pubkey);
      expect(asAlex.status, 200, reason: asAlex.text);
      expect(asAlex.body['lets_in'], isFalse, reason: 'the hub\'s help is off');
      expect(asAlex.body['proof'], isNull);

      final phone = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
      addTearDown(phone.close);
      final r = await signIn(mayas, phone.keys.pubkey);
      expect(r.status, 200, reason: r.text);
      expect(r.body['member_name'], 'Maya');
      expect(r.body['lets_in'], isFalse);
      expect(r.body['proof'], isNull);

      final node = SyncNode(phone);
      addTearDown(node.close);
      final attempt = await node.joinWithInvite(
        await connectWebSocket(f.base.replace(scheme: 'ws', path: '/ws')),
        await Invite.parse(r.body['invite']! as String),
        deviceName: "Maya's new iPhone",
        kind: DeviceKind.phone,
        memberId: f.id('Maya'),
      );
      await eventually(() => f.hubDen.device(phone.deviceId) != null);
      final asked = f.hubDen.device(phone.deviceId)!;
      expect(asked.approved, isFalse, reason: 'a passkey never lets in by itself');
      expect(asked.member, f.id('Maya'));
      await f.toPhone();
      await f.phone.approveDevice(phone.deviceId, member: f.id('Maya'), mode: DeviceMode.personal);
      await f.toHub();
      await attempt.completed;
      expect(phone.isApproved, isTrue);
      expect(phone.owner?.name, 'Maya');
    });

    test('a passkey that isn\'t anyone\'s here gets "ask for an invite", and creates nothing', () async {
      final devices = f.hubDen.devices.length;
      final r = await signIn(FakePasskey.make(), (await DeviceKeys.generate()).pubkey);
      expect(r.status, 403);
      expect(r.error['code'], 'not_in_family');
      expect(r.error['message'], contains('Ask someone in your family for an invite'));
      expect(r.body.containsKey('invite'), isFalse);
      expect(f.hubDen.devices.length, devices);
    });

    test('a challenge works once, for a while, at this address only; the signature and Face ID count', () async {
      final key = FakePasskey.make();
      await make(f.phone, key);
      final pubkey = (await DeviceKeys.generate()).pubkey;

      final o = await signInOptions();
      expect(o['rpId'], 'den.example.com');
      expect(o['userVerification'], 'required');
      expect(o['allowCredentials'], isEmpty);
      expect((await signIn(key, pubkey, options: o)).status, 200);
      expect((await signIn(key, pubkey, options: o)).status, 400, reason: 'used once');

      expect((await signIn(key, pubkey, uv: false)).status, 400);
      expect((await signIn(key, pubkey, origin: 'https://den.example.com.evil.test')).status, 400);
      final other = await signInOptions();
      final wrongRp = await f.call('POST', '/api/v1/passkeys/sign-in',
          body: {'credential': key.assert_(other, origin: _origin, rpId: 'evil.test'), 'pubkey': pubkey});
      expect(wrongRp.status, 400);
      final tampered = await f.call('POST', '/api/v1/passkeys/sign-in',
          body: {'credential': key.assert_(await signInOptions(), origin: _origin, tamper: true), 'pubkey': pubkey});
      expect(tampered.status, 400);
      final made = await f.call('POST', '/api/v1/passkeys/sign-in',
          body: {'credential': key.assert_(await signInOptions(), origin: _origin, type: 'webauthn.create'), 'pubkey': pubkey});
      expect(made.status, 400);
      final invented = await f.call('POST', '/api/v1/passkeys/sign-in',
          body: {'credential': key.assert_(o, origin: _origin, challenge: b64u(List.filled(32, 7))), 'pubkey': pubkey});
      expect(invented.status, 400, reason: 'a challenge the hub never made');
      final options = await signed(f.phone, 'POST', '/api/v1/passkeys/options', body: const <String, Object?>{});
      final creation = (options.body['options']! as Map).cast<String, Object?>();
      final crossed = await f.call('POST', '/api/v1/passkeys/sign-in', body: {
        'credential': key.assert_({'rpId': 'den.example.com', 'challenge': creation['challenge']}, origin: _origin),
        'pubkey': pubkey,
      });
      expect(crossed.status, 400, reason: 'a challenge for making one doesn\'t sign in');
    });

    test('removing a person or their device turns their passkeys off; a person removes their own', () async {
      final maya = await _device(f, 'Maya phone', DeviceMode.personal, member: f.id('Maya'));
      final mayas = FakePasskey.make();
      await make(maya, mayas);
      final leo = await _device(f, 'Leo tablet', DeviceMode.personal, member: f.id('Leo'));
      final leos = FakePasskey.make();
      await make(leo, leos);
      final alexs = FakePasskey.make();
      await make(f.phone, alexs);

      // Maya can't remove Alex's; Alex (a parent) can remove Maya's; Leo removes his own.
      expect((await signed(maya, 'DELETE', '/api/v1/passkeys/${alexs.credentialId}')).status, 403);
      expect((await signed(leo, 'DELETE', '/api/v1/passkeys/${leos.credentialId}')).status, 200);
      expect((await signIn(leos, (await DeviceKeys.generate()).pubkey)).status, 403);
      expect((await signed(leo, 'GET', '/api/v1/passkeys')).body['passkeys'], isEmpty);
      final asParent = await signed(f.phone, 'GET', '/api/v1/passkeys?member=${f.id('Maya')}');
      expect(asParent.body['passkeys'], hasLength(1));
      expect((await signed(maya, 'GET', '/api/v1/passkeys?member=${f.id('Alex')}')).status, 403);

      // Maya's phone is removed: her passkey with it.
      await f.phone.revokeDevice(maya.deviceId);
      await f.toHub();
      expect((await signIn(mayas, (await DeviceKeys.generate()).pubkey)).error['code'], 'not_in_family');

      // Alex makes another for Maya's new device... rather, Leo is removed from the family.
      final leos2 = FakePasskey.make();
      final leo2 = await _device(f, 'Leo phone', DeviceMode.personal, member: f.id('Leo'));
      await make(leo2, leos2);
      await f.phone.removeMember(f.id('Leo'));
      await f.toHub();
      expect((await signIn(leos2, (await DeviceKeys.generate()).pubkey)).error['code'], 'not_in_family');
      expect(File('${dir.path}/hub/$passkeysDoc.json').readAsStringSync(), isNot(contains(leos2.credentialId)),
          reason: 'forgotten, not just refused');
    });

    test('someone whose tries are all still waiting gets told to ask a parent', () async {
      final maya = await _device(f, 'Maya phone', DeviceMode.personal, member: f.id('Maya'));
      final key = FakePasskey.make();
      await make(maya, key);
      for (var i = 0; i < HubPasskeys.maxWaiting; i++) {
        final d = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
        await d.requestJoin(
          familyId: f.phone.familyId!,
          founderPubkey: f.phone.founderPubkey!,
          deviceName: "Maya's new iPhone",
          kind: DeviceKind.phone,
          memberId: f.id('Maya'),
        );
        await f.hubDen.ingest(d.changesSince(const {}));
        await d.close();
      }
      final r = await signIn(key, (await DeviceKeys.generate()).pubkey);
      expect(r.status, 429);
      expect(r.error['message'], contains('Ask a parent'));
    });
  });

  test('passkeys need an https address with a name: plain http or an IP address gets none', () async {
    for (final url in ['http://den.example.com', 'https://192.168.1.20']) {
      final f = await HubFixture.start(configure: (c) => _at(c, Uri.parse(url)));
      final r = await f.call('POST', '/api/v1/passkeys/sign-in/options');
      expect(r.status, 409, reason: url);
      expect(r.error['code'], 'needs_https');
      await f.stop();
    }
  });

  test('two families on one host: a passkey for one signs nobody into the other', () async {
    final dir = await Directory.systemTemp.createTemp('den-passkeys-host');
    final f = await HostFixture.start(
      hub: (name, c) => HubConfig(mdns: false, publicUrl: c.publicUrl, log: c.log, public: false, dataDir: '${dir.path}/$name'),
    );
    addTearDown(() async {
      await f.stop();
      await dir.delete(recursive: true);
    });
    final a = f['den-a.test'];
    final options = await f.signed(a.phone, 'POST', '/api/v1/passkeys/options', hub: a.hubDen.deviceId, hostname: 'den-a.test', body: const <String, Object?>{});
    expect(options.status, 200, reason: options.text);
    expect((options.body['options']! as Map)['rp'], {'id': 'den-a.test', 'name': 'Den'});
    final key = FakePasskey.make();
    final made = await f.signed(a.phone, 'POST', '/api/v1/passkeys',
        hub: a.hubDen.deviceId,
        hostname: 'den-a.test',
        body: {'credential': key.register((options.body['options']! as Map).cast<String, Object?>(), origin: 'https://den-a.test')});
    expect(made.status, 201, reason: made.text);

    Future<ApiResult> at(String host, {String? rpId, String? origin}) async {
      final o = await f.call('POST', '/api/v1/passkeys/sign-in/options', hostname: host);
      expect(o.status, 200, reason: o.text);
      final options = (o.body['options']! as Map).cast<String, Object?>();
      return f.call('POST', '/api/v1/passkeys/sign-in',
          hostname: host,
          body: {'credential': key.assert_(options, origin: origin ?? 'https://$host', rpId: rpId), 'pubkey': (await DeviceKeys.generate()).pubkey});
    }

    expect((await at('den-a.test')).status, 200);
    // At b's address with a's RP ID (no browser would), or as if b's page asked: b knows nothing of it.
    expect((await at('den-b.test', rpId: 'den-a.test', origin: 'https://den-a.test')).status, 400);
    expect((await at('den-b.test')).error['code'], 'not_in_family');
    // At an address that is no family's: nobody answers.
    expect((await f.call('POST', '/api/v1/passkeys/sign-in/options')).error['code'], 'no_family');
  });

  group('WebAuthn checks', () {
    test('CBOR: what passkeys send, and nothing more', () {
      expect(decodeCbor(cbor({1: 2, -1: Uint8List.fromList([1, 2]), 'a': 'b', 'l': [true, false, null]})), {
        1: 2,
        -1: [1, 2],
        'a': 'b',
        'l': [true, false, null],
      });
      expect(() => decodeCbor([0x9f]), throwsFormatException, reason: 'no indefinite lengths');
      expect(() => decodeCbor([0xc0, 0x00]), throwsFormatException, reason: 'no tags');
      expect(() => decodeCbor([0xfb, 0, 0, 0, 0, 0, 0, 0, 0]), throwsFormatException, reason: 'no floats');
      expect(() => decodeCbor([0x5a, 0xff, 0xff, 0xff, 0xff]), throwsFormatException);
      expect(() => decodeCbor([0x01, 0x02]), throwsFormatException, reason: 'nothing after the value');
      expect(() => decodeCbor([0xa2, 0x01, 0x01, 0x01, 0x02]), throwsFormatException, reason: 'a key twice');
      var deep = <int>[0x01];
      for (var i = 0; i < 20; i++) {
        deep = [0x81, ...deep];
      }
      expect(() => decodeCbor(deep), throwsFormatException);
    });

    test('RS256 (Windows Hello) checks out too', () {
      final generator = RSAKeyGenerator()
        ..init(ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64),
          FortunaRandom()..seed(KeyParameter(Uint8List.fromList(List.generate(32, (i) => i * 7 + 1)))),
        ));
      final pair = generator.generateKeyPair();
      final public = pair.publicKey;
      final private = pair.privateKey;
      final key = PasskeyKey.fromCose({1: 3, 3: -257, -1: _bytes(public.modulus!), -2: _bytes(public.publicExponent!)});
      expect(key.alg, 'RS256');
      final message = utf8.encode('authenticator data and the client data hash');
      final signer = RSASigner(SHA256Digest(), '0609608648016503040201')..init(true, PrivateKeyParameter<RSAPrivateKey>(private));
      final sig = signer.generateSignature(Uint8List.fromList(message)).bytes;
      expect(key.verify(message, sig), isTrue);
      expect(key.verify([...message, 0], sig), isFalse);
      expect(PasskeyKey.parse(key.toJson())!.verify(message, sig), isTrue);
    });

    test('only ES256 and RS256 keys, and ES256 points on the curve', () {
      expect(() => PasskeyKey.fromCose({1: 1, 3: -8, -1: 6, -2: Uint8List(32)}), throwsA(isA<WebAuthnRefused>()));
      expect(() => PasskeyKey.fromCose({1: 2, 3: -7, -1: 1, -2: Uint8List(32), -3: Uint8List(32)}), throwsA(isA<WebAuthnRefused>()));
      final good = FakePasskey.make();
      expect(PasskeyKey.fromCose({1: 2, 3: -7, -1: 1, -2: good.x, -3: good.y}).alg, 'ES256');
    });
  });
}

Uint8List _bytes(BigInt v) {
  final hex = v.toRadixString(16);
  final even = hex.length.isOdd ? '0$hex' : hex;
  return Uint8List.fromList([for (var i = 0; i < even.length; i += 2) int.parse(even.substring(i, i + 2), radix: 16)]);
}

HubConfig _at(HubConfig c, Uri publicUrl) => HubConfig(
      port: c.port,
      host: c.host,
      mdns: c.mdns,
      dataDir: c.dataDir,
      log: c.log,
      publicUrl: publicUrl,
    );

/// A device of the fixture's family, approved by Alex's phone, holding what it holds.
Future<Den> _device(HubFixture f, String name, DeviceMode mode, {String? member}) async {
  final d = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
  await d.requestJoin(
    familyId: f.phone.familyId!,
    founderPubkey: f.phone.founderPubkey!,
    deviceName: name,
    kind: mode == DeviceMode.shared ? DeviceKind.display : DeviceKind.phone,
    mode: mode,
    memberId: member,
  );
  await f.phone.ingest(d.changesSince(const {}));
  await f.phone.approveDevice(d.deviceId, member: member, mode: mode);
  await d.ingest(f.phone.changesSince(const {}));
  await f.toHub();
  return d;
}
