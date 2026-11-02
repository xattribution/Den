import 'dart:convert';
import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A JPEG's headers saying [width] by [height], padded to [size] bytes: enough for the schema,
/// which reads the format and size from the headers.
List<int> fakeJpeg({int width = Photo.side, int height = Photo.side, int size = 2000}) {
  final head = <int>[
    0xFF, 0xD8, // start of image
    0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
    0xFF, 0xC0, 0x00, 0x11, 0x08, height >> 8, height & 0xFF, width >> 8, width & 0xFF, 0x03, //
    0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
  ];
  return [...head, for (var i = head.length; i < size - 2; i++) i % 251, 0xFF, 0xD9];
}

/// A lossy WebP's headers saying [width] by [height].
List<int> fakeWebp({int width = Photo.side, int height = Photo.side}) {
  final b = List<int>.filled(64, 0);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      b[at + i] = s.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  ascii(8, 'WEBP');
  ascii(12, 'VP8 ');
  b[23] = 0x9D;
  b[24] = 0x01;
  b[25] = 0x2A;
  b[26] = width & 0xFF;
  b[27] = width >> 8;
  b[28] = height & 0xFF;
  b[29] = height >> 8;
  return b;
}

void main() {
  late TestClock clock;
  late Den phone;
  late String dana;

  setUp(() async {
    clock = TestClock.at(DateTime.utc(2026, 10, 14, 15));
    phone = await foundFamily(clock, timezone: 'America/Chicago');
    dana = phone.actor!.id;
  });

  group('rewards without asking', () {
    late String maya;
    late String leo;
    late Den mayaPhone;
    late String movie;

    setUp(() async {
      maya = await phone.addMember(name: 'Maya', role: Role.kid, tier: Tier.teen);
      leo = await phone.addMember(name: 'Leo', role: Role.kid, tier: Tier.big);
      movie = await phone.addReward(title: 'Movie night', cost: 8);
      await phone.adjustPoints(maya, 10, 'Helped out');
      await phone.adjustPoints(leo, 10, 'Helped out');
      mayaPhone = await joinDevice(phone, clock, member: maya, name: 'Maya\'s phone', kind: DeviceKind.phone);
    });

    test('a request waits for a parent until a parent turns the OK off for that kid', () async {
      expect(phone.family!.rewardsNeedOk(maya), isTrue);
      final first = await mayaPhone.requestReward(movie);
      expect(mayaPhone.points().pending.single.id, first);
      await sync(mayaPhone, phone);
      await phone.decideRedemption(first, approve: false);

      await phone.updateFamily({'oversight.$maya.${OversightSetting.rewardsNeedOk}': false});
      await exchange(phone, mayaPhone);
      expect(mayaPhone.family!.rewardsNeedOk(maya), isFalse);
      expect(mayaPhone.family!.rewardsNeedOk(leo), isTrue, reason: 'one kid at a time');
      final second = await mayaPhone.requestReward(movie);
      await sync(mayaPhone, phone);
      expect(phone.points().pending.map((r) => r.id), isNot(contains(second)));
      expect(phone.points().totals[maya], 2, reason: 'approved at once');
      expect(phone.history(type: RecordType.redemption).first.verb, 'requested');
    });

    test('the balance still counts requests waiting for a parent', () async {
      final waiting = await mayaPhone.requestReward(movie);
      await sync(mayaPhone, phone);
      await phone.updateFamily({'oversight.$maya.${OversightSetting.rewardsNeedOk}': false});
      final snack = await phone.addReward(title: 'Snack', cost: 5);
      await exchange(phone, mayaPhone);
      await expectLater(
        mayaPhone.requestReward(snack),
        throwsA(isA<InvalidInput>().having((e) => e.message, 'message', contains('waiting'))),
      );
      expect(mayaPhone.points().pending.map((r) => r.id), [waiting], reason: 'what waited before keeps waiting');
    });

    test('either the reward or the kid saying no asking is enough', () async {
      final bedtime = await phone.addReward(title: 'Later bedtime', cost: 2, needsApproval: false);
      final leoPhone = await joinDevice(phone, clock, member: leo, name: 'Leo\'s tablet');
      final free = await leoPhone.requestReward(bedtime);
      final asks = await leoPhone.requestReward(movie);
      await sync(leoPhone, phone);
      expect(phone.points().pending.map((r) => r.id), [asks]);
      expect(phone.points().pending.map((r) => r.id), isNot(contains(free)));
      expect(phone.points().totals[leo], 8);
    });

    test('only a parent on their own device turns it off', () async {
      final hub = await joinDevice(phone, clock, mode: DeviceMode.hub, name: 'Hub', kind: DeviceKind.hub);
      hub.actAs(dana, via: 'Claude');
      await expectLater(
        hub.updateFamily({'oversight.$maya.${OversightSetting.rewardsNeedOk}': false}),
        throwsA(isA<PermissionDenied>()),
      );
      final display = await joinDevice(phone, clock, mode: DeviceMode.shared, name: 'Kitchen', kind: DeviceKind.display);
      display.actAs(dana);
      await expectLater(
        display.updateFamily({'oversight.$maya.${OversightSetting.rewardsNeedOk}': false}),
        throwsA(isA<PermissionDenied>()),
      );
      await expectLater(
        mayaPhone.updateFamily({'oversight.$maya.${OversightSetting.rewardsNeedOk}': false}),
        throwsA(isA<PermissionDenied>()),
      );
      await expectLater(
        phone.updateFamily({'oversight.$maya.nap': false}),
        throwsA(isA<InvalidInput>()),
      );
    });

    test('a kid still decides nothing: not their own request, not anyone else\'s, no stars', () async {
      final leoPhone = await joinDevice(phone, clock, member: leo, name: 'Leo\'s tablet');
      final leos = await leoPhone.requestReward(movie);
      final mine = await mayaPhone.requestReward(movie);
      await phone.updateFamily({'oversight.$maya.${OversightSetting.rewardsNeedOk}': false});
      await exchange(phone, leoPhone);
      await exchange(phone, mayaPhone);
      await exchange(mayaPhone, leoPhone);
      await expectLater(mayaPhone.decideRedemption(leos, approve: true), throwsA(isA<PermissionDenied>()));
      await expectLater(mayaPhone.decideRedemption(mine, approve: true), throwsA(isA<PermissionDenied>()));
      await expectLater(mayaPhone.adjustPoints(leo, -5, 'Mine now'), throwsA(isA<PermissionDenied>()));
      final sticker = await phone.addReward(title: 'Sticker', cost: 1);
      await sync(phone, mayaPhone);
      await expectLater(mayaPhone.requestReward(sticker, member: leo), throwsA(isA<PermissionDenied>()));
    });

    test('with the OK on, a forged approval of a kid\'s own request counts for nothing', () async {
      final rid = newId();
      final forged = await forge(
        mayaPhone.keys,
        counter: 50,
        millis: clock.now + 1000,
        type: RecordType.redemption,
        rid: rid,
        actor: maya,
        fields: {'reward': movie, 'member': maya, 'cost': 8, 'status': 'approved', 'decidedBy': null},
      );
      final result = await phone.ingest([forged]);
      expect(result.invalid[forged.id], contains('approve'));
      expect(phone.points().totals[maya], 10);
    });

    test('two parents changing different settings for one kid both count, and privacy keeps its shape', () async {
      final tom = await phone.addMember(name: 'Tom', role: Role.parent);
      final tomPhone = await joinDevice(phone, clock, member: tom, name: 'Tom\'s phone', kind: DeviceKind.phone);
      await phone.updateFamily({'oversight.$maya': {'parentsSeePrivate': false}});
      await tomPhone.updateFamily({'oversight.$maya.${OversightSetting.rewardsNeedOk}': false});
      await phone.updateFamily({'oversight.$maya.${OversightSetting.ownPicture}': false});
      await exchange(phone, tomPhone);
      for (final d in [phone, tomPhone]) {
        final f = d.family!;
        expect(f.parentsSeePrivate(maya), isFalse);
        expect(f.rewardsNeedOk(maya), isFalse);
        expect(f.ownsPicture(d.member(maya)!), isFalse);
        expect(f.rec.map('oversight')[maya], {'parentsSeePrivate': false}, reason: 'what older versions read');
      }
    });
  });

  group('a sitter\'s last day', () {
    late String sam;
    late Den samPhone;

    setUp(() async {
      sam = await phone.addMember(name: 'Sam', role: Role.guest);
      await phone.updateMember(sam, {'until': '2026-10-18'});
      samPhone = await joinDevice(phone, clock, member: sam, name: 'Sam\'s phone', kind: DeviceKind.phone);
    });

    test('access lasts through the last day in the family\'s time zone', () async {
      final m = phone.member(sam)!;
      expect(m.until, '2026-10-18');
      expect(m.accessEndedOn('2026-10-18'), isFalse);
      expect(m.accessEndedOn('2026-10-19'), isTrue);
      expect(phone.member(dana)!.accessEndedOn('2030-01-01'), isFalse, reason: 'only sitters have a last day');
      clock.set(DateTime.utc(2026, 10, 19, 4, 30)); // 11:30 PM Sunday in Chicago
      expect(phone.accessEnded(samPhone.deviceId), isFalse);
      clock.set(DateTime.utc(2026, 10, 19, 5, 30)); // 12:30 AM Monday
      expect(phone.accessEnded(samPhone.deviceId), isTrue);
      expect(phone.accessEnded(phone.deviceId), isFalse);
    });

    test('a parent\'s own device removes the sitter\'s devices once the day has passed', () async {
      expect(await phone.endExpiredAccess(), isEmpty, reason: 'not yet');
      clock.set(DateTime.utc(2026, 10, 20, 15));
      final epoch = phone.spaceKeyEpoch(Space.family)!;
      expect(await phone.endExpiredAccess(), [sam]);
      final d = phone.device(samPhone.deviceId)!;
      expect(d.revoked, isTrue);
      expect(d.revokedAfter, isNotNull, reason: 'the usual revocation, with its cutoff');
      expect(phone.spaceKeyEpoch(Space.family), epoch + 1, reason: 'new keys for what the sitter held');
      expect(phone.history(type: RecordType.device).first.verb, 'removed');
      expect(await phone.endExpiredAccess(), isEmpty, reason: 'once');

      // The sitter's phone, its clock set back, can't write past the cutoff.
      final late = await forge(
        samPhone.keys,
        counter: 40,
        millis: DateTime.utc(2026, 10, 16, 12).millisecondsSinceEpoch,
        type: RecordType.item,
        rid: newId(),
        actor: sam,
        fields: {'list': 'x', 'text': 'Candy'},
      );
      final result = await phone.ingest([late]);
      expect(result.invalid, contains(late.id));
    });

    test('nothing ends access but a parent\'s own device', () async {
      clock.set(DateTime.utc(2026, 10, 20, 15));
      final kid = await phone.addMember(name: 'Leo', role: Role.kid);
      final kidPhone = await joinDevice(phone, clock, member: kid, name: 'Leo\'s phone', kind: DeviceKind.phone);
      expect(await kidPhone.endExpiredAccess(), isEmpty);
      final display = await joinDevice(phone, clock, mode: DeviceMode.shared, name: 'Kitchen', kind: DeviceKind.display);
      display.actAs(dana);
      expect(await display.endExpiredAccess(), isEmpty);
      expect(await samPhone.endExpiredAccess(), isEmpty);
      expect(phone.device(samPhone.deviceId)!.revoked, isFalse);
    });

    test('the last day is a parent\'s decision on their own device', () async {
      final hub = await joinDevice(phone, clock, mode: DeviceMode.hub, name: 'Hub', kind: DeviceKind.hub);
      hub.actAs(dana, via: 'Claude');
      await expectLater(hub.updateMember(sam, {'until': '2027-01-01'}), throwsA(isA<PermissionDenied>()));
      hub.actAs(null);
      await expectLater(samPhone.updateMember(sam, {'until': '2027-01-01'}), throwsA(isA<PermissionDenied>()));
      await expectLater(phone.updateMember(sam, {'until': 'Sunday'}), throwsA(isA<InvalidInput>()));
      await phone.updateMember(sam, {'until': null});
      expect(phone.member(sam)!.until, isNull);
    });

    test('ending it now makes yesterday the last day and removes their devices', () async {
      await phone.endAccessNow(sam);
      expect(phone.member(sam)!.until, '2026-10-13');
      expect(phone.device(samPhone.deviceId)!.revoked, isTrue);
      expect(phone.accessEnded(samPhone.deviceId), isTrue);
      await expectLater(phone.endAccessNow(dana), throwsA(isA<InvalidInput>()));
      // Extending after that means inviting them again: their old phone stays removed.
      await phone.updateMember(sam, {'until': '2026-11-01'});
      expect(phone.device(samPhone.deviceId)!.revoked, isTrue);
      expect(phone.accessEnded(samPhone.deviceId), isFalse);
    });
  });

  group('privacy changes', () {
    late String maya;

    setUp(() async {
      maya = await phone.addMember(name: 'Maya', role: Role.kid, tier: Tier.teen);
    });

    test('the latest change either way, with who made it', () async {
      expect(phone.privacyChange(maya), isNull);
      await phone.updateFamily({'oversight.$maya': {'parentsSeePrivate': true}});
      expect(phone.privacyChange(maya), isNull, reason: 'it was already so');
      await phone.updateFamily({'oversight.$maya': {'parentsSeePrivate': false}});
      final off = phone.privacyChange(maya)!;
      expect(off.parentsSee, isFalse);
      expect(off.by, dana);
      clock.advance(const Duration(minutes: 1));
      await phone.updateFamily({'oversight': {maya: {'parentsSeePrivate': true}}});
      final on = phone.privacyChange(maya)!;
      expect(on.parentsSee, isTrue);
      expect(on.change, isNot(off.change));
      await phone.updateFamily({'oversight.$maya.${OversightSetting.rewardsNeedOk}': false});
      expect(phone.privacyChange(maya)!.change, on.change, reason: 'other settings aren\'t privacy');
    });

    test('a teen\'s own device sees the change that reached it', () async {
      final mayaPhone = await joinDevice(phone, clock, member: maya, name: 'Maya\'s phone', kind: DeviceKind.phone);
      await phone.updateFamily({'oversight.$maya': {'parentsSeePrivate': false}});
      await sync(phone, mayaPhone);
      expect(mayaPhone.privacyChange(maya)!.parentsSee, isFalse);
      expect(mayaPhone.member(mayaPhone.privacyChange(maya)!.by!)!.name, 'Dana');
    });
  });

  group('photos', () {
    late String maya;
    late String leo;
    late String sam;
    late Den mayaPhone;
    late Den leoTablet;

    setUp(() async {
      maya = await phone.addMember(name: 'Maya', role: Role.kid, tier: Tier.teen);
      leo = await phone.addMember(name: 'Leo', role: Role.kid, tier: Tier.little);
      sam = await phone.addMember(name: 'Sam', role: Role.guest);
      mayaPhone = await joinDevice(phone, clock, member: maya, name: 'Maya\'s phone', kind: DeviceKind.phone);
      leoTablet = await joinDevice(phone, clock, member: leo, name: 'Leo\'s tablet');
    });

    test('a parent sets anyone\'s photo, kept in the family space for every device', () async {
      final bytes = fakeJpeg();
      final id = await phone.setPhoto(leo, bytes);
      final photo = phone.photo(id)!;
      expect(photo.space, Space.family);
      expect(photo.member, leo);
      expect(photo.mime, Photo.jpeg);
      expect(base64.decode(photo.data), bytes);
      expect(phone.member(leo)!.picture, 'photo:$id');
      expect(phone.member(leo)!.photo, id);
      await sync(phone, leoTablet);
      expect(leoTablet.member(leo)!.photo, id);
      expect(base64.decode(leoTablet.photo(id)!.data), bytes);
      final webp = await phone.setPhoto(maya, fakeWebp());
      expect(phone.photo(webp)!.mime, Photo.webp);
    });

    test('a photo a browser made small on its canvas (web/den_web.js) is one the schema takes', () async {
      final bytes = File('test/fixtures/canvas_photo.jpg').readAsBytesSync();
      expect(photoFormat(bytes), (mime: Photo.jpeg, width: 256, height: 256));
      final id = await phone.setPhoto(maya, bytes);
      expect(phone.member(maya)!.photo, id);
    });

    test('the schema takes only a small square JPEG or WebP', () async {
      await expectLater(phone.setPhoto(leo, fakeJpeg(width: 512, height: 512)), throwsA(isA<InvalidInput>()));
      await expectLater(phone.setPhoto(leo, fakeJpeg(width: 256, height: 200)), throwsA(isA<InvalidInput>()));
      await expectLater(phone.setPhoto(leo, fakeJpeg(size: Photo.maxBytes + 1)), throwsA(isA<InvalidInput>()));
      await expectLater(phone.setPhoto(leo, utf8.encode('<svg/>')), throwsA(isA<InvalidInput>()));
      expect(checkFields(RecordType.photo, {'member': leo, 'mime': Photo.jpeg, 'data': 'not base64!'}, creating: true), isNotNull);
      expect(checkFields(RecordType.photo, {'member': leo, 'mime': 'image/png', 'data': base64.encode(fakeJpeg())}, creating: true),
          isNotNull);
      expect(checkFields(RecordType.photo, {'member': leo, 'mime': Photo.jpeg, 'data': base64.encode(fakeJpeg(size: Photo.maxBytes))},
          creating: true), isNull);
      // A WebP called a JPEG.
      final forged = await forge(
        phone.keys,
        counter: 90,
        millis: clock.now + 1000,
        type: RecordType.photo,
        rid: newId(),
        actor: dana,
        fields: {'member': leo, 'mime': Photo.jpeg, 'data': base64.encode(fakeWebp())},
      );
      expect((await leoTablet.ingest([forged])).invalid[forged.id], contains('kind'));
    });

    test('a teen sets their own picture; a younger kid only once a parent allows it', () async {
      final id = await mayaPhone.setPhoto(maya, fakeJpeg());
      await mayaPhone.setPicture(maya, 'fox');
      await mayaPhone.setPicture(maya, Picture.photo(id));
      await expectLater(leoTablet.setPhoto(leo, fakeJpeg()), throwsA(isA<PermissionDenied>()));
      await expectLater(leoTablet.setPicture(leo, 'dinosaur'), throwsA(isA<PermissionDenied>()));
      await phone.updateFamily({'oversight.$leo.${OversightSetting.ownPicture}': true});
      await sync(phone, leoTablet);
      await leoTablet.setPicture(leo, 'dinosaur');
      await exchange(mayaPhone, phone);
      await phone.updateFamily({'oversight.$maya.${OversightSetting.ownPicture}': false});
      await sync(phone, mayaPhone);
      await expectLater(mayaPhone.setPicture(maya, 'owl'), throwsA(isA<PermissionDenied>()));
      await exchange(leoTablet, phone);
      await exchange(mayaPhone, phone);
      expect(phone.member(leo)!.picture, 'dinosaur');
      expect(phone.member(maya)!.picture, Picture.photo(id));
    });

    test('nobody but a parent changes someone else\'s picture, or names someone else\'s photo', () async {
      await expectLater(mayaPhone.setPicture(leo, 'fox'), throwsA(isA<PermissionDenied>()));
      await expectLater(mayaPhone.setPhoto(leo, fakeJpeg()), throwsA(isA<PermissionDenied>()));
      await expectLater(mayaPhone.updateMember(maya, {'picture': 'fox', 'name': 'Queen'}), throwsA(isA<PermissionDenied>()));
      final leos = await phone.setPhoto(leo, fakeJpeg());
      await sync(phone, mayaPhone);
      await expectLater(mayaPhone.setPicture(maya, Picture.photo(leos)), throwsA(isA<InvalidInput>()));
      final samPhone = await joinDevice(phone, clock, member: sam, name: 'Sam\'s phone', kind: DeviceKind.phone);
      await samPhone.setPhoto(sam, fakeJpeg());
      final grandpa = await phone.addMember(name: 'Grandpa', role: Role.adult);
      final grandpaPhone = await joinDevice(phone, clock, member: grandpa, name: 'Grandpa\'s phone', kind: DeviceKind.phone);
      await grandpaPhone.setPicture(grandpa, 'owl');
      await expectLater(grandpaPhone.setPicture(sam, 'owl'), throwsA(isA<PermissionDenied>()));
    });

    test('a shared screen changes pictures only as a verified parent, or as a kid allowed to', () async {
      final display = await joinDevice(phone, clock, mode: DeviceMode.shared, name: 'Kitchen', kind: DeviceKind.display);
      await expectLater(display.setPicture(leo, 'fox'), throwsA(isA<PermissionDenied>()));
      display.actAs(maya);
      await display.setPicture(maya, 'owl');
      await expectLater(display.setPicture(leo, 'fox'), throwsA(isA<PermissionDenied>()));
    });

    test('undo puts the picture back', () async {
      await phone.setPicture(leo, 'fox');
      final made = await phone.recording(() => phone.setPhoto(leo, fakeJpeg()));
      final id = made.value;
      await phone.undo(made.changes);
      expect(phone.member(leo)!.picture, 'fox');
      expect(phone.photo(id), isNull);
    });
  });
}
