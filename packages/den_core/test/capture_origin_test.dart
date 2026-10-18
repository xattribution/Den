import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  final clock = TestClock.at(DateTime.utc(2026, 10, 16, 13));
  const photo = CaptureOrigin(CaptureKind.photo, reader: 'Claude');

  test('records added from a capture say what was read, and History shows it', () async {
    final den = await foundFamily(clock);
    final groceries = await den.addList(title: 'Groceries', kind: ListKind.shopping, from: photo);
    await den.addItem(groceries, text: 'Milk', from: const CaptureOrigin(CaptureKind.voice));
    await den.addEvent(title: 'Book fair', start: clock.now, end: clock.now + 3600000, from: photo);
    await den.addChore(
      title: 'Return the permission slip',
      owner: const OwnerAnyone(),
      schedule: const ChoreSchedule.once('2026-10-19'),
      from: const CaptureOrigin(CaptureKind.email, reader: 'On this phone'),
    );

    final history = den.history();
    final byTitle = {for (final e in history) e.title: e};
    expect(byTitle['Book fair']!.from, photo);
    expect(byTitle['Milk']!.from, const CaptureOrigin(CaptureKind.voice));
    expect(byTitle['Return the permission slip']!.from!.reader, 'On this phone');
    expect(byTitle['Groceries']!.from!.kind, CaptureKind.photo);
    expect(byTitle['Book fair']!.diffs.map((d) => d.field), isNot(contains('_from')));
  });

  test('a change made by hand has no source', () async {
    final den = await foundFamily(clock);
    await den.addEvent(title: 'Dentist', start: clock.now, end: clock.now + 3600000);
    expect(den.history().first.from, isNull);
  });

  test('another device accepts the source and shows the same History', () async {
    final den = await foundFamily(clock);
    final tablet = await joinDevice(den, clock, member: den.actor!.id);
    await den.addEvent(title: 'Picture day', start: clock.now, end: clock.now + 3600000, from: photo);
    await sync(den, tablet);
    expect(tablet.events.single.title, 'Picture day');
    expect(tablet.history().firstWhere((e) => e.title == 'Picture day').from, photo);
  });

  test('a source Den doesn\'t know is refused like any other bad field', () {
    expect(checkFields(RecordType.item, {'list': 'L', 'text': 'Milk', '_from': {'kind': 'fax'}}, creating: true),
        contains('Source kind'));
    expect(checkFields(RecordType.item, {'list': 'L', 'text': 'Milk', '_from': 'photo'}, creating: true),
        contains('Source'));
    expect(checkFields(RecordType.item, {'list': 'L', 'text': 'Milk', '_from': photo.toJson()}, creating: true), isNull);
  });

  test('a reader name past the limit is refused', () {
    expect(
      checkFields(RecordType.category, {'name': 'School', '_from': {'kind': 'photo', 'reader': 'x' * 500}}, creating: true),
      contains('too long'),
    );
  });
}
