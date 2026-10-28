import 'package:den_app/app/den_app.dart';
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/features/shared_screens/screens/kid_home.dart';
import 'package:den_app/features/shared_screens/screens/kid_screen.dart';
import 'package:den_app/app/app_state.dart';
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
  testWidgets('Little kid, phone (Kid.dc.html)', (tester) async {
    final (state, kid) = await kidAs(tester, Tier.little);
    await shootWith(tester, 'kids_little_phone', KidScreen(memberId: kid.id), state: state, size: const Size(390, 1400));
    expect(find.text('Hi, ${kid.name}'), findsOneWidget);
  });

  testWidgets('Little kid, phone, night', (tester) async {
    final (state, kid) = await kidAs(tester, Tier.little);
    await shootWith(tester, 'kids_little_phone_night', KidScreen(memberId: kid.id), state: state, night: true);
  });

  testWidgets('Pre-reader, phone: pictures, and her jobs read aloud', (tester) async {
    final (state, kid) = await kidAs(tester, Tier.preReader);
    await shootWith(tester, 'kids_prereader_phone', KidScreen(memberId: kid.id), state: state);
    expect(find.text('Read my jobs to me'), findsOneWidget);
  });

  testWidgets('Pre-reader, iPad, night: three across', (tester) async {
    final (state, kid) = await kidAs(tester, Tier.preReader);
    await shootWith(tester, 'kids_prereader_tablet_night', KidScreen(memberId: kid.id), state: state, size: tablet, night: true);
  });

  testWidgets('A tap checks a job off, in the kid\'s color', (tester) async {
    final (state, kid) = await kidAs(tester, Tier.little);
    await pumpScreen(tester, KidScreen(memberId: kid.id), state: state, size: const Size(390, 1400));
    final day = state.den.choresOn(state.today).firstWhere((d) => d.owner == kid.id && !d.done && d.chore.steps.isEmpty);
    await tester.runAsync(() async {
      await tester.tap(find.text(day.chore.title));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pumpAndSettle();
    expect(state.den.choresOn(state.today).firstWhere((d) => d.chore.id == day.chore.id).done, isTrue);
    await matchShot('kids_little_checked_phone');
  });

  testWidgets('A job with steps opens them as big tiles', (tester) async {
    final (state, kid) = await kidAs(tester, Tier.little);
    final day = state.den.choresOn(state.today).where((d) => d.chore.steps.any((s) => s.owner == kid.id) || (d.owner == kid.id && d.chore.steps.isNotEmpty)).firstOrNull;
    if (day == null) return;
    await pumpScreen(tester, KidScreen(memberId: kid.id), state: state, size: const Size(390, 1400));
    await tester.tap(find.text(day.chore.title));
    await tester.pumpAndSettle();
    expect(find.text('Read it to me'), findsOneWidget);
    await matchShot('kids_steps_sheet_phone');
  });

  testWidgets('On a shared tablet: Done', (tester) async {
    final (state, kid) = await kidAs(tester, Tier.little);
    await shootWith(
      tester,
      'kids_little_shared_tablet',
      KidHome(kid: kid, action: KidHeaderPill(label: 'Done', onTap: () {})),
      state: state,
      size: tablet,
    );
  });

  testWidgets("Handed a parent's phone: Grown-ups, and the back gesture doesn't leave", (tester) async {
    final (state, kid) = await kidAs(tester, Tier.little);
    await pumpScreen(tester, KidScreen(memberId: kid.id, handed: true), state: state);
    expect(find.text('Grown-ups'), findsOneWidget);
    expect(find.byType(PopScope), findsOneWidget);
  });

  testWidgets("A little kid's own tablet opens the kids' screen", (tester) async {
    final state = await littleKidTablet(tester);
    await tester.pumpWidget(
      DenScope(state: state, child: MaterialApp.router(theme: denTheme(DenColors.day), routerConfig: buildRouter(state))),
    );
    await tester.pumpAndSettle();
    expect(find.byType(KidScreen), findsOneWidget);
    expect(find.text('Hi, Leo'), findsOneWidget);
    expect(find.byType(KidHeaderPill), findsNothing, reason: "it's Leo's own, so nobody signs out");
  });
}
