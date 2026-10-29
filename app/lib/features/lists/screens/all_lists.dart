import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_state.dart';
import '../../../app/household.dart';
import '../../../app/redirect.dart' show mergedFamilies;
import '../../../app/log_scope.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../state/lists_model.dart';
import '../widgets/list_content.dart';
import '../words/list_words.dart';
import 'lists_index.dart';

/// The Lists tab: the family the device shows, or "All my families" on a device in several.
class ListsTab extends StatelessWidget {
  const ListsTab({super.key});

  @override
  Widget build(BuildContext context) =>
      (Household.maybeOf(context)?.showingAll ?? false) ? const AllListsScreen() : const ListsIndex();
}

/// Lists in "All my families" (FAMILY-LINKS-PLAN §4.2): every family's lists as chips, pinned
/// first, each with its family's tag, and the chosen one below to add to and check off. The list
/// is its family's own: what is checked or added is written by that family's actions, with its
/// own receipts and Undo. The choice is in the URL: `/lists?log=<family>&list=<id>`.
class AllListsScreen extends StatelessWidget {
  const AllListsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final home = Household.maybeOf(context)!;
    final families = mergedFamilies(home);
    final query = GoRouterState.of(context).uri.queryParameters;
    return ListenableBuilder(
      listenable: Listenable.merge([for (final l in families) l.state]),
      builder: (context, _) => _build(context, families, query['log'], query['list']),
    );
  }

  Widget _build(BuildContext context, List<FamilyLog> families, String? pickedLog, String? pickedList) {
    context.watch(listReads);
    final lists = <(FamilyLog, ListState)>[
      for (final log in families)
        for (final l in log.state.view(const ListsModel()))
          if (l.list.pinned) (log, l),
      for (final log in families)
        for (final l in log.state.view(const ListsModel()))
          if (!l.list.pinned) (log, l),
    ];
    final current = lists.where((e) => e.$1.isId(pickedLog ?? '') && e.$2.list.id == pickedList).firstOrNull ?? lists.firstOrNull;
    void select((FamilyLog, ListState) e) => context.go('/lists?log=${Uri.encodeComponent(e.$1.id)}&list=${e.$2.list.id}');
    final compact = DenLayout.of(context).isCompact;
    const empty = EmptyState(message: 'No lists in any family yet.');

    Widget content((FamilyLog, ListState) e) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: DenLayout.headingInset, bottom: Sp.m),
              child: Row(
                children: [
                  SourceTag(label: e.$1.name, color: e.$1.color, size: 20, semantics: false),
                  const SizedBox(width: Sp.s),
                  Flexible(child: Text('In ${e.$1.name}', style: context.text.meta(context.colors.ink2))),
                ],
              ),
            ),
            LogScope(log: e.$1, child: ListContent(key: ValueKey('${e.$1.id}/${e.$2.list.id}'), list: e.$2)),
          ],
        );

    return LayoutBuilder(
      builder: (context, constraints) {
        final two = constraints.maxWidth >= ListsHome.twoColumns;
        final side = two ? 32.0 : (compact ? DenLayout.gutter : 24.0);
        if (!two) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(0, Sp.l, 0, Sp.xxl),
            children: [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: side),
                child: PageHeader(title: 'Lists', overline: 'All my families', large: !compact),
              ),
              const SizedBox(height: Sp.m),
              if (lists.isNotEmpty)
                ChipRow(
                  inset: side,
                  children: [
                    for (final e in lists)
                      _SourcedChip(
                        family: e.$1,
                        label: e.$2.list.title,
                        selected: identical(e, current),
                        onTap: () => select(e),
                      ),
                  ],
                ),
              const SizedBox(height: 20),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: side),
                child: current == null ? empty : content(current),
              ),
            ],
          );
        }
        return Padding(
          padding: EdgeInsets.fromLTRB(side, 0, side, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 300,
                child: ListView(
                  padding: const EdgeInsets.only(top: 32, bottom: 40),
                  children: [
                    const PageHeader(title: 'Lists', overline: 'All my families', large: true),
                    for (final log in families)
                      if (lists.any((e) => identical(e.$1, log))) ...[
                        const SizedBox(height: DenLayout.sectionGap),
                        DenSection(
                          title: log.name,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final e in lists)
                                if (identical(e.$1, log))
                                  _ListPick(entry: e, selected: identical(e, current), onTap: () => select(e)),
                            ],
                          ),
                        ),
                      ],
                  ],
                ),
              ),
              const SizedBox(width: DenLayout.sectionGap),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(top: 32, bottom: 40),
                  children: [
                    if (current == null)
                      empty
                    else ...[
                      PageHeader(title: current.$2.list.title, overline: kindWords(current.$2.list.kind), large: true),
                      const SizedBox(height: DenLayout.sectionGap),
                      content(current),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A list as a chip with its family's tag: ink when chosen.
class _SourcedChip extends StatelessWidget {
  const _SourcedChip({required this.family, required this.label, required this.selected, required this.onTap});

  final FamilyLog family;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fg = selected ? c.onPrimary : c.ink;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: DenPressable(
        onTap: onTap,
        selected: selected,
        color: selected ? c.primary : c.card,
        semanticLabel: '${tidy(label)}, ${family.name}',
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(Sp.s, 0, Sp.l, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SourceTag(label: family.name, color: family.color, size: 20, semantics: false),
                const SizedBox(width: Sp.s),
                Flexible(child: Text(tidy(label), style: context.text.meta(fg).bold)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A list in the iPad's column, under its family: its title and what's left on it.
class _ListPick extends StatelessWidget {
  const _ListPick({required this.entry, required this.selected, required this.onTap});

  final (FamilyLog, ListState) entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final (log, list) = entry;
    final timing = listTiming(log.state, list);
    return DenPressable(
      onTap: onTap,
      scale: false,
      selected: selected,
      color: selected ? c.fill : null,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(Radii.tile))),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.s, vertical: Sp.s),
          child: Row(
            children: [
              SourceTag(label: log.name, color: log.color, size: 22, semantics: false),
              const SizedBox(width: Sp.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tidy(list.list.title), style: selected ? t.body(c.ink).bold : t.body(c.ink)),
                    Text(tidy(timing?.text ?? listSummary(list)), style: t.meta(c.ink2)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
