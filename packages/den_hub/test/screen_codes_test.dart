@Timeout(Duration(seconds: 120))
library;

import 'dart:convert';
import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';

import 'support/fixture.dart';
import 'support/host_fixture.dart';
import 'support/test.dart';

/// A kitchen screen that showed its code at the family's address: its keys, the code, and what
/// the hub gave it to ask with.
class Screen {
  Screen(this.den, this.code, this.keys, this.secret);

  final Den den;
  final String code;
  final ScreenCodeKeys keys;
  final String secret;

  static const String name = 'Kitchen iPad';

  String get pubkey => den.keys.pubkey;
  String get xpub => den.keys.xpub;
}

void main() {
  late HubFixture f;
  late Den mayasPhone;
  late Den display;

  Future<Den> joined(String name, {String? member, required DeviceMode mode, DeviceKind kind = DeviceKind.phone}) async {
    final den = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    await den.requestJoin(familyId: f.phone.familyId!, founderPubkey: f.phone.founderPubkey!, deviceName: name, kind: kind, mode: mode);
    await f.phone.ingest(den.changesSince(const {}));
    await f.phone.approveDevice(den.deviceId, member: member, mode: mode);
    await den.ingest(f.phone.changesSince(const {}), through: f.phone.completeVector);
    await f.toHub();
    return den;
  }

  setUpAll(() async {
    f = await HubFixture.start(
      configure: (c) => HubConfig(
        port: 0,
        host: InternetAddress.loopbackIPv4,
        mdns: false,
        log: c.log,
        trustedProxies: [IpNetwork.parse('127.0.0.1')],
      ),
    );
    mayasPhone = await joined("Maya's phone", member: f.id('Maya'), mode: DeviceMode.personal);
    display = await joined('Hall display', mode: DeviceMode.shared, kind: DeviceKind.display);
  });

  tearDownAll(() async {
    await mayasPhone.close();
    await display.close();
    await f.stop();
  });

  // Each test starts with the hub's clock and wrong-code counts as they are; tests that move
  // the clock put it back.
  tearDown(() => f.hub.screens.clock = () => DateTime.now().toUtc().millisecondsSinceEpoch);

  var client = 0;
  // A different address for each test, so one test's wrong codes don't hold up the next.
  String nextClient() => '198.51.100.${++client}';

  Future<ApiResult> anon(String path, Object body, {String? from}) =>
      f.call('POST', path, body: body, headers: {'x-forwarded-for': ?from});

  Future<ApiResult> signed(Den device, String path, Object body, {String? actor, String? from}) async {
    final text = jsonEncode(body);
    final headers = await DeviceRequest.sign(
      keys: device.keys,
      method: 'POST',
      url: f.base.resolve(path),
      body: utf8.encode(text),
      hub: f.hubDen.deviceId,
      actorId: actor ?? f.id('Alex'),
    );
    return f.call('POST', path, body: text, headers: {...headers, 'x-forwarded-for': ?from});
  }

  Future<Screen> showCode({String? code, String? from}) async {
    final den = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    addTearDown(den.close);
    final c = code ?? ScreenCode.generate();
    final keys = await ScreenCode.derive(c);
    final made = await anon('/api/v1/screens/code', {
      'slot': keys.slot,
      'pubkey': den.keys.pubkey,
      'xpub': den.keys.xpub,
      'name': Screen.name,
      'kind': 'tablet',
      'tag': await keys.screenTag(pubkey: den.keys.pubkey, xpub: den.keys.xpub, name: Screen.name, kind: 'tablet'),
    }, from: from ?? nextClient());
    expect(made.status, 201, reason: made.text);
    return Screen(den, c, keys, made.body['secret']! as String);
  }

  Future<ApiResult> find(String code, {Den? by, String? actor, String? from}) async =>
      signed(by ?? f.phone, '/api/v1/screens/find', {'slot': (await ScreenCode.derive(code)).slot}, actor: actor, from: from);

  Future<ApiResult> accept(Screen s, {String name = Screen.name, Den? by, String? actor}) async => signed(by ?? f.phone, '/api/v1/screens/accept', {
        'slot': s.keys.slot,
        'family': f.phone.familyId,
        'founder': f.phone.founderPubkey,
        'hub': f.hubDen.deviceId,
        'name': name,
        'tag': await s.keys.familyTag(
          family: f.phone.familyId!,
          founder: f.phone.founderPubkey!,
          hub: f.hubDen.deviceId,
          pubkey: s.pubkey,
          name: name,
        ),
      }, actor: actor);

  Future<ApiResult> status(Screen s) => anon('/api/v1/screens/code/status', {'slot': s.keys.slot, 'secret': s.secret});

  /// The screen writes its own join request and hands it to the hub.
  Future<ApiResult> sendJoin(Screen s, {String name = Screen.name}) async {
    await s.den.requestJoin(
      familyId: f.phone.familyId!,
      founderPubkey: f.phone.founderPubkey!,
      deviceName: name,
      kind: DeviceKind.tablet,
      mode: DeviceMode.shared,
    );
    final change = s.den.changesSince(const {}).singleWhere((c) => c.rid == s.den.deviceId);
    return anon('/api/v1/screens/code/join', {'slot': s.keys.slot, 'secret': s.secret, 'change': change.toJson()});
  }

  test('happy path: the screen shows a code, a parent types it, approves it on her phone, and the screen is in', () async {
    final s = await showCode();
    expect((await status(s)).body['state'], 'waiting');

    final found = await find(s.code.toLowerCase());
    expect(found.status, 200, reason: found.text);
    expect(found.body['name'], Screen.name);
    expect(found.body['device'], s.den.deviceId);
    expect(
      ScreenCodeKeys.same(
        found.body['tag']! as String,
        await s.keys.screenTag(pubkey: found.body['pubkey']! as String, xpub: found.body['xpub']! as String, name: Screen.name, kind: 'tablet'),
      ),
      isTrue,
      reason: 'the phone can check the key it shows is the one the screen made',
    );

    expect((await accept(s, name: 'Kitchen')).status, 200);
    final accepted = (await status(s)).body;
    expect(accepted['state'], 'accepted');
    expect(accepted['family'], f.phone.familyId);
    expect(accepted['hub'], f.hubDen.deviceId);
    expect(
      ScreenCodeKeys.same(
        accepted['tag']! as String,
        await s.keys.familyTag(family: f.phone.familyId!, founder: f.phone.founderPubkey!, hub: f.hubDen.deviceId, pubkey: s.pubkey, name: 'Kitchen'),
      ),
      isTrue,
      reason: 'the screen can check what it joins came from someone who knows its code',
    );

    expect((await sendJoin(s, name: 'Kitchen')).status, 200);
    expect(f.hubDen.device(s.den.deviceId), isNull, reason: 'the hub keeps the request, it never writes it');

    final asked = await signed(f.phone, '/api/v1/screens/request', {'slot': s.keys.slot});
    expect(asked.body['state'], 'requested');
    final change = Change.fromJson((asked.body['change']! as Map).cast<String, Object?>());
    expect(await isScreenJoinRequest(change, pubkey: s.pubkey, xpub: s.xpub, name: 'Kitchen', kind: 'tablet'), isTrue);

    // On Alex's phone: the request and the approval, a shared screen that is nobody's.
    await f.phone.ingest([change]);
    await f.phone.approveDevice(s.den.deviceId, mode: DeviceMode.shared);
    await f.toHub();
    final there = f.hubDen.device(s.den.deviceId)!;
    expect(there.approved, isTrue);
    expect(there.mode, DeviceMode.shared);
    expect(there.member, isNull);
    expect(there.rec.fields['approvedBy'], f.id('Alex'));

    expect((await status(s)).body['state'], 'approved');
    expect((await status(s)).status, 404, reason: 'used once: the code is gone');
    expect((await find(s.code)).status, 404, reason: 'and a parent typing it again finds nothing');
  });

  test('a wrong code, a used one and one that ran out all get the same answer', () async {
    final wrong = await find(ScreenCode.generate(), from: nextClient());
    expect(wrong.status, 404);

    final used = await showCode();
    expect((await accept(used)).status, 200);
    final again = await find(used.code, from: nextClient());
    expect(again.status, 404, reason: 'once a parent took a code, nobody finds it again');
    expect(again.text, wrong.text);

    final late = await showCode();
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    f.hub.screens.clock = () => now + ScreenCode.life.inMilliseconds + 1000;
    final ranOut = await find(late.code, from: nextClient());
    expect(ranOut.status, 404);
    expect(ranOut.text, wrong.text);
    expect((await status(late)).status, 404, reason: 'the screen hears it ran out');
  });

  test('a second phone can\'t take over a code another parent took', () async {
    final s = await showCode();
    expect((await accept(s)).status, 200);
    final priyasPhone = await joined("Priya's phone", member: f.id('Priya'), mode: DeviceMode.personal);
    addTearDown(priyasPhone.close);
    expect((await accept(s, by: priyasPhone, actor: f.id('Priya'))).status, 404);
    final theirs = await signed(priyasPhone, '/api/v1/screens/request', {'slot': s.keys.slot}, actor: f.id('Priya'));
    expect(theirs.status, 404, reason: "only the phone that took the code sees the screen's request");
  });

  test('wrong codes from one place wait, and the family has a ceiling for everyone', () async {
    final from = nextClient();
    for (var i = 0; i < ScreenCodes.maxWrong; i++) {
      expect((await find(ScreenCode.generate(), from: from)).status, 404);
    }
    final s = await showCode();
    final held = await find(s.code, from: from);
    expect(held.status, 429, reason: 'even the right code waits after too many wrong ones');
    expect(held.error['message'], contains('from here'));
    expect((await find(s.code, from: nextClient())).status, 200, reason: 'another place is not held up');

    // Everyone together: past the ceiling nobody's codes are looked up for a while.
    var sent = ScreenCodes.maxWrong;
    while (sent < ScreenCodes.wrongCeiling) {
      final at = nextClient();
      for (var i = 0; i < 5 && sent < ScreenCodes.wrongCeiling; i++, sent++) {
        await find(ScreenCode.generate(), from: at);
      }
    }
    final s2 = await showCode();
    final all = await find(s2.code, from: nextClient());
    expect(all.status, 429);
    expect(all.error['message'], contains('Too many wrong codes were tried'));
    // A while later, it counts again.
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    f.hub.screens.clock = () => now + ScreenCodes.wrongWindow.inMilliseconds + 1000;
    expect((await find(ScreenCode.generate(), from: nextClient())).status, 404);
  });

  test('screens waiting are capped, per place and for the family', () async {
    final from = nextClient();
    for (var i = 0; i < ScreenCodes.maxPerClient; i++) {
      await showCode(from: from);
    }
    final den = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    addTearDown(den.close);
    final keys = await ScreenCode.derive(ScreenCode.generate());
    final over = await anon('/api/v1/screens/code', {
      'slot': keys.slot,
      'pubkey': den.keys.pubkey,
      'xpub': den.keys.xpub,
      'name': 'One too many',
      'kind': 'tablet',
      'tag': 'x',
    }, from: from);
    expect(over.status, 429);
    expect(f.hub.screens.waiting, lessThanOrEqualTo(ScreenCodes.maxWaiting));
  });

  test("the tablet's key is bound to its code: nobody can swap their key in after the parent typed it", () async {
    final s = await showCode();
    final thief = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    addTearDown(thief.close);

    // Someone who read the code off the screen can't put their own key under it.
    final taken = await anon('/api/v1/screens/code', {
      'slot': s.keys.slot,
      'pubkey': thief.keys.pubkey,
      'xpub': thief.keys.xpub,
      'name': Screen.name,
      'kind': 'tablet',
      'tag': await s.keys.screenTag(pubkey: thief.keys.pubkey, xpub: thief.keys.xpub, name: Screen.name, kind: 'tablet'),
    }, from: nextClient());
    expect(taken.status, 409);
    expect((await find(s.code)).body['pubkey'], s.pubkey);

    expect((await accept(s)).status, 200);
    // Nor send their own join request in its place, even holding the screen's secret.
    await thief.requestJoin(
      familyId: f.phone.familyId!,
      founderPubkey: f.phone.founderPubkey!,
      deviceName: Screen.name,
      kind: DeviceKind.tablet,
      mode: DeviceMode.shared,
    );
    final theirs = thief.changesSince(const {}).single;
    final swapped = await anon('/api/v1/screens/code/join', {'slot': s.keys.slot, 'secret': s.secret, 'change': theirs.toJson()});
    expect(swapped.status, 400);
    // Without the secret, they get nowhere at all.
    final guessed = await anon('/api/v1/screens/code/join', {'slot': s.keys.slot, 'secret': 'nope', 'change': theirs.toJson()});
    expect(guessed.status, 404);

    // A request for someone, or let in already, isn't a kitchen screen's either.
    final mine = await Den.open(storage: MemoryStorage(), keys: s.den.keys);
    addTearDown(mine.close);
    await mine.requestJoin(
      familyId: f.phone.familyId!,
      founderPubkey: f.phone.founderPubkey!,
      deviceName: Screen.name,
      kind: DeviceKind.tablet,
      memberId: f.id('Alex'),
    );
    final personal = mine.changesSince(const {}).single;
    expect(await isScreenJoinRequest(personal, pubkey: s.pubkey, xpub: s.xpub, name: Screen.name, kind: 'tablet'), isFalse);
    final asSomeone = await anon('/api/v1/screens/code/join', {'slot': s.keys.slot, 'secret': s.secret, 'change': personal.toJson()});
    expect(asSomeone.status, 400, reason: 'a code is only ever for a shared screen, never someone\'s own device');

    // A key the hub (or anyone between) put in place of the screen's fails the tag the parent's
    // phone checks.
    expect(
      ScreenCodeKeys.same(
        await s.keys.screenTag(pubkey: s.pubkey, xpub: s.xpub, name: Screen.name, kind: 'tablet'),
        await s.keys.screenTag(pubkey: thief.keys.pubkey, xpub: thief.keys.xpub, name: Screen.name, kind: 'tablet'),
      ),
      isFalse,
    );

    expect((await sendJoin(s)).status, 200, reason: "the screen's own request still goes");
  });

  test('the join request must be the kind the code was tagged with, under the name the parent chose, never a hub', () async {
    final s = await showCode();
    expect((await accept(s, name: 'Kitchen')).status, 200);
    Future<ApiResult> sendAs({required String name, required DeviceKind kind}) async {
      final den = await Den.open(storage: MemoryStorage(), keys: s.den.keys);
      addTearDown(den.close);
      await den.requestJoin(
        familyId: f.phone.familyId!,
        founderPubkey: f.phone.founderPubkey!,
        deviceName: name,
        kind: kind,
        mode: DeviceMode.shared,
      );
      final change = den.changesSince(const {}).single;
      return anon('/api/v1/screens/code/join', {'slot': s.keys.slot, 'secret': s.secret, 'change': change.toJson()});
    }

    expect((await sendAs(name: 'Kitchen', kind: DeviceKind.display)).status, 400, reason: 'another kind than the code said');
    expect((await sendAs(name: 'Hall', kind: DeviceKind.tablet)).status, 400, reason: 'another name than the parent chose');
    expect((await sendAs(name: 'Kitchen', kind: DeviceKind.hub)).status, 400, reason: 'never a hub');
    expect((await sendAs(name: 'Kitchen', kind: DeviceKind.tablet)).status, 200);

    final hubCode = await ScreenCode.derive(ScreenCode.generate());
    final asHub = await anon('/api/v1/screens/code', {
      'slot': hubCode.slot,
      'pubkey': (await DeviceKeys.generate()).pubkey,
      'xpub': 'x',
      'name': 'Closet',
      'kind': 'hub',
      'tag': 'x',
    }, from: nextClient());
    expect(asHub.status, 400, reason: 'a code is never for a hub');
  });

  test("a kid's phone and a shared screen can't add a screen, and a shared screen's approval counts for nothing", () async {
    final s = await showCode();
    final kid = await find(s.code, by: mayasPhone, actor: f.id('Maya'), from: nextClient());
    expect(kid.status, 403);
    final shared = await find(s.code, by: display, actor: f.id('Alex'), from: nextClient());
    expect(shared.status, 403, reason: 'not even with a parent verified on it');
    expect((await accept(s, by: display, actor: f.id('Alex'))).status, 403);
    final unsigned = await anon('/api/v1/screens/find', {'slot': s.keys.slot});
    expect(unsigned.status, 401);

    // The approval itself: only a parent's own device's counts, on every replica.
    expect((await accept(s)).status, 200);
    expect((await sendJoin(s)).status, 200);
    final request = Change.fromJson(
      ((await signed(f.phone, '/api/v1/screens/request', {'slot': s.keys.slot})).body['change']! as Map).cast<String, Object?>(),
    );
    await display.ingest([request]);
    display.actAs(f.id('Alex'), window: const Duration(minutes: 5));
    await expectLater(display.approveDevice(s.den.deviceId, mode: DeviceMode.shared), throwsA(anything));
    display.actAs(null);
    await f.hubDen.ingest(display.changesSince(f.hubDen.versionVector));
    expect(f.hubDen.device(s.den.deviceId)?.approved ?? false, isFalse);
  });

  group('on a host with several families', () {
    late HostFixture h;
    setUpAll(() async => h = await HostFixture.start());
    tearDownAll(() => h.stop());

    test("a code shown at one family's address is found only by that family's parents", () async {
      final a = h['den-a.test'], b = h['den-b.test'];
      final den = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
      addTearDown(den.close);
      final code = ScreenCode.generate();
      final keys = await ScreenCode.derive(code);
      final made = await h.call('POST', '/api/v1/screens/code', hostname: 'den-a.test', body: {
        'slot': keys.slot,
        'pubkey': den.keys.pubkey,
        'xpub': den.keys.xpub,
        'name': Screen.name,
        'kind': 'tablet',
        'tag': await keys.screenTag(pubkey: den.keys.pubkey, xpub: den.keys.xpub, name: Screen.name, kind: 'tablet'),
      });
      expect(made.status, 201, reason: made.text);

      final nobodys = await ScreenCode.derive(ScreenCode.generate());
      final nowhere = await h.signed(b.phone, 'POST', '/api/v1/screens/find', hub: b.hubDen.deviceId, body: {'slot': nobodys.slot});
      final crossed = await h.signed(b.phone, 'POST', '/api/v1/screens/find', hub: b.hubDen.deviceId, body: {'slot': keys.slot});
      expect(crossed.status, 404, reason: "b's parent finds nothing under a's code");
      expect(crossed.text, nowhere.text, reason: 'the same answer as a code that is nobody\'s: nothing says a has one');
      final viaAddress = await h.signed(b.phone, 'POST', '/api/v1/screens/find',
          hub: b.hubDen.deviceId, hostname: 'den-a.test', body: {'slot': keys.slot});
      expect(viaAddress.status, 404, reason: "b's phone at a's address is still b's family");

      final found = await h.signed(a.phone, 'POST', '/api/v1/screens/find', hub: a.hubDen.deviceId, body: {'slot': keys.slot});
      expect(found.status, 200, reason: found.text);
      expect(found.body['pubkey'], den.keys.pubkey);

      final atB = await h.call('POST', '/api/v1/screens/code/status',
          hostname: 'den-b.test', body: {'slot': keys.slot, 'secret': made.body['secret']});
      expect(atB.status, 404, reason: "b's address knows nothing of a screen waiting at a's");
    });
  });
}
