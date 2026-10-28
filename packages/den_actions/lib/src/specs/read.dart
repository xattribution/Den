import 'package:den_core/den_core.dart';

import '../context.dart';
import '../input.dart';
import '../privacy.dart';
import '../resolve.dart';
import '../schema.dart';
import '../shapes.dart';
import '../spec.dart';
import '../times.dart';
import '../wire.dart';

/// Actions that only read: the day, the week, search, history, people, events, chores, lists,
/// points and rewards.
List<ActionSpec> readActions() => [
      ActionSpec(
        name: 'overview.today',
        mcpName: 'get_today',
        title: 'Today',
        description: 'Everything happening on one day: events, chores by person, pinned and due lists, and gaps '
            'that need someone (no driver, overlapping events, unowned chores).',
        input: S.input({'date': S.time('The day (default today).')}),
        output: S.output(todayOutput),
        scopes: const {Scope.read},
        effect: Effect.read,
        engine: const {},
        example: const {},
        run: today,
      ),
      ActionSpec(
        name: 'overview.week',
        mcpName: 'get_week',
        title: 'The week',
        description: 'Events and chores day by day, for a week (or up to 14 days) from a start date.',
        input: S.input({
          'start': S.time('First day (default today).'),
          'days': S.integer('How many days (default 7).', min: 1, max: 14),
        }),
        output: S.output(weekOutput),
        scopes: const {Scope.read},
        effect: Effect.read,
        engine: const {},
        example: const {'days': 3},
        run: week,
      ),
      ActionSpec(
        name: 'search',
        mcpName: 'search',
        title: 'Search',
        description: 'Finds people, events, chores, lists and list items by words in their names.',
        input: S.input({
          'query': S.string('Words to look for.', maxLength: 200),
          'limit': S.integer('Most results (default 20).', min: 1, max: 100),
        }, required: ['query']),
        output: S.output({'results': S.array(searchHitShape, 'What matched, best first.')}),
        scopes: const {Scope.read},
        effect: Effect.read,
        engine: const {},
        example: const {'query': 'soccer'},
        run: _search,
      ),
      ActionSpec(
        name: 'history',
        mcpName: 'get_history',
        title: 'History',
        description: 'Who changed what and when, newest first.',
        input: S.input({
          'query': S.string('Only entries mentioning these words.', maxLength: 200),
          'person': S.person('Only changes this person made.'),
          'type': S.string('Only this kind of record.', oneOf: RecordType.all.toList()..sort()),
          'limit': S.integer('Most entries (default 20).', min: 1, max: 200),
        }),
        output: S.output({'entries': S.array(historyShape, 'Changes, newest first.')}),
        scopes: const {Scope.read},
        effect: Effect.read,
        engine: const {},
        example: const {'limit': 5},
        run: _history,
      ),
      ActionSpec(
        name: 'family.members',
        mcpName: 'list_members',
        title: 'People',
        description: 'The family and its people, with roles, and the categories events use.',
        input: S.input({}),
        output: S.output(membersOutput),
        scopes: const {Scope.read},
        effect: Effect.read,
        engine: const {},
        example: const {},
        run: members,
      ),
      ActionSpec(
        name: 'events.list',
        mcpName: 'list_events',
        title: 'Events',
        description: 'Event occurrences between two times (default the next 7 days), optionally for one person.',
        input: S.input({
          'start': S.time('Window start.'),
          'end': S.time('Window end (exclusive).'),
          'person': S.person('Only events this person is in (and events for everyone).'),
          'limit': S.integer('Most occurrences (default 200).', min: 1, max: 2000),
        }),
        output: S.output({
          'start': Out.str('Window start.'),
          'start_ms': Out.integer('Window start, UTC ms.'),
          'end': Out.str('Window end.'),
          'end_ms': Out.integer('Window end, UTC ms.'),
          'truncated': Out.flag('More occurrences than the limit.'),
          'events': S.array(occurrenceShape, 'Occurrences, by start.'),
        }),
        scopes: const {Scope.read},
        effect: Effect.read,
        engine: const {},
        example: const {},
        run: _events,
      ),
      ActionSpec(
        name: 'chores.list',
        mcpName: 'list_chores',
        title: 'Chores',
        description: 'Chores on a day with who has them, steps, points and whether they are done.',
        input: S.input({'date': S.time('The day (default today).'), 'person': S.person('Only this person\'s chores.')}),
        output: S.output(choresOutput),
        scopes: const {Scope.read},
        effect: Effect.read,
        engine: const {},
        example: const {},
        run: chores,
      ),
      ActionSpec(
        name: 'lists.list',
        mcpName: 'list_lists',
        title: 'Lists',
        description: 'Every list with its items (shopping lists, checklists, packing lists, meal plans).',
        input: S.input({'list': S.string('Just this list (title or id).')}),
        output: S.output(listsOutput),
        scopes: const {Scope.read},
        effect: Effect.read,
        engine: const {},
        example: const {'list': 'Groceries'},
        run: lists,
      ),
      ActionSpec(
        name: 'points.get',
        mcpName: 'get_points',
        title: 'Points',
        description: 'Star totals per person, goals with standings, recent points, rewards and pending requests.',
        input: S.input({}),
        output: S.output(pointsShape),
        scopes: const {Scope.read},
        effect: Effect.read,
        engine: const {},
        example: const {},
        run: points,
      ),
      ActionSpec(
        name: 'points.rewards',
        mcpName: 'list_rewards',
        title: 'Rewards',
        description: 'Rewards people can spend stars on, and requests waiting for a parent.',
        input: S.input({}),
        output: S.output({
          'rewards': S.array(rewardShape, 'Rewards.'),
          'pending': S.array(redemptionShape, 'Requests waiting for a parent.'),
        }),
        scopes: const {Scope.read},
        effect: Effect.read,
        engine: const {},
        example: const {},
        run: _rewards,
      ),
    ];

/// The output of one day.
final Map<String, Object?> todayOutput = {
  'date': Out.str('The day.'),
  'timezone': Out.str('The family\'s zone.'),
  'events': S.array(occurrenceShape, 'Events, by start.'),
  'chores': S.array(choreDayShape, 'Chores.'),
  'chore_summary': S.dictionary('Counts: total, done, left, anyone, by_member.'),
  'lists': S.array(listShape, 'Pinned lists, lists due that day, and lists for its events.'),
  'gaps': S.array(gapShape, 'What needs someone.'),
};

/// The output of several days.
final Map<String, Object?> weekOutput = {
  'start': Out.str('First day.'),
  'timezone': Out.str('The family\'s zone.'),
  'days': S.array(
    S.object({
      'date': Out.str('The day.'),
      'events': S.array(occurrenceShape, 'Events.'),
      'chores': S.array(choreDayShape, 'Chores.'),
    }),
    'Day by day.',
  ),
};

/// The output of the people tool.
final Map<String, Object?> membersOutput = {
  'family': {...familyShape, 'type': ['object', 'null']},
  'me': Out.strOrNull('The member this connection acts for; null is a parent-level automation.'),
  'members': S.array(memberShape, 'People, in order.'),
  'categories': S.array(categoryShape, 'Event categories.'),
};

/// The output of the chores tool.
final Map<String, Object?> choresOutput = {
  'date': Out.str('The day.'),
  'chores': S.array(choreDayShape, 'Chores.'),
  'summary': S.dictionary('Counts: total, done, left, anyone, by_member.'),
};

/// The output of the lists tool.
final Map<String, Object?> listsOutput = {'lists': S.array(listShape, 'Lists with their items.')};

/// One day: events, chores, lists and gaps.
ActionResult today(ActionContext c, ActionInput a) {
  final date = a.has('date') ? toolDate(a.raw['date'], c.zone, 'date') : c.today;
  final view = c.den.today(date: date);
  final events = [for (final o in view.events) if (c.readable.contains(o.event.space)) o];
  Wire.sortOccurrences(events);
  final chores = c.choresOn(date);
  final lists = [for (final l in view.lists) if (c.readable.contains(l.list.space)) l];
  final gaps = visibleGaps(c.den, view.gaps, c.readable);
  final done = chores.where((x) => x.done).length;
  final text = StringBuffer('${longDate(date)} (${c.zone})\n');
  text.writeln(events.isEmpty ? 'No events.' : 'Events:');
  events.map(c.occurrenceLine).forEach(text.writeln);
  text.writeln(chores.isEmpty ? 'No chores.' : 'Chores ($done of ${chores.length} done):');
  chores.map(c.choreLine).forEach(text.writeln);
  for (final l in lists) {
    text.writeln('List ${l.list.title}: ${l.open} open of ${l.items.length}');
  }
  for (final g in gaps) {
    text.writeln('Needs someone: ${g.message}');
  }
  return ActionResult(text.toString().trim(), {
    'date': date,
    'timezone': c.zone,
    'events': [for (final o in events) c.wire.occurrence(o)],
    'chores': [for (final cd in chores) c.wire.choreDay(cd)],
    'chore_summary': Wire.choreSummary(chores),
    'lists': [for (final l in lists) Wire.list(l)],
    'gaps': [for (final g in gaps) c.wire.gap(g)],
  });
}

/// Several days, day by day.
ActionResult week(ActionContext c, ActionInput a) {
  final start = a.has('start') ? toolDate(a.raw['start'], c.zone, 'start') : c.today;
  final days = a.integer('days') ?? 7;
  final text = StringBuffer();
  final out = <Map<String, Object?>>[];
  for (var i = 0; i < days; i++) {
    final date = addDays(start, i);
    final events = c.occurrences(midnightIn(c.zone, date), midnightIn(c.zone, addDays(date, 1)));
    final chores = c.choresOn(date).where((cd) => cd.date == date).toList();
    text.writeln('${longDate(date)}:');
    if (events.isEmpty && chores.isEmpty) text.writeln('- nothing');
    events.map(c.occurrenceLine).forEach(text.writeln);
    chores.map(c.choreLine).forEach(text.writeln);
    out.add({
      'date': date,
      'events': [for (final o in events) c.wire.occurrence(o)],
      'chores': [for (final cd in chores) c.wire.choreDay(cd)],
    });
  }
  return ActionResult(text.toString().trim(), {'start': start, 'timezone': c.zone, 'days': out});
}

ActionResult _search(ActionContext c, ActionInput a) {
  final query = a.str('query', required: true)!;
  final limit = a.integer('limit') ?? 20;
  final hits = [
    for (final h in c.den.search(query, limit: limit + 50))
      if (searchHitVisible(c.den, h, c.readable)) h,
  ].take(limit).toList();
  final text = hits.isEmpty
      ? 'Nothing matches "$query".'
      : [
          for (final h in hits)
            '- ${h.type} ${h.title}${h.detail == null ? '' : ' (${h.detail})'}'
                '${h.when == null ? '' : ', ${shortDate(dateIn(c.zone, h.when!))}'} [id ${h.id}]',
        ].join('\n');
  return ActionResult(text, {'results': [for (final h in hits) c.wire.searchHit(h)]});
}

ActionResult _history(ActionContext c, ActionInput a) {
  final limit = a.integer('limit') ?? 20;
  final person = a.str('person');
  final entries = c.den
      .history(
        query: a.str('query'),
        member: person == null ? null : c.people.one(person),
        type: a.str('type'),
        limit: limit + 200,
      )
      .where((h) => c.readable.contains(h.space))
      .take(limit)
      .toList();
  final text = entries.isEmpty
      ? 'No history matches.'
      : [
          for (final h in entries)
            '- ${shortDate(dateIn(c.zone, h.when.millis))} ${clockText(wallOf(c.zone, h.when.millis))}: '
                '${h.actorName}${h.via == null ? '' : ' (via ${h.via})'} ${h.verb} ${h.type} "${h.title}"',
        ].join('\n');
  return ActionResult(text, {'entries': [for (final h in entries) c.wire.history(h)]});
}

/// The family, its people and categories.
ActionResult members(ActionContext c, ActionInput a) {
  final members = c.den.members;
  final text = [
    'Family: ${c.den.family?.name} (${c.zone})',
    for (final m in members) '- ${m.name}: ${m.role.name}${m.id == c.member ? ' (this connection)' : ''} [id ${m.id}]',
    if (c.den.categories.isNotEmpty) 'Categories: ${c.den.categories.map((x) => x.name).join(', ')}',
  ].join('\n');
  return ActionResult(text, {
    'family': c.wire.family(),
    'me': c.member,
    'members': [for (final m in members) Wire.member(m)],
    'categories': [for (final x in c.den.categories) Wire.category(x)],
  });
}

ActionResult _events(ActionContext c, ActionInput a) {
  final start = a.has('start') ? toolInstant(a.raw['start'], c.zone, 'start') : midnightIn(c.zone, c.today);
  final end = a.has('end') ? toolInstant(a.raw['end'], c.zone, 'end') : start + 7 * Duration.millisecondsPerDay;
  if (end <= start) throw ActionError('"end" must be after "start".', field: 'end');
  if (end - start > 400 * Duration.millisecondsPerDay) throw ActionError('The window can be at most 400 days.', field: 'end');
  final person = a.str('person');
  final who = person == null ? null : c.people.one(person);
  final limit = a.integer('limit') ?? 200;
  final all = [
    for (final o in c.occurrences(start, end))
      if (who == null || o.assignees.isEmpty || o.assignees.contains(who)) o,
  ];
  final shown = all.take(limit).toList();
  final text = shown.isEmpty ? 'No events in that window.' : shown.map(c.occurrenceLine).join('\n');
  return ActionResult(text, {
    ...c.wire.instant('start', start),
    ...c.wire.instant('end', end),
    'truncated': all.length > limit,
    'events': [for (final o in shown) c.wire.occurrence(o)],
  });
}

/// The chores on one day.
ActionResult chores(ActionContext c, ActionInput a) {
  final date = a.has('date') ? toolDate(a.raw['date'], c.zone, 'date') : c.today;
  final person = a.str('person');
  final who = person == null ? null : c.people.one(person);
  final chores = [for (final cd in c.choresOn(date)) if (who == null || cd.owner == who) cd];
  final text = chores.isEmpty ? 'No chores on ${longDate(date)}.' : '${longDate(date)}:\n${chores.map(c.choreLine).join('\n')}';
  return ActionResult(text, {
    'date': date,
    'chores': [for (final cd in chores) c.wire.choreDay(cd)],
    'summary': Wire.choreSummary(chores),
  });
}

/// Lists with their items.
ActionResult lists(ActionContext c, ActionInput a) {
  final one = a.str('list');
  final lists = one == null ? c.lists : [c.list(one)];
  final text = StringBuffer();
  for (final l in lists) {
    text.writeln('${l.list.title} (${l.list.kind.name}, ${l.open} open) [list ${l.list.id}]');
    for (final i in l.items) {
      final extra = [?i.qty, ?i.store].join(', ');
      text.writeln('  ${i.checked ? '[x]' : '[ ]'} ${i.text}${extra.isEmpty ? '' : ' ($extra)'} [item ${i.id}]');
    }
  }
  return ActionResult(lists.isEmpty ? 'No lists.' : text.toString().trim(), {
    'lists': [for (final l in lists) Wire.list(l)],
  });
}

/// Stars, goals, rewards and requests.
ActionResult points(ActionContext c, ActionInput a) {
  final summary = visiblePoints(c.den, c.den.points(), c.readable);
  final data = c.wire.points(summary, recent: 20);
  final totals = (data['totals'] as Map).cast<String, Object?>();
  final text = StringBuffer(c.den.family?.pointsEnabled == false ? 'Points are turned off.\n' : '');
  for (final e in totals.entries) {
    text.writeln('- ${c.people.name(e.key)}: ${e.value} stars');
  }
  for (final g in summary.goals) {
    final lead = g.standings.isEmpty ? '' : ', leading: ${c.people.name(g.standings.first.member)} ${g.standings.first.earned}';
    text.writeln('Goal ${g.goal.title}: ${g.goal.target} stars$lead [goal ${g.goal.id}]');
  }
  return ActionResult(text.toString().trim(), data);
}

ActionResult _rewards(ActionContext c, ActionInput a) {
  final summary = c.den.points();
  final text = [
    for (final r in summary.rewards) '- ${r.title}: ${r.cost} stars${r.needsApproval ? ', needs a parent' : ''} [reward ${r.id}]',
    for (final p in summary.pending)
      'Waiting: ${c.people.name(p.member)} asked for ${summary.rewards.where((r) => r.id == p.reward).firstOrNull?.title ?? 'a reward'} [request ${p.id}]',
  ].join('\n');
  return ActionResult(text.isEmpty ? 'No rewards yet.' : text, {
    'rewards': [for (final r in summary.rewards) Wire.reward(r)],
    'pending': [for (final p in summary.pending) c.wire.redemption(p)],
  });
}
