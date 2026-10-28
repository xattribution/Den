import 'dart:convert';

import 'package:den_app/net/hub_push.dart';
import 'package:den_app/net/pairing.dart';
import 'package:den_app/screens/family/device_parts.dart';
import 'package:den_app/screens/settings/web_reminders.dart';
import 'package:den_app/screens/today/today_screen.dart';
import 'package:den_app/web/web_app.dart';
import 'package:den_app/web/web_insets.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';

/// The hub's push endpoints, answering at once.
class FakePushClient extends HubPushClient {
  FakePushClient(super.network);

  @override
  Future<HubPushStatus> status() async => const HubPushStatus(key: 'BPk-key', subscribed: false);
}

const homeScreen = WebAppInfo(
  ios: true,
  iosVersion: (major: 18, minor: 6),
  standalone: true,
  secure: true,
  worker: true,
  push: true,
  permission: 'default',
  share: true,
  ready: true,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('A device asking to join for someone is approved from Today with one tap', (tester) async {
    final state = await demo(tester);
    final zoe = kidOf(state);
    final asking = await real(tester, () async {
      final d = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
      await d.requestJoin(
        familyId: state.den.familyId!,
        founderPubkey: state.den.founderPubkey!,
        deviceName: "${zoe.name}'s iPhone",
        kind: DeviceKind.phone,
        memberId: zoe.id,
      );
      await state.den.ingest(d.changesSince(const {}));
      return d;
    });
    await pumpScreen(tester, const TodayScreen(), state: state);
    expect(find.text("${zoe.name}'s iPhone wants to join as ${zoe.name}"), findsOneWidget);
    await matchShot('today_join_request_phone');
    await tester.tap(find.text("Approve ${zoe.name}'s iPhone"));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    final device = state.den.device(asking.deviceId)!;
    expect(device.approved, isTrue);
    expect(device.member, zoe.id);
    expect(find.textContaining('wants to join'), findsNothing);
  });

  testWidgets("A parent signed in on a shared screen isn't offered to approve: only their own device can", (tester) async {
    final state = await kitchen(tester);
    final parent = state.den.members.firstWhere((m) => m.isParent);
    final den = state.den;
    await real(tester, () async {
      final d = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
      await d.requestJoin(
        familyId: den.familyId!,
        founderPubkey: den.founderPubkey!,
        deviceName: "Grandma's iPhone",
        kind: DeviceKind.phone,
      );
      await den.ingest(d.changesSince(const {}));
      return d;
    });
    den.actAs(parent.id);
    expect(state.allows(DenAction.manageFamily), isTrue);
    expect(state.allowsTrust(DenAction.manageFamily), isFalse);
    await pumpScreen(tester, const TodayScreen(), state: state);
    expect(find.textContaining('wants to join'), findsNothing);
    den.actAs(null);
  });

  testWidgets('An invite by message: the words, Send and Copy', (tester) async {
    final state = await demo(tester);
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final invite = InviteMessage(
      words: const ['maple', 'river', 'candle', 'tiger'],
      link: Uri.parse('https://den.example.com/#/join/maple-river-candle-tiger'),
      expires: demoNow.add(const Duration(days: 3)).millisecondsSinceEpoch,
      familyName: 'The Carters',
      forName: 'Grandma',
      qr: 'den://join?f=7Q2KX4M9PA3TBV6W&fk=Zm91bmRlcg&d=8CQ3HPLA&k=aW52aXRlcg&s=c2VjcmV0c2VjcmV0MTI4&x=1792170000',
    );
    await pumpScreen(
      tester,
      SingleChildScrollView(child: InvitePanel(now: () => demoNow)),
      state: state,
      pairing: FakePairing(now: demoNow, invite: invite),
    );
    expect(find.text('maple river candle tiger'), findsOneWidget);
    expect(find.text('Send invite'), findsOneWidget);
    await matchShot('family_invite_message_phone');
    await tester.tap(find.text('Copy invite'));
    await tester.pumpAndSettle();
    expect(copied.single, invite.text);
    expect(find.text('Copied. Paste it into a message to them.'), findsOneWidget);
  });

  testWidgets('Reminders in Safari say to add Den to the Home Screen first', (tester) async {
    final state = await demo(tester);
    await pumpScreen(
      tester,
      const WebReminders(web: WebAppInfo(ios: true, iosVersion: (major: 18, minor: 6), secure: true, worker: true)),
      state: state,
    );
    expect(find.textContaining('Reminders work once Den is on your Home Screen'), findsOneWidget);
  });

  testWidgets('Reminders on an iPhone before iOS 16.4 say to update it', (tester) async {
    final state = await demo(tester);
    await pumpScreen(
      tester,
      const WebReminders(web: WebAppInfo(ios: true, iosVersion: (major: 16, minor: 3), standalone: true, secure: true)),
      state: state,
    );
    expect(find.textContaining('need iOS 16.4 or later'), findsOneWidget);
  });

  testWidgets('Reminders on a Home Screen iPhone: one tap, and an honest note when it fails', (tester) async {
    final state = await networked(tester);
    await pumpScreen(tester, WebReminders(web: homeScreen, client: FakePushClient(state.network!)), state: state);
    expect(find.text('Turn on reminders on this iPhone'), findsOneWidget);
    await matchShot('settings_web_reminders_phone');
    await tester.tap(find.text('Turn on reminders on this iPhone'));
    await tester.pumpAndSettle();
    expect(find.text("This iPhone couldn't turn on reminders. Try again."), findsOneWidget);
  });

  testWidgets('The safe areas pad the app on the web, except under the keyboard', (tester) async {
    late EdgeInsets padding;
    Widget app(EdgeInsets keyboard) => MediaQuery(
          data: MediaQueryData(size: const Size(390, 844), viewInsets: keyboard),
          child: WebSafeArea(
            insets: const [0, 0, 34, 0],
            child: Builder(builder: (context) {
              padding = MediaQuery.paddingOf(context);
              return const SizedBox.shrink();
            }),
          ),
        );
    await tester.pumpWidget(app(EdgeInsets.zero));
    expect(padding.bottom, 34);
    await tester.pumpWidget(app(const EdgeInsets.only(bottom: 300)));
    expect(padding.bottom, 0);
  });

  test('Where reminders can work, and why not', () {
    const safari = WebAppInfo(ios: true, iosVersion: (major: 18, minor: 6), secure: true);
    expect(pushAvailability(safari), PushAvailability.addToHomeScreen);
    expect(pushAvailability(homeScreen), PushAvailability.ready);
    expect(
      pushAvailability(const WebAppInfo(ios: true, iosVersion: (major: 16, minor: 3), standalone: true, secure: true)),
      PushAvailability.updateIos,
    );
    expect(pushAvailability(const WebAppInfo(secure: false, push: true)), PushAvailability.needsHttps);
    expect(
      pushAvailability(const WebAppInfo(ios: true, iosVersion: (major: 17, minor: 0), standalone: true, secure: true, push: true, permission: 'denied')),
      PushAvailability.blocked,
    );
    expect(pushAvailability(const WebAppInfo(secure: true, push: true, permission: 'default')), PushAvailability.ready);
    expect(pushAvailability(const WebAppInfo(secure: true)), PushAvailability.unsupported);
  });

  test("The page's answer reads as the browser it describes", () {
    final info = WebAppInfo.fromJson(Map<String, Object?>.from(jsonDecode(
      '{"ios":true,"ios_version":[17,4],"ipad":true,"standalone":true,"secure":true,"worker":true,'
      '"push":true,"permission":"granted","share":true,"ready":false}',
    ) as Map));
    expect(info.iosVersion, (major: 17, minor: 4));
    expect(info.kind, DeviceKind.tablet);
    expect(info.needsHomeScreen, isFalse);
    expect(info.iosTooOld, isFalse);
    expect(const WebAppInfo(ios: true).kind, DeviceKind.phone);
    expect(const WebAppInfo().kind, DeviceKind.browser);
  });
}
