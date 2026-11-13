import 'package:den_core/den_core.dart';

import 'family_words.dart';

/// "Who is Leo?": the answers a parent gives when adding someone or changing who they are. Each
/// is a role and, for a kid, an age group, which sets the switches they start with.
enum Who {
  under6(Role.kid, Tier.preReader),
  sixTo8(Role.kid, Tier.little),
  nineTo12(Role.kid, Tier.big),
  teen(Role.kid, Tier.teen),
  parent(Role.parent, null),
  grownUp(Role.adult, null),
  sitter(Role.guest, null);

  const Who(this.role, this.tier);

  final Role role;
  final Tier? tier;

  bool get kid => role == Role.kid;

  /// What a chip says, by the family's ages: "Under 6", "Grown-up".
  String chip([AgeGroups groups = const AgeGroups()]) => kid ? FamilyWords.tier(tier!, groups) : FamilyWords.role(role);

  /// What a row in a list of roles says, by the family's ages: "Kid, under 6", "Parent".
  String label([AgeGroups groups = const AgeGroups()]) =>
      kid ? (this == teen ? 'Teen' : 'Kid, ${FamilyWords.tier(tier!, groups).toLowerCase()}') : FamilyWords.role(role);

  /// Who [m] is now.
  static Who of(Member m) {
    if (m.role != Role.kid) return values.firstWhere((w) => !w.kid && w.role == m.role);
    return values.firstWhere((w) => w.tier == (m.tier ?? Tier.big));
  }

  /// What [name] is, in a sentence, for someone new.
  String means(String name) => kid ? '$name ${FamilyWords.tierMeans(tier!)[0].toLowerCase()}${FamilyWords.tierMeans(tier!).substring(1)}' : FamilyWords.roleNow(name, role);
}
