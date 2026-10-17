import 'package:den_app/app.dart';
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/screens/kids/kid_screen.dart';
import 'package:den_app/screens/kids/little_kid.dart';
import 'package:den_app/screens/kids/pre_reader.dart';
import 'package:den_app/state/app_state.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';

/// The demo family and its kid on [tier] (Zoe is a pre-reader, Leo a little kid), or the
/// youngest kid moved to that tier.
Future<(AppState, Member)> kidAs(WidgetTester tester, Tier tier) => real(tester, () async {
      final state = await demoState();
      final kids = state.den.members.where((m) => m.isKid).toList();
      final kid = kids.where((m) => m.tier == tier).firstOrNull ?? kids.last;
      if (kid.tier != tier) await state.den.updateMember(kid.id, {'tier': tier.name});
      return (state, state.den.member(kid.id)!);
    });

void main() {
  testWidgets('Pre-reader, jobs, phone', (tester) async {
    final (state, kid) = await kidAs(tester, Tier.preReader);
    await shootWith(tester, 'kids_prereader_jobs_phone', KidScreen(memberId: kid.id), state: state);
  });

  testWidgets('Pre-reader, jobs, tablet, night', (tester) async {
    final (state, kid) = await kidAs(tester, Tier.preReader);
    await shootWith(tester, 'kids_prereader_jobs_tablet_night', KidScreen(memberId: kid.id), state: state, size: tablet, night: true);
  });

  testWidgets('Pre-reader, sticker chart, phone', (tester) async {
    final (state, kid) = await kidAs(tester, Tier.preReader);
    await shootWith(
      tester,
      'kids_prereader_stars_phone',
      PreReaderApp(kid: kid, header: KidHeader(kid: kid), initialTab: 1),
      state: state,
    );
  });

  testWidgets('Little kid, my jobs, phone', (tester) async {
    final (state, kid) = await kidAs(tester, Tier.little);
    await shootWith(tester, 'kids_little_jobs_phone', KidScreen(memberId: kid.id), state: state);
  });

  testWidgets('Little kid, my days, phone', (tester) async {
    final (state, kid) = await kidAs(tester, Tier.little);
    await shootWith(
      tester,
      'kids_little_days_phone',
      LittleKidApp(kid: kid, header: KidHeader(kid: kid), initialTab: 1),
      state: state,
    );
  });

  testWidgets('Little kid, my stars, phone, night', (tester) async {
    final (state, kid) = await kidAs(tester, Tier.little);
    await shootWith(
      tester,
      'kids_little_stars_phone_night',
      LittleKidApp(kid: kid, header: KidHeader(kid: kid), initialTab: 2),
      state: state,
      night: true,
    );
  });

  testWidgets('Little kid on a shared tablet', (tester) async {
    final (state, kid) = await kidAs(tester, Tier.little);
    await shootWith(
      tester,
      'kids_little_shared_tablet',
      LittleKidApp(kid: kid, header: KidHeader(kid: kid, onSwitch: () {}, onDone: () {})),
      state: state,
      size: tablet,
    );
  });

  testWidgets("A little kid's own tablet opens the kids' app", (tester) async {
    final state = await littleKidTablet(tester);
    await tester.pumpWidget(
      DenScope(state: state, child: MaterialApp.router(theme: denTheme(DenColors.day), routerConfig: buildRouter(state))),
    );
    await tester.pumpAndSettle();
    expect(find.byType(KidScreen), findsOneWidget);
    expect(find.text('My jobs'), findsOneWidget);
  });
}

