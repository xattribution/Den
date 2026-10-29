import 'package:den_app/features/settings/screens/calendars_screen.dart';
import 'package:den_app/features/settings/state/feed_links.dart';
import 'package:den_app/platform/web/web_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';

/// The hub's calendar links, answering at once.
class _Links implements FeedLinksSource {
  final links = <FeedLink>[];
  final made = <(String, String)>[];

  @override
  Future<List<FeedLink>> list() async => [...links];

  @override
  Future<FeedLink> create({required String feed, required String label}) async {
    made.add((feed, label));
    const secret = 'denfeed_q3JxV8kd2Lmw';
    final link = FeedLink(
      id: 'L${made.length}',
      label: label,
      feed: feed,
      feedName: 'The Carters',
      made: demoNow.millisecondsSinceEpoch,
      url: 'https://den.example.com/ics/$secret/$feed.ics',
      webcal: 'webcal://den.example.com/ics/$secret/$feed.ics',
    );
    links.insert(0, link);
    return link;
  }

  @override
  Future<void> remove(String id) async => links.removeWhere((l) => l.id == id);
}

const _iPhone = WebAppInfo(ios: true, iosVersion: (major: 18, minor: 1), standalone: true, secure: true, push: true);

const Size _tall = Size(390, 1800);

Future<void> _tapAndWait(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 400));
  });
  await tester.pumpAndSettle();
}

/// What the clipboard was given, for the rest of the test.
List<String> _clipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return copied;
}

/// Settings, Calendars: the interim way to share the family's calendar with another family, until
/// Groups carry the offer and the one-tap accept.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a link for another family holds Everyone events only, is named for them, and is copied to send', (tester) async {
    final state = await demoIn(tester);
    final links = _Links();
    final opened = <Uri>[];
    final copied = _clipboard(tester);
    await pumpScreen(
      tester,
      CalendarsScreen(
        feedLinks: links,
        web: _iPhone,
        openCalendar: (uri) async {
          opened.add(uri);
          return true;
        },
      ),
      state: state,
      size: _tall,
      pushed: true,
    );
    expect(find.text('Make the link'), findsNothing);
    await tester.tap(find.text('A link for another family'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Everyone events only'), findsOneWidget);
    expect(find.textContaining('Never Parents-only or Just-me'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'The Smiths'), 'The Smiths');
    await _tapAndWait(tester, find.text('Make the link'));
    expect(links.made.single, ('shared', 'The Smiths'));
    expect(opened, isEmpty, reason: "it goes to the other family, not to this phone's calendar");
    expect(findWords('Send this link to The Smiths.'), findsOneWidget);
    expect(find.textContaining('Settings, Calendars, Add a calendar by link'), findsOneWidget);
    expect(find.text('Make the link'), findsNothing, reason: 'the form closes once the link is made');

    await _tapAndWait(tester, find.text('Copy link'));
    expect(copied, ['https://den.example.com/ics/denfeed_q3JxV8kd2Lmw/shared.ics']);
    expect(find.text('Copied'), findsOneWidget);
    expect(find.textContaining('Everyone events, for another family'), findsOneWidget);
    await matchShot('settings_calendars_shared_phone');
  });

  testWidgets('without a name the link is for "Another family"; a long name is refused where it was typed', (tester) async {
    final state = await demoIn(tester);
    final links = _Links();
    await pumpScreen(tester, CalendarsScreen(feedLinks: links, web: _iPhone, openCalendar: (_) async => true),
        state: state, size: _tall, pushed: true);
    await tester.tap(find.text('A link for another family'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'The Smiths'), 'x' * 61);
    await _tapAndWait(tester, find.text('Make the link'));
    expect(links.made, isEmpty);
    expect(findWords('Keep it to 60 letters or fewer.'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'The Smiths'), '  ');
    await _tapAndWait(tester, find.text('Make the link'));
    expect(links.made.single, ('shared', 'Another family'));
  });

  testWidgets("turning a link for another family off says their Den stops showing the family's events", (tester) async {
    final state = await demoIn(tester);
    final links = _Links();
    await links.create(feed: FeedLink.sharedFeed, label: 'The Smiths');
    await pumpScreen(tester, CalendarsScreen(feedLinks: links, web: _iPhone, openCalendar: (_) async => true),
        state: state, size: _tall, pushed: true);
    expect(find.textContaining('Everyone events, for another family'), findsOneWidget);
    await tester.tap(find.text('Turn off'));
    await tester.pumpAndSettle();
    expect(findWords("The other family's Den stops showing your events."), findsOneWidget);
    await _tapAndWait(tester, find.text('Turn off The Smiths'));
    expect(links.links, isEmpty);
  });

  testWidgets("a calendar another family stopped sharing says so where calendars by link are listed", (tester) async {
    final state = await demoIn(tester);
    await tester.runAsync(() async {
      final id = await state.den.addSubscription(url: 'https://den-kotvas.example.com/ics/denfeed_x/shared.ics', label: 'Kotvas');
      await state.den.setSubscriptionStatus(id, 'The Kotvas family stopped sharing their calendar');
    });
    await pumpScreen(tester, const CalendarsScreen(), state: state, size: _tall, pushed: true);
    expect(find.text('Kotvas'), findsOneWidget);
    expect(find.text('The Kotvas family stopped sharing their calendar'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);
  });
}
