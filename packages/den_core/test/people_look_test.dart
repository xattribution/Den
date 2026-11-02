import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'support.dart';

Member _member(Map<String, Object?> fields) => Member(Rec(
      type: RecordType.member,
      id: 'm1',
      space: Space.family,
      fields: {'name': 'Leo', 'role': 'kid', ...fields},
      created: const Hlc(1, 0, 'd'),
      updated: const Hlc(1, 0, 'd'),
      createdBy: null,
      updatedBy: null,
    ));

void main() {
  group('family colors', () {
    test('eight, in the order new people get them', () {
      expect(Marker.values.map((m) => m.name),
          ['sky', 'grass', 'lavender', 'tangerine', 'aqua', 'coral', 'sunshine', 'bubblegum']);
    });

    test('the ten older names read as the nearest color', () {
      expect({for (final n in ['blue', 'green', 'plum', 'orange', 'teal', 'pink', 'brown', 'olive', 'sky', 'slate']) n: Marker.parse(n)}, {
        'blue': Marker.sky,
        'green': Marker.grass,
        'plum': Marker.lavender,
        'orange': Marker.tangerine,
        'teal': Marker.aqua,
        'pink': Marker.bubblegum,
        'brown': Marker.coral,
        'olive': Marker.sunshine,
        'sky': Marker.sky,
        'slate': Marker.lavender,
      });
      expect(Marker.parse('mauve'), isNull);
      expect(_member({'marker': 'teal'}).marker, Marker.aqua);
      expect(_member({}).marker, Marker.lavender, reason: 'a member with no color reads as the old default');
    });

    test('a new person gets the first color nobody has, then the least shared', () {
      expect(Marker.next([]), Marker.sky);
      expect(Marker.next([Marker.sky, Marker.grass]), Marker.lavender);
      expect(Marker.next([...Marker.values, Marker.sky]), Marker.grass);
    });

    test('records written with an older name are still accepted, and new ones use the new names', () async {
      final clock = TestClock.at(DateTime.utc(2026, 9, 1, 15));
      final den = await foundFamily(clock);
      final leo = await den.addMember(name: 'Leo', role: Role.kid);
      expect(den.member(leo)!.marker, isNot(den.actor!.marker), reason: 'the next free color');
      await den.updateMember(leo, {'marker': 'olive'});
      expect(den.member(leo)!.marker, Marker.sunshine);
      await den.updateMember(leo, {'marker': Marker.coral});
      expect(den.member(leo)!.rec.fields['marker'], 'coral');
      await expectLater(den.updateMember(leo, {'marker': 'mauve'}), throwsA(isA<InvalidInput>()));
    });
  });

  group('the family\'s color pack', () {
    test('bright until a parent picks another; anything else reads as bright', () {
      expect(ColorPack.values.map((p) => p.name), ['bright', 'deep', 'soft', 'bold']);
      expect(ColorPack.parse('deep'), ColorPack.deep);
      expect(ColorPack.parse('neon'), ColorPack.bright);
      expect(ColorPack.parse(null), ColorPack.bright);
    });

    test('is a family setting: everyone sees it, people keep their colors, and Undo puts it back', () async {
      final clock = TestClock.at(DateTime.utc(2026, 9, 1, 15));
      final den = await foundFamily(clock);
      final leo = await den.addMember(name: 'Leo', role: Role.kid, marker: Marker.bubblegum);
      expect(den.family!.colors, ColorPack.bright);
      final r = await den.recording(() => den.updateFamily({'colors': ColorPack.deep.name}));
      expect(den.family!.colors, ColorPack.deep);
      expect(den.member(leo)!.marker, Marker.bubblegum, reason: 'Leo keeps his place in the pack');
      final tablet = await joinDevice(den, clock, member: leo);
      expect(tablet.family!.colors, ColorPack.deep);
      await expectLater(den.updateFamily({'colors': 'neon'}), throwsA(isA<InvalidInput>()));
      await den.undo(r.changes);
      expect(den.family!.colors, ColorPack.bright);
      expect(den.family!.rec.fields['colors'], 'bright');
    });
  });

  group('pictures', () {
    test('a member has the picture chosen for them', () {
      expect(_member({'picture': 'dinosaur', 'animal': 'cat'}).picture, 'dinosaur');
      expect(_member({'picture': Picture.initial}).picture, Picture.initial);
    });

    test('an older member\'s animal reads as the matching picture', () {
      expect(_member({'animal': 'rabbit'}).picture, 'bunny');
      expect(_member({'animal': 'fish'}).picture, 'whale');
      expect(_member({'animal': 'horse'}).picture, Picture.initial, reason: 'the pack has no horse');
      expect(_member({}).picture, Picture.initial);
      for (final a in Animal.values) {
        expect(Picture.valid(Picture.forAnimal(a)), isTrue, reason: a.name);
      }
    });

    test('pictures are written, changed and checked', () async {
      final clock = TestClock.at(DateTime.utc(2026, 9, 1, 15));
      final den = await foundFamily(clock);
      final leo = await den.addMember(name: 'Leo', role: Role.kid, picture: 'rocket');
      expect(den.member(leo)!.picture, 'rocket');
      await den.updateMember(leo, {'picture': 'fox'});
      expect(den.member(leo)!.picture, 'fox');
      await expectLater(den.updateMember(leo, {'picture': 'Not A Picture!'}), throwsA(isA<InvalidInput>()));
      expect(Picture.valid('photo:abc123'), isTrue, reason: 'room for a photo later');
    });
  });
}
