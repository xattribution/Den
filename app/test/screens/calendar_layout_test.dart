import 'package:den_app/screens/calendar/day_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, (int, int, int)> place(List<(String, int, int)> items) {
    final placed = layoutDay([for (final (name, start, end) in items) DaySlot(name, start, end)]);
    return {for (final s in placed) s.item: (s.lane, s.lanes, s.span)};
  }

  test('events that do not overlap take the full width', () {
    expect(place([('a', 540, 600), ('b', 600, 660)]), {'a': (0, 1, 1), 'b': (0, 1, 1)});
  });

  test('two overlapping events split the column', () {
    expect(place([('a', 540, 660), ('b', 600, 720)]), {'a': (0, 2, 1), 'b': (1, 2, 1)});
  });

  test('a chain of overlaps shares lanes, and a free lane is reused', () {
    // a 9-11, b 10-12, c 11-13: c reuses a's lane.
    expect(place([('a', 540, 660), ('b', 600, 720), ('c', 660, 780)]), {
      'a': (0, 2, 1),
      'b': (1, 2, 1),
      'c': (0, 2, 1),
    });
  });

  test('an item widens into lanes nobody beside it uses', () {
    // a 9-12 spans the morning; b 9-10 and c 9-10 sit beside it; d 10:30-11 has lanes 1 and 2
    // free next to it.
    final placed = place([('a', 540, 720), ('b', 540, 600), ('c', 540, 600), ('d', 630, 660)]);
    expect(placed['a'], (0, 3, 1));
    expect(placed['b'], (1, 3, 1));
    expect(placed['c'], (2, 3, 1));
    expect(placed['d'], (1, 3, 2));
  });

  test('very short events still get room for a label', () {
    // Two 5-minute events 10 minutes apart overlap visually with a 20-minute minimum.
    expect(place([('a', 600, 605), ('b', 610, 615)]), {'a': (0, 2, 1), 'b': (1, 2, 1)});
  });
}
