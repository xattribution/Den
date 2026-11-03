@Timeout(Duration(seconds: 120))
library;

import 'dart:convert';
import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

/// Linked families (family_links.dart): a parent of one family makes a link, a parent of the
/// other accepts it, and the two hubs keep what each shares in step, both ways, over whatever
/// address reaches the other hub.
void main() {
  final hubs = <HubFixture>[];
  setUpAll(() => FamilyLinks.interval = const Duration(milliseconds: 200));
  tearDown(() async {
    for (final f in hubs.reversed) {
      await f.stop();
    }
    hubs.clear();
  });

  Future<HubFixture> hubFor(String name) async {
    final phone = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    await phone.createFamily(
      familyName: name,
      timezone: 'America/Chicago',
      yourName: 'Alex',
      deviceName: "Alex's phone",
      deviceKind: DeviceKind.phone,
    );
    final f = await HubFixture.start(
      phone: phone,
      configure: (c) => HubConfig(
        port: 0,
        host: InternetAddress.loopbackIPv4,
        mdns: false,
        log: HubLog(level: LogLevel.error, sink: (line) => stderr.writeln('[$name] $line')),
      ),
    );
    hubs.add(f);
    return f;
  }

  Future<ApiResult> signed(HubFixture f, String method, String path, {Object? body}) async {
    final bytes = body == null ? <int>[] : utf8.encode(jsonEncode(body));
    final headers = await DeviceRequest.sign(
      keys: f.phone.keys,
      method: method,
      url: f.base.resolve(path),
      body: bytes,
      hub: f.hubDen.deviceId,
      actorId: f.phone.actor?.id,
    );
    return f.call(method, path, body: body, headers: headers);
  }

  /// Links [a] with [b], [a] sharing [share]; returns the link's id.
  Future<String> link(HubFixture a, HubFixture b, Map<String, ShareLevel> share) async {
    final id = await a.phone.addFamilyLink();
    for (final e in share.entries) {
      await a.phone.shareWithFamily(id, e.key, e.value);
    }
    await a.toHub();
    final offer = await signed(a, 'POST', '/api/v1/families/$id/offer');
    expect(offer.status, 200, reason: offer.text);
    final url = offer.body['url']! as String;
    expect(url, contains('/family-link/$id/'));
    await b.phone.addFamilyLink(id: id);
    await b.toHub();
    final accepted = await signed(b, 'POST', '/api/v1/families/accept', body: {'url': url});
    expect(accepted.status, 200, reason: accepted.text);
    expect(accepted.body['name'], a.phone.family!.name);
    await eventually(() => a.hubDen.familyLink(id)?.status == LinkStatus.linked);
    return id;
  }

  test('a shared list goes both ways; a shared calendar follows its family', () async {
    final smith = await hubFor('Smith');
    final jones = await hubFor('Jones');
    final groceries = await smith.phone.addList(title: 'Groceries', kind: ListKind.shopping);
    final milk = await smith.phone.addItem(groceries, text: 'Milk');
    final now = DateTime.now().millisecondsSinceEpoch;
    final soccer = await smith.phone.addEvent(title: 'Soccer', start: now + 3600000, end: now + 7200000);
    final id = await link(smith, jones, {Shared.calendar: ShareLevel.see, groceries: ShareLevel.edit});

    // The Joneses get the list and the event, marked with the link, and know what's shared.
    await eventually(() => jones.hubDen.list(groceries)?.items.length == 1 && jones.hubDen.event(soccer) != null);
    expect(jones.hubDen.list(groceries)!.list.link, id);
    expect(jones.hubDen.event(soccer)!.link, id);
    await eventually(() => jones.hubDen.familyLink(id)!.theirs.length == 2);
    expect(jones.hubDen.familyLink(id)!.name, 'Smith');
    expect(smith.hubDen.familyLink(id)!.name, 'Jones');

    // A Jones checks the milk off and adds eggs: the Smiths have both.
    await jones.toPhone();
    await jones.phone.setItemChecked(milk, true);
    final eggs = await jones.phone.addItem(groceries, text: 'Eggs');
    await jones.toHub();
    await eventually(() => smith.hubDen.list(groceries)!.items.any((i) => i.id == eggs));
    await eventually(() => smith.hubDen.list(groceries)!.items.firstWhere((i) => i.id == milk).checked);
    // The Smiths' Eggs is their own now: no mark, in their own list.
    expect(smith.hubDen.list(groceries)!.list.link, isNull);

    // The Smiths rename the event; the Joneses see it. A Jones renaming it (shared only to see)
    // is put back.
    await smith.phone.updateEvent(soccer, {'title': 'Soccer practice'});
    await smith.toHub();
    await eventually(() => jones.hubDen.event(soccer)!.title == 'Soccer practice');
    await jones.toPhone();
    await jones.phone.updateEvent(soccer, {'title': 'Not ours to change'});
    await jones.toHub();
    await eventually(() => jones.hubDen.event(soccer)!.title == 'Soccer practice');
    expect(smith.hubDen.event(soccer)!.title, 'Soccer practice');

    // The Smiths stop sharing the list: it goes from the Joneses.
    await smith.phone.shareWithFamily(id, groceries, null);
    await smith.toHub();
    await eventually(() => jones.hubDen.list(groceries) == null);
    expect(jones.hubDen.event(soccer), isNotNull);

    // The Joneses end the link: the Smiths hear, and the event goes from the Joneses.
    await jones.toPhone();
    await jones.phone.endFamilyLink(id);
    await jones.toHub();
    await eventually(() => smith.hubDen.familyLink(id)!.status == LinkStatus.ended);
    await eventually(() => jones.hubDen.event(soccer) == null);
    expect(smith.hubDen.event(soccer), isNotNull);
  });

  test('a calendar both families change, and an event the other family adds to it', () async {
    final smith = await hubFor('Smith');
    final jones = await hubFor('Jones');
    final now = DateTime.now().millisecondsSinceEpoch;
    final trip = await smith.phone.addEvent(title: 'Camping', start: now + 86400000, end: now + 90000000);
    final id = await link(smith, jones, {Shared.calendar: ShareLevel.edit});
    await eventually(() => jones.hubDen.event(trip) != null);
    await jones.toPhone();
    await jones.phone.updateEvent(trip, {'location': 'Lake Ray Roberts'});
    final potluck = await jones.phone.addEvent(title: 'Potluck', start: now + 7200000, end: now + 9000000, link: id);
    await jones.toHub();
    await eventually(() => smith.hubDen.event(trip)!.location == 'Lake Ray Roberts');
    await eventually(() => smith.hubDen.event(potluck) != null);
    // The potluck is the Smiths' own now, and still on the Joneses' calendar through the link.
    expect(smith.hubDen.event(potluck)!.link, isNull);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(jones.hubDen.event(potluck)!.link, id);
    expect(jones.hubDen.event(potluck)!.title, 'Potluck');
  });

  test('the other family\'s hub needs the link\'s secret; a wrong one finds nothing', () async {
    final smith = await hubFor('Smith');
    final id = await smith.phone.addFamilyLink();
    await smith.toHub();
    final offer = await signed(smith, 'POST', '/api/v1/families/$id/offer');
    final wrong = await smith.call('POST', '/api/v1/families/peer/$id/accept',
        token: 'A' * 43, body: {'family': 'abcdefghijklmnop', 'name': 'Nope'}, headers: fromTunnel);
    expect(wrong.status, 404);
    final secret = Uri.parse(offer.body['url']! as String).pathSegments.last;
    final right = await smith.call('POST', '/api/v1/families/peer/$id/accept',
        token: secret, body: {'family': 'abcdefghijklmnop', 'name': 'Jones'}, headers: fromTunnel);
    expect(right.status, 200, reason: right.text);
    // Once only, for one family.
    final again = await smith.call('POST', '/api/v1/families/peer/$id/accept',
        token: secret, body: {'family': 'qrstuvwxyzabcdef', 'name': 'Other'}, headers: fromTunnel);
    expect(again.status, 409);
    // A kid's phone, or anyone not a parent on their own phone, can't make a link's address.
    final unsigned = await smith.call('POST', '/api/v1/families/$id/offer');
    expect(unsigned.status, 401);
  });
}
