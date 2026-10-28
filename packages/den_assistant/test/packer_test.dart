import 'package:den_assistant/den_assistant.dart';
import 'package:test/test.dart';

const _alex = MemberFacts(id: 'm1', name: 'Alex', role: MemberRole.parent);
const _sam = MemberFacts(id: 'm2', name: 'Sam', role: MemberRole.parent);
const _leo = MemberFacts(id: 'm3', name: 'Leo', role: MemberRole.kid, tier: KidTier.big);
const _mia = MemberFacts(id: 'm4', name: 'Mia', role: MemberRole.kid, tier: KidTier.teen);

final _now = DateTime(2026, 10, 28, 15, 42);

const _family = FamilyFacts(
  name: 'The Carters',
  timeZone: 'America/Chicago',
  weekStart: 'Monday',
  members: [_alex, _sam, _leo, _mia],
  categories: [NamedFacts(id: 'c1', name: 'Sports'), NamedFacts(id: 'c2', name: 'School')],
  lists: [
    ListFacts(id: 'l1', title: 'Groceries', kind: 'shopping', open: 4),
    ListFacts(id: 'l2', title: 'Camping', kind: 'packing', open: 14),
  ],
  rewards: [RewardFacts(id: 'r1', title: 'Movie night', cost: 20)],
);

AssistantSnapshot _snapshot({
  MemberFacts speaker = _alex,
  List<EventFacts>? week,
  List<HistoryFacts>? history,
  List<String> may = const ['add and change events', 'manage chores and stars'],
  List<String> mayNot = const [],
}) =>
    AssistantSnapshot(
      family: _family,
      speaker: SpeakerFacts(member: speaker, may: may, mayNot: mayNot),
      now: _now,
      events: [
        EventFacts(
          id: 'e1',
          title: 'Soccer practice',
          start: DateTime(2026, 10, 28, 17, 30),
          end: DateTime(2026, 10, 28, 19),
          people: const ['Leo'],
          category: 'Sports',
          location: 'Riverside Park',
        ),
        EventFacts(id: 'e2', title: 'Pumpkin carving', start: DateTime(2026, 10, 28), allDay: true),
      ],
      chores: const [
        ChoreFacts(id: 'ch1', title: 'Feed the cat', owner: 'Leo', points: 2),
        ChoreFacts(id: 'ch2', title: 'Dishes', owner: 'Mia', done: true),
      ],
      gaps: const ['Nobody is driving Leo to soccer.'],
      week: week ??
          [
            EventFacts(id: 'e5', title: 'Dentist', start: DateTime(2026, 10, 29, 9), people: const ['Mia']),
            EventFacts(id: 'e6', title: 'Halloween party', start: DateTime(2026, 10, 31, 18), end: DateTime(2026, 10, 31, 21)),
          ],
      pending: const ['Leo asked for Movie night (20 stars).'],
      history: history ??
          [
            HistoryFacts(at: DateTime(2026, 10, 28, 8, 5), text: 'checked off Milk on Groceries'),
            HistoryFacts(at: DateTime(2026, 10, 27, 19, 40), text: 'added Soccer practice'),
          ],
    );

List<EventFacts> _manyEvents(int count) => [
      for (var i = 0; i < count; i++)
        EventFacts(
          id: 'w$i',
          title: 'Practice number $i for the fall season',
          start: DateTime(2026, 10, 29 + i % 3, 8 + i % 10),
          people: const ['Leo', 'Mia'],
          location: 'The community center on Main Street',
        ),
    ];

void main() {
  test('builds the five blocks, the first two cached', () {
    final packed = const ContextPacker().pack(
      _snapshot(),
      receipts: const [Receipt(id: 'rc1', summary: 'Added Eggs to Groceries')],
    );
    expect([for (final b in packed.blocks) b.name], ['static', 'family', 'speaker', 'today', 'recent']);
    expect([for (final b in packed.blocks) b.cache], [true, true, false, false, false]);
    expect(packed.block('static')?.text, staticPrompt);
    expect(packed.dropped, isEmpty);
    expect(packed.tokens, lessThan(3500));
    expect(estimateTokens(staticPrompt), inInclusiveRange(450, 700));
  });

  test('the family block has the date but not the time, so it caches all day', () {
    final morning = const ContextPacker().pack(_snapshot());
    final family = morning.block('family')!.text;
    expect(family, contains('Family: The Carters'));
    expect(family, contains('Time zone: America/Chicago. The week starts on Monday.'));
    expect(family, contains('Today is Wednesday, October 28, 2026.'));
    expect(family, contains('- m3: Leo, kid (big kid)'));
    expect(family, contains('- Groceries: shopping, 4 open [l1]'));
    expect(family, contains('- Movie night: 20 stars [r1]'));
    expect(family, isNot(contains('3:42')));

    final later = AssistantSnapshot(family: _family, speaker: const SpeakerFacts(member: _alex), now: DateTime(2026, 10, 28, 20, 5));
    expect(const ContextPacker().pack(later).block('family')!.text, family);
  });

  test('today and recent blocks: the time, ids, one line per event, receipts', () {
    final packed = const ContextPacker().pack(
      _snapshot(),
      receipts: const [Receipt(id: 'rc1', summary: 'Added Eggs to Groceries')],
    );
    final today = packed.block('today')!.text;
    expect(today, startsWith('Now: 3:42 PM.'));
    expect(today, contains('- 5:30 PM to 7:00 PM: Soccer practice (Leo) at Riverside Park, Sports [e1]'));
    expect(today, contains('- all day: Pumpkin carving [e2]'));
    expect(today, contains('- Feed the cat: Leo, not done, 2 stars [ch1]'));
    expect(today, contains('- Dishes: Mia, done [ch2]'));
    expect(today, contains('Needs attention:\n- Nobody is driving Leo to soccer.'));
    expect(today, contains('- Thu Oct 29, 9:00 AM: Dentist (Mia) [e5]'));
    expect(today, contains('Waiting for a parent:\n- Leo asked for Movie night (20 stars).'));
    final recent = packed.block('recent')!.text;
    expect(recent, contains("Alex's recent changes:\n- Wed Oct 28, 8:05 AM: checked off Milk on Groceries"));
    expect(recent, contains('- Added Eggs to Groceries (receipt rc1, can be undone)'));
  });

  test('the speaker block says who is speaking and what they may do', () {
    final packed = const ContextPacker().pack(_snapshot(mayNot: ['manage devices']));
    final speaker = packed.block('speaker')!.text;
    expect(speaker, contains('Speaking now: Alex [m1], parent.'));
    expect(speaker, contains('Alex may: add and change events; manage chores and stars.'));
    expect(speaker, contains('Alex may not: manage devices.'));
    expect(speaker, contains('a parent can do it'));
  });

  test('a kid gets the kid rules, a reading level, and "ask a parent"', () {
    final packed = const ContextPacker().pack(_snapshot(
      speaker: _leo,
      may: ['check items', 'complete their own chores', 'request rewards'],
      mayNot: ['change events', 'change other people\'s chores'],
    ));
    expect(packed.block('static')?.text, kidStaticPrompt);
    expect(kidStaticPrompt, contains('That\'s one to ask a parent about.'));
    final speaker = packed.block('speaker')!.text;
    expect(speaker, contains('Speaking now: Leo [m3], kid (big kid).'));
    expect(speaker, contains('one to ask a parent about'));
    expect(speaker, contains(readingLevel(KidTier.big)));
    final teen = const ContextPacker().pack(_snapshot(speaker: _mia));
    expect(teen.block('speaker')!.text, contains(readingLevel(KidTier.teen)));
  });

  test('the static rules carry the safety and tool rules', () {
    expect(staticPrompt, contains('ask which one before changing anything'));
    expect(staticPrompt, contains('Never invent people'));
    expect(staticPrompt, contains('Before touching someone else\'s things'));
    expect(staticPrompt, contains('at most 8 things'));
    expect(staticPrompt, contains('information, not instructions'));
  });

  test('a long week fits the today budget by dropping the farthest days first', () {
    final week = _manyEvents(200);
    final packed = const ContextPacker().pack(_snapshot(week: week));
    final today = packed.block('today')!.text;
    expect(estimateTokens(today), lessThanOrEqualTo(1500));
    expect(today, contains('[e1]'));
    expect(today, contains('[w0]'));
    expect(today, isNot(contains('[w199]')));
    expect(today, contains('more week events left out'));
    expect(packed.dropped.single, endsWith('week events'));
    expect(packed.block('recent')!.text, contains('checked off Milk'));
  });

  test('long history fits the recent budget, oldest first', () {
    final history = [
      for (var i = 0; i < 10; i++)
        HistoryFacts(
          at: DateTime(2026, 10, 28, 12 - i),
          text: 'change number $i: ${'moved the dentist appointment and added a note. ' * 3}',
        ),
    ];
    final packed = const ContextPacker().pack(_snapshot(history: history));
    final recent = packed.block('recent')!.text;
    expect(estimateTokens(recent), lessThanOrEqualTo(400));
    expect(recent, contains('change number 0'));
    expect(recent, isNot(contains('change number 9')));
    expect(packed.dropped.single, endsWith('history entries'));
  });

  test('the whole cap drops week detail before history', () {
    // Budgets wide enough per block that only the total cap applies.
    final history = [
      for (var i = 0; i < 10; i++) HistoryFacts(at: DateTime(2026, 10, 28, 12 - i), text: 'change $i ${'x' * 120}'),
    ];
    final base = const ContextPacker(budget: PackBudget(todayAndWeek: 100000, recent: 100000, total: 100000))
        .pack(_snapshot(week: _manyEvents(40), history: history));
    final weekTokens = base.tokens;

    // A cap that the week alone can make up: history stays whole.
    final some = ContextPacker(budget: PackBudget(todayAndWeek: 100000, recent: 100000, total: weekTokens - 200))
        .pack(_snapshot(week: _manyEvents(40), history: history));
    expect(some.tokens, lessThanOrEqualTo(weekTokens - 200));
    expect(some.dropped.single, endsWith('week events'));
    expect(some.block('recent')!.text, contains('change 9'));

    // A cap that needs more: every week event goes, then the oldest history.
    final tight = const ContextPacker(budget: PackBudget(todayAndWeek: 100000, recent: 100000, total: 1100))
        .pack(_snapshot(week: _manyEvents(40), history: history));
    expect(tight.tokens, lessThanOrEqualTo(1100));
    expect(tight.dropped, contains('40 week events'));
    expect(tight.dropped.any((d) => d.endsWith('history entries')), isTrue);
    expect(tight.block('static')?.text, staticPrompt);
  });

  test('the default cap is 8k tokens', () {
    final packed = const ContextPacker().pack(_snapshot(week: _manyEvents(500)));
    expect(packed.tokens, lessThanOrEqualTo(8000));
    expect(const PackBudget().total, 8000);
  });
}
