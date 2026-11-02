/// A member's role, as in den_core's `Role`.
enum MemberRole {
  /// Runs the family.
  parent,

  /// A grown-up without family administration.
  adult,

  /// A child; what they may do depends on grants.
  kid,

  /// A visitor: checks items and their own chores.
  guest,
}

/// A kid's age group, as in den_core's `Tier`; sets the reading level.
enum KidTier {
  /// Can't read yet.
  preReader,

  /// Reads a little.
  little,

  /// Reads well.
  big,

  /// A teenager.
  teen,
}

/// A person in the family.
class MemberFacts {
  /// A member.
  const MemberFacts({required this.id, required this.name, required this.role, this.tier});

  /// Their member id.
  final String id;

  /// Their first name.
  final String name;

  /// Their role.
  final MemberRole role;

  /// A kid's age group.
  final KidTier? tier;
}

/// Something with an id and a name: an event category.
class NamedFacts {
  /// [name] with [id].
  const NamedFacts({required this.id, required this.name});

  /// Its id.
  final String id;

  /// Its name.
  final String name;
}

/// A list and how many items are still open.
class ListFacts {
  /// A list.
  const ListFacts({required this.id, required this.title, this.kind = 'checklist', this.open = 0});

  /// Its id.
  final String id;

  /// Its name.
  final String title;

  /// `shopping`, `checklist`, `packing` or `meal`.
  final String kind;

  /// Items not checked off.
  final int open;
}

/// A reward and its price in stars.
class RewardFacts {
  /// A reward.
  const RewardFacts({required this.id, required this.title, required this.cost});

  /// Its id.
  final String id;

  /// Its name.
  final String title;

  /// Stars it costs.
  final int cost;
}

/// One occurrence of an event. Times are wall-clock times in the family's time zone.
class EventFacts {
  /// An occurrence.
  const EventFacts({
    required this.id,
    required this.title,
    required this.start,
    this.end,
    this.allDay = false,
    this.people = const [],
    this.category,
    this.location,
  });

  /// The event's id.
  final String id;

  /// Its title.
  final String title;

  /// When it starts, in the family's zone.
  final DateTime start;

  /// When it ends, in the family's zone.
  final DateTime? end;

  /// Whether it has no time of day.
  final bool allDay;

  /// Who it's for, by first name.
  final List<String> people;

  /// Its category's name.
  final String? category;

  /// Where.
  final String? location;
}

/// One chore on one day.
class ChoreFacts {
  /// A chore.
  const ChoreFacts({required this.id, required this.title, required this.owner, this.done = false, this.points});

  /// The chore's id.
  final String id;

  /// Its title.
  final String title;

  /// Who has it today: a first name, or "anyone".
  final String owner;

  /// Whether it's done today.
  final bool done;

  /// Stars it earns.
  final int? points;
}

/// One entry from History.
class HistoryFacts {
  /// An entry.
  const HistoryFacts({required this.at, required this.text});

  /// When, in the family's zone.
  final DateTime at;

  /// What happened: "checked off Milk on Groceries".
  final String text;
}

/// The family, as the assistant sees it for the day.
class FamilyFacts {
  /// The family.
  const FamilyFacts({
    required this.name,
    required this.timeZone,
    this.weekStart = 'Monday',
    this.members = const [],
    this.categories = const [],
    this.lists = const [],
    this.rewards = const [],
    this.pointsOn = true,
  });

  /// "The Carters".
  final String name;

  /// IANA zone: `America/Chicago`.
  final String timeZone;

  /// The first day of the week.
  final String weekStart;

  /// Everyone, in the family's order.
  final List<MemberFacts> members;

  /// Event categories.
  final List<NamedFacts> categories;

  /// Lists the speaker can see.
  final List<ListFacts> lists;

  /// Rewards that can be bought with stars.
  final List<RewardFacts> rewards;

  /// Whether stars are on.
  final bool pointsOn;
}

/// Who is speaking and what Den lets them do (from `get_family`).
class SpeakerFacts {
  /// The speaker.
  const SpeakerFacts({required this.member, this.may = const [], this.mayNot = const []});

  /// Who.
  final MemberFacts member;

  /// What they may do, in plain words: "add and change events".
  final List<String> may;

  /// What they may not do.
  final List<String> mayNot;
}

/// A plain snapshot of what the assistant should know at the start of a turn, built by the app
/// from the engine (so this package doesn't depend on den_core). Only what the speaker can see.
class AssistantSnapshot {
  /// A snapshot.
  const AssistantSnapshot({
    required this.family,
    required this.speaker,
    required this.now,
    this.events = const [],
    this.chores = const [],
    this.gaps = const [],
    this.week = const [],
    this.pending = const [],
    this.history = const [],
  });

  /// The family.
  final FamilyFacts family;

  /// Who is speaking.
  final SpeakerFacts speaker;

  /// The wall-clock time in the family's zone.
  final DateTime now;

  /// Today's events, in order.
  final List<EventFacts> events;

  /// Today's chores.
  final List<ChoreFacts> chores;

  /// What needs attention today, written for people: "Nobody is driving Leo to soccer".
  final List<String> gaps;

  /// The next 7 days after today, in order.
  final List<EventFacts> week;

  /// Requests waiting for a parent: "Leo asked for Movie night (20 stars)".
  final List<String> pending;

  /// The speaker's latest History entries, newest first.
  final List<HistoryFacts> history;
}
