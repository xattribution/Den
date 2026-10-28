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

/// Actions that only read: the day or the week, the family, events, chores, lists, points,
/// search and history.
List<ActionSpec> readActions() => [
      ActionSpec(
        name: 'overview.get',
        mcpName: 'get_overview',
        title: 'Today or the week',
        description: 'What is happening: one day (events, chores by person, pinned and due lists, gaps that need '
            'someone: no driver, overlapping events, unowned chores), or several days from "start" with "days". '
            'Also what waits for a parent. Start here.',
        input: S.input({
          'date': S.date('One day (default today).'),
          'start': S.date('For several days: the first one.'),
          'days': S.integer('For several days: how many (default 7).', min: 1, max: 14),
          'person': S.person('Only this person\'s events (and events for everyone) and chores.'),
        }),
        output: S.output(overviewOutput),
        scopes: const {Scope.read},
        effect: Effect.read,
        engine: const {},
        example: const {},
        run: overview,
      ),
      ActionSpec(
        name: 'family.get',
        mcpName: 'get_family',
        title: 'The family',
        description: 'The family\'s people (with roles and ids), event categories and settings, who this '
            'connection acts for, and what it may do.',
        input: S.input({}),
        output: S.output(familyOutput),
        scopes: const {Scope.read},
        effect: Effect.read,
        engine: const {},
        example: const {},
        run: family,
      ),
      ActionSpec(
        name: 'events.list',
        mcpName: 'list_events',
        title: 'Events',
        description: 'Event occurrences between two times (default the next 7 days), optionally for one person '
            'or one category.',
        input: S.input({
          'start': S.time('Window start.'),
          'end': S.time('Window end (exclusive).'),
          'person': S.person('Only events this person is in (and events for everyone).'),
          'category': S.string('Only events in this category (name or id).'),
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
        example: const {'category': 'Sports'},
        run: _events,
      ),
      ActionSpec(
        name: 'chores.list',
        mcpName: 'list_chores',
        title: 'Chores',
        description: 'Chores on a day with who has them, steps, points and whether they are done; or, with '
            '"definitions" (or "chore"), the chores themselves: who they belong to, when they repeat, their '
            'steps and their recent completions.',
        input: S.input({
          'date': S.date('The day (default today).'),
          'person': S.person('Only this person\'s chores.'),
          'definitions': S.boolean('List the chores themselves rather than one day\'s.'),
          'chore': S.string('Just this chore\'s definition (title or id).'),
        }),
        output: S.output(choresOutput),
        scopes: const {Scope.read},
        effect: Effect.read,
        engine: const {},
        example: const {'chore': 'Dishes'},
        run: chores,
      ),
      ActionSpec(
        name: 'lists.get',
        mcpName: 'get_lists',
        title: 'Lists',
        description: 'Lists with their items (shopping lists, checklists, packing lists, meal plans), and the '
            'stores items are bought at.',
        input: S.input({
          'list': S.string('Just this list (title or id).'),
          'include_checked': S.boolean('Include checked items (default true).'),
        }),
        output: S.output(listsOutput),
        scopes: const {Scope.read},
        effect: Effect.read,
        engine: const {},
        example: const {'list': 'Groceries', 'include_checked': false},
        run: lists,
      ),
      ActionSpec(
        name: 'points.get',
        mcpName: 'get_points',
        title: 'Points',
        description: 'Star totals per person, goals with standings, recent points, rewards to spend stars on, '
            'and requests waiting for a parent.',
        input: S.input({
          'person': S.person('Only this person\'s total and recent points.'),
          'recent': S.integer('How many recent points (default 20).', min: 0, max: 200),
        }),
        output: S.output(pointsShape),
        scopes: const {Scope.read},
        effect: Effect.read,
        engine: const {},
        example: const {'person': 'Maya', 'recent': 5},
        run: points,
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
    ];

/// Older read tools: one day, the week, the people, the lists, the rewards.
List<ActionAlias> readAliases() => [
      const ActionAlias('get_today', 'get_overview'),
      ActionAlias('get_week', 'get_overview', (args) => {...args, 'days': args['days'] ?? 7}),
      const ActionAlias('list_members', 'get_family'),
      const ActionAlias('list_lists', 'get_lists'),
      const ActionAlias('list_rewards', 'get_points'),
    ];

/// What waits for someone: reward requests, and devices and AI connections waiting for a parent.
final Map<String, Object?> _pendingShape = S.object({
  'rewards': S.array(redemptionShape, 'Reward requests waiting for a parent.'),
  'devices': Out.integer('Devices waiting for a parent to approve them in the Den app.'),
  'connections': Out.integer('AI and automation connections waiting for a parent in the Den app.'),
});

/// The output of one day or several.
final Map<String, Object?> overviewOutput = {
  'date': Out.str('The day, for one day.'),
  'start': Out.str('The first day, for several.'),
  'timezone': Out.str('The family\'s zone.'),
  'events': S.array(occurrenceShape, 'One day\'s events, by start.'),
  'chores': S.array(choreDayShape, 'One day\'s chores.'),
  'chore_summary': S.dictionary('Counts: total, done, left, anyone, by_member.'),
  'lists': S.array(listShape, 'Pinned lists, lists due that day, and lists for its events.'),
  'days': S.array(
    S.object({
      'date': Out.str('The day.'),
      'events': S.array(occurrenceShape, 'Events.'),
      'chores': S.array(choreDayShape, 'Chores.'),
    }),
    'Several days, day by day.',
  ),
  'gaps': S.array(gapShape, 'What needs someone.'),
  'pending': _pendingShape,
};

/// The output of the family tool.
final Map<String, Object?> familyOutput = {
  'family': {...familyShape, 'type': ['object', 'null']},
  'me': Out.strOrNull('The member this connection acts for; null is a parent-level automation.'),
  'members': S.array(memberShape, 'People, in order.'),
  'categories': S.array(categoryShape, 'Event categories.'),
  'settings': S.object({
    'capture': Out.str('direct (what Den reads is added at once) or review (it waits in a tray).'),
  }),
  'may': S.dictionary('What this connection may do: editEvents, editChores, editLists, checkItems, '
      'completeOwnChore, completeAnyChore, swapChore, managePoints, requestReward, manageFamily.'),
};

/// The output of the chores tool.
final Map<String, Object?> choresOutput = {
  'date': Out.str('The day.'),
  'chores': S.array(choreDayShape, 'That day\'s chores.'),
  'summary': S.dictionary('Counts: total, done, left, anyone, by_member.'),
  'definitions': S.array(choreShape, 'The chores themselves.'),
};

/// The output of the lists tool.
final Map<String, Object?> listsOutput = {
  'lists': S.array(listShape, 'Lists with their items.'),
  'stores': Out.strings('Stores, most used first.'),
};

String? _who(ActionContext c, ActionInput a) => a.has('person') ? c.people.one(a.str('person')!) : null;

bool _for(Occurrence o, String? who) => who == null || o.assignees.isEmpty || o.assignees.contains(who);

/// Reward requests waiting, and for parents, devices and connections waiting for them.
Map<String, Object?> pending(ActionContext c) {
  final parent = c.me?.isParent ?? c.member == null;
  return {
    'rewards': [for (final r in c.den.points().pending) c.wire.redemption(r)],
    'devices': parent ? c.den.pendingDevices.length : 0,
    'connections': parent ? c.den.connections.where((x) => x.status == ConnectionStatus.pending).length : 0,
  };
}

String _pendingText(ActionContext c, Map<String, Object?> p) {
  final rewards = c.den.points();
  final titles = {for (final r in rewards.rewards) r.id: r.title};
  return [
    for (final r in rewards.pending)
      'Waiting for a parent: ${c.people.name(r.member)} asked for ${titles[r.reward] ?? 'a reward'} [request ${r.id}]',
    if ((p['devices'] as int) > 0) '${p['devices']} device(s) waiting for approval in the Den app',
    if ((p['connections'] as int) > 0) '${p['connections']} AI or automation connection(s) waiting in the Den app',
  ].join('\n');
}

/// One day, or several.
ActionResult overview(ActionContext c, ActionInput a) {
  final who = _who(c, a);
  final waiting = pending(c);
  final waitingText = _pendingText(c, waiting);
  if (a.has('start') || a.has('days')) {
    final start = a.has('start') ? toolDate(a.raw['start'], c.zone, 'start') : c.today;
    final days = a.integer('days') ?? 7;
    final text = StringBuffer();
    final out = <Map<String, Object?>>[];
    for (var i = 0; i < days; i++) {
      final date = addDays(start, i);
      final events = [
        for (final o in c.occurrences(midnightIn(c.zone, date), midnightIn(c.zone, addDays(date, 1))))
          if (_for(o, who)) o,
      ];
      final chores = [for (final cd in c.choresOn(date)) if (cd.date == date && (who == null || cd.owner == who)) cd];
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
    final gaps = visibleGaps(
      c.den,
      c.den.gaps(midnightIn(c.zone, start), midnightIn(c.zone, addDays(start, days))),
      c.readable,
    );
    for (final g in gaps) {
      text.writeln('Needs someone: ${g.message}');
    }
    if (waitingText.isNotEmpty) text.writeln(waitingText);
    return ActionResult(text.toString().trim(), {
      'start': start,
      'timezone': c.zone,
      'days': out,
      'gaps': [for (final g in gaps) c.wire.gap(g)],
      'pending': waiting,
    });
  }
  final date = a.has('date') ? toolDate(a.raw['date'], c.zone, 'date') : c.today;
  final view = c.den.today(date: date);
  final events = [for (final o in view.events) if (c.readable.contains(o.event.space) && _for(o, who)) o];
  Wire.sortOccurrences(events);
  final chores = [for (final cd in c.choresOn(date)) if (who == null || cd.owner == who) cd];
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
  if (waitingText.isNotEmpty) text.writeln(waitingText);
  return ActionResult(text.toString().trim(), {
    'date': date,
    'timezone': c.zone,
    'events': [for (final o in events) c.wire.occurrence(o)],
    'chores': [for (final cd in chores) c.wire.choreDay(cd)],
    'chore_summary': Wire.choreSummary(chores),
    'lists': [for (final l in lists) Wire.list(l)],
    'gaps': [for (final g in gaps) c.wire.gap(g)],
    'pending': waiting,
  });
}

const Map<DenAction, String> _abilities = {
  DenAction.editEvents: 'add and change events',
  DenAction.editChores: 'add and change chores',
  DenAction.editLists: 'add and change lists',
  DenAction.checkItems: 'check items off',
  DenAction.completeOwnChore: 'complete their own chores',
  DenAction.completeAnyChore: 'complete anyone\'s chores',
  DenAction.swapChore: 'swap chores for a day',
  DenAction.managePoints: 'give stars and set goals and rewards',
  DenAction.requestReward: 'ask for rewards',
  DenAction.manageFamily: 'change the family\'s people and settings',
};

/// The family, its people, categories and settings, and what the caller may do.
ActionResult family(ActionContext c, ActionInput a) {
  final members = c.den.members;
  final me = c.me;
  final may = {for (final action in DenAction.values) action.name: c.can(action)};
  final abilities = [for (final e in _abilities.entries) if (c.can(e.key)) e.value];
  final f = c.den.family;
  final text = [
    'Family: ${f?.name} (${c.zone})',
    me == null
        ? 'This connection acts for the whole family, at a parent\'s level except for the family\'s people and settings.'
        : 'This connection acts for ${me.name} (${me.role.name}).',
    if (abilities.isNotEmpty) 'It may ${joinNames(abilities)}.',
    for (final m in members) '- ${m.name}: ${m.role.name}${m.id == c.member ? ' (this connection)' : ''} [id ${m.id}]',
    if (c.den.categories.isNotEmpty) 'Categories: ${c.den.categories.map((x) => x.name).join(', ')}',
  ].join('\n');
  return ActionResult(text, {
    'family': c.wire.family(),
    'me': c.member,
    'members': [for (final m in members) Wire.member(m)],
    'categories': [for (final x in c.den.categories) Wire.category(x)],
    'settings': {'capture': f?.captureNeedsReview ?? false ? 'review' : 'direct'},
    'may': may,
  });
}

ActionResult _events(ActionContext c, ActionInput a) {
  final start = a.has('start') ? toolInstant(a.raw['start'], c.zone, 'start') : midnightIn(c.zone, c.today);
  final end = a.has('end') ? toolInstant(a.raw['end'], c.zone, 'end') : start + 7 * Duration.millisecondsPerDay;
  if (end <= start) throw ActionError('"end" must be after "start".', field: 'end');
  if (end - start > 400 * Duration.millisecondsPerDay) throw ActionError('The window can be at most 400 days.', field: 'end');
  final who = _who(c, a);
  final category = a.has('category') ? c.category(a.str('category')!) : null;
  final limit = a.integer('limit') ?? 200;
  final all = [
    for (final o in c.occurrences(start, end))
      if (_for(o, who) && (category == null || (o.category ?? o.event.category) == category)) o,
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

/// A chore as defined, with its last few completions.
Map<String, Object?> choreDefinition(ActionContext c, Chore chore) {
  final recent = c.den.completionsFor(chore.id).reversed.take(7);
  return {
    'id': chore.id,
    'title': chore.title,
    'notes': chore.notes,
    'icon': chore.icon,
    'owner_rule': chore.owner.toJson(),
    'owner_text': c.ownerText(chore),
    'schedule': chore.schedule.toJson(),
    'due_time': chore.dueTime,
    'points': chore.points,
    'steps': [
      for (final s in chore.steps) {'id': s.id, 'text': s.text, 'owner': s.owner, 'points': s.points},
    ],
    'reminders': chore.reminders,
    'active': chore.active,
    'recent': [
      for (final r in recent) {'date': r.date, 'done': r.done, 'done_by': r.doneBy},
    ],
    ...Wire.spaceFields(chore.space),
  };
}

String _scheduleText(Chore chore) {
  final s = chore.schedule;
  if (s.once != null) return 'once on ${shortDate(s.once!)}';
  return 'repeating ${s.rrule} from ${s.start}';
}

/// One day's chores, or the chores themselves.
ActionResult chores(ActionContext c, ActionInput a) {
  final who = _who(c, a);
  if (a.has('chore') || (a.flag('definitions') ?? false)) {
    final list = a.has('chore')
        ? [c.chore(a.str('chore')!)]
        : [
            for (final ch in c.chores)
              if (who == null ||
                  switch (ch.owner) {
                    OwnerMember(:final id) => id == who,
                    final OwnerRotation r => r.ids.contains(who),
                    OwnerAnyone() => true,
                  })
                ch,
          ];
    final text = list.isEmpty
        ? 'No chores.'
        : [
            for (final ch in list)
              '- ${ch.title} for ${c.ownerText(ch)}, ${_scheduleText(ch)}${ch.dueTime == null ? '' : ', due ${ch.dueTime}'}'
                  '${ch.points == 0 ? '' : ', ${ch.points} stars'}${ch.steps.isEmpty ? '' : ', ${ch.steps.length} steps'}'
                  '${ch.active ? '' : ' (paused)'} [chore ${ch.id}]',
          ].join('\n');
    return ActionResult(text, {'definitions': [for (final ch in list) choreDefinition(c, ch)]});
  }
  final date = a.has('date') ? toolDate(a.raw['date'], c.zone, 'date') : c.today;
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
  final checked = a.flag('include_checked') ?? true;
  final lists = [
    for (final l in one == null ? c.lists : [c.list(one)])
      checked ? l : ListState(l.list, [for (final i in l.items) if (!i.checked) i]),
  ];
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
    'stores': storesOf(lists),
  });
}

/// Stars, goals, rewards and requests.
ActionResult points(ActionContext c, ActionInput a) {
  final who = _who(c, a);
  final summary = visiblePoints(c.den, c.den.points(), c.readable);
  final narrowed = who == null
      ? summary
      : PointsSummary(
          totals: {for (final e in summary.totals.entries) if (e.key == who) e.key: e.value},
          goals: summary.goals,
          recent: [for (final l in summary.recent) if (l.member == who) l],
          rewards: summary.rewards,
          pending: [for (final r in summary.pending) if (r.member == who) r],
        );
  final data = c.wire.points(narrowed, recent: a.integer('recent') ?? 20);
  if (who != null) data['totals'] = {who: summary.totals[who] ?? 0};
  final totals = (data['totals'] as Map).cast<String, Object?>();
  final text = StringBuffer(c.den.family?.pointsEnabled == false ? 'Points are turned off.\n' : '');
  for (final e in totals.entries) {
    text.writeln('- ${c.people.name(e.key)}: ${e.value} stars');
  }
  for (final g in narrowed.goals) {
    final lead = g.standings.isEmpty ? '' : ', leading: ${c.people.name(g.standings.first.member)} ${g.standings.first.earned}';
    text.writeln('Goal ${g.goal.title}: ${g.goal.target} stars$lead [goal ${g.goal.id}]');
  }
  for (final r in narrowed.rewards) {
    text.writeln('Reward ${r.title}: ${r.cost} stars${r.needsApproval ? ', needs a parent' : ''} [reward ${r.id}]');
  }
  final titles = {for (final r in narrowed.rewards) r.id: r.title};
  for (final p in narrowed.pending) {
    text.writeln('Waiting: ${c.people.name(p.member)} asked for ${titles[p.reward] ?? 'a reward'} [request ${p.id}]');
  }
  return ActionResult(text.toString().trim(), data);
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
  final entries = c.den
      .history(query: a.str('query'), member: _who(c, a), type: a.str('type'), limit: limit + 200)
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
