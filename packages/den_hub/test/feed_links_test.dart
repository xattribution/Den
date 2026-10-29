@Timeout(Duration(seconds: 90))
library;

import 'dart:convert';
import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';

import 'support/fixture.dart';
import 'support/test.dart';

/// "Show Den in iPhone Calendar": calendar links a parent makes from their own phone.
void main() {
  late HubFixture f;
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('den-feed-links');
    f = await HubFixture.start(
      dataDir: dir.path,
      configure: (base) => HubConfig(
        port: 0,
        host: InternetAddress.loopbackIPv4,
        mdns: false,
        dataDir: dir.path,
        log: HubLog(level: LogLevel.error, sink: (_) {}),
      ),
    );
  });

  tearDown(() async {
    await f.stop();
    await dir.delete(recursive: true);
  });

  /// A device approved by Alex's phone for [name] (null: a shared display).
  Future<Den> device(String? name, {DeviceMode mode = DeviceMode.personal}) async {
    final d = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    final member = name == null ? null : f.id(name);
    await d.requestJoin(
      familyId: f.phone.familyId!,
      founderPubkey: f.phone.founderPubkey!,
      deviceName: "${name ?? 'Kitchen'}'s iPhone",
      kind: mode == DeviceMode.shared ? DeviceKind.display : DeviceKind.phone,
      mode: mode,
      memberId: member,
    );
    await f.phone.ingest(d.changesSince(const {}));
    await f.phone.approveDevice(d.deviceId, member: member, mode: mode);
    await f.toHub();
    await d.ingest(f.phone.changesSince(const {}));
    return d;
  }

  /// Calls the hub as [den], signing with its key.
  Future<ApiResult> signed(Den den, String method, String path, {Object? body}) async {
    final bytes = body == null ? <int>[] : utf8.encode(jsonEncode(body));
    final url = f.base.resolve(path);
    final headers = await DeviceRequest.sign(
      keys: den.keys,
      method: method,
      url: url,
      body: bytes,
      hub: f.hubDen.deviceId,
      actorId: den.actor?.id,
    );
    return f.call(method, path, body: body, headers: headers);
  }

  /// The path of [url] on the hub.
  String pathOf(String url) => Uri.parse(url).path;

  test('a parent makes a link from their own phone, a calendar app reads it, and turning it off ends it', () async {
    final alex = await device('Alex');
    final made = await signed(alex, 'POST', '/api/v1/feeds', body: {'feed': 'family', 'label': "Alex's iPhone"});
    expect(made.status, 201, reason: made.text);
    final url = made.body['url']! as String;
    expect(url, startsWith('${f.base}/ics/denfeed_'));
    expect(url, endsWith('/family.ics'));
    expect(made.body['webcal'], url.replaceFirst('http://', 'webcal://'));
    expect(made.body['made_by_name'], 'Alex');
    expect(File('${dir.path}/hub/feed_links.json').readAsStringSync(), isNot(contains(url.split('/')[4])),
        reason: 'the hub keeps a hash, never the address');

    final calendar = await f.call('GET', pathOf(url));
    expect(calendar.status, 200);
    expect(calendar.headers['content-type'], 'text/calendar; charset=utf-8');
    expect(calendar.text, contains('Soccer practice'));

    final listed = await signed(alex, 'GET', '/api/v1/feeds');
    expect(listed.status, 200);
    final feeds = (listed.body['feeds']! as List).cast<Map<String, Object?>>();
    expect(feeds.single['label'], "Alex's iPhone");
    expect(feeds.single.containsKey('url'), isFalse, reason: 'the address is shown once');

    final off = await signed(alex, 'DELETE', '/api/v1/feeds/${feeds.single['id']}');
    expect(off.status, 200);
    expect((await f.call('GET', pathOf(url))).status, 401);
    expect((await signed(alex, 'DELETE', '/api/v1/feeds/${feeds.single['id']}')).status, 404);
  });

  test("a person's link holds their events and everyone's, and opens nothing else", () async {
    final alex = await device('Alex');
    final leo = f.id('Leo');
    final made = await signed(alex, 'POST', '/api/v1/feeds', body: {'feed': leo, 'label': "Leo's calendar"});
    expect(made.status, 201, reason: made.text);
    final path = pathOf(made.body['url']! as String);
    expect(path, endsWith('/$leo.ics'));
    final calendar = await f.call('GET', path);
    expect(calendar.text, contains('Soccer practice'));
    expect(calendar.text, isNot(contains('Anniversary dinner')));

    final secret = path.split('/')[2];
    expect((await f.call('GET', '/ics/$secret/family.ics')).status, 404, reason: 'only the feed it was made for');
    expect((await f.call('GET', '/api/v1/today', token: secret)).status, 401, reason: 'never a token for the API');
  });

  test('it holds what its maker may read: a kid\'s private events stay out once parents may not see them', () async {
    final alex = await device('Alex');
    final leo = f.id('Leo');
    final today = f.phone.dayStart(f.phone.todayDate());
    await f.phone.addEvent(
      title: 'Secret surprise planning',
      start: today + 30 * 3600000,
      end: today + 31 * 3600000,
      assignees: [leo],
      space: Space.member(leo),
    );
    await f.toHub();
    final made = await signed(alex, 'POST', '/api/v1/feeds', body: {'feed': 'family', 'label': "Alex's iPhone"});
    final path = pathOf(made.body['url']! as String);
    expect((await f.call('GET', path)).text, contains('Secret surprise planning'));

    await f.phone.updateFamily({
      'oversight': {leo: {'parentsSeePrivate': false}},
    });
    await f.toHub();
    final after = await f.call('GET', path);
    expect(after.status, 200);
    expect(after.text, isNot(contains('Secret surprise planning')));
  });

  test("only a parent's own device makes, lists or turns off links", () async {
    final alex = await device('Alex');
    final zoe = await device('Zoe');
    final kitchen = await device(null, mode: DeviceMode.shared);
    expect((await f.call('POST', '/api/v1/feeds', body: {'feed': 'family', 'label': 'x'})).status, 401);
    expect((await signed(zoe, 'POST', '/api/v1/feeds', body: {'feed': 'family', 'label': "Zoe's iPad"})).status, 403);
    expect((await signed(kitchen, 'GET', '/api/v1/feeds')).status, 403);
    final made = await signed(alex, 'POST', '/api/v1/feeds', body: {'feed': 'family', 'label': "Alex's iPhone"});
    expect((await signed(zoe, 'DELETE', '/api/v1/feeds/${made.body['id']}')).status, 403);
    expect((await signed(alex, 'POST', '/api/v1/feeds', body: {'feed': 'nobody', 'label': 'x'})).status, 400);
    expect((await signed(alex, 'POST', '/api/v1/feeds', body: {'feed': 'family', 'label': ''})).status, 400);
  });

  test('a link stops working when the device it was made on is removed', () async {
    final alex = await device('Alex');
    final made = await signed(alex, 'POST', '/api/v1/feeds', body: {'feed': 'family', 'label': "Alex's old iPhone"});
    final path = pathOf(made.body['url']! as String);
    final other = await signed(f.phone, 'POST', '/api/v1/feeds', body: {'feed': 'family', 'label': "Alex's iPad"});
    final kept = pathOf(other.body['url']! as String);
    expect((await f.call('GET', path)).status, 200);
    await f.phone.revokeDevice(alex.deviceId);
    await f.toHub();
    expect((await f.call('GET', path)).status, 401, reason: 'a lost phone\'s links end with it');
    expect((await f.call('GET', kept)).status, 200, reason: 'links Alex made on another device go on');
    final listed = await signed(f.phone, 'GET', '/api/v1/feeds');
    expect([for (final l in listed.body['feeds']! as List) (l as Map)['label']], ["Alex's iPad"]);
  });

  test('a link stops working when the parent who made it leaves the family', () async {
    final priya = await device('Priya');
    final made = await signed(priya, 'POST', '/api/v1/feeds', body: {'feed': 'family', 'label': "Priya's iPhone"});
    final path = pathOf(made.body['url']! as String);
    expect((await f.call('GET', path)).status, 200);
    await f.phone.removeMember(f.id('Priya'));
    await f.toHub();
    expect((await f.call('GET', path)).status, 401);
  });
}
