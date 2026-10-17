import 'dart:math';

import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

void main() {
  group('Hlc', () {
    test('orders by millis, then counter, then device', () {
      expect(const Hlc(1, 9, 'z') < const Hlc(2, 0, 'a'), isTrue);
      expect(const Hlc(5, 1, 'z') < const Hlc(5, 2, 'a'), isTrue);
      expect(const Hlc(5, 2, 'a') < const Hlc(5, 2, 'b'), isTrue);
      expect(const Hlc(5, 2, 'a') == const Hlc(5, 2, 'a'), isTrue);
      expect(const Hlc(5, 2, 'a') > const Hlc(5, 1, 'b'), isTrue);
    });

    test('the string form sorts the same way and round-trips', () {
      final random = Random(7);
      final stamps = [
        for (var i = 0; i < 300; i++)
          Hlc(random.nextInt(1 << 31) * 997, random.nextInt(0x10000), ['abc', 'abd', 'zz', 'a'][random.nextInt(4)]),
      ];
      final byValue = [...stamps]..sort();
      final byText = [...stamps]..sort((a, b) => a.toString().compareTo(b.toString()));
      expect(byText, byValue);
      for (final s in stamps) {
        expect(Hlc.parse(s.toString()), s);
      }
    });

    test('rejects malformed text', () {
      expect(() => Hlc.parse('123-0000-dev'), throwsFormatException);
      expect(() => Hlc.parse('nonsense'), throwsFormatException);
    });
  });

  group('HlcClock', () {
    test('never runs backwards when the wall clock stalls or jumps back', () {
      var wall = 1000;
      final clock = HlcClock('dev', now: () => wall);
      final a = clock.next();
      final b = clock.next();
      wall = 500;
      final c = clock.next();
      wall = 2000;
      final d = clock.next();
      expect([a, b, c, d], [a, b, c, d]..sort());
      expect(b.counter, 1);
      expect(c.millis, 1000);
      expect(d, const Hlc(2000, 0, 'dev'));
    });

    test('moves past timestamps it observes', () {
      final clock = HlcClock('mine', now: () => 1000);
      clock.observe(const Hlc(5000, 3, 'theirs'));
      final next = clock.next();
      expect(next > const Hlc(5000, 3, 'theirs'), isTrue);
      expect(next.millis, 5000);
      expect(next.counter, 4);
    });

    test('rolls to the next millisecond instead of overflowing the counter', () {
      final clock = HlcClock('dev', now: () => 1000);
      clock.observe(const Hlc(1000, HlcClock.maxCounter, 'other'));
      final next = clock.next();
      expect(next, const Hlc(1001, 0, 'dev'));
      expect(Hlc.parse(next.toString()), next);
    });
  });
}
