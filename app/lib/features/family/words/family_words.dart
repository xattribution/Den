import 'package:den_core/den_core.dart';

/// The words family, device and connection screens use for engine enums, so every
/// screen says the same thing the same way.
abstract final class FamilyWords {
  /// What a family calls each role: a parent, a grown-up who helps (a co-parent who isn't an
  /// admin, a grandparent), a sitter, a kid.
  static String role(Role r) => switch (r) {
        Role.parent => 'Parent',
        Role.adult => 'Grown-up',
        Role.kid => 'Kid',
        Role.guest => 'Sitter',
      };

  /// "a parent", "a grown-up".
  static String aRole(Role r) => 'a ${role(r).toLowerCase()}';

  /// What [name] does as [r], in the present: the sentence on their page.
  static String roleNow(String name, Role r) => switch (r) {
        Role.parent => '$name runs the family: people, devices, stars and the AI helper.',
        Role.adult => "$name adds and changes plans, chores and lists, but doesn't manage people, devices or stars.",
        Role.kid => '$name checks off chores and asks for rewards, and adds only what you allow.',
        Role.guest => "$name sees the family's plans and checks things off, but doesn't add or change anything.",
      };

  /// What [name] will do as [r], said before a role change is saved.
  static String roleChange(String name, Role r) => switch (r) {
        Role.parent => "$name will run the family: people, devices, stars and the AI helper, and see what's kept for parents.",
        Role.adult => "$name will add and change plans, chores and lists, but won't manage people, devices or stars.",
        Role.kid => '$name will check off chores and ask for rewards, and add only what you allow.',
        Role.guest => "$name will see the family's plans and check things off, but won't add or change anything.",
      };

  static String tier(Tier t) => switch (t) {
        Tier.preReader => 'Under 6',
        Tier.little => '6 to 8',
        Tier.big => '9 to 12',
        Tier.teen => '13 or older',
      };

  /// What a kid of [t] gets, in one line.
  static String tierMeans(Tier t) => switch (t) {
        Tier.preReader => "Gets the kids' screen with pictures and read-aloud.",
        Tier.little => "Gets the kids' screen: big pictures and buttons.",
        Tier.big => 'Uses the regular app and can add to lists.',
        Tier.teen => 'Uses the regular app and can add to lists, events and chores.',
      };

  static String deviceKind(DeviceKind k) => switch (k) {
        DeviceKind.phone => 'Phone',
        DeviceKind.tablet => 'Tablet',
        DeviceKind.desktop => 'Computer',
        DeviceKind.browser => 'Browser',
        DeviceKind.hub => 'Hub',
        DeviceKind.display => 'Display',
      };

  static String mode(DeviceMode m) => switch (m) {
        DeviceMode.personal => 'Personal',
        DeviceMode.shared => 'Shared display',
        DeviceMode.hub => 'Hub',
      };

  static String layout(DisplayLayout l) => switch (l) {
        DisplayLayout.today => 'Today',
        DisplayLayout.week => 'Week',
        DisplayLayout.month => 'Month',
        DisplayLayout.lists => 'Lists',
        DisplayLayout.photos => 'Photos',
      };

  static String scope(Scope s) => switch (s) {
        Scope.read => 'Read',
        Scope.calendar => 'Calendar',
        Scope.chores => 'Chores',
        Scope.lists => 'Lists',
        Scope.points => 'Stars',
        Scope.admin => 'Family settings',
      };

  /// "Read, Calendar and Lists", in the enum's order.
  static String scopes(Set<Scope> scopes) {
    final words = [for (final s in Scope.values) if (scopes.contains(s)) scope(s)];
    return joinAnd(words, empty: 'Nothing');
  }

  /// "Mia", "Mia and Leo", "Mia, Leo and Ava".
  static String joinAnd(List<String> words, {String empty = ''}) {
    if (words.isEmpty) return empty;
    if (words.length == 1) return words.single;
    return '${words.sublist(0, words.length - 1).join(', ')} and ${words.last}';
  }

  /// "Leo's iPad".
  static String possessive(String name) => "$name's";

  /// The tier a kid of [age] usually starts on; parents can change it.
  static Tier tierForAge(int age) {
    if (age <= 5) return Tier.preReader;
    if (age <= 8) return Tier.little;
    if (age <= 12) return Tier.big;
    return Tier.teen;
  }

  /// Whole years from a `YYYY-MM-DD` birthday to [today], or null when either doesn't parse.
  static int? ageOn(String? birthday, String today) {
    final b = _parse(birthday);
    final t = _parse(today);
    if (b == null || t == null) return null;
    var years = t.$1 - b.$1;
    if (t.$2 < b.$2 || (t.$2 == b.$2 && t.$3 < b.$3)) years -= 1;
    return years < 0 ? null : years;
  }

  static (int, int, int)? _parse(String? date) {
    if (date == null) return null;
    final p = date.split('-');
    if (p.length != 3) return null;
    final y = int.tryParse(p[0]);
    final m = int.tryParse(p[1]);
    final d = int.tryParse(p[2]);
    if (y == null || m == null || d == null) return null;
    return (y, m, d);
  }

  /// Who someone is, as Family.dc.html says it: "Parent", "Grown-up", "Kid, 11", "Teen, 14",
  /// or for a kid with no birthday their age group, "Kid, 6 to 8".
  static String memberLine(Member m, String today) {
    if (m.role != Role.kid) return role(m.role);
    final age = ageOn(m.birthday, today);
    final teen = m.tier == Tier.teen || (age != null && age >= 13);
    if (age != null) return '${teen ? 'Teen' : 'Kid'}, $age';
    return switch (m.tier) {
      null => 'Kid',
      Tier.teen => 'Teen',
      final t => 'Kid, ${tier(t).toLowerCase()}',
    };
  }

  /// "0:42", "1:00", "9:59".
  static String countdown(Duration d) {
    final s = d.inSeconds < 0 ? 0 : d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

/// A new person's defaults: the next family color (the first nobody has) and their initial.
(Marker, String) freshLook(Iterable<Member> members) =>
    (Marker.next(members.map((m) => m.marker)), Picture.initial);
