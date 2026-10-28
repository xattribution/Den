import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../layout.dart';
import '../motion.dart';
import '../tokens.dart';
import 'buttons.dart';

/// A place in the app's navigation: Today, Calendar, Chores, Lists, Family.
class NavPlace {
  const NavPlace({required this.label, required this.icon, required this.selectedIcon, required this.onTap, this.selected = false});

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final VoidCallback onTap;
  final bool selected;
}

/// The phone's tab bar ([DenWidth.compact]): the places, with Add in the middle as a round ink
/// button. Labels follow text size up to 135 %, so five always fit.
class DenTabBar extends StatelessWidget {
  const DenTabBar({super.key, required this.places, required this.onAdd, this.addLabel = 'Add'});

  /// Two before Add and two after.
  final List<NavPlace> places;
  final VoidCallback onAdd;
  final String addLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final half = (places.length / 2).ceil();
    final bottom = MediaQuery.paddingOf(context).bottom;
    return DecoratedBox(
      decoration: BoxDecoration(color: c.bar, border: Border(top: BorderSide(color: c.line))),
      child: Padding(
        padding: EdgeInsets.fromLTRB(Sp.s, 6, Sp.s, bottom > 0 ? bottom : Sp.s),
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.35,
          child: Row(
            children: [
              for (final p in places.take(half)) Expanded(child: _Tab(p)),
              Expanded(child: Center(child: RoundButton(icon: PhosphorIconsBold.plus, label: addLabel, onTap: onAdd))),
              for (final p in places.skip(half)) Expanded(child: _Tab(p)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab(this.place);

  final NavPlace place;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = place.selected ? c.ink : c.ink3;
    return Semantics(
      selected: place.selected,
      button: true,
      label: place.label,
      excludeSemantics: true,
      child: DenPressable(
        onTap: place.onTap,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(Radii.tile))),
        child: SizedBox(
          height: 50,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(place.selected ? place.selectedIcon : place.icon, size: 26, color: color),
              const SizedBox(height: 2),
              Text(place.label, style: context.text.tab(color, selected: place.selected), maxLines: 1, softWrap: false),
            ],
          ),
        ),
      ),
    );
  }
}

/// The iPad's sidebar ([DenWidth.regular] and up), 248 wide: the family's name, Add as an ink
/// pill, the places, and at the bottom who is using the device (their menu).
class DenSidebar extends StatelessWidget {
  const DenSidebar({
    super.key,
    required this.title,
    required this.places,
    required this.onAdd,
    this.footer,
    this.addLabel = 'Add',
  });

  final String title;
  final List<NavPlace> places;
  final VoidCallback onAdd;
  final String addLabel;

  /// Who is using the device: a [NavRow]-like face and name that opens their menu.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return DecoratedBox(
      decoration: BoxDecoration(color: c.sidebar, border: Border(right: BorderSide(color: c.line))),
      child: SizedBox(
        width: DenLayout.sidebarWidth,
        child: SafeArea(
          right: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xxl, Sp.l, Sp.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Sp.m, 0, Sp.m, Sp.l),
                  child: Semantics(header: true, child: Text(title, style: t.sheetTitle(c.ink).copyWith(fontSize: 22 * t.scale))),
                ),
                FilledButton.icon(
                  onPressed: onAdd,
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  icon: const Icon(PhosphorIconsBold.plus, size: 20),
                  label: Text(addLabel),
                ),
                const SizedBox(height: 14),
                for (final p in places) ...[_SideItem(p), const SizedBox(height: 6)],
                const Spacer(),
                ?footer,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SideItem extends StatelessWidget {
  const _SideItem(this.place);

  final NavPlace place;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Semantics(
      selected: place.selected,
      button: true,
      label: place.label,
      excludeSemantics: true,
      child: DenPressable(
        onTap: place.onTap,
        scale: false,
        color: place.selected ? c.fill : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: Sp.xs),
            child: Row(
              children: [
                Icon(place.selected ? place.selectedIcon : place.icon, size: 22, color: place.selected ? c.ink : c.ink2),
                const SizedBox(width: Sp.m),
                Expanded(
                  child: Text(place.label, style: place.selected ? t.body(c.ink).bold : t.body(c.ink2)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A page's heading: a small line above (the date) and the title (30/800), with something at
/// the end (the person's face, which opens their menu).
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.overline, this.trailing, this.large = false});

  final String title;
  final String? overline;
  final Widget? trailing;

  /// iPad's larger title.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (overline != null) ...[
                  Text(overline!, style: t.meta(c.ink2)),
                  const SizedBox(height: 2),
                ],
                Semantics(header: true, child: Text(title, style: t.screenTitle(c.ink, large: large))),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: Sp.m), trailing!],
        ],
      ),
    );
  }
}
