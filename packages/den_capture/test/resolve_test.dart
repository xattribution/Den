import 'package:den_capture/den_capture.dart';
import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'support.dart';

const photo = CaptureOrigin(CaptureKind.photo, reader: 'Claude');

Map<String, Object?> event(Map<String, Object?> fields) => {
      'title': 'Soccer',
      'date': '2026-10-21',
      'start': null,
      'end': null,
      'endDate': null,
      'repeat': null,
      'people': <String>[],
      'location': null,
      'notes': null,
      'kind': null,
      'remindBefore': <int>[],
      ...fields,
    };

Map<String, Object?> repeat(String every, {List<String> days = const [], int interval = 1, int? nth, String? until, int? count}) => {
      'every': every,
      'interval': interval,
      'days': days,
      'nth': nth,
      'monthDay': null,
      'until': until,
      'count': count,
    };

void main() {
  late Den den;
  late CaptureContext context;
  setUpAll(() async {
    den = await demo();
    context = CaptureContext.of(den);
  });
  tearDownAll(() => den.close());

  CaptureDraft draft(Map<String, Object?> wire) => draftFrom({...empty, ...wire}, context, origin: photo);
  DraftEvent one(Map<String, Object?> fields) => draft({'events': [event(fields)]}).events.single;

  group('People', () {
    test('match members by name, first name or "me"; everyone means nobody in particular', () {
      final e = one({'people': ['Leo', 'me', 'Grandma', 'maya', 'everyone']});
      expect(e.people, [idOf(den, 'Leo'), idOf(den, 'Alex'), idOf(den, 'Grandma Rosa'), idOf(den, 'Maya')]);
      expect(e.issues, isEmpty);
    });

    test('a name nobody has holds the entry for a look', () {
      final e = one({'people': ['Leo', 'Coach Dan']});
      expect(e.people, [idOf(den, 'Leo')]);
      expect(e.issues, [const DraftIssue(IssueKind.unknownPerson, 'No one in the family is called Coach Dan')]);
      expect(e.ready, isFalse);
      expect(e.blocked, isFalse);
    });
  });

  group('Days and times', () {
    test('an event with no time is all day; a start with no end lasts an hour', () {
      expect(one({}).allDay, isTrue);
      final e = one({'start': '17:00'});
      expect((e.start, e.end), ('17:00', '18:00'));
      expect(one({'start': null, 'end': '18:00'}).end, isNull);
    });

    test('times come in loosely and leave as HH:mm', () {
      expect(one({'start': '5:00 PM', 'end': '6:30pm'}).start, '17:00');
      expect(one({'start': '5:00 PM', 'end': '6:30pm'}).end, '18:30');
      expect(one({'start': '7 am'}).start, '07:00');
      expect(one({'start': 'noonish'}).allDay, isTrue);
    });

    test('"11 to 1" ends at 1 PM, not before it starts', () {
      final e = one({'start': '11:00', 'end': '01:00'});
      expect(e.end, '13:00');
    });

    test('a missing day blocks the entry until someone picks one', () {
      final e = one({'date': null});
      expect(e.date, context.today);
      expect(e.blocked, isTrue);
      expect(e.issues.single.kind, IssueKind.needsDay);
    });

    test('"today" and "tomorrow" from a small model are read', () {
      expect(one({'date': 'tomorrow'}).date, '2026-10-17');
    });

    test('the same hours on several days repeat daily', () {
      final e = one({'date': '2026-11-02', 'endDate': '2026-11-06', 'start': '08:00', 'end': '15:30'});
      expect(e.rrule, 'FREQ=DAILY;UNTIL=20261106');
      expect(e.endDate, isNull);
    });

    test('an all-day span keeps its last day', () {
      final e = one({'date': '2026-11-26', 'endDate': '2026-11-27'});
      expect((e.allDay, e.endDate, e.rrule), (true, '2026-11-27', null));
    });
  });

  group('Repeats', () {
    test('weekly on named days starts on the first of them', () {
      final e = one({'date': '2026-10-16', 'repeat': repeat('week', days: ['WE'])});
      expect(e.rrule, 'FREQ=WEEKLY;BYDAY=WE');
      expect(e.date, '2026-10-21');
    });

    test('every other week, until a date, from day names a model spelled out', () {
      final e = one({'date': '2026-10-16', 'repeat': repeat('week', days: ['Tuesday', 'thursday'], interval: 2, until: '2026-12-17')});
      expect(e.rrule, 'FREQ=WEEKLY;INTERVAL=2;UNTIL=20261217;BYDAY=TU,TH');
      expect(e.date, '2026-10-20');
    });

    test('the second Tuesday of the month', () {
      final e = one({'date': '2026-10-16', 'repeat': repeat('month', days: ['TU'], nth: 2)});
      expect(e.rrule, 'FREQ=MONTHLY;BYDAY=2TU');
      expect(e.date, '2026-11-10');
    });

    test('"daily" on weekdays only is weekly on those days', () {
      final e = one({'date': '2026-10-17', 'repeat': repeat('day', days: ['MO', 'TU', 'WE', 'TH', 'FR'])});
      expect(e.rrule, 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR');
      expect(e.date, '2026-10-19');
    });

    test('an end before the start is dropped; a count is kept', () {
      expect(one({'repeat': repeat('week', until: '2026-01-01')}).rrule, 'FREQ=WEEKLY;BYDAY=WE');
      expect(one({'repeat': repeat('week', count: 8)}).rrule, 'FREQ=WEEKLY;COUNT=8;BYDAY=WE');
    });

    test('a repeat Den can\'t read happens once, and says so', () {
      final e = one({'repeat': {'every': 'fortnight'}});
      expect(e.rrule, isNull);
      expect(e.issues.single.kind, IssueKind.guessed);
      expect(e.ready, isTrue);
    });
  });

  group('Events', () {
    test('take the family\'s category for their kind, or a kind their title suggests', () {
      final sports = den.categories.firstWhere((c) => c.icon == 'sports').id;
      expect(one({'kind': 'sports'}).category, sports);
      expect(one({'title': 'Dentist', 'kind': null}).category, den.categories.firstWhere((c) => c.icon == 'health').id);
      expect(one({'kind': 'work'}).category, isNull);
    });

    test('shouting titles from flyers read in sentence case', () {
      expect(one({'title': 'FAMILY SCIENCE NIGHT'}).title, 'Family science night');
      expect(one({'title': 'iPad club'}).title, 'IPad club');
    });

    test('reminders before the start are kept within the engine\'s limits', () {
      expect(one({'start': '09:00', 'remindBefore': [60, 60, 1440, -5, 99999]}).reminders, [60, 1440]);
    });

    test('something without a title is dropped', () {
      expect(draft({'events': [event({'title': '  '})]}).isEmpty, isTrue);
      expect(draft({'events': 'not a list'}).isEmpty, isTrue);
    });
  });

  group('Chores', () {
    Map<String, Object?> chore(Map<String, Object?> f) =>
        {'title': 'Dishes', 'people': <String>[], 'takeTurns': false, 'date': null, 'repeat': null, 'due': null, 'points': null, ...f};

    test('nobody named is anyone\'s; one person owns it; people taking turns rotate weekly', () {
      expect(draft({'chores': [chore({})]}).chores.single.owner, isA<OwnerAnyone>());
      final leo = draft({'chores': [chore({'people': ['Leo']})]}).chores.single;
      expect((leo.owner as OwnerMember).id, idOf(den, 'Leo'));
      final turns = draft({'chores': [chore({'people': ['Maya', 'Leo'], 'takeTurns': true, 'repeat': repeat('day')})]}).chores.single;
      expect((turns.owner as OwnerRotation).ids, [idOf(den, 'Maya'), idOf(den, 'Leo')]);
      expect(turns.rrule, 'FREQ=DAILY');
    });

    test('several people not taking turns each get the chore', () {
      final both = draft({'chores': [chore({'title': 'Make bed', 'people': ['Maya', 'Leo']})]}).chores.toList();
      expect(both, hasLength(2));
      expect(both.map((c) => c.key), ['c0.0', 'c0.1']);
      expect(both.first.icon, 'bed');
    });

    test('a due time and points are kept', () {
      final c = draft({'chores': [chore({'title': 'Take out the trash', 'due': '19:00', 'points': 2})]}).chores.single;
      expect((c.dueTime, c.points, c.icon, c.date), ('19:00', 2, 'trash', context.today));
    });
  });

  group('Items', () {
    Map<String, Object?> item(Map<String, Object?> f) => {'text': 'Milk', 'qty': null, 'store': null, 'list': null, ...f};
    String listId(String title) => den.lists.firstWhere((l) => l.list.title == title).list.id;

    test('go on the groceries list unless they name another', () {
      expect(draft({'items': [item({})]}).items.single.listId, listId('Groceries'));
      expect(draft({'items': [item({'list': 'the packing list'})]}).items.single.listId, listId('Beach trip packing'));
      expect(draft({'items': [item({'list': 'Science fair'})]}).items.single.listId, listId('Science fair supplies'));
    });

    test('a list the family doesn\'t have is made for them', () {
      final i = draft({'items': [item({'text': 'Tent', 'list': 'Camping trip list'})]}).items.single;
      expect(i.listId, isNull);
      expect((i.newList!.title, i.newList!.kind), ('Camping trip', ListKind.packing));
    });

    test('stores keep the family\'s spelling', () {
      expect(draft({'items': [item({'store': 'costco', 'qty': '2 gal'})]}).items.single.store, 'Costco');
      expect(draft({'items': [item({'store': 'Aldi'})]}).items.single.store, 'Aldi');
    });
  });

  group('Reminders', () {
    test('are for the person sharing unless they name someone', () {
      final r = draft({
        'reminders': [
          {'text': 'Call the dentist', 'date': '2026-10-19', 'time': '09:00', 'people': <String>[]},
          {'text': 'Practice piano', 'date': '2026-10-19', 'time': null, 'people': ['Maya']},
        ],
      }).reminders.toList();
      expect(r.first.person, idOf(den, 'Alex'));
      expect(r.last.person, idOf(den, 'Maya'));
    });
  });

  test('a small on-device model\'s loose JSON still reads', () {
    final wire = lenientJson(fixtureText('gemini_nano.txt'))!;
    final d = draft(wire);
    final soccer = d.events.single;
    expect((soccer.title, soccer.date, soccer.start, soccer.end), ('Soccer', '2026-10-21', '17:00', '18:00'));
    expect(soccer.rrule, 'FREQ=WEEKLY;BYDAY=WE');
    expect(soccer.people, [idOf(den, 'Leo')]);
    final milk = d.items.single;
    expect((milk.text, milk.qty, milk.store), ('Milk', null, 'Costco'));
    final call = d.reminders.single;
    expect((call.text, call.date, call.time, call.person), ('Call grandma', '2026-10-17', '18:00', idOf(den, 'Alex')));
  });

  test('unclear notes are kept, a few at most', () {
    expect(draft({'unclear': ['a', 'b', 'c', 'd', 'e', 'f', 7]}).unclear, ['a', 'b', 'c', 'd', 'e']);
  });
}
