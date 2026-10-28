import '../model.dart';
import '../tools.dart';
import 'prompts.dart';
import 'snapshot.dart';

/// A rough token count: about four characters a token, which is close for English and errs
/// high for short words. Good enough for budgets; the provider's count is in [Usage].
int estimateTokens(String text) => (text.length + 3) ~/ 4;

/// Token budgets for the context blocks.
class PackBudget {
  /// Budgets.
  const PackBudget({this.todayAndWeek = 1500, this.recent = 400, this.total = 8000});

  /// Today's events, chores and gaps, the next 7 days, and pending requests.
  final int todayAndWeek;

  /// The speaker's recent History and this conversation's receipts.
  final int recent;

  /// Every block together.
  final int total;
}

/// The system blocks for a turn, and what was left out to fit.
class PackedContext {
  /// Packed blocks.
  const PackedContext({required this.blocks, this.dropped = const []});

  /// `static` and `family` (cached), then `speaker`, `today` and `recent`.
  final List<SystemBlock> blocks;

  /// What didn't fit, as "3 week events".
  final List<String> dropped;

  /// The estimated size of all blocks.
  int get tokens => blocks.fold(0, (sum, b) => sum + estimateTokens(b.text));

  /// The block called [name], or null.
  SystemBlock? block(String name) {
    for (final b in blocks) {
      if (b.name == name) return b;
    }
    return null;
  }
}

/// Builds the system blocks from a snapshot, following the budget table in the plan:
///
/// | Block | Contents | Budget |
/// | --- | --- | --- |
/// | static (cached) | Den's job, tone, safety and tool rules | ~600 |
/// | family (cached daily) | name, zone, week start, date; members; categories; lists; rewards | ~800 |
/// | speaker | who is speaking, what they may do; a kid's reading level | ~150 |
/// | today | the time; today's events, chores and gaps; the next 7 days; pending requests | at most 1,500 |
/// | recent | the speaker's last 10 History entries; this conversation's receipts | at most 400 |
///
/// The whole is capped at [PackBudget.total] (8k) by dropping week detail first, then history.
/// The family block carries the date but not the time, so it stays the same all day and caches.
class ContextPacker {
  /// A packer with [budget].
  const ContextPacker({this.budget = const PackBudget()});

  /// The budgets.
  final PackBudget budget;

  /// The blocks for [snapshot]; [receipts] are this conversation's changes.
  PackedContext pack(AssistantSnapshot snapshot, {List<Receipt> receipts = const []}) {
    final family = snapshot.family;
    final speaker = snapshot.speaker.member;
    final kid = speaker.role == MemberRole.kid;
    final staticText = kid ? kidStaticPrompt : staticPrompt;

    final familyHead = [
      'Family: ${family.name}',
      'Time zone: ${family.timeZone}. The week starts on ${family.weekStart}.',
      'Today is ${longDate(snapshot.now)}.',
      family.pointsOn ? 'Stars (points) are on.' : 'Stars (points) are off.',
    ].join('\n');
    final people = _Section('People (id: name, role):', [
      for (final m in family.members) '- ${m.id}: ${m.name}, ${roleName(m)}',
    ], label: 'people');
    final categories = _Section('Event categories:', [
      for (final c in family.categories) '- ${c.name} [${c.id}]',
    ], label: 'categories');
    final lists = _Section('Lists (open items):', [
      for (final l in family.lists) '- ${l.title}: ${l.kind}, ${l.open} open [${l.id}]',
    ], label: 'lists');
    final rewards = _Section('Rewards:', [
      for (final r in family.rewards) '- ${r.title}: ${r.cost} stars [${r.id}]',
    ], label: 'rewards');

    final speakerText = [
      'Speaking now: ${speaker.name} [${speaker.id}], ${roleName(speaker)}.',
      if (snapshot.speaker.may.isNotEmpty) '${speaker.name} may: ${snapshot.speaker.may.join('; ')}.',
      if (snapshot.speaker.mayNot.isNotEmpty)
        '${speaker.name} may not: ${snapshot.speaker.mayNot.join('; ')}. '
            'If they ask for one of these, say ${kid ? 'it\'s one to ask a parent about' : 'a parent can do it'}.',
      if (kid) readingLevel(speaker.tier),
    ].join('\n');

    final events = _Section("Today's events:", [
      for (final e in snapshot.events) _eventLine(e),
    ], label: 'events today', empty: 'Nothing on the calendar.');
    final chores = _Section("Today's chores:", [
      for (final c in snapshot.chores)
        '- ${c.title}: ${c.owner}, ${c.done ? 'done' : 'not done'}'
            '${c.points == null ? '' : ', ${c.points} stars'} [${c.id}]',
    ], label: 'chores today');
    final gaps = _Section('Needs attention:', [for (final g in snapshot.gaps) '- $g'], label: 'gaps');
    final week = _Section('Next 7 days:', [
      for (final e in snapshot.week) _eventLine(e, withDay: true),
    ], label: 'week events');
    final pending = _Section('Waiting for a parent:', [for (final p in snapshot.pending) '- $p'], label: 'pending requests');
    final history = _Section("${speaker.name}'s recent changes:", [
      for (final h in snapshot.history.take(10)) '- ${shortDay(h.at)}, ${clock(h.at)}: ${h.text}',
    ], label: 'history entries');
    final done = _Section('Done in this conversation:', [
      for (final r in receipts) '- ${r.summary} (receipt ${r.id}${r.undoable ? ', can be undone' : ''})',
    ], label: 'receipts', oldestFirst: true);

    String familyText() => _join([familyHead, people.render(), categories.render(), lists.render(), rewards.render()]);
    String todayText() => _join([
          'Now: ${clock(snapshot.now)}.',
          events.render(),
          chores.render(),
          gaps.render(),
          week.render(),
          pending.render(),
        ]);
    String recentText() => _join([history.render(), done.render()]);
    int total() =>
        estimateTokens(staticText) +
        estimateTokens(familyText()) +
        estimateTokens(speakerText) +
        estimateTokens(todayText()) +
        estimateTokens(recentText());

    _shrink(() => estimateTokens(todayText()), budget.todayAndWeek, [week, pending, chores, events, gaps]);
    _shrink(() => estimateTokens(recentText()), budget.recent, [history, done]);
    _shrink(total, budget.total, [week, history, done, rewards, lists, categories, pending, chores, events, gaps]);

    final recent = recentText();
    return PackedContext(
      blocks: [
        SystemBlock(staticText, cache: true, name: 'static'),
        SystemBlock(familyText(), cache: true, name: 'family'),
        SystemBlock(speakerText, name: 'speaker'),
        SystemBlock(todayText(), name: 'today'),
        if (recent.isNotEmpty) SystemBlock(recent, name: 'recent'),
      ],
      dropped: [
        for (final s in [week, history, done, rewards, lists, categories, pending, chores, events, gaps])
          if (s.omitted > 0) '${s.omitted} ${s.label}',
      ],
    );
  }

  static String _eventLine(EventFacts e, {bool withDay = false}) {
    final end = e.end;
    final when = e.allDay ? 'all day' : (end == null ? clock(e.start) : '${clock(e.start)} to ${clock(end)}');
    final day = withDay ? '${shortDay(e.start)}, ' : '';
    final who = e.people.isEmpty ? '' : ' (${e.people.join(', ')})';
    final where = e.location == null ? '' : ' at ${e.location}';
    final category = e.category == null ? '' : ', ${e.category}';
    return '- $day$when: ${e.title}$who$where$category [${e.id}]';
  }

  static String _join(List<String> parts) => parts.where((p) => p.isNotEmpty).join('\n\n');

  /// Drops lines from [order], one section at a time, until [size] fits [limit].
  static void _shrink(int Function() size, int limit, List<_Section> order) {
    for (final section in order) {
      while (size() > limit) {
        if (!section.drop()) break;
      }
    }
  }
}

/// A titled run of lines that can give up lines to fit a budget.
class _Section {
  _Section(this.title, this.lines, {required this.label, this.empty, this.oldestFirst = false});

  final String title;
  final List<String> lines;
  final String label;
  final String? empty;

  /// Whether [lines] are oldest first, so dropping takes from the front.
  final bool oldestFirst;
  int omitted = 0;

  bool drop() {
    if (lines.isEmpty) return false;
    if (oldestFirst) {
      lines.removeAt(0);
    } else {
      lines.removeLast();
    }
    omitted++;
    return true;
  }

  String render() {
    if (lines.isEmpty && omitted == 0) {
      final none = empty;
      return none == null ? '' : '$title\n- $none';
    }
    final out = StringBuffer(title);
    for (final line in lines) {
      out.write('\n$line');
    }
    if (omitted > 0) out.write('\n- ($omitted more $label left out; use the read tools for them)');
    return out.toString();
  }
}
