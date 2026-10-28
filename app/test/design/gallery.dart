/// The design gallery: the foundation drawn the way the approved canvas draws it, so golden
/// screenshots can be checked against the canvas side by side (gallery_test.dart). Everything
/// here uses only the tokens, the theme, the motion widgets and the picture pack.
library;

import 'package:den_app/design/avatar.dart';
import 'package:den_app/design/layout.dart';
import 'package:den_app/design/motion.dart';
import 'package:den_app/design/pictures.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/design/widgets.dart' show Star;
import 'package:den_app/design/words.dart';
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
    DenAvatar.initial(p.name, color: p.color.color, size: size, semanticLabel: p.name);

/// A section: its heading, with a count or a quiet action on the right, over one grouped card.
class Section extends StatelessWidget {
  const Section({super.key, required this.title, this.trailing, required this.child, this.carded = true});

  final String title;
  final Widget? trailing;
  final Widget child;
  final bool carded;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(child: Semantics(header: true, child: Text(title, style: context.text.section(c.ink)))),
              ?trailing,
            ],
          ),
        ),
        const SizedBox(height: DenLayout.headingGap),
        if (carded) GroupCard(child: child) else child,
      ],
    );
  }
}

/// One grouped section's card: the card color, 20 corners, no border, no shadow.
class GroupCard extends StatelessWidget {
  const GroupCard({super.key, required this.child, this.padding = const EdgeInsets.symmetric(horizontal: 16)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(color: context.colors.card, borderRadius: BorderRadius.circular(Radii.section)),
        child: Padding(padding: padding, child: child),
      );
}

/// A divider inside a section, inset to the text.
class Rule extends StatelessWidget {
  const Rule({super.key, this.indent = 0});

  final double indent;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(left: indent),
        child: SizedBox(height: 1, child: ColoredBox(color: context.colors.line)),
      );
}

/// Today, as Main.dc.html draws its top: the greeting, Needs you, today's events, chores and
/// the grocery bar, over the tab bar.
class TodaySample extends StatelessWidget {
  const TodaySample({super.key, this.tabBar = true});

  final bool tabBar;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final page = SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 24, DenLayout.gutter, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(keepUnits('Wednesday, October 28'), style: t.meta(c.ink2)),
                      const SizedBox(height: 2),
                      Text('Good morning', style: t.screenTitle(c.ink)),
                    ],
                  ),
                ),
                face(mom, 44),
              ],
            ),
          ),
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
  Widget build(BuildContext context) {
    final c = context.colors;
    return Section(
      title: 'Needs you',
      trailing: Text('2 things', style: context.text.meta(c.ink2)),
      child: const Column(
        children: [
          _Request(person: leo, title: 'Nobody is driving Leo', detail: 'Soccer, 3:30 PM at Field 4', action: 'I’ll drive'),
          Rule(indent: 52),
          _Request(person: mia, title: 'Mia wants movie night', detail: 'Costs 40 stars, she has 52', action: 'Approve'),
        ],
      ),
    );
  }
}

/// A "Needs you" row: their picture, one sentence, and the action under it.
class _Request extends StatelessWidget {
  const _Request({required this.person, required this.title, required this.detail, required this.action});

  final Person person;
  final String title;
  final String detail;
  final String action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          face(person, 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tidy(title), style: t.rowTitle(c.ink)),
                const SizedBox(height: 2),
                Text(tidy(detail), style: t.meta(c.ink2)),
                const SizedBox(height: 12),
                FilledButton(onPressed: () {}, child: Text(action)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class EventsSample extends StatelessWidget {
  const EventsSample({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Section(
      title: 'Today',
      trailing: Text('Week', style: context.text.meta(c.ink2).bold),
      child: const Column(
        children: [
          _EventRow(time: '7:30 AM', title: 'School drop-off', who: 'Dad', people: [dad]),
          Rule(),
          _EventRow(time: '9:00 AM', title: 'Dentist', who: 'Mia and Mom', people: [mia, mom]),
          Rule(),
          _EventRow(time: '3:30 PM', title: 'Soccer at Field 4', who: 'Leo, nobody driving yet', people: [leo]),
          Rule(),
          _EventRow(time: '6:00 PM', title: 'Dinner at Grandma’s', who: 'Everyone', people: [mom, dad, mia, leo]),
        ],
      ),
    );
  }
}

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
    // Past 135 % text the time goes above the title instead of squeezing it; below that the
    // time column fits the longest time at the current size.
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
          _Faces(people),
        ],
      ),
    );
  }
}

/// Small overlapping faces, each separated by a ring of the card color.
class _Faces extends StatelessWidget {
  const _Faces(this.people);

  final List<Person> people;

  static const double _size = 26;
  static const double _ring = 2;
  static const double _step = _size - 6;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    const outer = _size + _ring * 2;
    return SizedBox(
      width: outer + _step * (people.length - 1),
      height: outer,
      child: Stack(
        children: [
          for (final (i, p) in people.indexed)
            Positioned(
              left: _step * i,
              top: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: c.card, width: _ring),
                ),
                child: Padding(padding: const EdgeInsets.all(_ring), child: face(p, _size)),
              ),
            ),
        ],
      ),
    );
  }
}

class ChoresSample extends StatelessWidget {
  const ChoresSample({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Section(
      title: 'Chores',
      trailing: Text('2 of 5 done', style: context.text.meta(c.ink2)),
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            _KidChores(person: mia, chores: [('Dishes', 2, false), ('Feed the cat', 1, true)]),
            Rule(),
            _KidChores(person: leo, chores: [('Make bed', 1, true), ('Trash out', 1, false), ('Read 20 min', 2, false)]),
          ],
        ),
      ),
    );
  }
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
                    ChoreChip(title: title, stars: stars, done: done, color: person.color.color),
                ],
              ),
            ),
          ],
        ),
      );
}

/// A chore on Today: a pill with a check ring in the person's color that fills when done.
class ChoreChip extends StatelessWidget {
  const ChoreChip({super.key, required this.title, required this.stars, required this.done, required this.color});

  final String title;
  final int stars;
  final bool done;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return DenPressable(
      onTap: () {},
      haptic: true,
      toggled: done,
      color: c.card,
      shape: StadiumBorder(side: BorderSide(color: c.line, width: 1.5)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Targets.adult),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 14, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: done ? color : null,
                  border: Border.all(color: color, width: 2),
                ),
                child: SizedBox.square(
                  dimension: 26,
                  child: done ? Icon(PhosphorIconsBold.check, size: 16, color: c.onMarker) : null,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  title,
                  style: t.control(done ? c.ink2 : c.ink).copyWith(
                        decoration: done ? TextDecoration.lineThrough : null,
                        decorationColor: c.ink2,
                      ),
                ),
              ),
              if (stars > 0) ...[
                const SizedBox(width: 6),
                Text('$stars', style: t.meta(c.ink2)),
                const SizedBox(width: 2),
                const Star(size: 13),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class GrocerySample extends StatelessWidget {
  const GrocerySample({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Section(
      title: 'Groceries',
      trailing: Text(keepUnits('14 items'), style: context.text.meta(c.ink2).bold),
      carded: false,
      child: Row(
        children: [
          const Expanded(child: TextField(decoration: InputDecoration(hintText: 'Add to groceries'))),
          const SizedBox(width: 8),
          RoundButton(icon: PhosphorIconsBold.plus, label: 'Add to groceries', fill: c.primary, color: c.onPrimary),
        ],
      ),
    );
  }
}

/// A round icon button: Add (ink) or More (card).
class RoundButton extends StatelessWidget {
  const RoundButton({
    super.key,
    required this.icon,
    required this.label,
    required this.fill,
    required this.color,
    this.size = 52,
  });

  final IconData icon;
  final String label;
  final Color fill;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => DenPressable(
        onTap: () {},
        color: fill,
        shape: const CircleBorder(),
        semanticLabel: label,
        child: SizedBox.square(dimension: size, child: Icon(icon, size: size * 0.45, color: color)),
      );
}

/// The phone tab bar: five places, Add in the middle.
class TabBarSample extends StatelessWidget {
  const TabBarSample({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(color: c.bar, border: Border(top: BorderSide(color: c.line))),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 28),
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.35,
          child: Row(
            children: [
              const Expanded(child: _Tab(icon: PhosphorIconsBold.house, label: 'Today', selected: true)),
              const Expanded(child: _Tab(icon: PhosphorIconsRegular.calendarBlank, label: 'Calendar')),
              Expanded(
                child: Center(
                  child: RoundButton(icon: PhosphorIconsBold.plus, label: 'Add', fill: c.primary, color: c.onPrimary),
                ),
              ),
              const Expanded(child: _Tab(icon: PhosphorIconsRegular.checkCircle, label: 'Chores')),
              const Expanded(child: _Tab(icon: PhosphorIconsRegular.listBullets, label: 'Lists')),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.icon, required this.label, this.selected = false});

  final IconData icon;
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = selected ? c.ink : c.ink3;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 26, color: color),
        const SizedBox(height: 2),
        Text(label, style: context.text.tab(color, selected: selected), maxLines: 1, softWrap: false),
      ],
    );
  }
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
            Section(
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
            Section(
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
                      TextButton(onPressed: () {}, child: const Text('Undo')),
                      const FilledButton(onPressed: null, child: Text('Add')),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      RoundButton(icon: PhosphorIconsBold.plus, label: 'Add', fill: c.primary, color: c.onPrimary),
                      RoundButton(
                        icon: PhosphorIconsBold.dotsThree,
                        label: 'More',
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
            Section(
              title: 'Chips',
              carded: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      CategoryChip(name: 'Animals', selected: true),
                      CategoryChip(name: 'Critters'),
                      CategoryChip(name: 'Snacks'),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _PersonChip(person: mia, selected: true),
                      _PersonChip(person: leo),
                      _PersonChip(person: dad),
                    ],
                  ),
                  const SizedBox(height: 10),
                  GroupCard(
                    padding: const EdgeInsets.all(12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ChoreChip(title: 'Dishes', stars: 2, done: false, color: mia.color.color),
                        ChoreChip(title: 'Feed the cat', stars: 1, done: true, color: mia.color.color),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: DenLayout.sectionGap),
            const Section(
              title: 'Fields and switches',
              carded: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(decoration: InputDecoration(hintText: 'Add to groceries')),
                  SizedBox(height: 10),
                  GroupCard(
                    child: Column(
                      children: [
                        _SwitchRow(label: 'Leo can add events', value: true),
                        Rule(),
                        _SwitchRow(label: 'Mia asks before adding', value: false),
                      ],
                    ),
                  ),
                  SizedBox(height: 10),
                  Align(alignment: Alignment.centerLeft, child: _Segmented(options: ['Week', 'Day'], selected: 0)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The picker's category chip: ink when chosen, the card color otherwise.
class CategoryChip extends StatelessWidget {
  const CategoryChip({super.key, required this.name, this.selected = false});

  final String name;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DenPressable(
      onTap: () {},
      selected: selected,
      color: selected ? c.primary : c.card,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Center(
            widthFactor: 1,
            child: Text(name, style: context.text.meta(selected ? c.onPrimary : c.ink).bold),
          ),
        ),
      ),
    );
  }
}

/// A calendar filter: their face and name; chosen has an ink outline and a bold name.
class _PersonChip extends StatelessWidget {
  const _PersonChip({required this.person, this.selected = false});

  final Person person;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return DenPressable(
      onTap: () {},
      selected: selected,
      color: c.card,
      shape: StadiumBorder(side: BorderSide(color: selected ? c.ink : c.line, width: 1.5)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Targets.adult),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 16, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              face(person, 32),
              const SizedBox(width: 8),
              Text(person.name, style: selected ? t.control(c.ink).bold : t.control(c.ink)),
            ],
          ),
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

/// A segmented control: a fill-colored track with the chosen segment in ink.
class _Segmented extends StatelessWidget {
  const _Segmented({required this.options, required this.selected});

  final List<String> options;
  final int selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DecoratedBox(
      decoration: ShapeDecoration(shape: const StadiumBorder(), color: c.fill),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, o) in options.indexed)
              DenPressable(
                onTap: () {},
                selected: i == selected,
                color: i == selected ? c.primary : null,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 36, minWidth: 72),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Center(
                      widthFactor: 1,
                      child: Text(
                        o,
                        style: i == selected ? context.text.label(c.onPrimary) : context.text.control(c.ink2),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Palette.dc.html: the eight family colors, by day and at night.
class PaletteSample extends StatelessWidget {
  const PaletteSample({super.key});

  static String hex(Color color) =>
      '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return ColoredBox(
      color: c.bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(40, 36, 40, 36),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Family colors', style: t.screenTitle(c.ink)),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Text(
                tidy('Eight bright, happy colors, one for each person. The same color in the light and the '
                    'black theme, with dark text on every one.'),
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
                    for (final p in PersonColor.assignmentOrder)
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
              tidy('Checked, not guessed: dark text reads at 5.4:1 or better on every color, and in this order '
                  'every pair of neighbors stays clearly different, including for color-blind eyes.'),
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
                labeled(DenAvatar.photo(null, color: PersonColor.sky.color, size: 64), 'Photo'),
                const SizedBox(width: 16),
                labeled(DenAvatar.initial('M', color: PersonColor.aqua.color, size: 64), 'Initial'),
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
                              DenAvatar.picture(p.id, color: PersonColor.values[i % 8].color, size: 76),
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
  static const _color = PersonColor.bubblegum;

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
              DenAvatar.picture(_chosen, color: _color.color, size: 96, semanticLabel: 'Mia'),
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
              for (final p in PersonColor.assignmentOrder) _Swatch(color: p, selected: p == _color),
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
                  CategoryChip(name: g.name, selected: i == 0),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          for (final row in [group.pictures.sublist(0, 4), group.pictures.sublist(4)]) ...[
            Row(
              children: [
                for (final p in row)
                  Expanded(child: _PickerItem(picture: p, color: _color.color, selected: p.id == _chosen)),
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

  final PersonColor color;
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
