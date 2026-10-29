import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../design/layout.dart';
import '../design/motion.dart';
import '../design/sheet.dart';
import '../design/tokens.dart';
import '../design/widgets.dart';
import '../features/add/add.dart';
import 'app_state.dart';

/// The adult app's frame. On a phone: the screen over a tab bar with Today, Calendar, Add in the
/// middle, Chores and Lists. From 700 pt: the 248 pt sidebar with the family's name, Add, the
/// places and Family, and the person at the bottom. Family, points, search and settings open
/// from the person: their face on Today (phone) or at the foot of the sidebar.
///
/// Keyboard: ⌘N adds, ⌘1 to ⌘4 go to the places, ⌘F searches.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  /// A tap on the current place goes back to its first page.
  void _go(int index) => navigationShell.goBranch(index, initialLocation: index == navigationShell.currentIndex);

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final index = navigationShell.currentIndex;
    final places = [
      NavPlace(
        label: 'Today',
        icon: PhosphorIconsRegular.house,
        selectedIcon: PhosphorIconsBold.house,
        selected: index == 0,
        onTap: () => _go(0),
      ),
      NavPlace(
        label: 'Calendar',
        icon: PhosphorIconsRegular.calendarBlank,
        selectedIcon: PhosphorIconsBold.calendarBlank,
        selected: index == 1,
        onTap: () => _go(1),
      ),
      NavPlace(
        label: 'Chores',
        icon: PhosphorIconsRegular.checkCircle,
        selectedIcon: PhosphorIconsBold.checkCircle,
        selected: index == 2,
        onTap: () => _go(2),
      ),
      NavPlace(
        label: 'Lists',
        icon: PhosphorIconsRegular.listBullets,
        selectedIcon: PhosphorIconsBold.listBullets,
        selected: index == 3,
        onTap: () => _go(3),
      ),
    ];
    final shortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyN, meta: true): () => showAddSheet(context),
      const SingleActivator(LogicalKeyboardKey.keyN, control: true): () => showAddSheet(context),
      const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () => context.push('/search'),
      const SingleActivator(LogicalKeyboardKey.keyF, control: true): () => context.push('/search'),
      for (final (i, key) in [LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit3, LogicalKeyboardKey.digit4].indexed) ...{
        SingleActivator(key, meta: true): () => _go(i),
        SingleActivator(key, control: true): () => _go(i),
      },
    };

    final Widget frame;
    if (DenLayout.of(context).isCompact) {
      // Each place heads itself (the boards have no bar over them); Today carries the person.
      frame = Scaffold(
        body: SafeArea(bottom: false, child: navigationShell),
        bottomNavigationBar: DenTabBar(places: places, onAdd: () => showAddSheet(context)),
      );
    } else {
      final me = app.me;
      frame = Scaffold(
        body: Row(
          children: [
            DenSidebar(
              title: app.den.family?.name ?? 'Den',
              places: [
                ...places,
                NavPlace(
                  label: 'Family',
                  icon: PhosphorIconsRegular.usersThree,
                  selectedIcon: PhosphorIconsBold.usersThree,
                  onTap: () => context.push('/family'),
                ),
                NavPlace(
                  label: 'Search',
                  icon: PhosphorIconsRegular.magnifyingGlass,
                  selectedIcon: PhosphorIconsBold.magnifyingGlass,
                  onTap: () => context.push('/search'),
                ),
              ],
              onAdd: () => showAddSheet(context),
              footer: me == null
                  ? null
                  : NavRow(
                      leading: DenAvatar(me, size: 40),
                      label: me.name,
                      chevron: false,
                      onTap: () => showPersonMenu(context),
                    ),
            ),
            Expanded(child: SafeArea(left: false, child: navigationShell)),
          ],
        ),
      );
    }
    return CallbackShortcuts(bindings: shortcuts, child: Focus(autofocus: true, child: frame));
  }
}

/// Search: a magnifying glass that opens it (⌘F does too). On Today's header beside the face,
/// and in the iPad sidebar.
class SearchButton extends StatelessWidget {
  const SearchButton({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: 'Search',
      excludeFromSemantics: true,
      child: DenPressable(
        onTap: () => context.push('/search'),
        shape: const CircleBorder(),
        semanticLabel: 'Search',
        child: SizedBox.square(
          dimension: Targets.adult,
          child: Icon(PhosphorIconsRegular.magnifyingGlass, size: 22, color: c.ink),
        ),
      ),
    );
  }
}

/// The person using the device as a round face; it opens their menu.
class PersonButton extends StatelessWidget {
  const PersonButton({super.key, required this.member, this.size = 44});

  final Member? member;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: 'Family and settings',
      excludeFromSemantics: true,
      child: DenPressable(
        onTap: () => showPersonMenu(context),
        shape: const CircleBorder(),
        semanticLabel: 'Family and settings',
        child: SizedBox.square(
          dimension: size < Targets.adult ? Targets.adult : size,
          child: Center(
            child: member == null
                ? Icon(PhosphorIconsRegular.userCircle, size: size, color: c.ink2)
                : DenAvatar(member!, size: size),
          ),
        ),
      ),
    );
  }
}

/// What opens from the person: Family, Points and rewards (when stars are on), Search and
/// Settings.
Future<void> showPersonMenu(BuildContext context) {
  final app = DenScope.read(context);
  final router = GoRouter.of(context);
  final pointsOn = app.den.family?.pointsEnabled ?? true;
  final me = app.me;
  void open(BuildContext sheet, String route) {
    Navigator.of(sheet).pop();
    router.push(route);
  }

  return showDenSheet<void>(
    context,
    builder: (sheet) {
      final c = sheet.colors;
      final rows = [
        NavRow(icon: PhosphorIconsRegular.usersThree, label: 'Family', onTap: () => open(sheet, '/family')),
        if (pointsOn) NavRow(icon: PhosphorIconsRegular.star, label: 'Points and rewards', onTap: () => open(sheet, '/points')),
        NavRow(icon: PhosphorIconsRegular.magnifyingGlass, label: 'Search', onTap: () => open(sheet, '/search')),
        NavRow(icon: PhosphorIconsRegular.gearSix, label: 'Settings', onTap: () => open(sheet, '/settings')),
      ];
      return Padding(
        padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.s, DenLayout.headingInset, Sp.l),
              child: Row(
                children: [
                  if (me != null) ...[DenAvatar(me, size: 44), const SizedBox(width: Sp.m)],
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(me?.name ?? app.den.family?.name ?? 'Den', style: sheet.text.sheetTitle(c.ink)),
                    ),
                  ),
                ],
              ),
            ),
            GroupCard(child: Column(children: ruled(rows, indent: 36))),
          ],
        ),
      );
    },
  );
}
