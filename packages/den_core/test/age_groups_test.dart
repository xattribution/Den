import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The family's age groups (AgeGroups): parents set where each starts, and which group the AI
/// helper and keeping things private start from.
void main() {
  test('the ages say each group, and the group a kid of an age starts in', () {
    const g = AgeGroups();
    expect([for (final t in Tier.values) g.label(t)], ['Under 6', '6 to 8', '9 to 12', '13 or older']);
    const later = AgeGroups(little: 7, big: 10, teen: 14);
    expect(later.label(Tier.little), '7 to 9');
    expect(later.forAge(9), Tier.little);
    expect(later.forAge(10), Tier.big);
    expect(AgeGroups.parse({'little': 9, 'big': 8, 'teen': 13}).little, AgeGroups.defaultLittle, reason: 'out of order');
  });

  test('a parent moves the ages and who gets the AI helper; out of order is refused', () async {
    final clock = TestClock.at(DateTime.utc(2026, 11, 13, 10));
    final den = await foundFamily(clock);
    final leo = await den.addMember(name: 'Leo', role: Role.kid, tier: Tier.little);
    await den.updateFamily({
      'assistant': const AssistantPolicy(enabled: true).toJson()..['members'] = [leo],
    });
    expect(den.family!.assistant.allows(den.member(leo)!), isFalse, reason: 'little kids don\'t, by default');
    await den.updateFamily({
      'groups': const AgeGroups(little: 5, big: 10, teen: 14, assistantFrom: Tier.little).toJson(),
    });
    final g = den.family!.groups;
    expect((g.little, g.big, g.teen, g.assistantFrom), (5, 10, 14, Tier.little));
    expect(den.family!.assistant.allows(den.member(leo)!), isTrue);
    await expectLater(den.updateFamily({'groups': {'little': 9, 'big': 8, 'teen': 13}}), throwsA(isA<InvalidInput>()));
  });
}
