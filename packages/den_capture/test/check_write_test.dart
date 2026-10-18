import 'package:den_capture/den_capture.dart';
import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'support.dart';

const email = CaptureOrigin(CaptureKind.email, reader: 'Claude');

void main() {
  CaptureDraft draftOf(Den den, Map<String, Object?> wire) => draftFor(den, {...empty, ...wire}, email);

  Map<String, Object?> event(Map<String, Object?> f) => {
        'title': 'Book fair',
        'date': '2026-11-02',
        'start': null,
        'end': null,
        'endDate': null,
        'repeat': null,
        'people': <String>[],
        'location': null,
        'notes': null,
        'kind': null,
        'remindBefore': <int>[],
        ...f,
      };

  group('Checking before anything is written', () {
    test('what\'s already on the calendar or the list, or listed twice, waits for a look', () async {
      final den = await demo();
      final soccer = den.events.firstWhere((e) => e.title == 'Soccer practice');
      final next = den.occurrences(den.now(), den.now() + 7 * 86400000).firstWhere((o) => o.event.id == soccer.id);
      final d = draftOf(den, {
        'events': [
          event({'title': 'soccer practice', 'date': den.dateOf(next.start), 'start': '17:00', 'end': '18:30'}),
          event({}),
          event({}),
        ],
        'items': [
          {'text': 'eggs', 'qty': null, 'store': null, 'list': null},
          {'text': 'Glue sticks', 'qty': null, 'store': null, 'list': 'Science fair supplies'},
        ],
      });
      final entries = d.entries.toList();
      expect(entries[0].issues.map((i) => i.message), ['Already on the calendar']);
      expect(entries[1].issues, isEmpty);
      expect(entries[2].issues.map((i) => i.message), ['Listed twice']);
      expect(entries[3].issues.map((i) => i.message), ['Already on Groceries']);
      expect(entries[4].issues, isEmpty, reason: 'Glue sticks there are checked off');
      await den.close();
    });

    test('a kid without the grant can\'t add events, and a shared screen with nobody signed in can\'t add anything', () async {
      final phone = await demo();
      final display = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: () => demoNow.millisecondsSinceEpoch);
      await display.requestJoin(
        familyId: phone.familyId!,
        founderPubkey: phone.founderPubkey!,
        deviceName: 'Hall tablet',
        kind: DeviceKind.display,
        mode: DeviceMode.shared,
      );
      await phone.ingest(display.changesSince(phone.versionVector));
      await phone.approveDevice(display.deviceId, mode: DeviceMode.shared);
      await display.ingest(phone.changesSince(display.versionVector, spaces: phone.spacesForDevice(display.deviceId)));

      expect(draftOf(display, {'events': [event({})]}).events.single.issues.single.message, 'Sign in on this screen to add things');
      display.actAs(idOf(display, 'Leo'));
      final leo = draftOf(display, {
        'events': [event({})],
        'items': [{'text': 'Cocoa', 'qty': null, 'store': null, 'list': null}],
      });
      expect(leo.events.single.issues.single.message, 'Leo can\'t add events');
      expect(leo.items.single.issues.single.message, 'Leo can\'t add to lists');
      expect(leo.entries.every((e) => e.blocked), isTrue);
      display.actAs(idOf(display, 'Maya'));
      expect(draftOf(display, {'events': [event({})]}).events.single.issues, isEmpty, reason: 'Maya has the events grant');
      await display.close();
      await phone.close();
    });

    test('fields are held to den_core\'s schema: an event for someone no longer in the family is refused', () async {
      final den = await demo();
      final wire = {...empty, 'events': [event({'people': ['Leo']})]};
      final context = CaptureContext.of(den);
      final draft = draftFrom(wire, context, origin: email);
      await den.removeMember(idOf(den, 'Leo'));
      final checked = checkDraft(den, draft);
      expect(checked.events.single.issues.single.kind, IssueKind.invalid);
      expect(checked.events.single.blocked, isTrue);
      await den.close();
    });

    test('things already over wait for a look', () async {
      final den = await demo();
      final d = draftOf(den, {
        'events': [event({'date': '2026-10-01'})],
        'reminders': [{'text': 'Return library books', 'date': '2026-10-02', 'time': null, 'people': <String>[]}],
      });
      expect(d.entries.map((e) => e.issues.single.kind), [IssueKind.past, IssueKind.past]);
      await den.close();
    });

    test('checking again after an edit keeps resolution\'s notes and refreshes the rest', () async {
      final den = await demo();
      final d = draftOf(den, {'events': [event({'people': ['Coach Dan'], 'date': '2026-10-01'})]});
      expect(d.events.single.issues.map((i) => i.kind), [IssueKind.unknownPerson, IssueKind.past]);
      final edited = d.replace(d.events.single.copyWith(date: '2026-11-03'));
      expect(checkDraft(den, edited).events.single.issues.map((i) => i.kind), [IssueKind.unknownPerson]);
      await den.close();
    });
  });

  group('Writing', () {
    test('adds what was chosen through the engine as the acting member, marked with where it came from', () async {
      final den = await demo();
      final d = draftOf(den, {
        'events': [
          event({'title': 'Field trip', 'date': '2026-10-30', 'people': ['Maya'], 'kind': 'school'}),
          event({'title': 'Swim meet', 'date': '2026-10-25', 'start': '08:00', 'end': '11:00', 'location': 'YMCA pool'}),
        ],
        'chores': [
          {'title': 'Pack swim bag', 'people': ['Zoe'], 'takeTurns': false, 'date': '2026-10-24', 'repeat': null, 'due': '20:00', 'points': 1},
        ],
        'items': [
          {'text': 'Goggles', 'qty': '2', 'store': 'Target', 'list': null},
          {'text': 'Tent', 'qty': null, 'store': null, 'list': 'Camping trip'},
          {'text': 'Lantern', 'qty': null, 'store': null, 'list': 'Camping trip'},
        ],
        'reminders': [{'text': 'Sign the field trip form', 'date': '2026-10-21', 'time': '19:00', 'people': <String>[]}],
      });
      final receipt = await writeDraft(den, d);
      expect(receipt.failed, isEmpty);
      expect(receipt.keys, {'e0', 'e1', 'c0', 'i0', 'i1', 'i2', 'r0'});
      expect(receipt.added.where((a) => a.type == RecordType.list).single.title, 'Camping trip');

      final trip = den.events.firstWhere((e) => e.title == 'Field trip');
      expect((trip.allDay, den.dateOf(trip.start)), (true, '2026-10-30'));
      expect(trip.assignees, [idOf(den, 'Maya')]);
      final swim = den.events.firstWhere((e) => e.title == 'Swim meet');
      expect((den.dateOf(swim.start), swim.end - swim.start, swim.location), ('2026-10-25', 3 * 3600000, 'YMCA pool'));
      final camping = den.lists.firstWhere((l) => l.list.title == 'Camping trip');
      expect([for (final i in camping.items) i.text], ['Tent', 'Lantern']);
      expect(camping.list.kind, ListKind.packing);
      final remind = den.chores.firstWhere((c) => c.title == 'Sign the field trip form');
      expect((remind.schedule.once, remind.dueTime, (remind.owner as OwnerMember).id), ('2026-10-21', '19:00', idOf(den, 'Alex')));
      expect(remind.reminders, [0]);

      final history = den.history(limit: 20);
      final added = history.where((h) => h.from != null).toList();
      expect(added, hasLength(8));
      expect(added.every((h) => h.from == email && h.actor == idOf(den, 'Alex')), isTrue);
      await den.close();
    });

    test('by default writes only what needs no look; chosen keys write exactly those', () async {
      final den = await demo();
      final d = draftOf(den, {
        'events': [event({}), event({'title': 'Mystery', 'people': ['Coach Dan']}), event({'title': 'Undated', 'date': null})],
      });
      final direct = await writeDraft(den, d);
      expect(direct.keys, {'e0'});
      final chosen = await writeDraft(den, d, keys: ['e1', 'e2']);
      expect(chosen.keys, {'e1'});
      expect(chosen.failed, {'e2': 'Den couldn\'t tell which day'});
      await den.close();
    });

    test('undo takes back everything one capture added', () async {
      final den = await demo();
      final before = (den.events.length, den.lists.length, den.chores.length);
      final receipt = await writeDraft(
        den,
        draftOf(den, {
          'events': [event({})],
          'items': [{'text': 'Tent', 'qty': null, 'store': null, 'list': 'Camping trip'}],
          'reminders': [{'text': 'Order the books', 'date': '2026-10-20', 'time': null, 'people': <String>[]}],
        }),
      );
      expect(receipt.added, hasLength(4));
      await receipt.undo(den);
      expect((den.events.length, den.lists.length, den.chores.length), before);
      await den.close();
    });
  });
}
