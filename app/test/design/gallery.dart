/// The design gallery: the foundation drawn the way the approved canvas draws it, so golden
/// screenshots can be checked against the canvas side by side (gallery_test.dart). Everything
/// here uses only the tokens, the theme, the motion widgets, the picture pack and the shared
/// pieces in design/widgets.
library;

import 'dart:math' as math;

import 'package:den_app/design/layout.dart';
import 'package:den_app/design/motion.dart';
import 'package:den_app/design/pictures.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/design/widgets.dart';
import 'package:den_app/design/words.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

/// The canvas's family.
class Person {
  const Person(this.name, this.color);

  final String name;
  final PersonColor color;
}

const mom = Person('Mom', PersonColor.aqua);
const dad = Person('Dad', PersonColor.sky);
const mia = Person('Mia', PersonColor.bubblegum);
const leo = Person('Leo', PersonColor.grass);

Widget face(Person p, double size) =>
    Builder(builder: (context) => DenAvatar.initial(p.name, color: context.colors.marker(p.color.marker), size: size, semanticLabel: p.name));

/// Today, as Main.dc.html draws its top: the greeting, Needs you, today's events, chores and
/// the grocery bar, over the tab bar. Built from the shared pieces in design/widgets, the same
/// ones the app's screens use.
class TodaySample extends StatelessWidget {
  const TodaySample({super.key, this.tabBar = true});

  final bool tabBar;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final page = SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 24, DenLayout.gutter, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(overline: keepUnits('Wednesday, October 28'), title: 'Good morning', trailing: face(mom, 44)),
          const SizedBox(height: DenLayout.sectionGap),
          const NeedsYouSample(),
          const SizedBox(height: DenLayout.sectionGap),
          const EventsSample(),
          const SizedBox(height: DenLayout.sectionGap),
          const ChoresSample(),
          const SizedBox(height: DenLayout.sectionGap),
          const GrocerySample(),
        ],
      ),
    );
    if (!tabBar) return ColoredBox(color: c.bg, child: page);
    return ColoredBox(
      color: c.bg,
      child: Column(children: [Expanded(child: page), const TabBarSample()]),
    );
  }
}

class NeedsYouSample extends StatelessWidget {
  const NeedsYouSample({super.key});

  @override
  Widget build(BuildContext context) => DenSection(
        title: 'Needs you',
        trailing: const SectionCount('2 things'),
        child: Column(
          children: ruled([
            ActionRow(
              leading: face(leo, 40),
              title: 'Nobody is driving Leo',
              detail: 'Soccer, 3:30 PM at Field 4',
              action: FilledButton(onPressed: () {}, child: const Text('I’ll drive')),
            ),
            ActionRow(
              leading: face(mia, 40),
              title: 'Mia wants movie night',
              detail: 'Costs 40 stars, she has 52',
              action: FilledButton(onPressed: () {}, child: const Text('Approve')),
            ),
          ], indent: RowRule.afterFace),
        ),
      );
}

class EventsSample extends StatelessWidget {
  const EventsSample({super.key});

  @override
  Widget build(BuildContext context) => DenSection(
        title: 'Today',
        trailing: SectionLink('Week', onTap: () {}),
        child: Column(
          children: ruled(const [
            _EventRow(time: '7:30 AM', title: 'School drop-off', who: 'Dad', people: [dad]),
            _EventRow(time: '9:00 AM', title: 'Dentist', who: 'Mia and Mom', people: [mia, mom]),
            _EventRow(time: '3:30 PM', title: 'Soccer at Field 4', who: 'Leo, nobody driving yet', people: [leo]),
            _EventRow(time: '6:00 PM', title: 'Dinner at Grandma’s', who: 'Everyone', people: [mom, dad, mia, leo]),
          ]),
        ),
      );
}

/// The canvas's event row, from plain words (the app's EventLine reads an occurrence).
class _EventRow extends StatelessWidget {
  const _EventRow({required this.time, required this.title, required this.who, required this.people});

  final String time;
  final String title;
  final String who;
  final List<Person> people;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final scaler = MediaQuery.textScalerOf(context);
    final timeText = Text(keepUnits(time), style: t.meta(c.ink2), softWrap: false);
    final words = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tidy(title), style: t.rowTitle(c.ink)),
        const SizedBox(height: 2),
        Text(tidy(who), style: t.meta(c.ink2)),
      ],
    );
    // Past 135 % text the time goes above the title instead of squeezing it.
    final stacked = scaler.scale(1) > 1.35;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        crossAxisAlignment: stacked ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          if (stacked)
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [timeText, const SizedBox(height: 2), words],
              ),
            )
          else ...[
            SizedBox(width: scaler.scale(68), child: timeText),
            const SizedBox(width: 12),
            Expanded(child: words),
          ],
          const SizedBox(width: 8),
          FaceStack(faces: [for (final p in people) face(p, 26)]),
        ],
      ),
    );
  }
}

class ChoresSample extends StatelessWidget {
  const ChoresSample({super.key});

  @override
  Widget build(BuildContext context) => DenSection(
        title: 'Chores',
        trailing: const SectionCount('2 of 5 done'),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: ruled(const [
              _KidChores(person: mia, chores: [('Dishes', 2, false), ('Feed the cat', 1, true)]),
              _KidChores(person: leo, chores: [('Make bed', 1, true), ('Trash out', 1, false), ('Read 20 min', 2, false)]),
            ]),
          ),
        ),
      );
}

class _KidChores extends StatelessWidget {
  const _KidChores({required this.person, required this.chores});

  final Person person;
  final List<(String, int, bool)> chores;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(top: 2), child: face(person, 40)),
            const SizedBox(width: 12),
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (title, stars, done) in chores)
                    CheckPill(label: title, stars: stars, done: done, color: context.colors.marker(person.color.marker), onCheck: () {}, onOpen: () {}),
                ],
              ),
            ),
          ],
        ),
      );
}

class GrocerySample extends StatelessWidget {
  const GrocerySample({super.key});

  @override
  Widget build(BuildContext context) => DenSection(
        title: 'Groceries',
        trailing: SectionLink('14 items', onTap: () {}),
        carded: false,
        child: InlineAdd(hint: 'Add to groceries', onAdd: (_) async => true),
      );
}

/// The phone tab bar: five places, Add in the middle.
class TabBarSample extends StatelessWidget {
  const TabBarSample({super.key});

  @override
  Widget build(BuildContext context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(padding: const EdgeInsets.only(bottom: 28)),
        child: DenTabBar(
          onAdd: () {},
          places: [
            NavPlace(label: 'Today', icon: PhosphorIconsRegular.house, selectedIcon: PhosphorIconsBold.house, selected: true, onTap: () {}),
            NavPlace(label: 'Calendar', icon: PhosphorIconsRegular.calendarBlank, selectedIcon: PhosphorIconsBold.calendarBlank, onTap: () {}),
            NavPlace(label: 'Chores', icon: PhosphorIconsRegular.checkCircle, selectedIcon: PhosphorIconsBold.checkCircle, onTap: () {}),
            NavPlace(label: 'Lists', icon: PhosphorIconsRegular.listBullets, selectedIcon: PhosphorIconsBold.listBullets, onTap: () {}),
          ],
        ),
      );
}

/// The type ramp, buttons, chips, fields and switches, each with its spec.
class ControlsSample extends StatelessWidget {
  const ControlsSample({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    Widget spec(String name, Widget sample) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: t.caption(c.ink2)),
              const SizedBox(height: 2),
              sample,
            ],
          ),
        );
    return ColoredBox(
      color: c.bg,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 24, DenLayout.gutter, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DenSection(
              title: 'Type',
              child: Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    spec('Screen title, 30, 800', Text('Good morning', style: t.screenTitle(c.ink))),
                    spec('Sheet title, 26, 800', Text('Mia’s picture', style: t.sheetTitle(c.ink))),
                    spec('Section, 20, 700', Text('Needs you', style: t.section(c.ink))),
                    spec('Row title, 17, 700', Text('Nobody is driving Leo', style: t.rowTitle(c.ink))),
                    spec(
                      'Body, 17, 400',
                      Text(tidy('Soccer moved to Field 4. Bring water and the blue shin guards.'), style: t.body(c.ink)),
                    ),
                    spec('Meta, 15, 400', Text(tidy('Soccer, 3:30 PM at Field 4'), style: t.meta(c.ink2))),
                    spec('Label, 16, 700', Text('I’ll drive', style: t.label(c.ink))),
                    spec('Caption, 13, 400', Text('Sunflower', style: t.caption(c.ink2))),
                    spec(
                      'Display, 44, 700',
                      Row(
                        children: [
                          Text('52', style: t.display(c.ink)),
                          const SizedBox(width: 8),
                          const Star(size: 32),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: DenLayout.sectionGap),
            DenSection(
              title: 'Buttons',
              carded: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton(onPressed: () {}, child: const Text('I’ll drive')),
                      OutlinedButton(onPressed: () {}, child: const Text('Today')),
                      UndoButton(onTap: () {}),
                      const FilledButton(onPressed: null, child: Text('Add')),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      RoundButton(icon: PhosphorIconsBold.plus, label: 'Add', onTap: () {}),
                      RoundButton(
                        icon: PhosphorIconsBold.dotsThree,
                        label: 'More',
                        onTap: () {},
                        fill: c.card,
                        color: c.ink,
                        size: Targets.adult,
                      ),
                      TextButton.icon(
                        onPressed: () {},
                        style: TextButton.styleFrom(foregroundColor: c.destructive),
                        icon: const Icon(PhosphorIconsBold.trash, size: 20),
                        label: const Text('Remove Leo'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: DenLayout.sectionGap),
            DenSection(
              title: 'Chips',
              carded: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      TagChip(label: 'Animals', selected: true, onTap: () {}),
                      TagChip(label: 'Critters', selected: false, onTap: () {}),
                      TagChip(label: 'Snacks', selected: false, onTap: () {}),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (p, chosen) in [(mia, true), (leo, false), (dad, false)])
                        PersonPill(face: face(p, 32), name: p.name, selected: chosen, onTap: () {}),
                    ],
                  ),
                  const SizedBox(height: 10),
                  GroupCard(
                    padding: const EdgeInsets.all(12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        CheckPill(label: 'Dishes', stars: 2, done: false, color: context.colors.marker(mia.color.marker), onCheck: () {}),
                        CheckPill(label: 'Feed the cat', stars: 1, done: true, color: context.colors.marker(mia.color.marker), onCheck: () {}),
                        CheckPill(label: 'Tidy room', steps: (1, 4), done: false, color: context.colors.marker(leo.color.marker), onOpen: () {}),
                        CheckPill(label: 'Dishes', steps: (0, 3), done: false, color: context.colors.marker(leo.color.marker), onOpen: () {}),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: DenLayout.sectionGap),
            DenSection(
              title: 'Fields and switches',
              carded: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const TextField(decoration: InputDecoration(hintText: 'Add to groceries')),
                  const SizedBox(height: 10),
                  GroupCard(
                    child: Column(
                      children: ruled(const [
                        _SwitchRow(label: 'Leo can add events', value: true),
                        _SwitchRow(label: 'Mia asks before adding', value: false),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: DenSegmented<int>(options: const {0: 'Week', 1: 'Day'}, value: 0, onChanged: (_) {}),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.label, required this.value});

  final String label;
  final bool value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 64),
      child: Row(
        children: [
          Expanded(child: Text(label, style: context.text.rowTitle(c.ink))),
          Switch(value: value, onChanged: (_) {}),
        ],
      ),
    );
  }
}

/// Palette.dc.html: the eight family colors of the family's pack (the theme's), by day and at
/// night, with what was measured: the dark text's contrast on the palest-for-it color.
class PaletteSample extends StatelessWidget {
  const PaletteSample({super.key});

  static String hex(Color color) =>
      '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  /// WCAG contrast of [a] on [b].
  static double contrast(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  static String _about(ColorPack pack) => switch (pack) {
        ColorPack.bright => 'Eight bright, happy colors, one for each person.',
        ColorPack.deep => 'Deeper and richer, as dark as dark text allows, with a clear gold.',
        ColorPack.soft => 'Light and cheerful sorbet shades that keep their color: never cream or a wash.',
        ColorPack.bold => 'The crayon box: each color as strong as the screen draws it.',
      };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final pack = c.pack;
    final worst = pack.colors.map((p) => contrast(c.onMarker, p.color)).reduce(math.min);
    return ColoredBox(
      color: c.bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(40, 36, 40, 36),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Family colors: ${pack.label}', style: t.screenTitle(c.ink)),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Text(
                tidy('${_about(pack)} The same color in the light and the black theme, with dark text on every '
                    'one. Everyone keeps their place when the family changes packs.'),
                style: t.meta(c.ink2),
              ),
            ),
            const SizedBox(height: 20),
            LayoutBuilder(
              builder: (context, constraints) {
                final width = (constraints.maxWidth - 12 * 3) / 4;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final p in pack.colors)
                      SizedBox(
                        width: width,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(Radii.block),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ColoredBox(
                                color: p.color,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(p.label, style: t.section(c.onMarker)),
                                      const SizedBox(height: 28),
                                      Text(hex(p.color), style: t.caption(c.onMarker)),
                                    ],
                                  ),
                                ),
                              ),
                              ColoredBox(
                                color: DenColors.night.bg,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                                  child: Row(
                                    children: [
                                      DenAvatar.initial(p.label, color: p.color, size: 36),
                                      const SizedBox(width: 10),
                                      Text('at night', style: t.meta(DenColors.night.ink)),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 20),
            Text(
              tidy('Checked, not guessed: dark text reads at ${((worst * 10).floor() / 10).toStringAsFixed(1)}:1 or '
                  'better on every color, and in this order every pair of neighbors stays clearly different, '
                  'including for color-blind eyes.'),
              style: t.meta(c.ink2),
            ),
            const SizedBox(height: 6),
            Text(
              tidy('Color is never the only clue: every person also has their picture or initial and their name.'),
              style: t.meta(c.ink2),
            ),
          ],
        ),
      ),
    );
  }
}

/// AvatarPack.dc.html: all 64 pictures, by group, each in a ring of the next family color.
class PackSample extends StatelessWidget {
  const PackSample({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    Widget labeled(Widget avatar, String label) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            avatar,
            const SizedBox(height: 6),
            Text(label, style: t.meta(c.ink2), maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis),
          ],
        );
    return ColoredBox(
      color: c.bg,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(48, 40, 48, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Pictures for everyone, 64 to start', style: t.screenTitle(c.ink, large: true)),
                      const SizedBox(height: 4),
                      Text(
                        'A photo, their initial, or one of these. The ring is always their color.',
                        style: t.body(c.ink2),
                      ),
                    ],
                  ),
                ),
                labeled(DenAvatar.photo(null, color: c.marker(Marker.sky), size: 64), 'Photo'),
                const SizedBox(width: 16),
                labeled(DenAvatar.initial('M', color: c.marker(Marker.aqua), size: 64), 'Initial'),
              ],
            ),
            for (final g in DenPictures.groups) ...[
              const SizedBox(height: 22),
              GroupCard(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(g.name, style: t.section(c.ink)),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        for (final (i, p) in g.pictures.indexed)
                          Expanded(
                            child: labeled(
                              DenAvatar.picture(p.id, color: c.marker(Marker.values[i % 8]), size: 76),
                              p.name,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// AvatarPicker.dc.html: "Mia's picture", the sheet a parent picks a picture and color in.
class PickerSheet extends StatelessWidget {
  const PickerSheet({super.key});

  static const _chosen = 'fox';
  static const _color = Marker.bubblegum;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    Widget tile(Widget icon, String label, {bool selected = false}) => DecoratedBox(
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(Radii.tile),
            border: Border.all(color: selected ? c.ink : c.line, width: 1.5),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                icon,
                const SizedBox(height: 4),
                Text(label, style: t.caption(c.ink).bold),
              ],
            ),
          ),
        );
    final group = DenPictures.groups.first;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('Mia’s picture', style: t.sheetTitle(c.ink))),
              FilledButton(onPressed: () {}, child: const Text('Done')),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              DenAvatar.picture(_chosen, color: c.marker(_color), size: 96, semanticLabel: 'Mia'),
              const SizedBox(width: 16),
              Expanded(
                child: Row(
                  children: [
                    Expanded(child: tile(Icon(PhosphorIconsRegular.camera, size: 22, color: c.ink), 'Camera')),
                    const SizedBox(width: 8),
                    Expanded(child: tile(Icon(PhosphorIconsRegular.image, size: 22, color: c.ink), 'Photos')),
                    const SizedBox(width: 8),
                    Expanded(child: tile(Text('M', style: t.section(c.ink)), 'Initial')),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text('Her color', style: t.meta(c.ink2)),
          const SizedBox(height: 8),
          Wrap(
            children: [
              for (final m in Marker.values) _Swatch(color: c.pack.of(m), selected: m == _color),
            ],
          ),
          const SizedBox(height: 16),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            child: Row(
              children: [
                for (final (i, g) in DenPictures.groups.indexed) ...[
                  if (i > 0) const SizedBox(width: 8),
                  TagChip(label: g.name, selected: i == 0, onTap: () {}),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          for (final row in [group.pictures.sublist(0, 4), group.pictures.sublist(4)]) ...[
            Row(
              children: [
                for (final p in row)
                  Expanded(child: _PickerItem(picture: p, color: c.marker(_color), selected: p.id == _chosen)),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

/// A color to pick: the chosen one has an ink ring with a gap.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.selected});

  final PackColor color;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DenPressable(
      onTap: () {},
      selected: selected,
      semanticLabel: color.label,
      shape: const CircleBorder(),
      child: SizedBox.square(
        dimension: Targets.adult,
        child: Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: selected ? c.ink : const Color(0x00000000), width: 2),
            ),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: DecoratedBox(
                decoration: BoxDecoration(shape: BoxShape.circle, color: color.color),
                child: const SizedBox.square(dimension: 30),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PickerItem extends StatelessWidget {
  const _PickerItem({required this.picture, required this.color, required this.selected});

  final DenPicture picture;
  final Color color;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return DenPressable(
      onTap: () {},
      selected: selected,
      semanticLabel: picture.name,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.tile),
        side: selected ? BorderSide(color: c.ink, width: 2) : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          children: [
            DenAvatar.picture(picture.id, color: color, size: 64),
            const SizedBox(height: 6),
            Text(
              picture.label,
              style: selected ? t.caption(c.ink).bold : t.caption(c.ink2),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
