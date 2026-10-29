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
/// how many things are on it, which opens it. The add field reads like the list's own ("2 milk
/// @Costco, eggs") and shows where new things go as a store chip, which stays as picked for the
/// next ones. What was just added shows under the field, with Undo. With no shopping list yet,
/// the first thing added makes one.
class TodayGroceries extends StatefulWidget {
  const TodayGroceries({super.key});

  @override
  State<TodayGroceries> createState() => _TodayGroceriesState();
}

class _TodayGroceriesState extends State<TodayGroceries> {
  (String, Receipt?)? _added;

  /// Where new things go; null is any store.
  String? _store;

  Future<bool> _add(AppState app, String text) async {
    final actions = context.listActions;
    final read = parseItems(text, knownStores: app.den.stores);
    if (read.isEmpty) return false;
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
    final to = _store;
    final items = [for (final i in read) (text: i.text, qty: i.qty, store: i.store ?? to)];
    final result = await perform(context, () => actions.addItems(id, items));
    if (result == null || !mounted) return false;
    // "@Costco" moves the chip, so the next things go there too.
    final typed = read.lastWhere((i) => i.store != null, orElse: () => read.last).store;
    final stores = {for (final i in items) i.store};
    final at = stores.length == 1 && stores.single != null ? ' at ${stores.single}' : '';
    setState(() {
      if (typed != null) _store = typed;
      _added = ('Added ${itemNames(read)} to $title$at', result.receipt);
    });
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
            child: AddItemRow(
              hint: 'Add to ${list?.list.title.toLowerCase() ?? 'groceries'}',
              enabled: canAdd,
              onAdd: (text) => _add(app, text),
              stores: app.den.stores,
              store: _store,
              onStore: (store) => setState(() => _store = store),
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
