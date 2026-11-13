import 'package:den_app/features/family/words/oversight.dart';
import 'package:den_app/features/settings/screens/age_groups_screen.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'chores_shots.dart';
import 'family_fakes.dart' show pumpScreen;

/// Settings → Family → Age groups: parents move where each group starts and which group the AI
/// helper and keeping things private start from; the kids' switches follow.
void main() {
  testWidgets('a parent moves Big kids to 10 and the AI helper to little kids', (tester) async {
    final state = await demo(tester);
    await pumpScreen(tester, const AgeGroupsScreen(), state: state);
    await tester.pumpAndSettle();
    expect(find.textContaining('Under 6 · 6 to 8 · 9 to 12 · 13 or older'), findsOneWidget);
    await tester.tap(find.byIcon(PhosphorIconsBold.plus).at(1));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(state.den.family!.groups.big, 10);
    expect(find.textContaining('6 to 9 · 10 to 12'), findsOneWidget);
    await tester.tap(find.text('6 to 9').first);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(state.den.family!.groups.assistantFrom, Tier.little);
    // A little kid's page now offers the AI helper.
    final kid = state.den.members.firstWhere((m) => m.isKid && m.tier == Tier.little, orElse: () => state.den.members.firstWhere((m) => m.isKid));
    final switches = kidSwitches(kid, state.den.family).map((s) => s.which).toSet();
    if (kid.tier == Tier.little) expect(switches, contains(KidSwitch.assistant));
  });
}
