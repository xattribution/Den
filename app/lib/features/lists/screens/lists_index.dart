import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/pictograms.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../state/lists_model.dart';
import '../widgets/list_content.dart';
import '../widgets/list_menu.dart';
import '../words/list_words.dart';

/// The Lists tab (Lists.dc.html): the lists as chips, pinned first, and the chosen one below,
/// to add to and check off. The chosen list is in the URL: `/lists?list=<id>`.
class ListsIndex extends StatelessWidget {
  const ListsIndex({super.key});

  @override
  Widget build(BuildContext context) => ListsHome(selected: GoRouterState.of(context).uri.queryParameters['list']);
}

/// The lists and the chosen one. With room for two columns (an iPad in landscape, beside the
/// sidebar) the lists sit in a column on the left, each with how much is left on it.
class ListsHome extends StatefulWidget {
  const ListsHome({super.key, this.selected});

  /// A list's id; null (or a list that's gone) picks the first pinned one.
  final String? selected;

  /// The content width from which the lists sit beside the chosen one.
  static const double twoColumns = 760;

  @override
  State<ListsHome> createState() => _ListsHomeState();
}

class _ListsHomeState extends State<ListsHome> {
  Done? _deleted;

  Future<void> _more(ListState lv) async {
    final deleted = await showListMenu(context, lv);
    if (deleted == null || !mounted) return;
    setState(() => _deleted = deleted);
    context.go('/lists');
  }

  Future<void> _undoDelete(Receipt receipt) async {
    final result = await perform(context, () => context.actions.undo(receipt));
    if (result != null && mounted) setState(() => _deleted = null);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(listReads);
    final all = context.view(const ListsModel());
    final lists = [...all.where((l) => l.list.pinned), ...all.where((l) => !l.list.pinned)];
    final canAdd = app.allows(DenAction.editLists);
    final compact = DenLayout.of(context).isCompact;
    final current = lists.where((l) => l.list.id == widget.selected).firstOrNull ?? lists.firstOrNull;
    void select(ListState l) => context.go('/lists?list=${l.list.id}');
    final deleted = _deleted;

    final more = current == null
        ? null
        : RoundButton(
            icon: PhosphorIconsBold.dotsThree,
            label: 'More for ${current.list.title}',
            onTap: () => _more(current),
            fill: context.colors.card,
            color: context.colors.ink,
            size: Targets.adult,
          );
    final deletedNote = DenReveal(
      visible: deleted != null,
      child: deleted == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(bottom: Sp.m),
              child: GroupCard(
                child: DoneRow(
                  message: deleted.message,
                  onUndo: deleted.receipt?.undoable == true ? () => _undoDelete(deleted.receipt!) : null,
                ),
              ),
            ),
    );
    final empty = EmptyState(
      message: 'No lists yet. Groceries, a packing list, the week\'s meals: each gets its own.',
      actionLabel: canAdd ? 'New list' : null,
      onAction: canAdd ? () => context.push('/lists/new') : null,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final two = constraints.maxWidth >= ListsHome.twoColumns;
        final side = two ? 32.0 : (compact ? DenLayout.gutter : 24.0);
        if (!two) {
          return ListView(
            padding: EdgeInsets.fromLTRB(0, Sp.l, 0, Sp.xxl),
            children: [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: side),
                child: PageHeader(title: 'Lists', large: !compact, trailing: more),
              ),
              const SizedBox(height: Sp.m),
              if (lists.isNotEmpty || canAdd)
                ChipRow(
                  inset: side,
                  children: [
                    for (final l in lists)
                      TagChip(label: l.list.title, selected: l.list.id == current?.list.id, onTap: () => select(l)),
                    if (canAdd) TagChip(label: 'New list', icon: PhosphorIconsBold.plus, selected: false, onTap: () => context.push('/lists/new')),
                  ],
                ),
              const SizedBox(height: 20),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: side),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    deletedNote,
                    if (current == null) empty else ListContent(key: ValueKey(current.list.id), list: current),
                  ],
                ),
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
                    const PageHeader(title: 'Lists', large: true),
                    const SizedBox(height: DenLayout.sectionGap),
                    if (lists.isNotEmpty)
                      GroupCard(
                        padding: const EdgeInsets.symmetric(horizontal: Sp.s, vertical: Sp.s),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final l in lists) _ListPick(list: l, selected: l.list.id == current?.list.id, onTap: () => select(l)),
                          ],
                        ),
                      ),
                    if (canAdd) ...[
                      const SizedBox(height: Sp.m),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: OutlinedButton.icon(
                          onPressed: () => context.push('/lists/new'),
                          icon: const Icon(PhosphorIconsBold.plus, size: 18),
                          label: const Text('New list'),
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
                    deletedNote,
                    if (current == null)
                      empty
                    else ...[
                      PageHeader(
                        title: current.list.title,
                        overline: kindWords(current.list.kind),
                        large: true,
                        trailing: more,
                      ),
                      const SizedBox(height: DenLayout.sectionGap),
                      ListContent(key: ValueKey(current.list.id), list: current),
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

/// A list in the iPad's column: its kind's glyph, its title and what's left on it.
class _ListPick extends StatelessWidget {
  const _ListPick({required this.list, required this.selected, required this.onTap});
  final ListState list;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(listReads);
    final c = context.colors;
    final t = context.text;
    final timing = listTiming(app, list);
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
              Icon(Pictograms.listKind(list.list.kind), size: 22, color: c.ink),
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
