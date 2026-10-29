import 'dart:typed_data';

import 'package:den_app/app/app_state.dart';
import 'package:den_app/design/widgets.dart';
import 'package:den_app/features/advanced/words/history_words.dart';
import 'package:den_app/features/family/screens/family_screen.dart';
import 'package:den_app/features/rewards/screens/points_screen.dart';
import 'package:den_app/platform/photos/photo_source.dart';
import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../helpers/shots.dart';
import 'calendar_shots.dart' show shootAt, tallPhone;
import 'family_fakes.dart';

const Size _tall = Size(390, 2000);

/// Taps on the real clock, so the engine can sign what the tap writes, then lets the screen
/// catch up.
Future<void> _tapAndWait(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 400));
  });
  await tester.pumpAndSettle();
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
  await tester.pumpAndSettle();
}

/// Text that contains [part], whatever spaces the line-breaking helpers made unbreakable.
Finder _says(String part) => find.byWidgetPredicate(
      (w) => w is Text && ((w.data ?? w.textSpan?.toPlainText()) ?? '').replaceAll(RegExp('[\u00a0\u202f]'), ' ').contains(part),
      description: 'text containing "$part"',
    );

String _id(Den den, String name) => den.members.firstWhere((m) => m.name == name).id;

/// The demo family with Sam, a sitter whose last day is [until], and Sam's phone approved.
/// Returns the parent's phone (Alex) and Sam's phone.
Future<(Den, Den)> _sitter(String? until) async {
  final phone = await createDemoFamily(now: demoNow);
  final sam = await phone.addMember(name: 'Sam', role: Role.guest, picture: 'sun');
  if (until != null) await phone.updateMember(sam, {'until': until});
  final samPhone = await _join(phone, sam, "Sam's phone");
  return (phone, samPhone);
}

/// A phone for [member], joined through [parent] and caught up.
Future<Den> _join(Den parent, String member, String name) async {
  final d = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: () => demoNow.millisecondsSinceEpoch);
  await d.requestJoin(
    familyId: parent.familyId!,
    founderPubkey: parent.founderPubkey!,
    deviceName: name,
    kind: DeviceKind.phone,
    memberId: member,
  );
  await parent.ingest(d.changesSince(parent.versionVector));
  await parent.approveDevice(d.deviceId, member: member, mode: DeviceMode.personal);
  await d.ingest(parent.changesSince(d.versionVector, spaces: parent.spacesForDevice(d.deviceId)), through: parent.completeVector);
  return d;
}

/// Maya's own phone, after [before] ran on Alex's.
Future<AppState> _mayasPhone(WidgetTester tester, {Future<void> Function(Den phone, String maya)? before}) =>
    real(tester, () async {
      final phone = await createDemoFamily(now: demoNow);
      final maya = _id(phone, 'Maya');
      await before?.call(phone, maya);
      return AppState(await _join(phone, maya, "Maya's phone"));
    });

/// A 256 px square photo: a face on a blue ground, as a JPEG.
Uint8List _portrait() {
  final image = img.Image(width: 256, height: 256);
  img.fill(image, color: img.ColorRgb8(70, 130, 200));
  img.fillCircle(image, x: 128, y: 300, radius: 120, color: img.ColorRgb8(40, 40, 60));
  img.fillCircle(image, x: 128, y: 110, radius: 58, color: img.ColorRgb8(236, 188, 150));
  img.fillCircle(image, x: 128, y: 70, radius: 52, color: img.ColorRgb8(80, 50, 30));
  img.fillCircle(image, x: 128, y: 118, radius: 50, color: img.ColorRgb8(236, 188, 150));
  return img.encodeJpg(image, quality: 85);
}

class _FakePhotos implements PhotoSource {
  _FakePhotos(this.bytes);
  final Uint8List bytes;
  int asked = 0;

  @override
  bool get canTake => true;

  @override
  bool get canChoose => true;

  @override
  Future<Uint8List?> take() async {
    asked++;
    return bytes;
  }

  @override
  Future<Uint8List?> choose() => take();
}

/// Decodes every photo the family's avatars show, on the real clock, so a screenshot draws them.
Future<void> _precachePhotos(WidgetTester tester, Den den) async {
  final context = tester.element(find.byType(Scaffold).first);
  await tester.runAsync(() async {
    for (final m in den.members) {
      final bytes = DenPhotos.of(m.photo);
      if (bytes != null) await precacheImage(MemoryImage(bytes), context);
    }
  });
  await tester.pumpAndSettle();
}

void main() {
  group('Rewards need my OK, per kid', () {
    testWidgets('the switch is unlocked and says what turning it off does before it saves', (tester) async {
      final state = await demo(tester);
      final maya = _id(state.den, 'Maya');
      await pumpScreen(tester, FamilyScreen(selected: maya), state: state, size: _tall, pushed: true);
      final line = find.ancestor(of: findWords('Rewards need my OK'), matching: find.byType(SwitchLine));
      expect(tester.widget<SwitchLine>(line).onChanged, isNotNull, reason: 'no longer locked on');
      await tester.tap(findWords('Rewards need my OK'));
      await tester.pumpAndSettle();
      expect(_says('trade stars for rewards without asking you'), findsOneWidget);
      expect(state.den.family!.rewardsNeedOk(maya), isTrue, reason: 'nothing saves before the yes');
      await matchShot('family_rewards_ok_confirm_phone');
      await _tapAndWait(tester, find.text('Turn off'));
      expect(state.den.family!.rewardsNeedOk(maya), isFalse);
      expect(findWords('Maya can trade stars for rewards without asking you'), findsOneWidget);
      expect(state.den.history().first.diffs.map((d) => d.field), ['oversight.$maya.rewardsNeedOk']);
      expect(historyLine(state, state.den.history().first).title, 'Maya can trade stars for rewards without asking');
    });

    testWidgets('on her own phone, Maya gets what she can afford without asking', (tester) async {
      final state = await _mayasPhone(tester, before: (phone, maya) async {
        await phone.updateFamily({'oversight.$maya.${OversightSetting.rewardsNeedOk}': false});
      });
      await shootWith(tester, 'points_kid_no_asking_phone', const PointsScreen(), state: state, size: tallPhone, pushed: true);
      expect(find.text('Get it'), findsWidgets);
      expect(find.text('Ask for this'), findsNothing);
    });
  });

  group('A sitter\'s last day', () {
    testWidgets('the sitter\'s page says until when, and the sheet says what a new day does', (tester) async {
      final (phone, _) = (await real(tester, () => _sitter('2026-10-18')));
      final state = AppState(phone);
      final sam = _id(phone, 'Sam');
      await shootWith(tester, 'family_sitter_phone', FamilyScreen(selected: sam), state: state, size: _tall, pushed: true);
      expect(find.text('Until Sunday'), findsOneWidget);
      await tester.tap(find.text('Has Den'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('No end'));
      await tester.pumpAndSettle();
      expect(_says('Sam can use Den until you remove Sam'), findsOneWidget);
      await tester.tap(find.text('Until Sunday').last);
      await tester.pumpAndSettle();
      expect(_says("End Sam's access now"), findsOneWidget);
      await matchShot('family_sitter_until_sheet_phone');
    });

    testWidgets('night', (tester) async {
      final (phone, _) = (await real(tester, () => _sitter('2026-10-18')));
      await shootWith(tester, 'family_sitter_phone_night', FamilyScreen(selected: _id(phone, 'Sam')), state: AppState(phone), night: true, pushed: true);
    });

    testWidgets('iPad, landscape', (tester) async {
      final (phone, _) = (await real(tester, () => _sitter('2026-10-18')));
      await shootWith(tester, 'family_sitter_tablet', FamilyScreen(selected: _id(phone, 'Sam')), state: AppState(phone), size: tablet, pushed: true);
    });

    testWidgets('saving a day and ending access now', (tester) async {
      final (phone, samPhone) = (await real(tester, () => _sitter(null)));
      final state = AppState(phone);
      final sam = _id(phone, 'Sam');
      await pumpScreen(tester, FamilyScreen(selected: sam), state: state, size: _tall, pushed: true);
      expect(find.text('No end'), findsOneWidget);
      await tester.tap(find.text('Has Den'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Until Sunday'));
      await tester.pumpAndSettle();
      await _tapAndWait(tester, find.text('Save'));
      expect(phone.member(sam)!.until, '2026-10-18');
      await tester.tap(find.text('Has Den'));
      await tester.pumpAndSettle();
      await tester.tap(find.text("End Sam's access now"));
      await tester.pumpAndSettle();
      expect(_says('stop syncing and are removed now'), findsOneWidget);
      await _tapAndWait(tester, find.text('End access'));
      expect(phone.device(samPhone.deviceId)!.revoked, isTrue);
      expect(phone.member(sam)!.accessEndedOn(phone.todayDate()), isTrue);
      expect(_says("Sam's access ended Thursday. To let Sam back in"), findsOneWidget);
      expect(find.text('Invite Sam'), findsNothing, reason: 'a new day first, then an invite');
    });

    testWidgets('after the day, a parent\'s phone removes the sitter\'s phone and says so in Needs you', (tester) async {
      final (phone, samPhone) = (await real(tester, () => _sitter('2026-10-11')));
      final state = AppState(phone);
      await shootAt(tester, 'today_sitter_ended_phone', state: state, location: '/today');
      expect(findWords("Sam's access ended Sunday"), findsOneWidget);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
      await tester.pumpAndSettle();
      expect(phone.device(samPhone.deviceId)!.revoked, isTrue, reason: 'Den on Alex\'s own phone ends it');
      final removed = phone.history(type: RecordType.device).first;
      final line = historyLine(state, removed);
      expect('${line.verb} ${line.title}', "removed Sam's phone: Sam's access ended Sunday");
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      expect(findWords("Sam's access ended Sunday"), findsNothing);
      expect(state.seen('ended:${_id(phone, 'Sam')}:2026-10-11'), isTrue);
    });

    testWidgets('the sitter\'s own phone says their access ended', (tester) async {
      final (_, samPhone) = (await real(tester, () => _sitter('2026-10-11')));
      await shootAt(tester, 'sitter_access_ended_phone', state: AppState(samPhone), location: '/today');
      expect(findWords('Your access ended'), findsOneWidget);
      expect(_says('through Sunday, October 11'), findsOneWidget);
    });
  });

  group('Privacy changes reach the teen', () {
    testWidgets('turning privacy on says plainly that what parents saw can\'t be unseen', (tester) async {
      final state = await demo(tester);
      final maya = _id(state.den, 'Maya');
      await pumpScreen(tester, FamilyScreen(selected: maya), state: state, size: _tall, pushed: true);
      await tester.tap(findWords('Can keep things private from parents'));
      await tester.pumpAndSettle();
      await matchShot('family_private_confirm_phone');
      expect(_says("What you already saw can't be unseen"), findsOneWidget);
      expect(_says('Maya will see that you changed this'), findsOneWidget);
    });

    testWidgets('her Today says who changed it and what it means, until she says Got it', (tester) async {
      final state = await _mayasPhone(tester, before: (phone, maya) async {
        await phone.updateFamily({'oversight.$maya': {'parentsSeePrivate': false}});
        await phone.updateFamily({'oversight.$maya': {'parentsSeePrivate': true}});
      });
      await shootAt(tester, 'today_teen_privacy_notice_phone', state: state, location: '/today');
      expect(findWords('Alex changed this: parents can now see things you mark Just me'), findsOneWidget);
      final entry = state.den.history(type: RecordType.family).first;
      final line = historyLine(state, entry);
      expect('${entry.actorName} ${line.verb} ${line.title}', 'Alex changed this: parents can now see things you mark Just me');
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      expect(findWords('Alex changed this: parents can now see things you mark Just me'), findsNothing);
    });

    testWidgets('iPad, landscape, night', (tester) async {
      final state = await _mayasPhone(tester, before: (phone, maya) async {
        await phone.updateFamily({'oversight.$maya': {'parentsSeePrivate': false}});
        await phone.updateFamily({'oversight.$maya': {'parentsSeePrivate': true}});
      });
      await shootAt(tester, 'today_teen_privacy_notice_tablet_night', state: state, location: '/today', size: tablet, night: true);
    });

    testWidgets('at 200 % text', (tester) async {
      final state = await _mayasPhone(tester, before: (phone, maya) async {
        await phone.updateFamily({'oversight.$maya': {'parentsSeePrivate': false}});
      });
      await shootAt(tester, 'today_teen_privacy_notice_phone_200', state: state, location: '/today', size: const Size(390, 1600), text: 2);
      expect(findWords('Alex changed this: things you mark Just me are for you alone'), findsOneWidget);
    });
  });

  group('Photos', () {
    testWidgets('the picture sheet offers Camera and Photos, and a photo becomes the picture', (tester) async {
      final state = await demo(tester);
      final photos = _FakePhotos(_portrait());
      final before = Photos.source;
      Photos.source = photos;
      addTearDown(() => Photos.source = before);
      final leo = _id(state.den, 'Leo');
      await pumpScreen(tester, FamilyScreen(selected: leo), state: state, pushed: true);
      await tester.tap(find.text('Change picture'));
      await tester.pumpAndSettle();
      expect(find.text('Camera'), findsOneWidget);
      expect(find.text('Photos'), findsOneWidget);
      await matchShot('family_picture_sheet_camera_phone');
      await _tapAndWait(tester, find.text('Photos'));
      expect(photos.asked, 1);
      final photo = state.den.member(leo)!.photo;
      expect(photo, isNotNull);
      expect(state.den.photo(photo!)!.space, Space.family);
      expect(DenPhotos.of(photo), isNotNull);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await _precachePhotos(tester, state.den);
      await matchShot('family_photo_avatar_phone');
    });

    testWidgets('night, at 200 % text: the tiles move under the picture', (tester) async {
      final state = await demo(tester);
      withTextScale(tester, 2);
      await pumpScreen(tester, FamilyScreen(selected: _id(state.den, 'Maya')), state: state, night: true, size: const Size(390, 1400), pushed: true);
      await tester.tap(find.text('Change picture'));
      await tester.pumpAndSettle();
      await matchShot('family_picture_sheet_camera_phone_night_200');
    });

    testWidgets('a teen changes their own picture; a little kid only once a parent allows it', (tester) async {
      final teen = await _mayasPhone(tester);
      await pumpScreen(tester, FamilyScreen(selected: teen.den.owner!.id), state: teen, pushed: true);
      expect(find.text('Change picture'), findsOneWidget);
      await tester.tap(find.text('Change picture'));
      await tester.pumpAndSettle();
      expect(findWords('Your picture'), findsOneWidget);
      expect(_says('color'), findsNothing, reason: 'a parent changes colors');
      await _tapAndWait(tester, find.text('Rocket'));
      expect(teen.den.owner!.picture, 'rocket');

      final kid = await littleKidTablet(tester);
      final leo = kid.den.owner!;
      await pumpScreen(tester, FamilyScreen(selected: leo.id), state: kid, pushed: true);
      expect(find.text('Change picture'), findsNothing);
    });

    testWidgets('a parent sees the switch on a kid\'s page', (tester) async {
      final state = await demo(tester);
      await pumpScreen(tester, FamilyScreen(selected: _id(state.den, 'Leo')), state: state, size: _tall, pushed: true);
      expect(findWords('Can change their own picture'), findsOneWidget);
      expect(findWords('Only parents change it'), findsOneWidget);
    });
  });
}
