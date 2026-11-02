import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../layout.dart';
import '../motion.dart';
import '../tokens.dart';
import '../words.dart';
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
    // A phone on its side has the notch or Dynamic Island at one end and rounded corners at
    // both: the tabs stay between the safe areas, the bar's color goes to the edges.
    final safe = MediaQuery.paddingOf(context);
    final bottom = safe.bottom;
    return DecoratedBox(
      decoration: BoxDecoration(color: c.bar, border: Border(top: BorderSide(color: c.line))),
      child: Padding(
        padding: EdgeInsets.fromLTRB(Sp.s + safe.left, 6, Sp.s + safe.right, bottom > 0 ? bottom : Sp.s),
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.35,
          child: Row(
            children: [
              for (final p in places.take(half)) Expanded(child: _Tab(p)),
              Expanded(child: Center(heightFactor: 1, child: RoundButton(icon: PhosphorIconsBold.plus, label: addLabel, onTap: onAdd))),
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
/// pill, the places, and at the bottom who is using the device (their menu). In a window too
/// short for all of it (a tablet under the browser's bars, a short desktop window, large text)
/// the name, Add and the places scroll and the person stays at the bottom, within the safe
/// areas; in one too short even for that, the person scrolls with the rest.
class DenSidebar extends StatelessWidget {
  const DenSidebar({
    super.key,
    required this.title,
    required this.places,
    required this.onAdd,
    this.footer,
    this.addLabel = 'Add',
    this.heading,
  });

  final String title;

  /// Drawn in place of [title] when given: the family switcher on a device in several families.
  final Widget? heading;
  final List<NavPlace> places;
  final VoidCallback onAdd;
  final String addLabel;

  /// Who is using the device: a [NavRow]-like face and name that opens their menu.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final top = [
      Padding(
        padding: EdgeInsets.fromLTRB(Sp.m, 0, Sp.m, heading == null ? Sp.l : Sp.s),
        child: heading ??
            Semantics(header: true, child: Text(title, style: t.sheetTitle(c.ink).copyWith(fontSize: 22 * t.scale))),
      ),
      FilledButton.icon(
        onPressed: onAdd,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        icon: const Icon(PhosphorIconsBold.plus, size: 20),
        label: Text(addLabel),
      ),
      const SizedBox(height: 14),
      for (final p in places) ...[_SideItem(p), const SizedBox(height: 6)],
    ];
    return DecoratedBox(
      decoration: BoxDecoration(color: c.sidebar, border: Border(right: BorderSide(color: c.line))),
      child: SizedBox(
        width: DenLayout.sidebarWidth,
        child: SafeArea(
          right: false,
          child: LayoutBuilder(
            builder: (context, box) {
              final footer = this.footer;
              // The person stays put below the rest while that leaves the rest some room; in a
              // shorter window they scroll with it, so nothing is ever out of reach.
              final pinned = footer != null && box.maxHeight >= _pinnedFooterMin(context);
              final scrolling = CustomScrollView(
                primary: false,
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(Sp.l, Sp.xxl, Sp.l, pinned || footer == null ? Sp.l : 0),
                    sliver: SliverList.list(children: top),
                  ),
                  if (!pinned && footer != null)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.xl),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [const Spacer(), footer],
                        ),
                      ),
                    ),
                ],
              );
              if (!pinned) return scrolling;
              return _PinnedFooter(scrolling: scrolling, footer: footer);
            },
          ),
        ),
      ),
    );
  }

  /// The least height in which the person stays pinned at the bottom: room for them and for
  /// a couple of places above them, at the text size in use.
  static double _pinnedFooterMin(BuildContext context) => MediaQuery.textScalerOf(context).scale(1) * 160 + 120;
}

/// The sidebar's scrolling part over the person, with a hairline between them while there's
/// more to scroll to: the places that don't fit go under it instead of running into the face.
class _PinnedFooter extends StatefulWidget {
  const _PinnedFooter({required this.scrolling, required this.footer});

  final Widget scrolling;
  final Widget footer;

  @override
  State<_PinnedFooter> createState() => _PinnedFooterState();
}

class _PinnedFooterState extends State<_PinnedFooter> {
  bool _more = false;

  bool _measure(Notification n) {
    final metrics = switch (n) {
      ScrollMetricsNotification(:final metrics) => metrics,
      ScrollNotification(:final metrics) => metrics,
      _ => null,
    };
    if (metrics != null && metrics.axis == Axis.vertical) {
      final more = metrics.extentAfter > 0.5;
      if (more != _more) setState(() => _more = more);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: NotificationListener<Notification>(onNotification: _measure, child: widget.scrolling)),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: _more ? context.colors.line : const Color(0x00000000))),
            ),
            child: Padding(padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, Sp.xl), child: widget.footer),
          ),
        ],
      );
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
                  // "October 16" stays together when large text wraps the date.
                  Text(keepUnits(overline!), style: t.meta(c.ink2)),
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


/// Moving a page through days (Chores, a calendar day): back, "Today" when it isn't today, and
/// forward, as round 44 pt buttons on the card color. The page says which day it is in its own
/// heading; [dayLabel] names it for screen readers ("Tomorrow, Saturday, October 17").
class DayStepper extends StatelessWidget {
  const DayStepper({
    super.key,
    required this.dayLabel,
    required this.onPrevious,
    required this.onNext,
    this.onToday,
    this.previousLabel = 'Previous day',
    this.nextLabel = 'Next day',
  });

  final String dayLabel;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  /// Null on today itself, which hides the Today button.
  final VoidCallback? onToday;
  final String previousLabel;
  final String nextLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      container: true,
      label: dayLabel,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RoundButton(
            icon: PhosphorIconsBold.caretLeft,
            label: previousLabel,
            onTap: onPrevious,
            fill: c.card,
            color: c.ink,
            size: Targets.adult,
          ),
          AnimatedSize(
            duration: DenMotion.reduced(context) ? Duration.zero : DenMotion.uiSettle,
            curve: DenMotion.uiCurve,
            child: onToday == null
                ? const SizedBox(width: Sp.s)
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Sp.s),
                    child: DenPressable(
                      onTap: onToday,
                      color: c.card,
                      semanticLabel: 'Go to today',
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: Targets.adult),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: Sp.l),
                          child: Center(widthFactor: 1, child: Text('Today', style: context.text.label(c.ink))),
                        ),
                      ),
                    ),
                  ),
          ),
          RoundButton(
            icon: PhosphorIconsBold.caretRight,
            label: nextLabel,
            onTap: onNext,
            fill: c.card,
            color: c.ink,
            size: Targets.adult,
          ),
        ],
      ),
    );
  }
}
