import 'package:den_assistant/den_assistant.dart';
import 'package:den_core/den_core.dart';

import '../../../app/app_state.dart';
import '../../advanced/advanced.dart' show bookkeeping, historyLine;
import '../../today/today.dart';

/// The next seven days after [from]'s eve: the week the helper sees one line per event.
class WeekAheadModel extends DenView<List<Occurrence>> {
  const WeekAheadModel(this.from);

  /// The first day, tomorrow.
  final String from;

  @override
  Set<String> get reads => const {RecordType.event, RecordType.eventException, RecordType.category};

  @override
  Object get key => (WeekAheadModel, from);

  @override
  List<Occurrence> compute(AppState app) {
    final f = app.formats;
    return app.den.occurrences(f.startOf(from), f.startOf(f.addDays(from, 7)));
  }
}

/// The kinds of change the helper hears about in someone's recent History.
const Set<String> _recentTypes = {
  RecordType.event,
  RecordType.eventException,
  RecordType.chore,
  RecordType.completion,
  RecordType.list,
  RecordType.item,
  RecordType.adjustment,
  RecordType.goal,
  RecordType.reward,
  RecordType.redemption,
};

/// What each permission lets someone do, as the helper is told it.
const Map<DenAction, String> _abilities = {
  DenAction.editEvents: 'add and change events',
  DenAction.editChores: 'add and change chores',
  DenAction.editLists: 'add and change lists and their items',
  DenAction.checkItems: 'check items off lists',
  DenAction.completeOwnChore: 'check off their own chores',
  DenAction.completeAnyChore: "check off anyone's chores",
  DenAction.swapChore: 'swap chores',
  DenAction.managePoints: 'give stars and set goals and rewards',
  DenAction.requestReward: 'ask for rewards',
  DenAction.manageFamily: "change the family's people and settings (in Settings, not here)",
};

const _weekdays = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

/// What the helper knows at the start of a turn, built from the app's own views: the family and
/// who is asking with what they may do, today (Today's own view), the next seven days, what
/// waits for a parent, and the asker's last changes. Only what the asker can see in Den; the
/// packer trims it to its budget.
AssistantSnapshot assistantSnapshot(AppState app, {required int now}) {
  final den = app.den;
  final f = app.formats;
  final me = den.actor ?? den.owner;
  if (me == null) throw StateError('Nobody is using this device.');
  final family = den.family;
  final readable = den.readableSpaces;
  final pointsOn = family?.pointsEnabled ?? true;

  DateTime wall(int ms) {
    final t = f.at(ms);
    return DateTime(t.year, t.month, t.day, t.hour, t.minute);
  }

  String name(String? id) => app.memberById(id)?.name ?? 'someone';

  EventFacts event(Occurrence o) => EventFacts(
    id: o.event.id,
    title: o.title,
    start: wall(o.start),
    end: o.allDay || o.end <= o.start ? null : wall(o.end),
    allDay: o.allDay,
    people: [for (final id in o.assignees) ?app.memberById(id)?.name],
    category: o.category == null ? null : den.category(o.category!)?.name,
    location: o.location.isEmpty ? null : o.location,
  );

  MemberFacts member(Member m) => MemberFacts(
    id: m.id,
    name: m.name,
    role: switch (m.role) {
      Role.parent => MemberRole.parent,
      Role.adult => MemberRole.adult,
      Role.kid => MemberRole.kid,
      Role.guest => MemberRole.guest,
    },
    tier: switch (m.tier) {
      Tier.preReader => KidTier.preReader,
      Tier.little => KidTier.little,
      Tier.big => KidTier.big,
      Tier.teen => KidTier.teen,
      null => null,
    },
  );

  final today = app.view(const TodayModel());
  final week = app.view(WeekAheadModel(f.addDays(app.today, 1)));
  final abilities = {
    for (final e in _abilities.entries)
      if (e.key != DenAction.managePoints && e.key != DenAction.requestReward || pointsOn) e.key: e.value,
  };

  final history = den.history(member: me.id, limit: 60).where((h) => _recentTypes.contains(h.type)).toList();
  final noise = bookkeeping(history);
  final recent = [
    for (final h in history)
      if (!noise.contains(h))
        HistoryFacts(
          at: wall(h.when.millis),
          text: () {
            final line = historyLine(app, h);
            final from = h.from?.kind == CaptureKind.assistant ? ' (through the AI helper)' : '';
            return '${line.verb} ${line.title}$from';
          }(),
        ),
  ].take(10).toList();

  final rewards = {for (final r in den.rewards) r.id: r};
  return AssistantSnapshot(
    family: FamilyFacts(
      name: family?.name ?? 'The family',
      timeZone: family?.timezone ?? 'UTC',
      weekStart: _weekdays[(family?.weekStart ?? 0) % 7],
      members: [for (final m in den.members) member(m)],
      categories: [for (final c in den.categories) NamedFacts(id: c.id, name: c.name)],
      lists: [
        for (final l in den.lists)
          if (readable.contains(l.list.space))
            ListFacts(id: l.list.id, title: l.list.title, kind: l.list.kind.name, open: l.open),
      ],
      rewards: [
        if (pointsOn)
          for (final r in den.rewards)
            if (r.active) RewardFacts(id: r.id, title: r.title, cost: r.cost),
      ],
      pointsOn: pointsOn,
    ),
    speaker: SpeakerFacts(
      member: member(me),
      may: [
        for (final e in abilities.entries)
          if (app.allows(e.key)) e.value,
      ],
      mayNot: [
        for (final e in abilities.entries)
          if (!app.allows(e.key)) e.value,
      ],
    ),
    now: wall(now),
    events: [
      for (final o in today.events)
        if (readable.contains(o.event.space)) event(o),
    ],
    chores: [
      for (final cd in today.chores)
        if (readable.contains(cd.chore.space))
          ChoreFacts(
            id: cd.chore.id,
            title: cd.chore.title,
            owner: cd.owner == null ? 'anyone' : name(cd.owner),
            done: cd.done,
            points: pointsOn && cd.pointsAvailable > 0 ? cd.pointsAvailable : null,
          ),
    ],
    gaps: [
      for (final g in today.gaps)
        if (g.kind != GapKind.unowned) g.message,
    ],
    week: [
      for (final o in week)
        if (readable.contains(o.event.space)) event(o),
    ],
    pending: [
      if (pointsOn && app.allows(DenAction.managePoints))
        for (final r in den.points().pending)
          '${name(r.member)} asked for ${rewards[r.reward]?.title ?? 'a reward'} (${r.cost} stars)',
    ],
    history: recent,
  );
}
