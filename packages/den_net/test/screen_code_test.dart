import 'package:den_net/den_net.dart';
import 'package:test/test.dart';

void main() {
  group('ScreenCode', () {
    test('a new code is eight characters of the alphabet, and different each time', () {
      final codes = {for (var i = 0; i < 200; i++) ScreenCode.generate()};
      expect(codes.length, greaterThan(195));
      for (final c in codes) {
        expect(c, hasLength(ScreenCode.length));
        expect(c.split('').every(ScreenCode.alphabet.contains), isTrue, reason: c);
      }
    });

    test('typed codes ignore case, spaces and dashes, and read O, I and L as digits', () {
      expect(ScreenCode.normalize('K7QM-3RXA'), 'K7QM3RXA');
      expect(ScreenCode.normalize(' k7qm 3rxa '), 'K7QM3RXA');
      expect(ScreenCode.normalize('k7qm–3rxa'), 'K7QM3RXA');
      expect(ScreenCode.normalize('O1IL-ABCD'), '0111ABCD');
      expect(ScreenCode.normalize('K7QM-3RX'), isNull, reason: 'too short');
      expect(ScreenCode.normalize('K7QM-3RXAB'), isNull, reason: 'too long');
      expect(ScreenCode.normalize('K7QM-3RXU'), isNull, reason: 'U is never in a code');
      expect(ScreenCode.normalize('K7QM!3RXA'), isNull);
    });

    test('a code reads in two groups', () {
      expect(ScreenCode.format('k7qm3rxa'), 'K7QM-3RXA');
    });

    test('the QR code holds the code for Den\'s own scanner, never a link', () {
      expect(ScreenCode.qr('k7qm-3rxa'), 'den://screen/K7QM3RXA');
      expect(ScreenCode.fromText('den://screen/K7QM3RXA'), 'K7QM3RXA');
      expect(ScreenCode.fromText('k7qm-3rxa'), 'K7QM3RXA');
      expect(ScreenCode.fromText('https://den.example.com/#/add-screen/K7QM3RXA'), isNull);
    });

    test("the family's address is written the same however it came", () {
      const want = 'https://den.example.com';
      for (final a in ['https://Den.Example.com/', 'https://den.example.com:443/#/welcome', 'wss://den.example.com/ws']) {
        expect(ScreenCode.origin(Uri.parse(a)), want, reason: a);
      }
      expect(ScreenCode.origin(Uri.parse('http://192.168.1.20:47733/ws')), 'http://192.168.1.20:47733');
      expect(ScreenCode.origin(Uri.parse('ws://192.168.1.20:47733/ws')), 'http://192.168.1.20:47733');
    });

    test('the same code at another address stretches to another slot', () async {
      final here = await ScreenCode.derive('K7QM-3RXA', at: Uri.parse('https://den.example.com'));
      final there = await ScreenCode.derive('K7QM-3RXA', at: Uri.parse('https://other.example.com'));
      expect(here.slot, isNot(there.slot));
    });

    test('both ends derive the same slot and tags, and a tag covers the key it names', () async {
      final at = Uri.parse('https://den.example.com');
      final a = await ScreenCode.derive('K7QM-3RXA', at: at);
      final b = await ScreenCode.derive('k7qm3rxa', at: Uri.parse('wss://DEN.example.com/ws'));
      expect(a.slot, b.slot);
      expect(ScreenCode.isSlot(a.slot), isTrue);
      final other = await ScreenCode.derive('K7QM-3RXB', at: at);
      expect(other.slot, isNot(a.slot));

      final tag = await a.screenTag(pubkey: 'key-1', xpub: 'x-1', name: 'Kitchen iPad', kind: 'tablet');
      expect(ScreenCodeKeys.same(tag, await b.screenTag(pubkey: 'key-1', xpub: 'x-1', name: 'Kitchen iPad', kind: 'tablet')), isTrue);
      expect(ScreenCodeKeys.same(tag, await b.screenTag(pubkey: 'key-2', xpub: 'x-1', name: 'Kitchen iPad', kind: 'tablet')), isFalse,
          reason: 'another key gets another tag');
      expect(ScreenCodeKeys.same(tag, await other.screenTag(pubkey: 'key-1', xpub: 'x-1', name: 'Kitchen iPad', kind: 'tablet')), isFalse,
          reason: 'another code gets another tag');

      final family = await a.familyTag(family: 'F', founder: 'K', hub: 'H', pubkey: 'key-1', name: 'Kitchen iPad');
      expect(family, isNot(tag));
      expect(ScreenCodeKeys.same(family, await b.familyTag(family: 'F', founder: 'K', hub: 'H', pubkey: 'key-1', name: 'Kitchen')),
          isFalse);
      expect(ScreenCodeKeys.same('not base64!', family), isFalse);
    });
  });
}
