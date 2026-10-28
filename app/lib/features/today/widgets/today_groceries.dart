import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_state.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../lists/lists.dart';
import '../state/today_model.dart';
import '../words/today_words.dart';

/// Groceries on Today (Main.dc.html): add to the family's shopping list without leaving, and
/// how many things are on it, which opens it. What was just added shows under the field, with
/// Undo. With no shopping list yet, the first thing added makes one.
class TodayGroceries extends StatefulWidget {
  const TodayGroceries({super.key});

  @override
  State<TodayGroceries> createState() => _TodayGroceriesState();
}

class _TodayGroceriesState extends State<TodayGroceries> {
  (String, Receipt?)? _added;

  Future<bool> _add(AppState app, String text) async {
    final actions = context.listActions;
    var list = groceriesList(app.den);
    if (list == null) {
      final made = await perform(
        context,
        () => actions.save(
          null,
          title: 'Groceries',
          kind: ListKind.shopping,
          lifecycle: ListLifecycle.running,
          needBy: null,
          event: null,
          pinned: true,
        ),
      );
      if (made == null || !mounted) return false;
      list = groceriesList(app.den);
      if (list == null) return false;
    }
    final id = list.list.id;
    final title = list.list.title;
    final result = await perform(context, () => actions.addItem(id, text));
    if (result == null || !mounted) return false;
    setState(() => _added = ('Added $text to $title', result.receipt));
    return true;
  }

  Future<void> _undo(Receipt receipt) async {
    final result = await perform(context, () => context.actions.undo(receipt));
    if (result != null && mounted) setState(() => _added = null);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(todayReads);
    final list = groceriesList(app.den);
    final canAdd = app.canChangeItems;
    final added = _added;
    final receipt = added?.$2;
    return DenSection(
      title: list?.list.title ?? 'Groceries',
      carded: false,
      trailing: SectionLink(
        itemCount(list?.open ?? 0),
        semanticLabel: 'Open ${list?.list.title ?? 'lists'}',
        onTap: () => list == null ? context.go('/lists') : context.push('/lists/${list.list.id}'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DisabledReason(
            disabled: !canAdd,
            reason: '${app.me?.name ?? 'You'} can\'t change lists here. A parent can change that in Family.',
            child: InlineAdd(
              hint: 'Add to ${list?.list.title.toLowerCase() ?? 'groceries'}',
              enabled: canAdd,
              onAdd: (text) => _add(app, text),
            ),
          ),
          DenReveal(
            visible: added != null,
            child: added == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Sp.xs),
                    child: DoneRow(
                      message: added.$1,
                      onUndo: receipt != null && receipt.undoable ? () => _undo(receipt) : null,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
