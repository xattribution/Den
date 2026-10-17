import 'package:den_core/den_core.dart';

import '../api.dart' show searchHitVisible;
import '../times.dart';
import '../wire.dart';
import 'resolve.dart';
import 'tool.dart';

/// Tools that only read: today, the week, search, history, people, events, chores, lists,
/// points and rewards.
List<Tool> readTools() => [
      Tool(
        name: 'get_today',
        title: 'Today',
        description: 'Everything happening on one day: events, chores by person, pinned and due lists, and gaps '
            'that need someone (no driver, overlapping events, unowned chores).',
        properties: {'date': sTime('The day (default today).')},
        scope: Scope.read,
        readOnly: true,
        run: _today,
      ),
      Tool(
        name: 'get_week',
        title: 'The week',
        description: 'Events and chores day by day, for a week (or up to 14 days) from a start date.',
        properties: {
          'start': sTime('First day (default today).'),
          'days': sInt('How many days (default 7).', min: 1, max: 14),
        },
        scope: Scope.read,
        readOnly: true,
        run: _week,
      ),
      Tool(
        name: 'search',
        title: 'Search',
        description: 'Finds people, events, chores, lists and list items by words in their names.',
        properties: {'query': sString('Words to look for.'), 'limit': sInt('Most results (default 20).', min: 1, max: 100)},
        required: ['query'],
        scope: Scope.read,
        readOnly: true,
        run: _search,
      ),
      Tool(
        name: 'get_history',
        title: 'History',
        description: 'Who changed what and when, newest first.',
        properties: {
          'query': sString('Only entries mentioning these words.'),
          'person': sPerson('Only changes this person made.'),
          'type': sString('Only this kind of record.', oneOf: RecordType.all.toList()..sort()),
          'limit': sInt('Most entries (default 20).', min: 1, max: 200),
        },
        scope: Scope.read,
        readOnly: true,
        run: _history,
      ),
      Tool(
        name: 'list_members',
        title: 'People',
        description: 'The family and its people, with roles, and the categories events use.',
        properties: const {},
        scope: Scope.read,
        readOnly: true,
        run: _members,
      ),
      Tool(
        name: 'list_events',
        title: 'Events',
        description: 'Event occurrences between two times (default the next 7 days), optionally for one person.',
        properties: {
          'start': sTime('Window start.'),
          'end': sTime('Window end (exclusive).'),
          'person': sPerson('Only events this person is in (and events for everyone).'),
          'limit': sInt('Most occurrences (default 200).', min: 1, max: 2000),
        },
        scope: Scope.read,
        readOnly: true,
        run: _events,
      ),
      Tool(
        name: 'list_chores',
        title: 'Chores',
        description: 'Chores on a day with who has them, steps, points and whether they are done.',
        properties: {'date': sTime('The day (default today).'), 'person': sPerson('Only this person\'s chores.')},
        scope: Scope.read,
        readOnly: true,
        run: _chores,
      ),
      Tool(
        name: 'list_lists',
        title: 'Lists',
        description: 'Every list with its items (shopping lists, checklists, packing lists, meal plans).',
        properties: {'list': sString('Just this list (title or id).')},
        scope: Scope.read,
        readOnly: true,
        run: _lists,
      ),
      Tool(
        name: 'get_points',
        title: 'Points',
        description: 'Star totals per person, goals with standings, recent points, rewards and pending requests.',
        properties: const {},
        scope: Scope.read,
        readOnly: true,
        run: _points,
      ),
      Tool(
        name: 'list_rewards',
        title: 'Rewards',
        description: 'Rewards people can spend stars on, and requests waiting for a parent.',
        properties: const {},
        scope: Scope.read,
        readOnly: true,
        run: _rewards,
      ),
    ];

ToolResult _today(ToolContext c, Args a) {
  final date = a.has('date') ? toolDate(a.raw['date'], c.zone, 'date') : c.today;
  final view = c.den.today(date: date);
  final events = [for (final o in view.events) if (c.readable.contains(o.event.space)) o];
  Wire.sortOccurrences(events);
  final chores = c.choresOn(date);
  final lists = [for (final l in view.lists) if (c.readable.contains(l.list.space)) l];
  final done = chores.where((x) => x.done).length;
  final text = StringBuffer('${longDate(date)} (${c.zone})\n');
  text.writeln(events.isEmpty ? 'No events.' : 'Events:');
  events.map(c.occurrenceLine).forEach(text.writeln);
  text.writeln(chores.isEmpty ? 'No chores.' : 'Chores ($done of ${chores.length} done):');
  chores.map(c.choreLine).forEach(text.writeln);
  for (final l in lists) {
    text.writeln('List ${l.list.title}: ${l.open} open of ${l.items.length}');
  }
  for (final g in view.gaps) {
    text.writeln('Needs someone: ${g.message}');
  }
  return ToolResult(text.toString().trim(), {
    'date': date,
    'timezone': c.zone,
    'events': [for (final o in events) c.wire.occurrence(o)],
    'chores': [for (final cd in chores) c.wire.choreDay(cd)],
    'chore_summary': Wire.choreSummary(chores),
    'lists': [for (final l in lists) Wire.list(l)],
    'gaps': [for (final g in view.gaps) c.wire.gap(g)],
  });
}

ToolResult _week(ToolContext c, Args a) {
  final start = a.has('start') ? toolDate(a.raw['start'], c.zone, 'start') : c.today;
  final days = a.integer('days', min: 1, max: 14) ?? 7;
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
  return ToolResult(text.toString().trim(), {'start': start, 'timezone': c.zone, 'days': out});
}

ToolResult _search(ToolContext c, Args a) {
  final query = a.str('query', required: true, max: 200)!;
  final limit = a.integer('limit', min: 1, max: 100) ?? 20;
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
  return ToolResult(text, {'results': [for (final h in hits) c.wire.searchHit(h)]});
}

ToolResult _history(ToolContext c, Args a) {
  final limit = a.integer('limit', min: 1, max: 200) ?? 20;
  final person = a.str('person');
  final entries = c.den
      .history(
        query: a.str('query', max: 200),
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
  return ToolResult(text, {'entries': [for (final h in entries) c.wire.history(h)]});
}

ToolResult _members(ToolContext c, Args a) {
  final members = c.den.members;
  final text = [
    'Family: ${c.den.family?.name} (${c.zone})',
    for (final m in members) '- ${m.name}: ${m.role.name}${m.id == c.access.member ? ' (this connection)' : ''} [id ${m.id}]',
    if (c.den.categories.isNotEmpty) 'Categories: ${c.den.categories.map((x) => x.name).join(', ')}',
  ].join('\n');
  return ToolResult(text, {
    'family': c.wire.family(),
    'me': c.access.member,
    'members': [for (final m in members) Wire.member(m)],
    'categories': [for (final x in c.den.categories) Wire.category(x)],
  });
}

ToolResult _events(ToolContext c, Args a) {
  final start = a.has('start') ? toolInstant(a.raw['start'], c.zone, 'start') : midnightIn(c.zone, c.today);
  final end = a.has('end') ? toolInstant(a.raw['end'], c.zone, 'end') : start + 7 * Duration.millisecondsPerDay;
  if (end <= start) throw ToolError('"end" must be after "start".');
  if (end - start > 400 * Duration.millisecondsPerDay) throw ToolError('The window can be at most 400 days.');
  final person = a.str('person');
  final who = person == null ? null : c.people.one(person);
  final limit = a.integer('limit', min: 1, max: 2000) ?? 200;
  final all = [
    for (final o in c.occurrences(start, end))
      if (who == null || o.assignees.isEmpty || o.assignees.contains(who)) o,
  ];
  final shown = all.take(limit).toList();
  final text = shown.isEmpty ? 'No events in that window.' : shown.map(c.occurrenceLine).join('\n');
  return ToolResult(text, {
    ...c.wire.instant('start', start),
    ...c.wire.instant('end', end),
    'truncated': all.length > limit,
    'events': [for (final o in shown) c.wire.occurrence(o)],
  });
}

ToolResult _chores(ToolContext c, Args a) {
  final date = a.has('date') ? toolDate(a.raw['date'], c.zone, 'date') : c.today;
  final person = a.str('person');
  final who = person == null ? null : c.people.one(person);
  final chores = [for (final cd in c.choresOn(date)) if (who == null || cd.owner == who) cd];
  final text = chores.isEmpty ? 'No chores on ${longDate(date)}.' : '${longDate(date)}:\n${chores.map(c.choreLine).join('\n')}';
  return ToolResult(text, {
    'date': date,
    'chores': [for (final cd in chores) c.wire.choreDay(cd)],
    'summary': Wire.choreSummary(chores),
  });
}

ToolResult _lists(ToolContext c, Args a) {
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
  return ToolResult(lists.isEmpty ? 'No lists.' : text.toString().trim(), {
    'lists': [for (final l in lists) Wire.list(l)],
  });
}

ToolResult _points(ToolContext c, Args a) {
  final summary = c.den.points();
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
  return ToolResult(text.toString().trim(), data);
}

ToolResult _rewards(ToolContext c, Args a) {
  final summary = c.den.points();
  final text = [
    for (final r in summary.rewards) '- ${r.title}: ${r.cost} stars${r.needsApproval ? ', needs a parent' : ''} [reward ${r.id}]',
    for (final p in summary.pending)
      'Waiting: ${c.people.name(p.member)} asked for ${summary.rewards.where((r) => r.id == p.reward).firstOrNull?.title ?? 'a reward'} [request ${p.id}]',
  ].join('\n');
  return ToolResult(text.isEmpty ? 'No rewards yet.' : text, {
    'rewards': [for (final r in summary.rewards) Wire.reward(r)],
    'pending': [for (final p in summary.pending) c.wire.redemption(p)],
  });
}
