import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/pictograms.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../app/app_state.dart';
import '../words/list_words.dart';
import '../state/lists_model.dart';

/// The Lists tab: pinned lists first, then the rest, each a card you open on its own.
class ListsIndex extends StatelessWidget {
  const ListsIndex({super.key});

  /// A card with a title, a count and a timing line.
  static const double _cardHeight = 94;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(listReads);
    final c = context.colors;
    final lists = context.view(const ListsModel());
    final pinned = lists.where((l) => l.list.pinned).toList();
    final rest = lists.where((l) => !l.list.pinned).toList();
    final canAdd = app.allows(DenAction.editLists);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - Sp.l * 2;
        final columns = (width / 340).floor().clamp(1, 4);
        final cardWidth = (width - (columns - 1) * Sp.s) / columns;

        Widget grid(List<ListState> group) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.l),
          child: Wrap(
            spacing: Sp.s,
            runSpacing: Sp.s,
            children: [
              for (final lv in group)
                SizedBox(
                  width: cardWidth,
                  // Side by side, cards share one height so the rows read as a grid.
                  child: columns > 1
                      ? ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: _cardHeight),
                          child: ListCard(lv),
                        )
                      : ListCard(lv),
                ),
            ],
          ),
        );

        return ListView(
          padding: const EdgeInsets.only(bottom: Sp.xxxl),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.s, Sp.s),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(header: true, child: Text('Lists', style: context.type.heading(c.ink))),
                  ),
                  if (canAdd)
                    TextButton.icon(
                      onPressed: () => context.push('/lists/new'),
                      icon: const Icon(PhosphorIconsBold.plus, size: 18),
                      label: const Text('Add list'),
                    ),
                ],
              ),
            ),
            if (lists.isEmpty)
              EmptyLine(
                message: 'No lists yet.',
                actionLabel: canAdd ? 'Add list' : null,
                onAction: () => context.push('/lists/new'),
              ),
            if (pinned.isNotEmpty && rest.isNotEmpty) const _GroupLabel('Pinned'),
            if (pinned.isNotEmpty) grid(pinned),
            if (pinned.isNotEmpty && rest.isNotEmpty) const _GroupLabel('More lists'),
            if (rest.isNotEmpty) grid(rest),
          ],
        );
      },
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.l, Sp.l, Sp.l, Sp.s),
      child: Semantics(header: true, child: Text(text, style: context.type.bodyStrong(c.ink2))),
    );
  }
}

/// A list in the index: kind icon, title, open count with top stores, and when it's for.
class ListCard extends StatelessWidget {
  const ListCard(this.lv, {super.key});
  final ListState lv;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(listReads);
    final c = context.colors;
    final timing = listTiming(app, lv);
    return Material(
      color: c.paper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.control),
        side: BorderSide(color: c.rule),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.control),
        onTap: () => context.push('/lists/${lv.list.id}'),
        child: Padding(
          padding: const EdgeInsets.all(Sp.l),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(Pictograms.listKind(lv.list.kind), size: 24, color: c.ink2),
              ),
              const SizedBox(width: Sp.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(lv.list.title, style: context.type.title(c.ink), maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                      listSummary(lv),
                      style: context.type.meta(c.ink2),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (timing != null) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (timing.late) ...[
                            Icon(PhosphorIconsFill.clockCountdown, size: 14, color: c.bad),
                            const SizedBox(width: Sp.xs),
                          ],
                          Flexible(
                            child: Text(
                              timing.text,
                              style: context.type.meta(timing.late ? c.bad : c.ink2),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
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
