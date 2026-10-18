import 'package:den_capture/den_capture.dart';
import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Den's own reader, from what people type or say to what the family gets.
void main() {
  late Den den;
  late CaptureContext context;
  setUpAll(() async {
    den = await demo();
    context = CaptureContext.of(den);
  });
  tearDownAll(() => den.close());

  CaptureDraft read(String text) =>
      draftFrom(readWords(text, context), context, origin: const CaptureOrigin(CaptureKind.typed));

  test('"soccer every Wednesday at 5 for Leo"', () {
    final e = read('soccer every Wednesday at 5 for Leo').events.single;
    expect(e.title, 'Soccer');
    expect(e.date, '2026-10-21');
    expect((e.start, e.end), ('17:00', '18:00'));
    expect(e.rrule, 'FREQ=WEEKLY;BYDAY=WE');
    expect(e.people, [idOf(den, 'Leo')]);
    expect(e.category, den.categories.firstWhere((c) => c.icon == 'sports').id);
    expect(e.issues.single.kind, IssueKind.guessed, reason: 'Den guessed PM for "5"');
  });

  test('"Dentist for Zoe next Tuesday at 3:30pm"', () {
    final e = read('Dentist for Zoe next Tuesday at 3:30pm').events.single;
    expect((e.title, e.date, e.start, e.end), ('Dentist', '2026-10-20', '15:30', '16:30'));
    expect(e.people, [idOf(den, 'Zoe')]);
    expect(e.issues, isEmpty);
  });

  test('a time range with one AM or PM, and a place', () {
    final e = read('Piano lessons for Maya Tuesdays and Thursdays 4-5pm at Riverside Music until Dec 17').events.single;
    expect((e.title, e.start, e.end, e.location), ('Piano lessons', '16:00', '17:00', 'Riverside Music'));
    expect(e.rrule, 'FREQ=WEEKLY;UNTIL=20261217;BYDAY=TU,TH');
    expect(e.date, '2026-10-20');
  });

  test('"Lunch with Grandma Rosa at Luca\'s Friday at noon"', () {
    final e = read("Lunch with Grandma Rosa at Luca's Friday at noon").events.single;
    expect((e.title, e.location, e.date, e.start), ('Lunch', "Luca's", '2026-10-16', '12:00'));
    expect(e.people, [idOf(den, 'Grandma Rosa')]);
  });

  test('a date with a month name and no year is the next one', () {
    expect(read('Science fair March 3').events.single.date, '2027-03-03');
    expect(read('Book fair Nov. 2').events.single.date, '2026-11-02');
    expect(read('Party on 10/31 at 2pm').events.single.start, '14:00');
  });

  test('"milk, eggs, 2 lb apples from Costco"', () {
    final items = read('milk, eggs, 2 lb apples from Costco').items.toList();
    expect([for (final i in items) (i.text, i.qty, i.store)], [
      ('Milk', null, 'Costco'),
      ('Eggs', null, 'Costco'),
      ('Apples', '2 lb', 'Costco'),
    ]);
    final groceries = den.lists.firstWhere((l) => l.list.title == 'Groceries').list.id;
    expect(items.every((i) => i.listId == groceries), isTrue);
  });

  test('"we need paper towels, a dozen eggs and bananas", and speech with no commas', () {
    expect([for (final i in read('we need paper towels, a dozen eggs and bananas').items) (i.text, i.qty)], [
      ('Paper towels', null),
      ('Eggs', 'a dozen'),
      ('Bananas', null),
    ]);
    expect([for (final i in read('milk eggs bread').items) i.text], ['Milk', 'Eggs', 'Bread']);
  });

  test('"add sunscreen and beach towels to the packing list"', () {
    final packing = den.lists.firstWhere((l) => l.list.kind == ListKind.packing).list.id;
    final items = read('add sunscreen and beach towels to the packing list').items.toList();
    expect([for (final i in items) i.text], ['Sunscreen', 'Beach towels']);
    expect(items.every((i) => i.listId == packing), isTrue);
  });

  test('"remind me to call the dentist tomorrow at 9"', () {
    final r = read('remind me to call the dentist tomorrow at 9').reminders.single;
    expect((r.text, r.date, r.time, r.person), ('Call the dentist', '2026-10-17', '09:00', idOf(den, 'Alex')));
  });

  test('"Permission slips due Monday" is a reminder', () {
    final r = read('Permission slips due Monday').reminders.single;
    expect((r.text, r.date), ('Permission slips due', '2026-10-19'));
  });

  test('"Leo takes out the trash every Thursday night"', () {
    final c = read('Leo takes out the trash every Thursday night').chores.single;
    expect(c.title, 'Take out the trash');
    expect((c.owner as OwnerMember).id, idOf(den, 'Leo'));
    expect(c.rrule, 'FREQ=WEEKLY;BYDAY=TH');
    expect(c.date, '2026-10-22');
    expect(c.icon, 'trash');
  });

  test('"Maya and Leo take turns doing the dishes every night" rotates', () {
    final c = read('Maya and Leo take turns doing the dishes every night').chores.single;
    expect((c.owner as OwnerRotation).ids, [idOf(den, 'Maya'), idOf(den, 'Leo')]);
    expect(c.rrule, 'FREQ=DAILY');
    expect(c.icon, 'dishes');
  });

  test('a typed sentence with two things in it', () {
    final d = read('Picture day Thursday. Buy poster board and glue sticks.');
    expect(d.events.single.title, 'Picture day');
    expect([for (final i in d.items) i.text], ['Poster board', 'Glue sticks']);
  });

  test('"in the sun" isn\'t a Sunday, and words with no day go to unclear', () {
    final wire = readWords('Sit in the sun', context);
    expect(wire['events'], isEmpty);
    expect(wire['unclear'], ['Sit in the sun']);
  });

  test('an email\'s headers aren\'t events, and its sign-off isn\'t a note', () {
    final d = read('From: Ms. Lee\nDate: Oct 15, 2026\nSubject: Field trip\n\n'
        'Our field trip to the Nature Center is Friday, October 30.\nPlease pack a lunch.\nThanks, Ms. Lee');
    final e = d.events.single;
    expect((e.title, e.date, e.allDay), ('Field trip to the Nature Center', '2026-10-30', true));
    expect(e.notes, 'Please pack a lunch');
  });
}
