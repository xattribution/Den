@Timeout(Duration(seconds: 180))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

import 'support/fixture.dart';
import 'support/host_fixture.dart';

/// Two families on one host never reach each other's logs, whatever a request carries and
/// whichever address it comes to.
void main() {
  late Directory dir;
  late HostFixture f;
  late HostedFamily a;
  late HostedFamily b;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('den-isolation');
    f = await HostFixture.start(
      hub: (name, c) => HubConfig(mdns: false, publicUrl: c.publicUrl, log: c.log, public: false, dataDir: '${dir.path}/$name'),
    );
    a = f['den-a.test'];
    b = f['den-b.test'];
  });

  tearDown(() async {
    await f.stop();
    await dir.delete(recursive: true);
  });

  Uri ws() => f.base.replace(scheme: 'ws', path: '/ws');

  Future<WebSocket> socketAt(String hostname) => WebSocket.connect('${ws()}', headers: {'host': hostname});

  test("the two demo families really are two: their own family ids, hubs and people", () {
    expect(a.phone.familyId, isNot(b.phone.familyId));
    expect(a.hubDen.deviceId, isNot(b.hubDen.deviceId));
    expect(a.id('Alex'), isNot(b.id('Alex')));
  });

  group('sync', () {
    test("a's phone naming b's family reaches b's hub only as a stranger, and gets nothing of b's", () async {
      for (final at in ['den-b.test', 'den-a.test', '127.0.0.1']) {
        final session = await Session.connect(IOWebSocketChannel(await socketAt(at)), keys: a.phone.keys, familyId: b.phone.familyId);
        expect(session.peerDevice, b.hubDen.deviceId, reason: 'the hello decides: $at');
        final got = <Map<String, Object?>>[];
        final listening = session.messages.listen(got.add, onError: (Object _) {});
        await session.send({'t': 'have', 'vv': <String, Object?>{}, 'keys': <String, Object?>{}});
        await Future<void>.delayed(const Duration(milliseconds: 800));
        expect(got.where((m) => m['t'] == 'changes' || m['t'] == 'push'), isEmpty, reason: 'nothing of b\'s: $at');
        expect(b.hubDen.device(a.phone.deviceId), isNull);
        expect(a.hub.node.peers, isEmpty, reason: "a's hub never saw it");
        await listening.cancel();
        await session.close();
      }
    });

    test("a's phone pinned to b's hub can't get there: its hello names a, so a's hub answers", () async {
      final node = SyncNode(a.phone);
      addTearDown(node.close);
      await expectLater(
        node.connect(IOWebSocketChannel(await socketAt('den-b.test')), expectDevice: b.hubDen.deviceId),
        throwsA(isA<SessionException>()),
      );
      expect(b.hub.node.peers, isEmpty);
    });
  });

  group('signed requests', () {
    test("a device of a's, signing for b's hub or naming it, is refused by b and learns nothing", () async {
      final forB = await f.signed(a.phone, 'GET', '/api/v1/feeds', hub: b.hubDen.deviceId, hostname: 'den-b.test');
      expect(forB.status, 401);
      // Signed for a's hub, but X-Den-Hub says b: the signature doesn't check out at b, so it goes
      // by address. At a's, a answers its own device; at b's, b refuses it.
      final headers = await DeviceRequest.sign(
          keys: a.phone.keys, method: 'GET', url: f.base.resolve('/api/v1/feeds'), body: const [], hub: a.hubDen.deviceId);
      headers[DeviceRequest.hubHeader] = b.hubDen.deviceId;
      final atA = await f.call('GET', '/api/v1/feeds', hostname: 'den-a.test', headers: headers);
      expect(atA.status, 200, reason: "a's device, a's hub, a's address: ${atA.text}");
      final again = await DeviceRequest.sign(
          keys: a.phone.keys, method: 'GET', url: f.base.resolve('/api/v1/feeds'), body: const [], hub: a.hubDen.deviceId);
      again[DeviceRequest.hubHeader] = b.hubDen.deviceId;
      final tampered = await f.call('GET', '/api/v1/feeds', hostname: 'den-b.test', headers: again);
      expect(tampered.status, 401);
      final push = await f.signed(a.phone, 'PUT', '/api/v1/push', hub: b.hubDen.deviceId, body: {'endpoint': 'https://web.push.apple.com/x'});
      expect(push.status, 401);
      final unknownHub = await f.signed(a.phone, 'GET', '/api/v1/feeds', hub: 'NOSUCHHUB0000000');
      expect(unknownHub.status, 401, reason: 'a hub nobody here has: no family, not the first one');
      // Its own hub, through b's address (one origin holding both families): a's answer.
      final own = await f.signed(a.phone, 'GET', '/api/v1/feeds', hub: a.hubDen.deviceId, hostname: 'den-b.test');
      expect(own.status, 200, reason: own.text);
    });
  });

  group('tokens', () {
    test("a's token works at a's address (or one that is no family's) and nowhere else", () async {
      final token = await a.token();
      final ids = {for (final m in a.phone.members) m.id};
      for (final at in ['den-a.test', null]) {
        final members = await f.call('GET', '/api/v1/members', hostname: at, token: token);
        expect(members.status, 200, reason: members.text);
        expect({for (final m in members.body['members']! as List) (m as Map)['id']}, ids, reason: "a's people: $at");
      }
      final atB = await f.call('GET', '/api/v1/members', hostname: 'den-b.test', token: token);
      expect(atB.status, 401);
      final mcp = await f.call('POST', '/mcp', hostname: 'den-b.test', token: token, body: {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'});
      expect(mcp.status, 401);
      expect(mcp.headers['www-authenticate'], contains('https://den-b.test/.well-known/oauth-protected-resource'),
          reason: "b's address sends a client to b's sign-in");
      expect((await f.call('GET', '/api/v1/members', token: 'den_nonsense')).status, 401);
    });

    test('MCP and OAuth name each family\'s own address, the same as its own hub did', () async {
      for (final name in ['den-a.test', 'den-b.test']) {
        final server = await f.call('GET', '/.well-known/oauth-authorization-server', hostname: name);
        expect(server.body['issuer'], 'https://$name');
        final resource = await f.call('GET', '/.well-known/oauth-protected-resource/mcp', hostname: name);
        expect(resource.body['resource'], 'https://$name/mcp');
      }
      // b, as a hub of its own at the same address, said exactly the same.
      final alone = await HubFixture.start(configure: (c) => HubConfig(
            port: 0,
            host: InternetAddress.loopbackIPv4,
            mdns: false,
            log: c.log,
            publicUrl: Uri.parse('https://den-b.test'),
            public: false,
          ));
      addTearDown(alone.stop);
      for (final path in ['/.well-known/oauth-authorization-server', '/.well-known/oauth-protected-resource/mcp']) {
        final before = await alone.call('GET', path, headers: {'host': 'den-b.test'});
        final after = await f.call('GET', path, hostname: 'den-b.test');
        expect(after.json, before.json, reason: path);
      }
    });
  });

  group('calendar links', () {
    Future<String> sharedLink(HostedFamily family, {String? at}) async {
      final made = await f.signed(family.phone, 'POST', '/api/v1/feeds',
          hub: family.hubDen.deviceId, hostname: at, body: {'feed': 'shared', 'label': 'For the cousins'});
      expect(made.status, 201, reason: made.text);
      return made.body['url']! as String;
    }

    test("a's link opens a's calendar, at a's address or one that is no family's; never at b's", () async {
      final url = await sharedLink(a);
      expect(url, startsWith('https://den-a.test/ics/'));
      final path = Uri.parse(url).path;
      for (final at in ['den-a.test', null]) {
        final r = await f.open(path, hostname: at);
        expect(r.statusCode, 200, reason: '$at');
        expect(await r.stream.bytesToString(), contains('@${a.phone.familyId}.den'));
      }
      final atB = await f.open(path, hostname: 'den-b.test');
      expect(atB.statusCode, 401);
      await atB.stream.drain<void>();
      final made = await f.open('/ics/denfeed_nonsense/shared.ics');
      expect(made.statusCode, 404, reason: "no family's link, at no family's address: no family");
      await made.stream.drain<void>();
    });

    test("a's watch stream opens with a's secret only, and only a's", () async {
      final url = await sharedLink(a);
      final watch = Uri.parse(url).path.replaceFirst('shared.ics', 'watch');
      final atB = await f.open(watch, hostname: 'den-b.test');
      expect(atB.statusCode, 401);
      await atB.stream.drain<void>();
      final r = await f.open(watch);
      expect(r.statusCode, 200);
      expect(r.headers['content-type'], startsWith('text/event-stream'));
      final first = await r.stream.transform(utf8.decoder).firstWhere((s) => s.contains('hello'));
      expect(first, contains(r'"etag"'));
    });

    test("a link made through b's address for a's hub still names a's own address", () async {
      final url = await sharedLink(a, at: 'den-b.test');
      expect(url, startsWith('https://den-a.test/'), reason: 'existing links and new ones keep their family\'s address');
    });
  });

  group('codes', () {
    /// An invite naming [family]'s hub (made as its own parent's phone would), signed by
    /// [signer]: that parent, or someone else's device.
    Future<Map<String, Object?>> grant(HostedFamily family, {required Den signer, String context = 'invite'}) async {
      final node = SyncNode(family.phone);
      addTearDown(node.close);
      final invite = node.createHubInvite(family.hubDen.deviceId, hubs: [ws()]);
      return (await InviteGrant.sign(invite, keys: signer.keys, context: context)).toJson();
    }

    test("invite words find a's invite at any address, and only a's", () async {
      final made = await f.call('POST', '/api/v1/invites', hostname: 'den-b.test', body: await grant(a, signer: a.phone));
      expect(made.status, 201, reason: "the grant names a's hub: ${made.text}");
      final words = (made.body['words']! as List).cast<String>();
      final redeemed = await f.call('POST', '/api/v1/invites/redeem', hostname: 'den-b.test', body: {'code': words.join(' ')});
      expect(redeemed.status, 200, reason: redeemed.text);
      final invite = Invite.decode(redeemed.body['invite']! as String);
      expect(invite.familyId, a.phone.familyId);
      expect(invite.inviterDevice, a.hubDen.deviceId, reason: "the joiner pins a's hub");
      final wrong = await f.call('POST', '/api/v1/invites/redeem', body: {'code': 'maple river canoe tiger'});
      expect(wrong.status, 404);
      // b's parent can't make an invite into a's family, wherever they ask.
      final crossed = await f.call('POST', '/api/v1/invites', hostname: 'den-b.test', body: await grant(a, signer: b.phone));
      expect(crossed.status, 403);
    });

    test('invite words and slots are unique per host', () async {
      final slot = 'ab' * 32;
      final key = await grant(a, signer: a.phone, context: 'invite:${a.id('Zoe')}');
      final first = await f.call('POST', '/api/v1/invites', body: {...key, 'slot': slot});
      expect(first.status, 201, reason: first.text);
      final again = await f.call('POST', '/api/v1/invites', body: {...await grant(b, signer: b.phone, context: 'invite:${b.id('Zoe')}'), 'slot': slot});
      expect(again.status, 409, reason: "b can't take a slot a keeps: the words would find two invites");
      final redeemed = await f.call('POST', '/api/v1/invites/redeem', hostname: 'den-b.test', body: {'slot': slot});
      expect(Invite.decode(redeemed.body['invite']! as String).familyId, a.phone.familyId);
      expect(a.hub.invites.holds('slot:$slot'), isTrue);
      expect(b.hub.invites.holds('slot:$slot'), isFalse);
    });

    test('a setup code works only at its own hub\'s address, and opens only that hub', () async {
      final fresh = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
      final c = await f.host.add(fresh, HubConfig(mdns: false, publicUrl: Uri.parse('https://den-c.test'), log: HubLog.silent()));
      addTearDown(() async {
        await f.host.remove(c);
        await fresh.close();
      });
      final code = c.setupCode!;
      expect([for (final t in f.host.tenants) t.setupCode].where((x) => x == code), hasLength(1));
      final body = {'code': code, 'invite': 'not an invite'};
      final found = await f.call('POST', '/api/v1/hub/setup', hostname: 'den-c.test', body: body);
      expect(found.status, 400, reason: 'the code is right (it got as far as the invite): ${found.text}');
      expect(found.error['details'], {'field': 'invite'});
      final nowhere = await f.call('POST', '/api/v1/hub/setup', body: body);
      expect(nowhere.error['code'], 'no_family', reason: "at no family's address, no code is tried at all");
      final atA = await f.call('POST', '/api/v1/hub/setup', hostname: 'den-a.test', body: body);
      expect(atA.status, 409, reason: "a's address is a's, which is set up");
      // A fresh hub on the host is never set up into a family the host serves already.
      final node = SyncNode(a.phone);
      addTearDown(node.close);
      final intoA = (await node.createInvite(relay: Uri.parse('https://relay.test'))).toUrl();
      final twice = await f.call('POST', '/api/v1/hub/setup', hostname: 'den-c.test', body: {'code': code, 'invite': intoA});
      expect(twice.status, 409, reason: twice.text);
      expect(twice.error['message'], contains('on this server already'));
      expect(c.den.hasFamily, isFalse);
      // Wrong codes count at the hub they were tried at: five, then a wait. From outside the home
      // (on the home network a fresh hub needs no code), with the setup link's door pass.
      final outside = {...fromTunnel, 'cookie': await doorPass(f.base, '/setup/$code/${c.den.deviceId}')};
      var tries = 0;
      while (tries < 10) {
        final wrong = await f.call('POST', '/api/v1/hub/setup', hostname: 'den-c.test', body: {'code': 'ZZZZ-ZZZZ', 'invite': 'x'}, headers: outside);
        if (wrong.status == 429) break;
        expect(wrong.status, 403);
        tries++;
      }
      expect(tries, 5);
    });

    test("recovery: a's code lets a phone into a only, typed at any address; den_hub recover reaches only its family", () async {
      final key = await f.signed(a.phone, 'GET', '/api/v1/recovery/key', hub: a.hubDen.deviceId);
      expect(key.status, 200, reason: key.text);
      await a.phone.setServerRecoveryKey(key.body['key']! as String);
      await a.toHub();
      final ticket = await a.hub.recovery.issue('Alex');
      final phone = await DeviceKeys.generate();
      final redeemed = await f.call('POST', '/api/v1/recovery/redeem',
          hostname: 'den-b.test', body: {'code': ticket.words.join(' '), 'pubkey': phone.pubkey});
      expect(redeemed.status, 200, reason: redeemed.text);
      final invite = Invite.decode(redeemed.body['invite']! as String);
      expect(invite.familyId, a.phone.familyId);
      expect(invite.inviterDevice, a.hubDen.deviceId);
      expect(redeemed.body['member'], a.id('Alex'));

      String secret(String name) => File('${dir.path}/$name/hub/$recoveryCliFile').readAsStringSync().trim();
      Future<ApiResult> recover(String? given, {String? at}) => f.call('POST', '/api/v1/recovery/tickets',
          hostname: at, headers: {'x-den-recovery-secret': ?given}, body: {'person': 'Alex'});
      final forA = await recover(secret('den-a.test'), at: 'den-b.test');
      expect(forA.status, 201, reason: "a's secret, wherever asked, is a's command: ${forA.text}");
      expect(forA.body['member'], a.id('Alex'));
      final forB = await recover(secret('den-b.test'));
      expect(forB.error['code'], 'off', reason: "b hasn't turned server help on");
      expect((await recover('guess')).error['code'], 'permission_denied');
    });

    test('a link code is answered by the family that gave it, and only its parents can grant it', () async {
      final made = await f.call('POST', '/api/v1/link', hostname: 'den-a.test');
      expect(made.status, 201, reason: made.text);
      final slot = made.body['slot']! as String;
      final secret = made.body['secret']! as String;
      final poll = await f.call('GET', '/api/v1/link/$slot', hostname: 'den-b.test', headers: {'x-den-link-secret': secret});
      expect(poll.body['state'], 'waiting');
      final node = SyncNode(b.phone);
      addTearDown(node.close);
      final invite = node.createHubInvite(b.hubDen.deviceId, hubs: [ws()]);
      final grant = await InviteGrant.sign(invite, keys: b.phone.keys, context: 'link:$slot');
      final crossed = await f.call('POST', '/api/v1/link/$slot', hostname: 'den-b.test', body: grant.toJson());
      expect(crossed.status, 403, reason: "b's parent can't link a browser into a");
    });
  });
}
