import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/forms/forms.dart' show Hang;
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/sheet.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../state/list_actions.dart';
import '../state/lists_model.dart';
import '../words/list_words.dart';

/// One list's content (Lists.dc.html): when it's needed by, the one add field ("2 milk
/// @Costco, eggs"), the open items (on a shopping list grouped by store, with store chips to
/// show one), and what's done ("In the cart") with Clear. Checking is one tap; adding, removing,
/// clearing and "Add to groceries" each say what they did in place, with Undo.
class ListContent extends StatefulWidget {
  const ListContent({super.key, required this.list, this.focusAdd = false});

  final ListState list;

  /// Opens with the add field focused (Add's "Grocery item").
  final bool focusAdd;

  @override
  State<ListContent> createState() => _ListContentState();
}

/// What a tap did, kept in place with its Undo until the list is left.
class _Note {
  const _Note(this.message, this.receipt);
  final String message;
  final Receipt? receipt;
}

class _ListContentState extends State<ListContent> {
  /// Null shows every store; the empty string the items with none.
  String? _store;
  _Note? _added;
  _Note? _cleared;

  /// Items removed here, by id, with where they were so the note stays in their place.
  final _removed = <String, (Item, _Note)>{};

  /// Meal items just put on the groceries, with their Undo.
  final _sent = <String, _Note>{};

  @override
  void didUpdateWidget(ListContent old) {
    super.didUpdateWidget(old);
    if (old.list.list.id != widget.list.list.id) {
      _store = null;
      _added = null;
      _cleared = null;
      _removed.clear();
      _sent.clear();
    }
  }

  Future<void> _undo(_Note note, VoidCallback forget) async {
    final receipt = note.receipt;
    if (receipt == null) return;
    final result = await perform(context, () => context.actions.undo(receipt));
    if (result != null && mounted) setState(forget);
  }

  Future<bool> _add(String text) async {
    final lv = widget.list;
    final items = parseItems(text, knownStores: DenScope.read(context).den.stores);
    if (items.isEmpty) return false;
    final result = await perform(context, () => context.listActions.addItems(lv.list.id, items));
    if (result == null || !mounted) return false;
    setState(() => _added = _Note('Added ${itemNames(items)}', result.receipt));
    return true;
  }

  Future<void> _remove(Item item) async {
    final result = await perform(context, () => context.listActions.remove(item));
    if (result == null || !mounted) return;
    setState(() => _removed[item.id] = (item, _Note('Removed ${item.text}', result.receipt)));
  }

  Future<void> _clear(int count) async {
    final lv = widget.list;
    final result = await perform(context, () => context.listActions.clearChecked(lv.list.id));
    if (result == null || !mounted) return;
    final n = (result.data['removed'] as int?) ?? count;
    setState(() => _cleared = _Note('Cleared $n done ${n == 1 ? 'item' : 'items'}', result.receipt));
  }

  Future<void> _toGroceries(Item item) async {
    if (groceriesList(DenScope.read(context).den) == null) {
      showNote(context, 'There\'s no shopping list to add to yet. Make one in Lists, then try again.');
      return;
    }
    final result = await perform(context, () => context.listActions.sendToGroceries(item));
    if (result == null || !mounted) return;
    setState(() => _sent[item.id] = _Note('On the groceries', result.receipt));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(listReads);
    final c = context.colors;
    final t = context.text;
    final lv = app.den.list(widget.list.list.id) ?? widget.list;
    final kind = lv.list.kind;
    final canEdit = app.canChangeItems;
    final canCheck = app.allows(DenAction.checkItems);

    final open = [for (final i in lv.items) if (!i.checked) i];
    final done = [for (final i in lv.items) if (i.checked) i];
    final storeOrder = app.den.stores;
    final stores = open.map((i) => i.store ?? '').where((s) => s.isNotEmpty).toSet().toList()
      ..sort((a, b) {
        final ia = storeOrder.indexOf(a), ib = storeOrder.indexOf(b);
        if (ia != ib) return (ia < 0 ? 999 : ia).compareTo(ib < 0 ? 999 : ib);
        return a.compareTo(b);
      });
    final noStore = open.any((i) => (i.store ?? '').isEmpty);
    if (_store != null && _store!.isNotEmpty && !stores.contains(_store)) _store = null;
    if (_store == '' && !noStore) _store = null;
    final byStore = kind == ListKind.shopping && stores.isNotEmpty;

    Widget row(Item item) {
      final removed = _removed[item.id];
      if (removed != null) {
        return KeyedSubtree(
          key: ValueKey('removed:${item.id}'),
          child: DoneRow(
            message: removed.$2.message,
            onUndo: removed.$2.receipt?.undoable == true ? () => _undo(removed.$2, () => _removed.remove(item.id)) : null,
          ),
        );
      }
      return _ItemRow(
        key: ValueKey(item.id),
        item: item,
        kind: kind,
        canCheck: canCheck,
        onRemove: canEdit ? () => _remove(item) : null,
        onEdit: canEdit ? () => _editItem(item) : null,
        sent: _sent[item.id],
        onSend: kind == ListKind.meal && canEdit && !item.toGroceries ? () => _toGroceries(item) : null,
        onUndoSend: _sent[item.id]?.receipt?.undoable == true
            ? () => _undo(_sent[item.id]!, () => _sent.remove(item.id))
            : null,
      );
    }

    // Removed items keep their place, so their note can stand where they were.
    final shown = [
      ...open,
      for (final r in _removed.values)
        if (!lv.items.any((i) => i.id == r.$1.id) && !r.$1.checked) r.$1,
    ]..sort((a, b) => a.order.compareTo(b.order));
    final doneShown = [
      ...done,
      for (final r in _removed.values)
        if (!lv.items.any((i) => i.id == r.$1.id) && r.$1.checked) r.$1,
    ]..sort((a, b) => a.order.compareTo(b.order));

    final groups = <String, List<Item>>{};
    if (byStore) {
      for (final s in [...stores, '']) {
        if (_store != null && _store != s) continue;
        final inStore = [for (final i in shown) if ((i.store ?? '') == s) i];
        if (inStore.isNotEmpty) groups[s] = inStore;
      }
    } else {
      groups[''] = shown;
    }

    final children = <Widget>[];

    if (listTiming(app, lv) case final timing?) {
      children.add(Padding(
        padding: const EdgeInsets.only(bottom: Sp.m),
        child: NoticeLine(
          icon: timing.late ? PhosphorIconsBold.clockCountdown : PhosphorIconsRegular.calendarBlank,
          message: timing.text,
        ),
      ));
    }

    children.add(DisabledReason(
      disabled: !canEdit,
      reason: '${app.me?.name ?? 'You'} can check things off here, but adding needs the lists permission. A parent can turn it on in Family.',
      child: AddItemRow(
        hint: switch (kind) {
          ListKind.shopping => 'Add milk, eggs, 2 lemons',
          ListKind.packing => 'Add sunscreen, 2 towels',
          ListKind.meal => 'Add a meal, like Tacos',
          ListKind.checklist => 'Add something to do',
        },
        enabled: canEdit,
        autofocus: widget.focusAdd,
        onAdd: _add,
      ),
    ));
    final added = _added;
    children.add(DenReveal(
      visible: added != null,
      child: added == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: Sp.xs),
              child: DoneRow(
                message: added.message,
                onUndo: added.receipt?.undoable == true ? () => _undo(added, () => _added = null) : null,
              ),
            ),
    ));

    if (byStore && (stores.length > 1 || (stores.isNotEmpty && noStore))) {
      int count(String s) => open.where((i) => (i.store ?? '') == s).length;
      children.add(Padding(
        padding: const EdgeInsets.only(top: Sp.l),
        child: ChipRow(
          inset: 0,
          children: [
            TagChip(label: 'All stores', selected: _store == null, onTap: () => setState(() => _store = null)),
            for (final s in stores)
              TagChip(
                label: '$s ${count(s)}',
                selected: _store == s,
                onTap: () => setState(() => _store = _store == s ? null : s),
              ),
            if (noStore)
              TagChip(
                label: 'Anywhere ${count('')}',
                selected: _store == '',
                onTap: () => setState(() => _store = _store == '' ? null : ''),
              ),
          ],
        ),
      ));
    }

    if (lv.items.isEmpty && _removed.isEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: DenLayout.sectionGap),
        child: GroupCard(
          child: EmptyState(compact: true, message: 'Nothing on ${lv.list.title} yet.'),
        ),
      ));
    } else if (shown.isEmpty && done.isNotEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: DenLayout.sectionGap),
        child: GroupCard(child: EmptyState(compact: true, message: 'Everything on ${lv.list.title} is done.')),
      ));
    }

    for (final e in groups.entries) {
      if (e.value.isEmpty) continue;
      children.add(Padding(
        padding: const EdgeInsets.only(top: DenLayout.sectionGap),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (byStore) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
                child: Semantics(
                  header: true,
                  child: Text(e.key.isEmpty ? 'Anywhere' : e.key, style: t.label(c.ink2)),
                ),
              ),
              const SizedBox(height: DenLayout.headingGap),
            ],
            GroupCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: ruled(e.value.map(row), indent: 42))),
          ],
        ),
      ));
    }

    final cleared = _cleared;
    if (doneShown.isNotEmpty || cleared != null) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: DenLayout.sectionGap),
        child: DoneSwap(
          done: cleared == null || done.isNotEmpty
              ? null
              : GroupCard(
                  child: DoneRow(
                    message: cleared.message,
                    onUndo: cleared.receipt?.undoable == true ? () => _undo(cleared, () => _cleared = null) : null,
                  ),
                ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(start: DenLayout.headingInset),
                child: Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(kind == ListKind.shopping ? 'In the cart' : 'Done', style: t.label(c.ink2)),
                      ),
                    ),
                    if (canEdit && done.isNotEmpty)
                      TextButton(
                        onPressed: () => _clear(done.length),
                        child: Text('Clear ${done.length}'),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: Sp.xs),
              GroupCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: ruled(doneShown.map(row), indent: 42))),
            ],
          ),
        ),
      ));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  Future<void> _editItem(Item item) => showDenSheet<void>(
        context,
        builder: (_) => _ItemSheet(item: item, kind: widget.list.list.kind, onRemove: () => _remove(item)),
      );
}

/// One item: a 28 pt ring, the words, and the quantity at the end; done is a filled ring and
/// struck words. A tap checks it; a long press (or a screen reader's action) edits it, and a
/// swipe removes it. On a meal plan, "Add to groceries" at the end.
class _ItemRow extends StatelessWidget {
  const _ItemRow({
    super.key,
    required this.item,
    required this.kind,
    required this.canCheck,
    required this.onRemove,
    required this.onEdit,
    required this.sent,
    required this.onSend,
    required this.onUndoSend,
  });

  final Item item;
  final ListKind kind;
  final bool canCheck;
  final VoidCallback? onRemove;
  final VoidCallback? onEdit;
  final _Note? sent;
  final VoidCallback? onSend;
  final VoidCallback? onUndoSend;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final checked = item.checked;
    final qty = item.qty ?? '';
    final by = checked ? DenScope.read(context).memberById(item.checkedBy)?.name : null;
    final trailing = checked ? (by ?? '') : qty;
    final meal = kind == ListKind.meal && !checked;

    Widget end;
    if (kind == ListKind.meal && (item.toGroceries || sent != null)) {
      end = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(PhosphorIconsBold.check, size: 16, color: c.ink2),
          const SizedBox(width: Sp.xs),
          Text('On groceries', style: t.meta(c.ink2)),
          if (onUndoSend != null) UndoButton(onTap: onUndoSend),
        ],
      );
    } else if (onSend != null && !checked) {
      end = TextButton(onPressed: onSend, child: const Text('Add to groceries', maxLines: 1, softWrap: false));
    } else {
      end = trailing.isEmpty ? const SizedBox.shrink() : Text(trailing, style: t.meta(c.ink2));
    }

    final row = Semantics(
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Edit item'): ?onEdit,
        const CustomSemanticsAction(label: 'Remove item'): ?onRemove,
      },
      child: DenPressable(
        onTap: canCheck ? () => attempt(context, () => context.listActions.setChecked(item, !checked)) : null,
        onLongPress: onEdit,
        scale: false,
        haptic: true,
        toggled: checked,
        semanticLabel: qty.isEmpty ? item.text : '${item.text}, $qty',
        shape: const RoundedRectangleBorder(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Row(
            children: [
              // Lists are nobody's color: a quiet ink ring, filled when done (Lists.dc.html).
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: checked ? c.ink2 : null,
                  border: checked ? null : Border.all(color: c.ink2, width: 2),
                ),
                child: checked ? Icon(PhosphorIconsBold.check, size: 17, color: c.card) : null,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Sp.s),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ExcludeSemantics(
                        child: Text(
                          tidy(item.text),
                          style: t.body(checked ? c.ink2 : c.ink).copyWith(
                                decoration: checked ? TextDecoration.lineThrough : null,
                                decorationColor: c.ink2,
                              ),
                        ),
                      ),
                      // A meal's groceries action goes under its name, so the name keeps the
                      // row's width.
                      if (meal) Hang(by: onSend == null ? 0 : 12, child: end),
                    ],
                  ),
                ),
              ),
              if (!meal) ...[
                const SizedBox(width: Sp.s),
                ExcludeSemantics(child: end),
              ],
            ],
          ),
        ),
      ),
    );
    if (onRemove == null) return row;
    return Dismissible(
      key: ValueKey('dismiss-${item.id}'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onRemove!(),
      background: ColoredBox(
        color: c.destructive,
        child: Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.l),
            child: Text('Remove', style: t.label(c.onPrimary)),
          ),
        ),
      ),
      child: row,
    );
  }
}

/// The one add field: what to add, read by [parseItems] ("2 milk @Costco, eggs"), and the
/// round Add button. Return adds and keeps the keyboard up.
class AddItemRow extends StatelessWidget {
  const AddItemRow({super.key, required this.hint, required this.onAdd, this.enabled = true, this.autofocus = false});

  final String hint;
  final Future<bool> Function(String text) onAdd;
  final bool enabled;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => InlineAdd(hint: hint, onAdd: onAdd, enabled: enabled, autofocus: autofocus);
}

/// Change an item's words, quantity or store, or remove it.
class _ItemSheet extends StatefulWidget {
  const _ItemSheet({required this.item, required this.kind, required this.onRemove});
  final Item item;
  final ListKind kind;
  final VoidCallback onRemove;

  @override
  State<_ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends State<_ItemSheet> {
  late final _text = TextEditingController(text: widget.item.text);
  late final _qty = TextEditingController(text: widget.item.qty ?? '');
  late final _store = TextEditingController(text: widget.item.store ?? '');
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    _qty.dispose();
    _store.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final text = _text.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'An item needs words. To get rid of it, remove it instead.');
      return;
    }
    final nav = Navigator.of(context);
    final ok = await attempt(
      context,
      () => context.listActions.edit(
        widget.item,
        text: text,
        qty: _qty.text.trim().isEmpty ? null : _qty.text.trim(),
        store: _store.text.trim().isEmpty ? null : _store.text.trim(),
      ),
    );
    if (ok) nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final shopping = widget.kind == ListKind.shopping;
    final withQty = widget.kind == ListKind.shopping || widget.kind == ListKind.packing;
    Widget field(String label, TextEditingController controller, {bool autofocus = false, TextCapitalization caps = TextCapitalization.sentences}) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.l, 0, Sp.xs),
              child: Text(label, style: t.meta(c.ink2)),
            ),
            TextField(
              controller: controller,
              autofocus: autofocus,
              textCapitalization: caps,
              style: t.body(c.ink),
              onSubmitted: (_) => _save(),
            ),
          ],
        );
    return Padding(
      padding: EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.xl + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.xs, 0, 0),
            child: Semantics(header: true, child: Text('Edit item', style: t.sheetTitle(c.ink))),
          ),
          field('Item', _text, autofocus: true),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: Sp.xs),
              child: Text(_error!, style: t.meta(c.destructive)),
            ),
          Row(
            children: [
              if (withQty) Expanded(child: field('How many', _qty)),
              if (withQty && shopping) const SizedBox(width: Sp.s),
              if (shopping) Expanded(flex: 2, child: field('Store', _store, caps: TextCapitalization.words)),
            ],
          ),
          const SizedBox(height: Sp.xl),
          Row(
            children: [
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: c.destructive),
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onRemove();
                },
                icon: const Icon(PhosphorIconsRegular.trash, size: 20),
                label: const Text('Remove'),
              ),
              const Spacer(),
              FilledButton(onPressed: _save, child: const Text('Save')),
            ],
          ),
        ],
      ),
    );
  }
}
