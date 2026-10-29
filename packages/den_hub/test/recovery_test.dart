@Timeout(Duration(seconds: 90))
library;

import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_hub/cli_support.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/fixture.dart';

/// Server-assisted recovery: only for a family that turned it on, made by whoever runs the hub
/// with `den_hub recover`, redeemed once by the new phone.
void main() {
  late Directory dir;
  late HubFixture f;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('den-recovery');
    f = await HubFixture.start(dataDir: dir.path, configure: (c) => _withPublicUrl(c));
  });

  tearDown(() async {
    await f.stop();
    await dir.delete(recursive: true);
  });

  Uri sync() => f.base.replace(scheme: 'ws', path: '/ws');

  Future<Map<String, String>> signed(Den den, String method, String path) => DeviceRequest.sign(
        keys: den.keys,
        method: method,
        url: f.base.resolve(path),
        body: const [],
        hub: f.hubDen.deviceId,
        actorId: den.actor?.id,
      );

  /// What `den_hub recover` sends the running hub.
  Map<String, String> command() => {
        'x-den-recovery-secret': File('${dir.path}/hub/$recoveryCliFile').readAsStringSync().trim(),
      };

  /// Alex's phone asks the hub for its key and turns server help on.
  Future<String> turnOn() async {
    final r = await f.call('GET', '/api/v1/recovery/key', headers: await signed(f.phone, 'GET', '/api/v1/recovery/key'));
    expect(r.status, 200, reason: r.text);
    expect(r.body['on'], isFalse);
    final key = r.body['key']! as String;
    await f.phone.setServerRecoveryKey(key);
    await f.toHub();
    return key;
  }

  test('only a parent\'s own device gets the hub\'s key; it is kept, owner-only, beside the hub\'s secrets', () async {
    expect((await f.call('GET', '/api/v1/recovery/key')).status, 401);
    final key = await turnOn();
    final again = await f.call('GET', '/api/v1/recovery/key', headers: await signed(f.phone, 'GET', '/api/v1/recovery/key'));
    expect(again.body, {'key': key, 'on': true});
    final file = File('${dir.path}/hub/recovery.json');
    expect(file.readAsStringSync(), contains(key));
    if (!Platform.isWindows) expect(file.statSync().mode & 0x3f, 0, reason: 'nobody but the hub\'s user reads it');
  });

  test('den_hub recover only works once the family turned server help on, and only for a parent', () async {
    Future<ApiResult> ticket(String person, {Map<String, String>? headers}) =>
        f.call('POST', '/api/v1/recovery/tickets', body: {'person': person}, headers: headers ?? command());

    final stranger = await ticket('Alex', headers: {'x-den-recovery-secret': 'guess'});
    expect(stranger.status, 403, reason: 'only the command on the hub\'s machine, with the secret the hub left');
    final off = await ticket('Alex');
    expect(off.status, 403);
    expect(off.error['code'], 'off');
    expect(off.error['message'], contains('Let the hub help us get back in'));

    await turnOn();
    final made = await ticket('Alex');
    expect(made.status, 201, reason: made.text);
    final words = (made.body['words']! as List).cast<String>();
    expect(words, hasLength(4));
    expect(made.body['member_name'], 'Alex');
    expect(made.body['link'], 'https://den.example.com/#/recover/${words.join('-')}');
    expect(made.body['expires_ms'], closeTo(DateTime.now().millisecondsSinceEpoch + 30 * 60000, 60000));

    expect((await ticket('Maya')).error['code'], 'not_parent');
    final nobody = await ticket('Mallory');
    expect(nobody.error['code'], 'nobody');
    expect(nobody.error['message'], contains('Alex'));
  });

  test('the new phone redeems the words and joins as Alex; every device sees how', () async {
    await turnOn();
    final made = await f.call('POST', '/api/v1/recovery/tickets', body: {'person': 'Alex'}, headers: command());
    final code = made.body['code']! as String;

    final phone = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    final redeemed = await f.call('POST', '/api/v1/recovery/redeem', body: {'code': code.toUpperCase(), 'pubkey': phone.keys.pubkey});
    expect(redeemed.status, 200, reason: redeemed.text);
    expect(redeemed.body['member_name'], 'Alex');
    expect(redeemed.body['family'], f.phone.family!.name);
    final proof = RecoveryProof.parse(redeemed.body['proof'])!;
    expect(proof.kind, RecoveryKind.hub);
    expect(proof.member, f.id('Alex'));

    // Asked again by the same phone (a dropped connection), the same proof; by another, nothing.
    final retry = await f.call('POST', '/api/v1/recovery/redeem', body: {'code': code, 'pubkey': phone.keys.pubkey});
    expect(retry.body['proof'], redeemed.body['proof']);
    final other = await DeviceKeys.generate();
    expect((await f.call('POST', '/api/v1/recovery/redeem', body: {'code': code, 'pubkey': other.pubkey})).status, 404);

    final invite = await Invite.parse(redeemed.body['invite']! as String);
    final node = SyncNode(phone);
    addTearDown(node.close);
    final attempt = await node.joinWithRecoveryProof(
      await connectWebSocket(sync()),
      invite,
      proof,
      deviceName: "Alex's new iPhone",
      kind: DeviceKind.phone,
    );
    await attempt.completed;
    expect(phone.isApproved, isTrue);
    expect(phone.owner?.name, 'Alex');
    expect(recoveryOf(f.hubDen.device(phone.deviceId)!)?.kind, RecoveryKind.hub);
    await f.toPhone();
    final entry = f.phone.history().firstWhere((h) => h.rid == phone.deviceId && h.type == RecordType.device);
    expect(entry.actorName, "Alex's new iPhone");
    expect(entry.diffs.firstWhere((d) => d.field == 'recovery').after, {'kind': 'hub', 'member': f.id('Alex')});
    await phone.close();
  });

  test('turning server help off makes a waiting code useless', () async {
    await turnOn();
    final made = await f.call('POST', '/api/v1/recovery/tickets', body: {'person': 'Alex'}, headers: command());
    await f.phone.setServerRecoveryKey(null);
    await f.toHub();
    final phone = await DeviceKeys.generate();
    final r = await f.call('POST', '/api/v1/recovery/redeem', body: {'code': made.body['code'], 'pubkey': phone.pubkey});
    expect(r.status, 403);
    expect((await f.call('POST', '/api/v1/recovery/tickets', body: {'person': 'Alex'}, headers: command())).error['code'], 'off');
  });

  test('wrong words count, and too many stop the hub answering for a while', () async {
    await turnOn();
    final phone = await DeviceKeys.generate();
    final bad = await f.call('POST', '/api/v1/recovery/redeem', body: {'code': 'not four words', 'pubkey': phone.pubkey});
    expect(bad.status, 400);
    for (var i = 0; i < HubRecovery.maxWrong; i++) {
      final wrong = await f.call('POST', '/api/v1/recovery/redeem', body: {'code': 'maple river canoe tiger', 'pubkey': phone.pubkey});
      expect(wrong.status, 404);
    }
    final locked = await f.call('POST', '/api/v1/recovery/redeem', body: {'code': 'maple river canoe tiger', 'pubkey': phone.pubkey});
    expect(locked.status, 429);
  });

  test('one address may try only so many times, as with invites', () async {
    await turnOn();
    final phone = await DeviceKeys.generate();
    var limited = false;
    for (var i = 0; i < 25 && !limited; i++) {
      final r = await f.call('POST', '/api/v1/recovery/redeem', body: {'code': 'x', 'pubkey': phone.pubkey});
      limited = r.status == 429;
    }
    expect(limited, isTrue);
  });

  test('a code made while the hub was stopped works once it starts', () async {
    await turnOn();
    await f.hub.stop();
    final offline = HubContext(
      den: f.hubDen,
      gate: DenGate(f.hubDen),
      config: HubConfig(dataDir: dir.path, mdns: false),
      log: HubLog(level: LogLevel.error),
      state: HubState(dir.path),
      node: SyncNode(f.hubDen),
      http: http.Client(),
    );
    final ticket = await HubRecovery.offline(offline).issue('Alex');
    await offline.state.flush();
    await offline.node.close();
    expect(ticket.link, isNull, reason: 'the command didn\'t know the public address');
    final again = await DenHub.start(f.hubDen, f.hub.config);
    final phone = await DeviceKeys.generate();
    final r = await apiCall(again.localUrl, 'POST', '/api/v1/recovery/redeem', body: {'code': ticket.words.join(' '), 'pubkey': phone.pubkey});
    await again.stop();
    expect(r.status, 200, reason: r.text);
  });
}

HubConfig _withPublicUrl(HubConfig c) => HubConfig(
      port: c.port,
      host: c.host,
      mdns: c.mdns,
      dataDir: c.dataDir,
      log: c.log,
      publicUrl: Uri.parse('https://den.example.com'),
      public: false,
    );
