/// Parental oversight as a parent thinks of it: a few switches on each kid's page, written as
/// sentences, mapped onto what the engine keeps (a kid's grants, the family's per-person
/// oversight entry and its assistant policy). Pure Dart, so an assistant can say them the same
/// way.
///
/// | Switch | Engine |
/// | --- | --- |
/// | Can add to lists | `Grant.lists` |
/// | Can add events and chores | `Grant.events` and `Grant.chores` together |
/// | Rewards need my OK | `family.oversight.<id>.rewardsNeedOk` (default on) and no `Grant.points` |
/// | Can keep things private from parents | `family.oversight.<id>.parentsSeePrivate` false |
/// | Can change their own picture | `family.oversight.<id>.ownPicture` (default: teens on) |
/// | Can use the AI helper | the kid's id in `family.assistant.members` |
/// | Gets reminders | `family.oversight.<id>.reminders` (default on) |
/// | I get their reminders too | `family.oversight.<id>.parentsReminded` (default off) |
library;

import 'package:den_core/den_core.dart';

import 'family_words.dart';

/// The switches on a kid's page, in the order they show.
enum KidSwitch { lists, plans, rewardsOk, private, ownPicture, reminders, parentsReminded, assistant }

/// One switch as a kid's page shows it.
class KidSwitchView {
  const KidSwitchView(this.which, {required this.on, required this.label, required this.detail, this.reason});

  final KidSwitch which;
  final bool on;
  final String label;
  final String detail;

  /// Why it can't be flipped now; null when it can.
  final String? reason;

  bool get changeable => reason == null;
}

/// What a kid of [tier] starts with: lists from nine, events and chores for teens.
Set<Grant> defaultGrants(Tier? tier) => switch (tier) {
      Tier.teen => {Grant.lists, Grant.events, Grant.chores},
      Tier.big => {Grant.lists},
      _ => const {},
    };

/// Whether [kid]'s [which] is on.
bool kidSwitchOn(KidSwitch which, Member kid, Family? family) => switch (which) {
      KidSwitch.lists => kid.grants.contains(Grant.lists),
      KidSwitch.plans => kid.grants.contains(Grant.events) || kid.grants.contains(Grant.chores),
      KidSwitch.rewardsOk => !kid.grants.contains(Grant.points) && (family?.rewardsNeedOk(kid.id) ?? true),
      KidSwitch.private => !(family?.parentsSeePrivate(kid.id) ?? true),
      KidSwitch.ownPicture => family?.ownsPicture(kid) ?? kid.tier == Tier.teen,
      KidSwitch.reminders => family?.getsReminders(kid.id) ?? true,
      KidSwitch.parentsReminded => family?.parentsReminded(kid.id) ?? false,
      KidSwitch.assistant => family?.assistant.members.contains(kid.id) ?? false,
    };

/// The switches [kid]'s page shows. Keeping things private is for teens (or whoever already
/// has it, so it can be turned off); the AI helper never for a little kid or a pre-reader.
List<KidSwitchView> kidSwitches(Member kid, Family? family) {
  final name = kid.name;
  final groups = family?.groups ?? const AgeGroups();
  // The family's ages decide who may have the AI helper, and keep things private.
  final little = !AgeGroups.reaches(kid.tier, groups.assistantFrom);
  final out = <KidSwitchView>[];
  bool on(KidSwitch s) => kidSwitchOn(s, kid, family);

  out.add(KidSwitchView(
    KidSwitch.lists,
    on: on(KidSwitch.lists),
    label: 'Can add to lists',
    detail: 'Groceries, packing and to-do lists',
  ));

  final events = kid.grants.contains(Grant.events);
  final chores = kid.grants.contains(Grant.chores);
  out.add(KidSwitchView(
    KidSwitch.plans,
    on: on(KidSwitch.plans),
    label: 'Can add events and chores',
    detail: events && !chores
        ? 'Events only, for now'
        : chores && !events
            ? 'Chores only, for now'
            : kidSwitchOn(KidSwitch.private, kid, family)
                ? 'What $name keeps private stays private'
                : 'You see everything $name adds',
  ));

  if (family?.pointsEnabled ?? true) {
    final ok = on(KidSwitch.rewardsOk);
    out.add(KidSwitchView(
      KidSwitch.rewardsOk,
      on: ok,
      label: 'Rewards need my OK',
      detail: ok
          ? 'Only parents give stars and say yes to rewards'
          : kid.grants.contains(Grant.points)
              ? '$name can give stars and approve rewards'
              : '$name can trade stars for rewards without asking you',
    ));
  }

  final private = on(KidSwitch.private);
  if (AgeGroups.reaches(kid.tier, groups.privateFrom) || private) {
    out.add(KidSwitchView(
      KidSwitch.private,
      on: private,
      label: 'Can keep things private from parents',
      detail: private ? 'Things set to Just me stay on ${FamilyWords.possessive(name)} devices' : 'Off: you can see everything',
    ));
  }

  final ownPicture = on(KidSwitch.ownPicture);
  out.add(KidSwitchView(
    KidSwitch.ownPicture,
    on: ownPicture,
    label: 'Can change their own picture',
    detail: ownPicture ? 'A photo from the camera too' : 'Only parents change it',
  ));

  final reminded = on(KidSwitch.reminders);
  out.add(KidSwitchView(
    KidSwitch.reminders,
    on: reminded,
    label: 'Gets reminders',
    detail: reminded ? "For events and chores given to $name, on $name's own devices" : "$name's devices stay quiet",
  ));
  final parents = on(KidSwitch.parentsReminded);
  out.add(KidSwitchView(
    KidSwitch.parentsReminded,
    on: parents,
    label: 'Parents get them too',
    detail: parents ? "Reminders for what's given to $name go to parents as well" : 'Only $name gets them',
  ));

  final assistant = on(KidSwitch.assistant);
  if (!little || assistant) {
    final helperOn = family?.assistant.enabled ?? false;
    out.add(KidSwitchView(
      KidSwitch.assistant,
      on: assistant && helperOn,
      label: 'Can use the AI helper',
      detail: 'Off for kids until you turn it on',
      reason: helperOn ? null : 'Turn on the AI helper in Settings first',
    ));
  }
  return out;
}

/// [current] with [which] turned [on]: the grants a kid has after the switch.
Set<Grant> grantsWith(KidSwitch which, bool on, Set<Grant> current) {
  final next = {...current};
  void set(Iterable<Grant> grants) => on ? next.addAll(grants) : next.removeAll(grants);
  switch (which) {
    case KidSwitch.lists:
      set(const [Grant.lists]);
    case KidSwitch.plans:
      set(const [Grant.events, Grant.chores]);
    case KidSwitch.rewardsOk:
      // On means parents decide: the kid loses the points grant. Off keeps the grants as they
      // are: the kid trades their own stars without asking, and gives nobody any.
      if (on) next.remove(Grant.points);
    case KidSwitch.private || KidSwitch.ownPicture || KidSwitch.reminders || KidSwitch.parentsReminded || KidSwitch.assistant:
      break;
  }
  return next;
}

/// What flipping [which] for [name] does, said in place before it saves.
String kidSwitchChange(KidSwitch which, String name, {required bool on}) => switch ((which, on)) {
      (KidSwitch.lists, true) => '$name will add, change and check off items on the lists $name sees.',
      (KidSwitch.lists, false) => '$name will still check items off, but won\'t add or change them.',
      (KidSwitch.plans, true) => '$name will add and change events and chores, and you\'ll see them on the calendar.',
      (KidSwitch.plans, false) => '$name won\'t add or change events and chores. What $name added stays.',
      (KidSwitch.rewardsOk, true) => 'Only parents will give stars and say yes to rewards $name asks for.',
      (KidSwitch.rewardsOk, false) =>
        '$name can trade stars for rewards without asking you, when $name has enough. Only parents give stars.',
      (KidSwitch.private, true) => 'From now on, what $name sets to Just me is for $name alone. What you already saw '
          'can\'t be unseen: it stays on your devices. $name will see that you changed this.',
      (KidSwitch.private, false) => 'Parents will see what $name sets to Just me, including what $name kept private '
          'until now. $name will see that you changed this.',
      (KidSwitch.ownPicture, true) => '$name can choose their own picture, or take a photo for it.',
      (KidSwitch.ownPicture, false) => 'Only parents will change $name\'s picture.',
      (KidSwitch.reminders, true) => '$name\'s own devices will remind $name of events and chores given to $name.',
      (KidSwitch.reminders, false) => '$name\'s devices won\'t remind $name of anything.',
      (KidSwitch.parentsReminded, true) => 'Parents will get the reminders for events and chores given to $name too.',
      (KidSwitch.parentsReminded, false) => 'Only $name will get the reminders for what\'s given to $name.',
      (KidSwitch.assistant, true) =>
        '$name can ask the AI helper to add and find things, up to the daily limit you set. What $name asks goes to '
            'the company that runs it.',
      (KidSwitch.assistant, false) => '$name won\'t see the AI helper.',
    };

/// The button that saves a switch change: "Turn on", "Turn off".
String kidSwitchVerb(bool on) => on ? 'Turn on' : 'Turn off';

/// What a person is told about a change to their privacy, on their Today and in History:
/// "Mom changed this: parents can now see things you mark Just me". [by] is the parent's name.
String privacyNotice(String by, {required bool parentsSee}) => '$by changed this: ${privacyNow(parentsSee: parentsSee)}';

/// How a person's privacy stands after a change, said to them ([you]) or about [name].
String privacyNow({required bool parentsSee, bool you = true, String name = ''}) => parentsSee
    ? 'parents can now see ${you ? 'things you mark' : 'what $name marks'} Just me'
    : you
        ? 'things you mark Just me are for you alone'
        : 'what $name marks Just me is for $name alone';
