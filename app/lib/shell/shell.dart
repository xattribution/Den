import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../design/tokens.dart';
import '../design/widgets.dart';
import '../state/app_state.dart';

class _Destination {
  const _Destination(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

const _destinations = [
  _Destination('Today', PhosphorIconsRegular.sun, PhosphorIconsFill.sun),
  _Destination('Calendar', PhosphorIconsRegular.calendarBlank, PhosphorIconsFill.calendarBlank),
  _Destination('Chores', PhosphorIconsRegular.checkSquare, PhosphorIconsFill.checkSquare),
  _Destination('Lists', PhosphorIconsRegular.shoppingCart, PhosphorIconsFill.shoppingCart),
];

/// The adult app's frame: four daily tabs (bottom bar on phones, a rail on wider screens), a top
/// bar with Add and the person menu. Points, Family, History and Settings live in the menu.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  void _go(int index) => navigationShell.goBranch(index, initialLocation: index == navigationShell.currentIndex);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final body = Column(
      children: [
        const DenTopBar(),
        Expanded(child: navigationShell),
      ],
    );

    if (!wide) {
      return Scaffold(
        body: SafeArea(bottom: false, child: body),
        bottomNavigationBar: DecoratedBox(
          decoration: BoxDecoration(border: Border(top: BorderSide(color: c.rule))),
          child: NavigationBar(
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: _go,
            destinations: [
              for (final d in _destinations)
                NavigationDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selectedIcon), label: d.label),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            NavigationRail(
              selectedIndex: navigationShell.currentIndex,
              onDestinationSelected: _go,
              labelType: NavigationRailLabelType.all,
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selectedIcon), label: Text(d.label)),
              ],
            ),
            VerticalDivider(width: 1, color: c.rule),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

/// Family name on the left; Add and the person menu on the right.
class DenTopBar extends StatelessWidget {
  const DenTopBar({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final me = app.me;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.s, Sp.s),
      child: Row(
        children: [
          Expanded(
            child: Text(app.den.family?.name ?? 'Den', style: context.type.bodyStrong(c.ink2), overflow: TextOverflow.ellipsis),
          ),
          FilledButton.icon(
            onPressed: () => showAddSheet(context),
            icon: const Icon(PhosphorIconsBold.plus, size: 18),
            label: const Text('Add'),
          ),
          const SizedBox(width: Sp.s),
          PopupMenuButton<String>(
            tooltip: 'Menu',
            onSelected: (route) => context.push(route),
            itemBuilder: (_) => [
              const PopupMenuItem(value: '/points', child: Text('Points and rewards')),
              const PopupMenuItem(value: '/family', child: Text('Family and devices')),
              const PopupMenuItem(value: '/history', child: Text('History')),
              const PopupMenuItem(value: '/settings', child: Text('Settings')),
            ],
            child: Padding(
              padding: const EdgeInsets.all(Sp.s),
              child: me == null
                  ? Icon(PhosphorIconsRegular.userCircle, size: 32, color: c.ink2)
                  : DenAvatar(me, size: 32),
            ),
          ),
        ],
      ),
    );
  }
}

/// The one way to add anything: a short sheet of what you can add, by permission.
Future<void> showAddSheet(BuildContext context) {
  final app = context.app;
  final today = app.today;
  final choices = <(String, IconData, String, DenAction)>[
    ('Event', PhosphorIconsRegular.calendarPlus, '/event/new?date=$today', DenAction.editEvents),
    ('Chore', PhosphorIconsRegular.checkSquare, '/chore/new', DenAction.editChores),
    ('Grocery item', PhosphorIconsRegular.shoppingCart, '/lists/groceries/add', DenAction.checkItems),
    ('List', PhosphorIconsRegular.listPlus, '/lists/new', DenAction.editLists),
    ('Points', PhosphorIconsRegular.star, '/points/adjust', DenAction.managePoints),
  ].where((choice) => app.allows(choice.$4)).toList();

  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: Sp.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.s),
              child: Text('Add', style: sheetContext.type.title(sheetContext.colors.ink)),
            ),
            for (final choice in choices)
              ListTile(
                leading: Icon(choice.$2),
                title: Text(choice.$1),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  context.push(choice.$3);
                },
              ),
          ],
        ),
      ),
    ),
  );
}
